#requires -Version 5.1
<#
  40-runtime.ps1 —— 运行时健康与语义
  前面三组是"代码对不对"，这一组是"现在这台机器上跑得对不对"。
  重点不是端口通不通（verify.ps1 已经查了），而是：
    · 返回的数据结构是不是前端真正能吃的（缺字段 = 面板显示 --）
    · 延迟有没有踩到单线程代理的 200ms 红线（踩了就连坐所有接口）
    · 心跳是不是"空闲也刷新"（否则看门狗会把健康代理当假死杀掉）
#>

function Run-ReadPid([string]$file) {
    if (-not (Test-Path -LiteralPath $file)) { return 0 }
    try { $raw = ([System.IO.File]::ReadAllText($file)).Trim() } catch { return 0 }
    $p = 0; [void][int]::TryParse($raw.Split('|')[0], [ref]$p); return $p
}

function Run-Alive([int]$procId) {
    # 参数不能叫 $pid：那是 PowerShell 的只读自动变量，赋值会抛「无法覆盖变量 pid」
    if ($procId -le 0) { return $false }
    return [bool](Get-Process -Id $procId -ErrorAction SilentlyContinue)
}

function Run-Prop([string]$body, [string]$key) {
    # JSONP 体是 JS 字面量，不是 JSON：`web:true` / `bal:"¥15.36"` 都能用这个抠出来
    $m = [regex]::Match($body, '(?:^|[{,])' + [regex]::Escape($key) + '\s*:\s*("[^"]*"|\[[^\]]*\]|[^,}]+)')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value.Trim()
}

Test-Case RUN-001 '运行时' '四件套进程存活' high {
    $inst = Get-DshInstall
    if (-not (Test-Path -LiteralPath $inst)) { return @{ Status = 'skip'; Detail = '还没安装（运行目录不存在）' } }
    $bad = @()

    $ahk = @(Get-Process -Name 'AutoHotkey64' -ErrorAction SilentlyContinue)
    if ($ahk.Count -eq 0) { $bad += '抽屉(AutoHotkey64)未运行' }
    elseif ($ahk.Count -gt 1) { $bad += ('抽屉进程有 ' + $ahk.Count + ' 个（多实例会抢钩子，滚轮表现随机）') }

    $agentPid = Run-ReadPid (Join-Path $inst 'dsh-agent.pid')
    if (-not (Run-Alive $agentPid)) { $bad += ('代理未运行(dsh-agent.pid=' + $agentPid + ')') }

    $watchPid = Run-ReadPid (Join-Path $inst 'agent-watch.pid')
    if (-not (Run-Alive $watchPid)) { $bad += ('看门狗未运行(agent-watch.pid=' + $watchPid + ')') }

    $lively = @(Get-Process -Name 'Lively' -ErrorAction SilentlyContinue)
    if ($lively.Count -eq 0) { $bad += 'Lively 未运行（壁纸不显示）' }

    if ($bad.Count -gt 0) { throw ($bad -join '；') }
    ('抽屉 ' + ($ahk.Id -join ',') + ' / 代理 ' + $agentPid + ' / 看门狗 ' + $watchPid + ' / Lively ' + ($lively.Id -join ',') + ' 全部存活')
} -Hint '依次重启：先杀 agent-watch（否则 5s 内重拉旧代理）→ 代理/采样 → AutoHotkey64 → 跑 Autostart 任务'

