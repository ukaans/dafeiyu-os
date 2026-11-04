<#
  大肥鱼桌面系统 自检脚本
  用法：powershell -ExecutionPolicy Bypass -File .\verify.ps1 [-InstallDir <安装目录>]
  检查：文件齐全 → 抽屉/代理/看门狗进程 → 代理心跳与端口 → HTTP 接口 → 日志健康
  退出码 = 失败项数量（0 表示全通过）
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'DesktopPage')
)
$fail = 0
function Ok([string]$m)   { Write-Host ("[ OK ] " + $m) -ForegroundColor Green }
function Bad([string]$m)  { Write-Host ("[FAIL] " + $m) -ForegroundColor Red; $script:fail++ }
function Info([string]$m) { Write-Host ("[info] " + $m) }

function Test-Tcp([int]$port, [int]$ms = 400) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($ms)) { $c.Close(); return $false }
        $c.EndConnect($ar); $c.Close(); return $true
    } catch { return $false }
}

function Read-Pid([string]$file) {
    if (-not (Test-Path $file)) { return 0 }
    try { $raw = ([System.IO.File]::ReadAllText($file)).Trim() } catch { return 0 }
    $p = 0; [void][int]::TryParse($raw.Split('|')[0], [ref]$p); return $p
}

Write-Host "== 文件"
foreach ($f in @('AutoHotkey64.exe','DesktopPage.ahk','dsh-agent.ps1','agent-watch.ps1','ensure-all.ps1','ensure-all.vbs','start-all.vbs','hwmon.ps1','wxmon.ps1','items.tsv','layout.dat')) {
    if (Test-Path (Join-Path $InstallDir $f)) { Ok "$f 存在" } else { Bad "$f 缺失（$InstallDir）" }
}

Write-Host "== 计划任务"
# 只检查"存在且已启用"，不检查上次结果；任务缺失只提示，不算失败（有人可能故意 -SkipTask）
foreach ($tn in @('DesktopPage Autostart','DesktopPage Ensure')) {
    $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
    if ($t) {
        if ($t.State -eq 'Disabled') { Info "$tn 已禁用（不会自启）" } else { Ok "$tn 已注册（$($t.State)）" }
    } else { Info "$tn 不存在（不会开机自启 / 没有兜底巡检）" }
}

Write-Host "== 进程"
$ahk = Get-Process -Name 'AutoHotkey64' -ErrorAction SilentlyContinue
if ($ahk) { Ok ("抽屉进程 AutoHotkey64 运行中 (pid " + ($ahk.Id -join ',') + ")") } else { Bad "抽屉进程未运行" }

$lively = Get-Process -Name 'Lively' -ErrorAction SilentlyContinue
if ($lively) { Ok ("Lively 运行中 (pid " + ($lively.Id -join ',') + ")") } else { Info "Lively 未运行（壁纸不会显示）" }

$agentPid = Read-Pid (Join-Path $InstallDir 'dsh-agent.pid')
if ($agentPid -gt 0 -and (Get-Process -Id $agentPid -ErrorAction SilentlyContinue)) {
    Ok "桌面代理运行中 (dsh-agent.pid=$agentPid)"
} else {
    Bad "桌面代理未运行（dsh-agent.pid=$agentPid，127.0.0.1:17433 不会有响应）"
}

$watchPid = Read-Pid (Join-Path $InstallDir 'agent-watch.pid')
if ($watchPid -gt 0 -and (Get-Process -Id $watchPid -ErrorAction SilentlyContinue)) {
    Ok "代理看门狗运行中 (agent-watch.pid=$watchPid)"
} else {
    Bad "代理看门狗未运行（假死时没人重启代理）"
}

Write-Host "== 代理心跳与端口"
$hb = Join-Path $InstallDir 'dsh-agent.hb'
if (Test-Path $hb) {
    $age = ((Get-Date) - (Get-Item $hb).LastWriteTime).TotalSeconds
    if ($age -le 45) { Ok ("心跳新鲜（{0:N0} 秒前）" -f $age) }
    else { Bad ("心跳过期（{0:N0} 秒）——代理可能假死，等 agent-watch 自愈" -f $age) }
} else {
    Info "dsh-agent.hb 不存在（代理从没起来过）"
}
if (Test-Tcp 17433 600) { Ok "127.0.0.1:17433 可连接" } else { Bad "127.0.0.1:17433 连不上（代理没监听）" }

