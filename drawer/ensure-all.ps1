# ensure-all.ps1 — 兜底巡检（计划任务每 2 分钟跑一次）
#
# 为什么需要它：抽屉/代理/看门狗任一进程都可能被外力杀掉或假死（实测 2026-11-03 19:50
# 代理与看门狗一起消失，抽屉还在，于是点图标退化成"AHK 自己 Run"→ 鹰角启动器报
# Load launcher failed；控制台面板报"本地代理没有响应"）。
# 这个脚本不做任何等待，只补缺失的三件套，日志只记动作。
#
# 判定与 agent-watch.ps1 一致：pid 活着 + 心跳 ≤45s + 代理端口能连上。
# 端口只在 agent-config.ps1 里定义。

$ErrorActionPreference = 'SilentlyContinue'
$cfg = Join-Path $PSScriptRoot 'agent-config.ps1'
$AgentPort = 17433
if (Test-Path $cfg) { . $cfg }

$appDir      = Join-Path $env:LOCALAPPDATA 'DesktopPage'
$logFile     = Join-Path $appDir 'ensure-all.log'
$ahkExe      = Join-Path $appDir 'AutoHotkey64.exe'
$ahkScript   = Join-Path $appDir 'DesktopPage.ahk'
$agentScript = Join-Path $appDir 'dsh-agent.ps1'
$watchScript = Join-Path $appDir 'agent-watch.ps1'
$agentPidF   = Join-Path $appDir 'dsh-agent.pid'
$watchPidF   = Join-Path $appDir 'agent-watch.pid'
$agentHbF    = Join-Path $appDir 'dsh-agent.hb'
$drawerPidF  = Join-Path $appDir 'drawer.pid'

function Log([string]$msg) {
    $line = (Get-Date).ToString('MM-dd HH:mm:ss') + '  ' + $msg
    try {
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 256KB)) {
            [System.IO.File]::WriteAllText($logFile, '')
        }
        [System.IO.File]::AppendAllText($logFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function ReadPid([string]$path) {
    try {
        if (Test-Path $path) {
            $t = ([System.IO.File]::ReadAllText($path)).Trim()
            if ($t -match '^\d+') { return [int](($t -split '\|')[0]) }
        }
    } catch { }
    return 0
}

function ProcAlive([int]$procId) {
    if ($procId -le 0) { return $false }
    return [bool](Get-Process -Id $procId -ErrorAction SilentlyContinue)
}

function TestPort([int]$p, [int]$ms) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect('127.0.0.1', $p, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($ms) -and $c.Connected) { return $true }
        return $false
    } catch { return $false } finally { try { $c.Close() } catch { } }
}

function StartHidden([string]$exe, [string[]]$argv) {
    # 起一个完全没有控制台的进程（等价于 cmd /c start 的 CreateProcess 效果，但绝不带控制台窗口）。
    # 为什么不用 cmd /c start + -WindowStyle Hidden：这台机器的默认终端是 Windows Terminal，
    # -WindowStyle Hidden 对 WT 宿主无效 —— 每次重启代理/看门狗都会闪出一个空的「管理员:」终端窗，
    # 还会在 conhost 下堆积几十个 OpenConsole.exe。CreateProcess(CREATE_NO_WINDOW) 才是干净的。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    if ($argv -and $argv.Count -gt 0) { $psi.Arguments = ($argv -join ' ') }
    $psi.WorkingDirectory = $appDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try {
        [void][System.Diagnostics.Process]::Start($psi)
        return $true
    } catch {
        Log ('ensure: spawn failed ' + $exe + ' err=' + $_.Exception.Message)
        return $false
    }
}

