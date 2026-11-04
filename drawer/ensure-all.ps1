# ensure-all.ps1 — 兜底巡检（计划任务每 2 分钟跑一次）
#
# 为什么需要它：抽屉/代理/看门狗任一进程都可能被外力杀掉或假死（实测 2026-11-03 19:50
# 代理与看门狗一起消失，抽屉还在，于是点图标退化成"AHK 自己 Run"→ 鹰角启动器报
# Load launcher failed；控制台面板报"本地代理没有响应"）。
# 这个脚本不做任何等待，只补缺失的三件套，日志只记动作。
#
# 判定与 agent-watch.ps1 一致：pid 活着 + 心跳 ≤45s + 17433 能连上。

$ErrorActionPreference = 'SilentlyContinue'

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

function AgentHealthy {
    if (-not (Test-Path $agentHbF)) { return $false }
    $age = ((Get-Date) - (Get-Item $agentHbF).LastWriteTime).TotalSeconds
    if ($age -gt 45) { return $false }
    return (TestPort 17433 400)
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
    try { Remove-Item $queueFile -Force -ErrorAction SilentlyContinue } catch { }
    foreach ($ln in $qlines) {
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
