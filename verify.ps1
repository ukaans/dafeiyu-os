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
# Invoke-WebRequest 默认会画进度条，把 [ OK ] / [FAIL] 一行行冲掉 —— 每次自检都
# 读成一团乱麻（"正在读取 Web 响应" 混在结论里）。自检的输出是给人看的，关掉。
$ProgressPreference = 'SilentlyContinue'
# 端口从唯一配置源读（drawer\agent-config.ps1），不再在本脚本里写死一份。
$AgentPort = 0
try {
    $cfg = Join-Path $PSScriptRoot 'drawer\agent-config.ps1'
    if (Test-Path $cfg) {
        $cfgText = [System.IO.File]::ReadAllText($cfg, [System.Text.Encoding]::UTF8)
        if ($cfgText -match '(?m)^\s*\$AgentPort\s*=\s*(\d+)') { $AgentPort = [int]$matches[1] }
    }
    if ($AgentPort -le 0) {
        $liveP = Join-Path $InstallDir 'agent-port.txt'
        if (Test-Path $liveP) { [void][int]::TryParse(([System.IO.File]::ReadAllText($liveP)).Trim(), [ref]$AgentPort) }
    }
} catch { }
if ($AgentPort -le 0) { $AgentPort = 17433 }
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
foreach ($f in @('AutoHotkey64.exe','DesktopPage.ahk','dsh-agent.ps1','agent-watch.ps1','agent-config.ps1','ensure-all.ps1','ensure-all.vbs','start-all.vbs','hwmon.ps1','wxmon.ps1','items.tsv','layout.dat')) {
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
    Bad "桌面代理未运行（dsh-agent.pid=$agentPid，127.0.0.1:$AgentPort 不会有响应）"
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
if (Test-Tcp $AgentPort 600) { Ok "127.0.0.1:$AgentPort 可连接" } else { Bad "127.0.0.1:$AgentPort 连不上（代理没监听）" }

Write-Host "== 游戏守卫（库外进程 SessionGuard）"
# 守卫装在 %LOCALAPPDATA%\SessionGuard\，**不在本仓库**。它只做一件事：`[games]` 名单里有游戏
# 在跑时让 AutoHotkey 退出（先 WM_CLOSE、1.5s 不退强杀），免得反作弊看见抽屉。它与桌面系统
# 没有编译依赖，所以**没装不算失败**（换机 / 不玩游戏的机器本来就不会有）。
# 判据给了 10 分钟宽限：ensure-all 每 2 分钟自愈一次，刚被重拉的那几秒里「进程在但心跳还没刷」
# 或「进程还没起来」都是正常过渡，按秒判会变成每次重启都假红（11-14 那串 restart FAILED 的教训）。
# 超过 10 分钟还没恢复，说明自愈也失败了，那时才判 FAIL，并把 ensure-all 里最后一次失败原文带上。
$guardExe = Join-Path $env:LOCALAPPDATA 'SessionGuard\SessionGuard.exe'
if (-not (Test-Path -LiteralPath $guardExe)) {
    Info "本机没装游戏守卫（$guardExe 不存在）—— 与桌面系统无依赖，跳过"
} else {
    $guardDir   = Split-Path -Parent $guardExe
    $guardBeat  = Join-Path $guardDir 'guard-heartbeat.txt'
    $guardPidF  = Join-Path $guardDir 'guard.pid'
    $guardProcs = @(Get-Process -Name 'SessionGuard' -ErrorAction SilentlyContinue)
    $gAge = -1
    if (Test-Path -LiteralPath $guardBeat) {
        try { $gAge = [int]((Get-Date) - (Get-Item -LiteralPath $guardBeat).LastWriteTime).TotalSeconds } catch { $gAge = -1 }
    }
    $gProcOk = ($guardProcs.Count -gt 0)
    $gBeatOk = ($gAge -ge 0 -and $gAge -le 60)
    if ($gProcOk) { Ok ("游戏守卫运行中 (pid " + ($guardProcs.Id -join ',') + ")") }
    else { Info "游戏守卫没在跑（ensure-all 每 2 分钟会补一次）" }
    if ($gBeatOk) { Ok ("守卫心跳新鲜（{0:N0} 秒前）" -f $gAge) }
    elseif ($gAge -lt 0) { Info "guard-heartbeat.txt 不存在（守卫从没写过心跳）" }
    else { Info ("守卫心跳已 {0:N0} 秒没更新（>60s 视为卡死，ensure-all 会按 guard.pid 重拉）" -f $gAge) }

    if (-not ($gProcOk -and $gBeatOk)) {
        # 「多久没恢复」以心跳为准；心跳文件都没有就看 guard.pid，两个都没有 = 从没起来过，只提示
        $gStale = $gAge
        if ($gStale -lt 0 -and (Test-Path -LiteralPath $guardPidF)) {
            try { $gStale = [int]((Get-Date) - (Get-Item -LiteralPath $guardPidF).LastWriteTime).TotalSeconds } catch { $gStale = -1 }
        }
        if ($gStale -gt 600) {
            $gFail = $null
            $egl = Join-Path $InstallDir 'ensure-all.log'
            if (Test-Path $egl) {
                $el = @(Get-Content $egl -Tail 200 -Encoding utf8 | Where-Object { $_ -match 'SessionGuard start FAILED' })
                if ($el.Count -gt 0) { $gFail = $el[-1].Trim() }
            }
            if ($gFail) { Bad ("游戏守卫已 {0:N0} 秒没恢复，自愈也失败过：{1}" -f $gStale, $gFail) }
            else { Bad ("游戏守卫已 {0:N0} 秒没恢复（进程={1}，心跳={2}s）—— 这期间开游戏，抽屉可能被误拉起" -f $gStale, $gProcOk, $gAge) }
        } else {
            Info ("守卫正在恢复中（进程=" + $gProcOk + "，心跳=" + $gAge + "s），10 分钟内不算失败")
        }
    }
}

Write-Host "== HTTP 接口"
$state = ''
foreach ($ep in @('/state.js','/log.js','/media.js','/scroll.js','/dock.js','/todo.gif','/rect.gif')) {
    try {
        $r = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $AgentPort + $ep) -TimeoutSec 6 -UseBasicParsing
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
    elseif ($parts.Count -eq 4 -and $line -eq '0 0 0 0') { Info "控制台当前未显示（显式零矩形 0 0 0 0 —— 正常态，AHK 据此不接管右侧滚轮）" }
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
    # 「末尾 N 行里出现过 STILL DOWN 就失败」是假红制造机：一轮启动只写 4~6 行，末 12 行
    # 里能同时躺着两轮多，一次失败会连着红好几轮。历史上有两条（11-05 21:47、11-14 0:38），
    # 之后几十轮全是 done —— 按老写法只要它还留在窗口里就一直报。与 RES-008 同一套判据：
    # 按 "start: appDir=" 切轮次，只看最近一轮能判的：
    #   有 done              → 成功，再确认这一轮没有 STILL DOWN
    #   没 done 且 ≤120s     → 这一轮还在跑，跳过
    #   没 done 且 >120s     → 卡住（11-05 那次 start-all.vbs 漏 Dim 就是这个形状）
    $sl = @(Get-Content $sal -Tail 300 -Encoding utf8)
    $rounds = @(); $cur = $null
    foreach ($l in $sl) {
        if ($l -match 'start:\s*appDir=') { if ($cur) { $rounds += , @($cur) }; $cur = @($l) }
        elseif ($cur) { $cur += $l }
    }
    if ($cur) { $rounds += , @($cur) }
    if ($rounds.Count -eq 0) {
        Info "start-all.log 里没有轮次标记（start: appDir=），无从判断启动链"
    } else {
        $verdict = $null
        for ($i = $rounds.Count - 1; $i -ge 0; $i--) {
            $r = @($rounds[$i])
            $ageSec = 999999.0
            if ($r[0] -match '^(\d{4}-\d{1,2}-\d{1,2}\s+\d{1,2}:\d{2}:\d{2})') {
                # 小时不补零（11-14 那轮写的是 0:38:35），格式串用单字符 M/H
                try { $ageSec = ((Get-Date) - [datetime]::ParseExact($matches[1], 'yyyy-M-d H:mm:ss', $null)).TotalSeconds } catch { $ageSec = 999999.0 }
            }
            $hasDone = [bool]($r -match 'done\s*$')
            if (-not $hasDone -and $i -eq ($rounds.Count - 1) -and $ageSec -le 120) { continue }
            $verdict = $r
            break
        }
        if (-not $verdict) {
            Info "启动链路最近一轮还在跑（≤120 秒未到 done，本轮不下结论）"
        } else {
            $down = @($verdict -match 'STILL DOWN')
            if ($down.Count -gt 0) {
                Bad ("启动链路最近一轮有 STILL DOWN：" + $down[-1])
            } elseif (-not [bool]($verdict -match 'done\s*$')) {
                Bad ("启动链路最近一轮卡住了（没走到 done，wscript 可能弹着模态框）：" + $verdict[-1])
            } else {
                Ok ("启动链路最近一轮走到 done，无 STILL DOWN（本轮 " + $verdict.Count + " 行 / 窗口内 " + $rounds.Count + " 轮）")
            }
        }
    }
} else { Info "start-all.log 不存在（还没通过计划任务启动过）" }

$awl = Join-Path $InstallDir 'agent-watch.log'
if (Test-Path $awl) {
    # 「出现过 restart FAILED」不能直接判失败：机器满载时代理冷启动要十几秒，看门狗 25→45 秒
    # 等不到心跳就记一条 FAILED，下一轮往往就起来了（2026-11-14 21:39~22:06 那一串，22:06:42
    # 恢复后十几个小时没再动）。只报「现在还在失败」：最近 60 分钟内失败过，或最后一次动手
    # 就是失败、之后没有成功重启。历史失败写成 info，保留证据但不制造噪音。
    $al2 = @(Get-Content $awl -Tail 60 -Encoding utf8)
    $nowW = Get-Date
    $rst = @()
    foreach ($ln in $al2) {
        $kind = $null
        if ($ln -match 'restart FAILED') { $kind = 'FAILED' } elseif ($ln -match 'restart ok') { $kind = 'ok' }
        if (-not $kind) { continue }
        $m = [regex]::Match($ln, '(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})')
        if (-not $m.Success) { continue }
        try {
            $dt = [datetime]::ParseExact(($m.Groups[1].Value + '-' + $m.Groups[2].Value + ' ' + $m.Groups[3].Value + ':' + $m.Groups[4].Value + ':' + $m.Groups[5].Value), 'MM-dd HH:mm:ss', $null)
            if ($dt -gt $nowW.AddDays(1)) { $dt = $dt.AddYears(-1) }
            $rst += [pscustomobject]@{ At = $dt; Kind = $kind; Line = $ln.Trim() }
        } catch { }
    }
    $rst = @($rst | Sort-Object At)
    $bad = @($rst | Where-Object { $_.Kind -eq 'FAILED' })
    if ($bad.Count -eq 0) {
        Ok "agent-watch.log 无 restart FAILED"
    } else {
        $lastBad = $bad[-1]
        $mins = [int](($nowW - $lastBad.At).TotalMinutes)
        $okAfter = @($rst | Where-Object { $_.Kind -eq 'ok' -and $_.At -gt $lastBad.At }).Count -gt 0
        if ($mins -le 60) { Bad ("agent-watch.log 最近 " + $mins + " 分钟内有 restart FAILED：" + $lastBad.Line) }
        elseif (-not $okAfter) { Bad ("agent-watch.log 最后一次重启失败之后再没成功过：" + $lastBad.Line) }
        else { Info ("agent-watch.log 有 " + $bad.Count + " 次历史 restart FAILED（最近 " + $mins + " 分钟前），此后已成功重启 —— 不判失败") }
    }
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