function StartHiddenCmd([string]$cmdline) {
    # 用 cmd.exe /c 起进程，唯一目的是能把子进程的 stderr 重定向到文件 ——
    # 桥解析级死亡（丢 BOM / 语法错）时进程一条日志都写不出来，stderr 是唯一线索。
    # 必须 ShellExecute：子进程不能继承本脚本的 stdout 管道，否则桥（长期进程）会一直
    # 占着句柄，任何「用管道读 ensure-all 输出」的调用方都会挂到桥退出（2026-11-14 实测）。
    # WindowStyle Hidden 保证不闪控制台（2026-11-03 的教训见 StartHidden 注释）。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = $cmdline
    $psi.WorkingDirectory = $appDir
    $psi.UseShellExecute = $true
    $psi.WindowStyle = 'Hidden'
    try {
        [void][System.Diagnostics.Process]::Start($psi)
        return $true
    } catch {
        Log ('ensure: cmd spawn failed err=' + $_.Exception.Message)
        return $false
    }
}

function AgentHealthy {
    if (-not (Test-Path $agentHbF)) { return $false }
    $age = ((Get-Date) - (Get-Item $agentHbF).LastWriteTime).TotalSeconds
    if ($age -gt 45) { return $false }
    return (TestPort $AgentPort 400)
}

# ---- 抽屉存活判定 ----
# 用 FindWindow 找抽屉自己的 Gui（类 AutoHotkeyGUI / 标题 DesktopPage）：
# 窗口隐藏时也能找到，而且诊断脚本（probe 也是 AutoHotkey64）不会被误判成抽屉。
# 教训：2026-11-03 20:05 只按进程名判断，导致"抽屉还活着"被判成"已死"，
# 于是又起了一个实例，旧实例被 #SingleInstance 顶掉，用户看到抽屉自己闪退。
function InitNative {
    if ('EnsNative' -as [type]) { return }
    Add-Type -Namespace Ens -Name Native -MemberDefinition @"
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
"@
}

function DrawerAlive {
    InitNative
    try {
        if ([Ens.Native]::FindWindowW('AutoHotkeyGUI', 'DesktopPage') -ne [IntPtr]::Zero) { return $true }
    } catch { }
    # 兜底一：drawer.pid 里的进程还活着且确实是 AutoHotkey64
    $dp = ReadPid $drawerPidF
    if (ProcAlive $dp) {
        $nm = ''
        try { $nm = (Get-Process -Id $dp).ProcessName } catch { }
        if ($nm -like 'AutoHotkey*') { return $true }
    }
    return $false
}

# 互斥体还在 = 进程还持有它（比 pid 文件可靠：文件可能被清理/被别的程序写坏）
function Test-Mutex([string]$name) {
    try {
        $m = [System.Threading.Mutex]::OpenExisting($name)
        $m.Dispose()
        return $true
    } catch { return $false }
}

# 1) 抽屉
if (-not (DrawerAlive)) {
    if ((Test-Path $ahkExe) -and (Test-Path $ahkScript)) {
        StartHidden $ahkExe @(('"' + $ahkScript + '"'))
        Log 'ensure: drawer was down, started'
    } else {
        Log 'ensure: drawer down and files missing'
    }
}