Test-Case RUN-002 '运行时' 'pid 文件与实际进程一致' medium {
    $inst = Get-DshInstall
    if (-not (Test-Path -LiteralPath $inst)) { return (Test-DshAbort) }
    $drawerPid = Run-ReadPid (Join-Path $inst 'drawer.pid')
    $ahk = @(Get-Process -Name 'AutoHotkey64' -ErrorAction SilentlyContinue)
    $bad = @()
    if ($ahk.Count -gt 0 -and $drawerPid -gt 0 -and (@($ahk.Id) -notcontains $drawerPid)) {
        $bad += ('drawer.pid=' + $drawerPid + ' 但实跑 ' + ($ahk.Id -join ','))
    }
    foreach ($n in @('hwmon.pid', 'wxmon.pid')) {
        $p = Run-ReadPid (Join-Path $inst $n)
        if ($p -gt 0 -and -not (Run-Alive $p)) { $bad += ($n + ' 指向的进程已死(' + $p + ')') }
    }
    if ($bad.Count -gt 0) { throw ($bad -join '；' + ' —— ensure-all 会因此误判并重复拉起') }
    'drawer/hwmon/wxmon 的 pid 记录与实际一致'
} -Hint 'pid 文件过期会让 ensure-all 认为"没起"，反复拉起 → 多实例抢同一个锁'

Test-Case RUN-003 '运行时' '代理心跳新鲜且空闲也刷新' high {
    $inst = Get-DshInstall
    $hb = Join-Path $inst 'dsh-agent.hb'
    if (-not (Test-Path -LiteralPath $hb)) { throw 'dsh-agent.hb 不存在（代理从没起来过，或新版删了心跳）' }

    $age = ((Get-Date) - (Get-Item -LiteralPath $hb).LastWriteTime).TotalSeconds
    if ($age -gt 45) { throw ('心跳已 ' + [int]$age + ' 秒没刷新（阈值 45s）——代理可能假死') }

    # 空闲刷新是历史事故点：早期实现只在"有请求"时刷心跳，代理一空闲就被看门狗判死，
    # 每 50 秒被杀一次，用户看到的是"点应用卡住、提示等待队列"。
    $s1 = (Read-Raw $hb).Trim()
    Start-Sleep -Milliseconds 1300
    $s2 = (Read-Raw $hb).Trim()

    if ($s1 -eq $s2) {
        throw ('空闲 1.3 秒内心跳没有前进（' + $s1 + '）—— 说明心跳仍只在有请求时刷新，看门狗会误杀')
    }
    ('心跳 ' + [int]$age + ' 秒前；空闲 1.3s 内从 ' + $s1.Substring(11) + ' 前进到 ' + $s2.Substring(11))
} -Hint '主循环必须用 GetContextAsync + 250ms 超时刷心跳，不能裸 GetContext()'

Test-Case RUN-004 '运行时' '四个数据接口可达且不踩延迟红线' high {
    if (-not (Test-DshApiUp)) { throw ('代理无响应（' + (Get-DshApiBase) + '）') }
    $bad = @()
    $slow = @()
    $rows = @()
    # /scroll.js 会"取走"滚动增量（读后清零），这里只探一次，影响最多一个滚轮刻度
    foreach ($ep in @('/state.js', '/media.js', '/dock.js', '/scroll.js')) {
        $r = Invoke-DshHttp -Path $ep -TimeoutMs 3000
        if (-not $r.Ok) { $bad += ($ep + ' 失败：' + $r.Error); continue }
        if ($r.Status -ne 200) { $bad += ($ep + ' 状态码 ' + $r.Status); continue }
        if ($r.Ms -gt 200) { $slow += ($ep + ' ' + $r.Ms + 'ms') }
        $rows += ($ep + ' ' + $r.Ms + 'ms')
    }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }
    if ($slow.Count -gt 0) {
        throw ('这些接口超过 200ms（单线程代理会连坐其它接口）：' + ($slow -join '、'))
    }
    ($rows -join '，')
} -Hint '超过 200ms 的同步操作要挪出请求线程或加缓存；用 stopwatch 分段定位到具体 handler'