Write-Host "== HTTP 接口"
$state = ''
foreach ($ep in @('/state.js','/media.js','/scroll.js','/dock.js','/todo.gif','/rect.gif')) {
    try {
        $r = Invoke-WebRequest -Uri ('http://127.0.0.1:17433' + $ep) -TimeoutSec 6 -UseBasicParsing
        if ($r.StatusCode -ne 200) { Bad "GET $ep 状态码 $($r.StatusCode)" ; continue }
        $body = ''
        if ($r.Content -is [string]) { $body = $r.Content }
        if ($body) { Ok ("GET $ep -> " + $body.Substring(0, [Math]::Min(60, $body.Length)).Replace("`r", ' ').Replace("`n", ' ')) }
        else { Ok "GET $ep -> 200（二进制/空响应）" }
        if ($ep -eq '/state.js') { $state = $body }
    } catch { Bad ("GET $ep 失败：" + $_.Exception.Message) }
}
if ($state) {
    if ($state -match 'web:true')   { Ok "DSH web 在线" } else { Info "DSH web 不在线（state.web=false）" }
    if ($state -match 'drawer:true') { Ok "抽屉状态已上报" } else { Info "抽屉状态未上报（drawer=false）" }
    if ($state -match 'busy:true')  { Info "state.busy=true（有指令在跑，或 pid 记录异常）" }
}

Write-Host "== 壁纸回传"
$rect = Join-Path $InstallDir 'panel-rect.txt'
if (Test-Path $rect) {
    $line = (Get-Content $rect -Raw).Trim()
    $parts = $line -split '\s+'
    if ($parts.Count -eq 4 -and $parts[2] -ne '0') { Ok ("panel-rect.txt = " + $line) }
    else { Info ("panel-rect.txt 内容异常：" + $line) }
    $rage = ((Get-Date) - (Get-Item $rect).LastWriteTime).TotalSeconds
    if ($rage -gt 120) { Info ("panel-rect.txt 已 {0:N0} 秒没更新（壁纸被全屏窗口遮住时正常）" -f $rage) }
} else { Info "panel-rect.txt 还不存在（壁纸没打开时正常）" }

Write-Host "== 日志健康"
$wheel = Join-Path $InstallDir 'wheel.log'
if (Test-Path $wheel) {
    $wl = @(Get-Content $wheel -Tail 400 -Encoding utf8)
    $errs = @($wl | Where-Object { $_ -match 'ERROR' })
    if ($errs.Count -eq 0) { Ok "wheel.log 末 400 行无 ERROR" } else { Bad ("wheel.log 有 $($errs.Count) 条 ERROR，末条：" + $errs[-1]) }
    if (@($wl | Where-Object { $_ -match 'rawinput: register=1' }).Count -ge 1) { Ok "滚轮 Raw Input 已注册" } else { Info "wheel.log 里没看到 rawinput: register=1" }
} else { Bad "wheel.log 不存在" }

$sal = Join-Path $InstallDir 'start-all.log'
if (Test-Path $sal) {
    $sl = @(Get-Content $sal -Tail 12 -Encoding utf8)
    if (@($sl | Where-Object { $_ -match 'STILL DOWN' }).Count -ge 1) { Bad "start-all.log 出现 STILL DOWN（有东西没拉起来）" } else { Ok "start-all.log 无 STILL DOWN" }
    if (@($sl | Where-Object { $_ -match 'done$' }).Count -ge 1) { Ok "启动链路最近一轮走到 done" } else { Info "start-all.log 最近没有 done" }
} else { Info "start-all.log 不存在（还没通过计划任务启动过）" }

$awl = Join-Path $InstallDir 'agent-watch.log'
if (Test-Path $awl) {
    $al2 = @(Get-Content $awl -Tail 60 -Encoding utf8)
    if (@($al2 | Where-Object { $_ -match 'restart FAILED' }).Count -ge 1) { Bad "agent-watch.log 出现过 restart FAILED" } else { Ok "agent-watch.log 无 restart FAILED" }
} else { Info "agent-watch.log 不存在" }

