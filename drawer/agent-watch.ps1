# agent-watch.ps1 — DSH 本地代理（dsh-agent.ps1）的看门狗。
#
# 为什么需要它：代理是单线程 HttpListener 循环，偶发"进程在、端口在、就是不回包"的假死；
# 从抽屉（AutoHotkey）里拉起代理不行——实测 AHK 当祖先时子进程 New-Object System.Net.HttpListener
# 会抛"此平台上不支持操作"，代理根本起不来；而 medium 权限的抽屉跑 schtasks /run 又是"拒绝访问"。
# 所以由一个独立的、由 start-all.vbs 拉起（没有 AHK 祖先）的脚本负责杀+重启。
#
# 判定：三件事同时成立才算健康 —— pid 活着、心跳文件新鲜（≤45s）、17433 端口能连上。
param(
    # 5 秒一轮：代理假死到重启的窗口越短，抽屉点图标越不容易撞上"等待队列"
    [int]$IntervalSec = 5,
    [int]$MaxHbAgeSec = 45,
    [int]$Port = 17433
)

$ErrorActionPreference = 'SilentlyContinue'

$appDir = Join-Path $env:LOCALAPPDATA 'DesktopPage'
$logFile = Join-Path $appDir 'agent-watch.log'
$pidFile = Join-Path $appDir 'agent-watch.pid'
$agentPidFile = Join-Path $appDir 'dsh-agent.pid'
$agentHbFile = Join-Path $appDir 'dsh-agent.hb'
$agentScript = Join-Path $appDir 'dsh-agent.ps1'

function Watch-Log([string]$msg) {
    $line = (Get-Date).ToString('MM-dd HH:mm:ss') + '  ' + $msg
    try {
        if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -gt 256KB)) {
            [System.IO.File]::WriteAllText($logFile, '')
        }
        [System.IO.File]::AppendAllText($logFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# 单实例：重复启动（start-all.vbs 每次可能都拉一次）直接退出
$mtx = New-Object System.Threading.Mutex($false, 'Global\DesktopPage_agentwatch')
if (-not $mtx.WaitOne(0)) { exit 0 }
try { [System.IO.File]::WriteAllText($pidFile, [string]$PID) } catch { }
Watch-Log ("watch: start pid=" + $PID + " interval=" + $IntervalSec + "s")

function Get-AgentPid {
    try {
        if (Test-Path $agentPidFile) {
            $t = ([System.IO.File]::ReadAllText($agentPidFile)).Trim()
            if ($t -match '^\d+$') { return [int]$t }
        }
    } catch { }
    return 0
}

function Test-HbFresh {
    try {
        if (-not (Test-Path $agentHbFile)) { return $false }
        $age = ((Get-Date) - (Get-Item $agentHbFile).LastWriteTime).TotalSeconds
        return ($age -le $MaxHbAgeSec)
    } catch { return $false }
}

function Test-PortOpen([int]$p, [int]$ms) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect('127.0.0.1', $p, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($ms) -and $c.Connected) { return $true }
        return $false
    } catch { return $false } finally { try { $c.Close() } catch { } }
}

function Start-Agent {
    # 用 CreateProcess(CREATE_NO_WINDOW) 拉起：PowerShell 立刻返回，也不会有控制台窗口。
    # 原来走 cmd.exe /c start + -WindowStyle Hidden：这台机器默认终端是 Windows Terminal，
    # Hidden 对 WT 宿主无效，每次重启代理都会闪出一个空的「管理员:」终端窗并堆 OpenConsole。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $agentScript + '"')) -join ' ')
    $psi.WorkingDirectory = $appDir
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try { [void][System.Diagnostics.Process]::Start($psi) }
    catch { Watch-Log ('watch: start agent FAILED err=' + $_.Exception.Message) }
}

$queueFile = Join-Path $appDir 'launch-queue.txt'
# 5 分钟内排队的点击仍然有意义（抽屉在代理假死期间排的队）；超过就丢，避免"日志里点过、十分钟后才莫名启动"
$queueMaxAgeSec = 300

function Invoke-LaunchQueue {
    if (-not (Test-Path $queueFile)) { return }
    $qlines = @()
    try { $qlines = [System.IO.File]::ReadAllLines($queueFile) } catch { }
    try { Remove-Item $queueFile -Force -ErrorAction SilentlyContinue } catch { }
    foreach ($ln in $qlines) {
        $v = $ln.Trim()
        if ($v -eq '') { continue }
        $ts = 0; $p = $v
        if ($v.Contains('|')) {
            $parts = $v.Split('|', 2)
            [void][int]::TryParse($parts[0], [ref]$ts)
            $p = $parts[1]
        }
        $age = -1
        if ($ts -gt 0) { $age = ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $ts) }
        if (($ts -gt 0) -and ($age -gt $queueMaxAgeSec)) { Watch-Log ('watch: dropped stale launch queue (' + $age + 's): ' + $p); continue }
        try {
            # 交给 explorer 启动：CreateProcess 立刻返回，不会把看门狗自己阻塞几秒
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $p + '"') | Out-Null
            Watch-Log ('watch: queued launch ' + $p)
        } catch {
            Watch-Log ('watch: queued launch FAILED ' + $p + ' err=' + $_.Exception.Message)
        }
    }
}

$fails = 0
$tick = 0
while ($true) {
    Start-Sleep -Seconds 1
    $tick++
    Invoke-LaunchQueue
    if (($tick % $IntervalSec) -ne 0) { continue }
    if (($tick % 300) -eq 0) { Watch-Log ('watch: alive pid=' + $PID + ' fails=' + $fails) }
    $pid2 = Get-AgentPid
    $alive = $false
    if ($pid2 -gt 0) { $alive = [bool](Get-Process -Id $pid2 -ErrorAction SilentlyContinue) }
    $hb = Test-HbFresh
    $portOk = Test-PortOpen $Port 400

    if ($alive -and $hb -and $portOk) {
        if ($fails -ge 2) { Watch-Log 'watch: agent healthy again' }
        $fails = 0
        continue
    }

    $fails++
    Watch-Log ('watch: agent unhealthy #' + $fails + ' pid=' + $pid2 + ' alive=' + $alive + ' hb=' + $hb + ' port=' + $portOk)
    if ($fails -lt 2) { continue }

    if ($pid2 -gt 0) {
        & taskkill.exe /PID $pid2 /T /F 2>&1 | Out-Null
        $t0 = [Environment]::TickCount
        while ((([Environment]::TickCount - $t0) -lt 5000) -and (Get-Process -Id $pid2 -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 200
        }
        $stillAlive = [bool](Get-Process -Id $pid2 -ErrorAction SilentlyContinue)
        Watch-Log ('watch: kill pid=' + $pid2 + ' ok=' + (-not $stillAlive))
        if ($stillAlive) { Watch-Log 'watch: kill FAILED, giving up this round'; $fails = 1; continue }
    }

    if (-not (Test-Path $agentScript)) { Watch-Log ('watch: agent script missing: ' + $agentScript); continue }
    Start-Agent
    $t0 = [Environment]::TickCount
    $ok = $false
    while ((([Environment]::TickCount - $t0) -lt 25000)) {
        Start-Sleep -Milliseconds 500
        if ((Test-HbFresh) -and (Test-PortOpen $Port 300)) { $ok = $true; break }
    }
    $verdict = 'FAILED'
    if ($ok) { $verdict = 'ok' }
    Watch-Log ('watch: restart ' + $verdict + ' pid=' + (Get-AgentPid))
    $fails = 0
}