Test-Case RUN-005 '运行时' 'state.js 字段齐全' high {
    if (-not (Test-DshApiUp)) { return (Test-DshAbort) }
    $r = Invoke-DshHttp -Path '/state.js' -TimeoutMs 3000
    Assert-True $r.Ok ('请求失败：' + $r.Error)
    $b = [string]$r.Body
    Assert-Match $b 'window\.__DSH_STATE\s*=' 'JSONP 赋值前缀'
    $need = @('web', 'scroll', 'busy', 'bal', 'drawer', 'lines', 'sig', 'err', 'reload', 'dbg')
    $miss = @()
    foreach ($k in $need) { if ($null -eq (Run-Prop $b $k)) { $miss += $k } }
    if ($miss.Count -gt 0) { throw ('缺字段：' + ($miss -join '、') + '（前端会显示 -- 或不更新）') }
    ('10 个字段齐全：web=' + (Run-Prop $b 'web') + ' busy=' + (Run-Prop $b 'busy') + ' bal=' + (Run-Prop $b 'bal') + ' drawer=' + (Run-Prop $b 'drawer') + ' sig=' + (Run-Prop $b 'sig'))
} -Hint 'dsh.js 的 poll() 直接读这些键；删/改名要同步改 dsh.js 与文档 §3.1（sig/err/reload/dbg 是 2026-11-05 会话视图加的）'

Test-Case RUN-006 '运行时' 'state.lines 是可渲染字符串数组' medium {
    if (-not (Test-DshApiUp)) { return (Test-DshAbort) }
    $b = [string](Invoke-DshHttp -Path '/state.js' -TimeoutMs 3000).Body
    $v = Run-Prop $b 'lines'
    if ($null -eq $v) { throw 'lines 字段缺失' }
    if ($v -notmatch '^\[') { throw ('lines 不是数组：' + $v.Substring(0, [Math]::Min(60, $v.Length))) }
    # 典型的 PS 序列化事故：数组被 ToString() 成 "System.Object[]"，面板上就显示这串字
    if ($v -match 'System\.(Object|String)\[\]|Microsoft\.PowerShell') {
        throw ('lines 里出现 .NET 类型名，说明数组被字符串化了：' + $v.Substring(0, [Math]::Min(80, $v.Length)))
    }
    $cnt = ([regex]::Matches($v, '"')).Count
    ('lines 是数组，含 ' + [int]($cnt / 2) + ' 条字符串')
} -Hint 'Get-LogTail 必须返回 string[]；接字符串时要 -join 或逐条加引号'

Test-Case RUN-007 '运行时' 'state.js 响应稳定（无抖动）' medium {
    if (-not (Test-DshApiUp)) { return (Test-DshAbort) }
    $t = @()
    for ($i = 0; $i -lt 5; $i++) {
        $r = Invoke-DshHttp -Path '/state.js' -TimeoutMs 3000
        if (-not $r.Ok) { throw ('第 ' + ($i + 1) + ' 次失败：' + $r.Error) }
        $t += $r.Ms
        Start-Sleep -Milliseconds 120
    }
    $min = ($t | Measure-Object -Minimum).Minimum
    $max = ($t | Measure-Object -Maximum).Maximum
    $avg = [int](($t | Measure-Object -Average).Average)
    # 缓存命中时应该稳定在个位数毫秒；某个采样突然跳到上百说明缓存没命中或有同步慢调用
    if ($max -gt 200) { throw ('最慢 ' + $max + 'ms（明细 ' + ($t -join ',') + '）') }
    if ($min -gt 0 -and ($max / [Math]::Max($min, 1)) -gt 8 -and $max -gt 60) {
        return @{ Status = 'warn'; Detail = ('抖动大：' + ($t -join ',') + 'ms（均值 ' + $avg + '）') }
    }
    ('5 次 ' + ($t -join '/') + 'ms，均值 ' + $avg + 'ms')
} -Hint '缓存键漏了会让某项每次都重算；看 dsh-agent.log 里的 cache=0:xxx 判断是谁在重算'