# 1b) 滚轮桥（wheel-bridge.ps1 → 由 powershell.exe 承载）
# 为什么要有它：本机 AHK 进程的鼠标通道会整条哑掉（WheelDown/WheelUp 热键不触发、
# WM_INPUT 一条都收不到），而同一时刻普通 .NET 进程装 WH_MOUSE_LL 能稳定收到滚轮
# （2026-11-04 23:2x 对照实测）。编译成 exe 的同一份代码反而收不到事件，
# 所以桥由 powershell.exe 承载（23:44–23:50 三组对照）。
#
# 存活判定（2026-11-13 事故后重写）：旧实现找「命令行里含 wheel-bridge.ps1 的 powershell」，
# 探针/自检命令会误匹配；更糟的是桥解析级死亡时压根没有进程可匹配 —— 于是每天每 2 分钟
# 「正确地拉起一个必死的桥」，35 小时没人知道（桥日志零新行）。现在只看桥自己持有的
# 互斥体 Local\DshWheelBridge（probe 不持有它），再用心跳判卡死：
#   互斥体不在            → 拉起，并把 stderr 重定向留痕 + 6 秒内复查是否真起来
#   互斥体在但心跳 >180s  → 卡死，按 pid 文件 T 掉，下一轮重拉
$bridgeScript = Join-Path $appDir 'wheel-bridge.ps1'
$bridgeErr    = Join-Path $appDir 'wheel-bridge-launch.err'
$bridgeBoot   = Join-Path $appDir 'wheel-bridge-boot.log'
$bridgePidF   = Join-Path $appDir 'wheel-bridge.pid'
$bridgeLog    = Join-Path $appDir 'wheel-bridge.log'
if (Test-Path $bridgeScript) {
    $ageBeat = -1
    if (Test-Path $bridgeLog) { $ageBeat = [int]((Get-Date) - (Get-Item $bridgeLog).LastWriteTime).TotalSeconds }
    # 先判互斥体（唯一可信的判活依据）；若互斥体在但 beat 太老 = 卡死，杀掉并当场重启，
    # 不把恢复留给下一轮（下一次 ensure 最多要等 2 分钟，这段时间滚轮是哑的 —— 2026-11-14 实测）。
    $needStart = -not (Test-Mutex 'Local\DshWheelBridge')
    if (-not $needStart -and $ageBeat -gt 180) {
        $bp = ReadPid $bridgePidF
        if ($bp -gt 0 -and (ProcAlive $bp)) {
            & taskkill.exe /PID $bp /T /F 2>&1 | Out-Null
            Log ('ensure: wheel-bridge hung (no beat ' + $ageBeat + 's), killed pid=' + $bp)
        } else {
            Log ('ensure: wheel-bridge hung (no beat ' + $ageBeat + 's) but pid file missing/stale')
        }
        $needStart = $true
    }
    if ($needStart) {
        $bootBefore = 0
        if (Test-Path $bridgeBoot) { $bootBefore = (Get-Item $bridgeBoot).Length }
        try { [IO.File]::WriteAllText($bridgeErr, '') } catch { }
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        # cmd 命令串：无外层引号 + 末尾 >NUL。这是实测唯一能同时做到「stderr 进文件」和
        # 「不挂住调用方」的写法（外层引号形式 cmd 会误解析，stderr 文件根本不生成）。
        if ($psExe -match ' ' -or $bridgeScript -match ' ' -or $bridgeErr -match ' ') {
            Log 'ensure: wheel-bridge launch skipped (path contains space; stderr capture unsupported)'
            $cmd = $null
        } else {
            $cmd = '/c ' + $psExe + ' -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $bridgeScript + '" 2>"' + $bridgeErr + '" >NUL'
        }
        if ($cmd -and (StartHiddenCmd $cmd)) {
            $t0 = [Environment]::TickCount
            $up = $false
            while ((([Environment]::TickCount - $t0) -lt 6000)) {
                Start-Sleep -Milliseconds 300
                if (Test-Mutex 'Local\DshWheelBridge') { $up = $true; break }
            }
            if ($up) {
                Log ('ensure: wheel-bridge was down, started (mutex up, previous beat age ' + $ageBeat + 's)')
            } else {
                $why = ''
                # stderr 的编码取决于子进程启动时的控制台代码页（实测两种都出现过：
                # UTF-8 与 936/GBK）。先按严格 UTF-8 解，解不开再按 936 解，才能保证留痕可读。
                try {
                    if (Test-Path $bridgeErr) {
                        $bytes = [IO.File]::ReadAllBytes($bridgeErr)
                        $strict = New-Object System.Text.UTF8Encoding($false, $true)
                        try { $why = $strict.GetString($bytes) }
                        catch { $why = [Text.Encoding]::GetEncoding(936).GetString($bytes) }
                        $why = $why -replace '\s+', ' '
                    }
                } catch { }
                $why = $why.Trim()
                if ($why.Length -gt 240) { $why = $why.Substring(0, 240) + '…' }
                $bootNow = 0
                if (Test-Path $bridgeBoot) { $bootNow = (Get-Item $bridgeBoot).Length }
                $phase = 'died before its first line (BOM/encoding/parse)'
                if ($bootNow -gt $bootBefore) { $phase = 'died after boot line (Add-Type/mutex/window)' }
                Log ('ensure: wheel-bridge FAILED to start - ' + $phase + '; stderr=' + $why)
            }
        }
    }

} else {
    Log 'ensure: wheel-bridge.ps1 missing'
}