$agl = Join-Path $InstallDir 'dsh-agent.log'
if (Test-Path $agl) {
    # 只判断本次启动之后：日志是追加的，历史 FATAL 不代表现在有问题
    $rows = @(Get-Content $agl -Tail 200 -Encoding utf8)
    $si = -1
    for ($i = $rows.Count - 1; $i -ge 0; $i--) { if ($rows[$i] -match 'agent: start pid=') { $si = $i; break } }
    $cur = if ($si -ge 0) { @($rows[$si..($rows.Count - 1)]) } else { $rows }
    $fat = @($cur | Where-Object { $_ -match 'FATAL' })
    if ($fat.Count -ge 1) { Bad ("本次启动后有 FATAL：" + $fat[-1]) } else { Ok "本次启动后无 FATAL" }
    if (@($cur | Where-Object { $_ -match 'listening on' }).Count -ge 1) { Ok "本次启动有 listening 记录" } else { Info "本次启动没看到 listening" }
} else { Info "dsh-agent.log 不存在" }

Write-Host "== 审计日志"
# 三端（抽屉 [AHK ]、代理 [API ]、壁纸 [WEB ]）写同一份 audit.log。
# 只做健康检查：不存在只提示（刚装还没写过），最近没更新也只提示（空闲时正常），
# 绝不让审计日志缺失影响 verify.ps1 的退出码。
$audit = Join-Path $InstallDir 'audit.log'
if (Test-Path $audit) {
    $aItem = Get-Item $audit
    Ok ("audit.log 存在（" + $aItem.Length + " 字节）")
    $aAge = ((Get-Date) - $aItem.LastWriteTime).TotalMinutes
    if ($aAge -gt 5) {
        Info ("最近 {0:N0} 分钟没有审计记录（没人操作时正常）" -f $aAge)
    } else {
        Ok ("最近 {0:N1} 分钟内有审计记录" -f $aAge)
    }
    if (Test-Path ($audit + '.1')) { Info ("audit.log.1 存在（已轮转过，旧一份 " + (Get-Item ($audit + '.1')).Length + " 字节）") }
    # 末几行里三种标签都出现过，说明三端确实都接上了
    try {
        $atail = @(Get-Content $audit -Tail 200 -Encoding utf8)
        $tags = @()
        foreach ($t in @('[AHK ]', '[API ]', '[WEB ]')) { if (@($atail | Where-Object { $_.Contains($t) }).Count -ge 1) { $tags += $t } }
        if ($tags.Count -gt 0) { Ok ("末 200 行里出现的来源：" + ($tags -join ' ')) } else { Info "末 200 行里没有三端标签（格式可能被改坏）" }
    } catch { Info "audit.log 读取失败（可能正被占用）" }
} else {
    Info "audit.log 不存在（刚装还没写过审计，不算失败）"
}

# 抽屉 pid 文件与实际运行实例一致（ensure-all / start-all 靠它判断"是不是同一个抽屉"）
$drawerPid = Read-Pid (Join-Path $InstallDir 'drawer.pid')
if ($ahk -and $drawerPid -gt 0 -and (@($ahk.Id) -contains $drawerPid)) {
    Ok "drawer.pid 与实际抽屉进程一致 (pid=$drawerPid)"
} else {
    Bad ("drawer.pid 与实际抽屉进程不一致（drawer.pid=" + $drawerPid + "，实跑 pid=" + ($ahk.Id -join ',') + "）")
}

# 启动队列不该有残留：有残留说明代理/看门狗都没在消费（点图标会"点了没反应"）
$qf = Join-Path $InstallDir 'launch-queue.txt'
if (Test-Path $qf) { Info ("launch-queue.txt 有残留（" + (Get-Item $qf).Length + "B），看门狗每秒会消费一次") } else { Ok "启动队列无残留" }

Write-Host ""
if ($fail -eq 0) { Write-Host "全部通过。" -ForegroundColor Green } else { Write-Host ("有 " + $fail + " 项失败，见上面 [FAIL]。") -ForegroundColor Yellow }
exit $fail