Test-Case RUN-008 '运行时' 'media.js 字段齐全' medium {
    if (-not (Test-DshApiUp)) { return (Test-DshAbort) }
    $b = [string](Invoke-DshHttp -Path '/media.js' -TimeoutMs 3000).Body
    Assert-Match $b 'window\.__MEDIA\s*=' 'JSONP 赋值前缀'
    $need = @('ok', 'playing', 'app', 'title', 'artist', 'pos', 'dur', 'est')
    $miss = @()
    foreach ($k in $need) { if ($null -eq (Run-Prop $b $k)) { $miss += $k } }
    if ($miss.Count -gt 0) { throw ('缺字段：' + ($miss -join '、')) }
    ('8 个字段齐全：playing=' + (Run-Prop $b 'playing') + ' est=' + (Run-Prop $b 'est'))
} -Hint 'media.js 的 fit() 依赖 est 判断是否显示 ≈；删字段会让面板卡在旧值'

Test-Case RUN-009 '运行时' 'dock.js 结构正常且不超上限' medium {
    if (-not (Test-DshApiUp)) { return (Test-DshAbort) }
    $b = [string](Invoke-DshHttp -Path '/dock.js' -TimeoutMs 3000).Body
    Assert-Match $b 'window\.__DOCK\s*=' 'JSONP 赋值前缀'
    $v = Run-Prop $b '__DOCK'
    $m = [regex]::Match($b, 'window\.__DOCK\s*=\s*(\[[^\]]*\])')
    if (-not $m.Success) { throw '解析不出 __DOCK 数组' }
    $arr = $m.Groups[1].Value
    $n = ([regex]::Matches($arr, '\{')).Count
    if ($n -gt 6) { throw ('快捷启动有 ' + $n + ' 项，超过面板上限 6（第 7 项开始画不出来）') }
    if ($b -notmatch 'window\.__DOCK_BUSY') { throw '__DOCK_BUSY 缺失（dsh.js 判断"正在选择文件"要用）' }
    ('__DOCK 有 ' + $n + ' 项，__DOCK_BUSY 存在')
} -Hint 'dock.txt 最多 6 行；加项要在 dock-add-host.ps1 里拦，不要靠前端裁剪'

Test-Case RUN-010 '运行时' 'OPTIONS 预检与 JSONP 内容类型' low {
    if (-not (Test-DshApiUp)) { return (Test-DshAbort) }
    $o = Invoke-DshHttp -Path '/state.js' -Method OPTIONS -TimeoutMs 2500
    if (-not $o.Ok) { throw ('OPTIONS 失败：' + $o.Error) }
    if ($o.Status -ne 204) { throw ('OPTIONS 期望 204，实际 ' + $o.Status) }
    $g = Invoke-DshHttp -Path '/state.js' -TimeoutMs 2500
    if ($g.ContentType -notmatch 'javascript') {
        throw ('.js 接口 Content-Type 是 ' + $g.ContentType + '，应为 application/javascript（否则 <script src> 可能被当文本）')
    }
    ('OPTIONS 204；/state.js Content-Type=' + $g.ContentType)
} -Hint 'JSONP 必须 application/javascript；某些浏览器对 text/html 的 script 会拒绝执行'