# 2) 看门狗
$watchPid = ReadPid $watchPidF
$watchAlive = (ProcAlive $watchPid) -or (Test-Mutex 'Global\DesktopPage_agentwatch')
if (-not $watchAlive) {
    if (Test-Path $watchScript) {
        StartHidden 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $watchScript + '"'))
        Log ('ensure: watch was down (pid=' + $watchPid + '), started')
    } else {
        Log 'ensure: agent-watch.ps1 missing'
    }
}

# 3) 代理
$agentPid = ReadPid $agentPidF
$agentOk = (ProcAlive $agentPid) -and (AgentHealthy)
if (-not $agentOk) {
    if (ProcAlive $agentPid) {
        & taskkill.exe /PID $agentPid /T /F 2>&1 | Out-Null
        $t0 = [Environment]::TickCount
        while ((([Environment]::TickCount - $t0) -lt 4000) -and (ProcAlive $agentPid)) { Start-Sleep -Milliseconds 200 }
        Log ('ensure: agent unhealthy (pid=' + $agentPid + ' alive=' + (ProcAlive $agentPid) + '), killed')
    }
    if (Test-Path $agentScript) {
        StartHidden 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + $agentScript + '"'))
        $t0 = [Environment]::TickCount
        $ok = $false
        while ((([Environment]::TickCount - $t0) -lt 20000)) {
            Start-Sleep -Milliseconds 500
            if (AgentHealthy) { $ok = $true; break }
        }
        $v = 'FAILED'
        if ($ok) { $v = 'ok' }
        Log ('ensure: agent restart ' + $v + ' pid=' + (ReadPid $agentPidF))
    } else {
        Log 'ensure: dsh-agent.ps1 missing'
    }
}
# 4) 启动队列：抽屉点图标时代理不在 → 它写 launch-queue.txt 而不是让 AHK 自己 Run
#    （AHK 祖先会让鹰角启动器报 Load launcher failed）。看门狗通常 1 秒内就处理了；
#    这里处理"看门狗也死了"的情形，阈值放宽到 3 分钟，超过就丢弃并记日志。
$queueFile = Join-Path $appDir 'launch-queue.txt'
if (Test-Path $queueFile) {
    $qlines = @()
    try { $qlines = [System.IO.File]::ReadAllLines($queueFile) } catch { }
    # 同 agent-watch.ps1：删掉才算消费。本脚本没有设 $ErrorActionPreference（默认 Continue），
    # 所以 Remove-Item -ErrorAction SilentlyContinue 失败时既抛不出去也不记日志 ——
    # 队列文件留着，下一轮（2 分钟后）把同一批路径再启动一遍。
    $consumed = $false
    try { [System.IO.File]::Delete($queueFile) } catch { }
    if (-not (Test-Path $queueFile)) {
        $consumed = $true
    } else {
        try { [System.IO.File]::WriteAllText($queueFile, '') } catch { }
        $left = Get-Item $queueFile -ErrorAction SilentlyContinue
        if (-not $left -or $left.Length -le 0) { $consumed = $true }
    }
    if (-not $consumed) { Log 'ensure: launch queue busy (delete failed), skipped this round' }
    foreach ($ln in $(if ($consumed) { $qlines } else { @() })) {
        $v = $ln.Trim()
        if ($v -eq '') { continue }
        $ts = 0; $p = $v
        if ($v.Contains('|')) { $parts = $v.Split('|', 2); [void][int]::TryParse($parts[0], [ref]$ts); $p = $parts[1] }
        $age = -1
        if ($ts -gt 0) { $age = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $ts) }
        if (($ts -gt 0) -and ($age -gt 600)) { Log ('ensure: dropped stale launch queue (' + $age + 's): ' + $p); continue }
        # 交给 explorer 启动：CreateProcess 立刻返回，不会把这个看门狗进程也拖住几秒
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $p + '"') | Out-Null; Log ('ensure: queued launch ' + $p) }
        catch { Log ('ensure: queued launch FAILED ' + $p + ' err=' + $_.Exception.Message) }
    }
}