Test-Case RUN-011 '运行时' '抽屉文件通道可达（AHK 真在跑）' medium {
    # 这是唯一能验到 AutoHotkey 主循环的用例：本机安全策略掐掉 /validate，也没有可用的
    # 自动化通道去点抽屉，但 summon.cmd 是它每 400ms 轮询一次的输入口。
    # 用 diag（只落一行快照到 wheel.log，不弹窗）来证明三件事同时成立：
    # 抽屉活着、文件通道通、日志可写。
    $inst = Get-DshInstall
    if (-not (Test-Path -LiteralPath $inst)) { return (Test-DshAbort) }
    if (-not @(Get-Process -Name 'AutoHotkey64' -ErrorAction SilentlyContinue)) {
        return (Test-DshAbort)
    }
    $summon = Join-Path $inst 'summon.cmd'
    $wheelLog = Join-Path $inst 'wheel.log'
    $before = 0
    if (Test-Path -LiteralPath $wheelLog) {
        $before = @(Sec-ReadShared $wheelLog 500 | Where-Object { $_ -match 'diag:' }).Count
    }

    # 抽屉用 FileRead(..., "UTF-8") 读，所以写 UTF-8 无 BOM（带 BOM 会让首字符变成 U+FEFF）
    [System.IO.File]::WriteAllText($summon, 'diag', (New-Object System.Text.UTF8Encoding($false)))

    $ok = $false
    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Milliseconds 250
        if (-not (Test-Path -LiteralPath $summon)) { $ok = $true; break }
    }
    if (-not $ok) {
        try { [System.IO.File]::Delete($summon) } catch { }
        throw ('summon.cmd 3.7 秒内没被消费（文件还在）—— 抽屉主循环卡住，或文件通道失效')
    }

    # 文件被吃掉了，再确认 diag 真的落了日志（防止"吃掉了但没执行"）
    $after = 0
    for ($i = 0; $i -lt 8; $i++) {
        Start-Sleep -Milliseconds 250
        $after = @(Sec-ReadShared $wheelLog 500 | Where-Object { $_ -match 'diag:' }).Count
        if ($after -gt $before) { break }
    }
    if ($after -le $before) {
        return @{ Status = 'warn'; Detail = 'summon.cmd 被消费了，但 wheel.log 里没看到新的 diag: 行（日志可能已轮转/写失败）' }
    }
    ('summon.cmd 被消费，wheel.log 新增 diag 快照（diag 行 ' + $before + ' → ' + $after + '）')
} -Hint '这条红了先看 wheel.log 有没有在增长；抽屉卡死时 Ctrl+Alt+D 也救不回桌面图标，需重启 Autostart 任务'

Test-Case RUN-012 '运行时' '滚轮桥热跟随（桥没在旧 hwnd 上打转）' medium {
    # 桥把抽屉的脚本窗口 hwnd 缓存成投递目标，抽屉重启后 hwnd 会变。
    # 改前必须手动 kill 掉桥再跑一次 start-all，忘了就出现「滚轮完全没反应」，
    # 而 wheel-bridge.log 里一直刷 post FAILED target=<旧hwnd>（日志看着像桥活着，其实投给死窗口）。
    # 改后桥每 5 秒 tick 和每次投递前都重读 wheel-bridge.hwnd，并丢掉已死的目标。
    # 这条用例只读文件、不碰钩子：beat 行里有 follows= 说明跑的是新代码，beat 的 target 应等于抽屉 announce 的 hwnd。
    $inst = Get-DshInstall
    if (-not (Test-Path -LiteralPath $inst)) { return (Test-DshAbort) }
    $log = Join-Path $inst 'wheel-bridge.log'
    $hwndFile = Join-Path $inst 'wheel-bridge.hwnd'
    if (-not (Test-Path -LiteralPath $log)) { return (Test-DshAbort) }
    $beats = @(Sec-ReadShared $log 400 | Where-Object { $_ -match 'beat ' })
    if ($beats.Count -eq 0) {
        return @{ Status = 'warn'; Detail = 'wheel-bridge.log 里没有 beat 行（桥没跑，或刚起来还没到第一个 5 秒 tick）' }
    }
    $last = $beats[-1].Trim()
    if ($last -notmatch 'follows=') {
        throw ('桥还在跑旧代码（beat 里没有 follows= 字段）：' + $last + ' → kill 掉 powershell 桥再跑一次 start-all，新代码才会热跟随')
    }
    $mFollow = [regex]::Match($last, 'follows=(\d+)')
    $mTarget = [regex]::Match($last, 'target=(\d+)')
    $mAlive = [regex]::Match($last, 'alive=(\d+)')
    $follows = if ($mFollow.Success) { $mFollow.Groups[1].Value } else { '?' }
    $beatTarget = if ($mTarget.Success) { [long]$mTarget.Groups[1].Value } else { 0 }
    $alive = if ($mAlive.Success) { $mAlive.Groups[1].Value } else { '?' }

    $fileHwnd = 0
    if (Test-Path -LiteralPath $hwndFile) {
        try { $raw = ([System.IO.File]::ReadAllText($hwndFile)).Trim() } catch { $raw = '' }
        if ($raw -match '^\d+$') { $fileHwnd = [long]$raw }
    }
    if ($fileHwnd -le 0) {
        return @{ Status = 'warn'; Detail = ('wheel-bridge.hwnd 空着或不是数字（抽屉还没 announce 成功）：beat=' + $last) }
    }
    if ($beatTarget -ne $fileHwnd) {
        $fileAge = ((Get-Date) - (Get-Item -LiteralPath $hwndFile).LastWriteTime).TotalSeconds
        $logAge = ((Get-Date) - (Get-Item -LiteralPath $log).LastWriteTime).TotalSeconds
        if ($fileAge -lt 30 -and $fileAge -lt $logAge) {
            # 抽屉刚 announce、桥还没走到下一个 tick：不是故障，别误报
            return @{ Status = 'warn'; Detail = ('抽屉 ' + [int]$fileAge + ' 秒前才 announce，桥还没等到下一个 tick：beat target=' + $beatTarget + '，文件=' + $fileHwnd) }
        }
        throw ('桥没跟随：beat target=' + $beatTarget + '，但 wheel-bridge.hwnd=' + $fileHwnd + '（同一次 tick 里目标该换成新 hwnd；差得久说明跟随逻辑失效）')
    }
    ('桥热跟随正常：beat target = wheel-bridge.hwnd = ' + $fileHwnd + '，follows=' + $follows + ' alive=' + $alive)
} -Hint '红了先看 wheel-bridge.log 末尾：target=0/alive=0 说明抽屉没 announce（回 wheel.log 搜 announce 落盘失败）；没有 follows= 字段说明桥还在跑旧脚本，kill 掉重启一次'

Test-Case RUN-013 '运行时' 'log.js 会话正文通道可用' high {
    # 2026-11-05 起，桌面控制台不再把日志尾巴当纯文本刷，而是渲染成「我说的话 + DSH 的回答」。
    # 正文走 /log.js（一次 ≤60000 字符），/state.js 只给 sig 让页面判断要不要来拿。
    if (-not (Test-DshApiUp)) { return (Test-DshAbort) }
    $r = Invoke-DshHttp -Path '/log.js' -TimeoutMs 5000
    if (-not $r.Ok) { throw ('/log.js 请求失败：' + $r.Error) }
    if ($r.Status -ne 200) { throw ('/log.js 状态码 ' + $r.Status) }
    if ($r.ContentType -notmatch 'javascript') { throw ('/log.js Content-Type=' + $r.ContentType + '，应为 application/javascript') }
    $b = [string]$r.Body
    Assert-Match $b 'window\.__DSH_LOG\s*="' 'JSONP 赋值前缀'
    # 60KB 正文 + 转义余量：超过就说明 Get-LogText 的上限没生效，单线程代理会被拖死
    if ($b.Length -gt 70000) { throw ('/log.js 响应 ' + $b.Length + ' 字符，超过 60000 上限（页面会卡，代理也会排队）') }
    $st = [string](Invoke-DshHttp -Path '/state.js' -TimeoutMs 3000).Body
    $sig = Run-Prop $st 'sig'
    if ([string]::IsNullOrWhiteSpace($sig) -or $sig -eq '""') {
        # 日志文件不存在时 sig 是空串，属于正常（还没发过指令）
        return ('__DSH_LOG ' + $b.Length + ' 字符（' + $r.Ms + 'ms）；日志为空，sig 未生成')
    }
    ('__DSH_LOG ' + $b.Length + ' 字符（' + $r.Ms + 'ms）；sig=' + $sig)
} -Hint '红了先 curl http://127.0.0.1:17433/log.js 看回包；sig 一直不变说明 Get-LogSig 读不到 dsh-run.log（代理没权限或路径不对）'
