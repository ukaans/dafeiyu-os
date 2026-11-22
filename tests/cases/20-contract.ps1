#requires -Version 5.1
<#
  20-contract.ps1 —— 契约一致性
  这套系统没有类型系统、没有接口定义，靠的全是「约定」：
  端口写死五处、JSONP 变量名两头对齐、路由表与前端调用对齐、文档与实现对齐。
  约定一歪，表现是"点了没反应"，而不是报错 —— 所以必须用测试咬住。
#>

function Contract-RouteTable {
    if ($script:ContractCache -and $script:ContractCache.Routes) { return $script:ContractCache }
    $src = Read-Raw (Join-Path (Get-DshRoot) 'drawer\dsh-agent.ps1')
    $keys = New-Object System.Collections.ArrayList
    $handlers = New-Object System.Collections.ArrayList

    $blocks = @(
        @{ Name = 'ROUTES'; Pattern = '(?s)\$script:ROUTES\s*=\s*@\{(.*?)\r?\n\}' }
        @{ Name = 'PREFIX'; Pattern = '(?s)\$script:ROUTES_PREFIX\s*=\s*@\((.*?)\r?\n\)' }
    )
    foreach ($b in $blocks) {
        $m = [regex]::Match($src, $b.Pattern)
        if (-not $m.Success) { continue }
        $body = $m.Groups[1].Value
        if ($b.Name -eq 'ROUTES') {
            foreach ($km in [regex]::Matches($body, "'([^']+)'\s*=\s*@\{([^}]*)\}")) {
                [void]$keys.Add($km.Groups[1].Value)
                $h = [regex]::Match($km.Groups[2].Value, "handler\s*=\s*'([^']+)'")
                if ($h.Success) { [void]$handlers.Add($h.Groups[1].Value) }
            }
        } else {
            foreach ($pm in [regex]::Matches($body, "@\{([^}]*)\}")) {
                $inner = $pm.Groups[1].Value
                $pf = [regex]::Match($inner, "prefix\s*=\s*'([^']+)'")
                $h = [regex]::Match($inner, "handler\s*=\s*'([^']+)'")
                if ($pf.Success) { [void]$keys.Add(($pf.Groups[1].Value + '*')) }
                if ($h.Success) { [void]$handlers.Add($h.Groups[1].Value) }
            }
        }
    }
    $script:ContractCache = @{ Src = $src; Routes = @($keys); Handlers = @($handlers) }
    return $script:ContractCache
}

Test-Case CON-001 '契约' '代理端口单一配置源' high {
    $root = Get-DshRoot
    # P2（2026-11-11）：原来 9 处写死 17433。现在只有 drawer\agent-config.ps1 一处定义，
    # 三个 PowerShell 脚本 dot-source 它；AHK 读 agent-port.txt、壁纸读 port.js，
    # 两个生成物都由 install.ps1 与代理启动时从同一个 $AgentPort 写出。
    $cfgP = Join-Path $root 'drawer\agent-config.ps1'
    if (-not (Test-Path -LiteralPath $cfgP)) { throw '缺少 drawer\agent-config.ps1（端口唯一来源）' }
    $m = [regex]::Match((Read-Raw $cfgP), '(?m)^\s*\$AgentPort\s*=\s*(\d+)\s*$')
    if (-not $m.Success) { throw 'agent-config.ps1 里没有 $AgentPort = <port>' }
    $port = $m.Groups[1].Value

    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    if ($agent -notmatch 'agent-config\.ps1') { throw 'dsh-agent.ps1 没有 dot-source agent-config.ps1' }
    if ($agent -match '(?m)^\s*\[int\]\$Port\s*=\s*[1-9]\d*') { throw 'dsh-agent.ps1 仍把端口写死在 param 默认值里' }
    $watch = Read-Raw (Join-Path $root 'drawer\agent-watch.ps1')
    if ($watch -notmatch 'agent-config\.ps1') { throw 'agent-watch.ps1 没有 dot-source agent-config.ps1' }
    if ($watch -notmatch "'-Port'") { throw 'agent-watch.ps1 拉起代理时没有把 -Port 传下去' }
    $ens = Read-Raw (Join-Path $root 'drawer\ensure-all.ps1')
    if ($ens -notmatch 'TestPort\s+\$AgentPort') { throw 'ensure-all.ps1 没有用 $AgentPort 探活' }
    if ($ens -match '(?m)^\s*return \(TestPort\s+\d+') { throw 'ensure-all.ps1 仍写死端口探活' }

    $ahk = Read-Raw (Join-Path $root 'drawer\DesktopPage.ahk')
    if ($ahk -notmatch 'agent-port\.txt') { throw 'AHK 没有读 agent-port.txt' }
    if ($ahk -match '127\.0\.0\.1:17433') { throw 'AHK 仍写死 127.0.0.1:17433' }

    $api = Read-Raw (Join-Path $root 'wallpaper\api.js')
    if ($api -notmatch '__DSH_AGENT_PORT') { throw 'api.js 没有读 window.__DSH_AGENT_PORT' }
    $pj = Join-Path $root 'wallpaper\port.js'
    if (-not (Test-Path -LiteralPath $pj)) { throw '缺少 wallpaper\port.js（端口生成物）' }
    $pt = (Read-Raw $pj).Trim()
    if ($pt -ne ('window.__DSH_AGENT_PORT=' + $port + ';')) { throw ('port.js 与 agent-config 不一致：' + $pt) }
    $idx = Read-Raw (Join-Path $root 'wallpaper\index.html')
    $ip = $idx.IndexOf('port.js'); $ia = $idx.IndexOf('src="api.js"')
    if ($ip -lt 0 -or $ia -lt 0 -or $ip -gt $ia) { throw 'index.html 没有在 api.js 之前加载 port.js' }
    foreach ($f in @('dsh.js','media.js','todo.js','audit.js')) {
        $t = Read-Raw (Join-Path $root ('wallpaper\' + $f))
        if ($t -notmatch '__DSH_AGENT_PORT') { throw ($f + ' 没有读 window.__DSH_AGENT_PORT') }
        if ($t -match '127\.0\.0\.1:\d{4,5}') { throw ($f + ' 仍写死 127.0.0.1 端口') }
    }

    $inst = Read-Raw (Join-Path $root 'install.ps1')
    if ($inst -notmatch 'agent-config\.ps1') { throw 'install.ps1 没有安装 agent-config.ps1' }
    if ($inst -notmatch 'agent-port\.txt' -or $inst -notmatch "'port\.js'") { throw 'install.ps1 没有生成 agent-port.txt / port.js' }

    $live = Join-Path $env:LOCALAPPDATA 'DesktopPage\agent-port.txt'
    if (Test-Path -LiteralPath $live) {
        $lv = (Read-Raw $live).Trim()
        if ($lv -ne $port) { throw ("运行态 agent-port.txt=$lv 与配置 $port 不一致") }
    }
    ('端口唯一来源 agent-config.ps1 = ' + $port)
} -Hint 'P2：原 9 处写死 17433；现在配置一处，脚本 dot-source，AHK/壁纸读生成物'

Test-Case CON-002 '契约' '路由表 handler 都有实现' high {
    $t = Contract-RouteTable
    if ($t.Routes.Count -eq 0) { throw '解析不出 $script:ROUTES（路由表结构可能被改了）' }
    $missing = @()
    foreach ($h in ($t.Handlers | Sort-Object -Unique)) {
        if ($t.Src -notmatch ('(?m)^\s*function\s+' + [regex]::Escape($h) + '\b')) { $missing += $h }
    }
    if ($missing.Count -gt 0) { throw ('handler 未定义：' + ($missing -join '、') + ' —— 请求会 500 或空响应') }
    ('路由表 ' + $t.Routes.Count + ' 条，' + (@($t.Handlers | Sort-Object -Unique).Count) + ' 个 handler 全部有实现')
} -Hint '加接口 = 加一条表项 + 写一个 function；表项写了但函数没写会静默失败'

Test-Case CON-003 '契约' '前端调用的路由都在路由表里' high {
    $t = Contract-RouteTable
    $known = @($t.Routes | ForEach-Object { $_.TrimEnd('*') })
    $calls = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path (Get-DshRoot) 'wallpaper') -Filter '*.js' -File)) {
        if ($f.Name -eq 'app.js') { continue }
        $txt = Read-Raw $f.FullName
        foreach ($m in [regex]::Matches($txt, "(?<![\w/])/([a-z]+\.(?:gif|js))(?![\w])")) {
            $route = '/' + $m.Groups[1].Value
            if (-not $calls.ContainsKey($route)) { $calls[$route] = $f.Name }
        }
        if ($txt -match "/icon/") { $calls['/icon/'] = $f.Name }
    }
    $unknown = @($calls.Keys | Where-Object { $known -notcontains $_ })
    if ($unknown.Count -gt 0) {
        $desc = ($unknown | ForEach-Object { $_ + '（' + $calls[$_] + '）' }) -join '、'
        throw ('前端在调不存在的路由：' + $desc + ' → 点了永远没反应')
    }
    ('前端用到 ' + $calls.Count + ' 条路由，全部命中路由表')
} -Hint '删/改路由要全局搜 wallpaper\*.js，漏一处就是"按钮失灵"'

Test-Case CON-004 '契约' '路由表与项目地图双向对齐' medium {
    $t = Contract-RouteTable
    $docPath = Join-Path (Get-DshRoot) 'docs\项目地图.md'
    Assert-File $docPath '项目地图'
    $doc = Read-Raw $docPath

    # 方向一：代码有、文档没写 → 以后没人知道这个接口存在
    $undoc = @()
    foreach ($r in $t.Routes) {
        if ($r -eq '/state') { continue }          # 别名，文档已用 /state.js 代表
        $probe = $r.TrimEnd('*')
        if ($doc -notmatch [regex]::Escape($probe)) { $undoc += $r }
    }
    # 方向二：文档写了、代码没有 → 死文档，排障时会照着不存在的东西查
    $dead = @()
    $known = @($t.Routes | ForEach-Object { $_.TrimEnd('*') })
    foreach ($m in [regex]::Matches($doc, '`(/(?:[a-z]+\.(?:gif|js)|icon/))`')) {
        $r = $m.Groups[1].Value
        if ($r -eq '/icon/') { continue }
        if ($known -notcontains $r) { $dead += $r }
    }
    $dead = @($dead | Sort-Object -Unique)

    if ($undoc.Count -gt 0 -or $dead.Count -gt 0) {
        $msg = @()
        if ($undoc.Count -gt 0) { $msg += ('代码有但文档没写：' + ($undoc -join '、')) }
        if ($dead.Count -gt 0) { $msg += ('文档写了但代码没有：' + ($dead -join '、')) }
        throw ($msg -join '；')
    }
    '路由表与项目地图 §3 双向一致'
} -Hint '按项目地图 §7.2 矩阵，改路由必须同步 §3 + 实现手册 §4.4 + 部署指南 §6'

Test-Case CON-005 '契约' '壁纸脚本加载顺序' medium {
    $html = Read-Raw (Join-Path (Get-DshRoot) 'wallpaper\index.html')
    $order = @([regex]::Matches($html, '<script\s+src="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    if ($order.Count -lt 6) { throw ('只找到 ' + $order.Count + ' 个 <script src>，加载链可能被改坏') }

    $idx = @{}
    for ($i = 0; $i -lt $order.Count; $i++) { if (-not $idx.ContainsKey($order[$i])) { $idx[$order[$i]] = $i } }

    $rule = @(
        @{ Before = 'todo-data.js'; After = 'todo.js'; Why = 'todo.js 启动时要读 __TODO 初始值' }
        @{ Before = 'audio-host.js'; After = 'dsh.js'; Why = 'Lively 音频回调要在控制台之前注册' }
        @{ Before = 'audit.js'; After = 'dsh.js'; Why = 'dsh.js 调 window.__AUDIT' }
        @{ Before = 'hw.js'; After = 'dsh.js'; Why = 'dsh.js 读硬件面板节点' }
        @{ Before = 'wx.js'; After = 'dsh.js'; Why = 'dsh.js 读天气面板节点' }
    )
    $bad = @()
    foreach ($r in $rule) {
        if (-not $idx.ContainsKey($r.Before) -or -not $idx.ContainsKey($r.After)) {
            $bad += ('缺少 ' + $r.Before + ' 或 ' + $r.After); continue
        }
        if ($idx[$r.Before] -ge $idx[$r.After]) { $bad += ($r.Before + ' 必须在 ' + $r.After + ' 之前（' + $r.Why + '）') }
    }
    if ($order[$order.Count - 1] -ne 'media.js') { $bad += ('media.js 应最后加载，实际最后是 ' + $order[$order.Count - 1]) }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }
    ('加载链 ' + ($order -join ' → '))
} -Hint '顺序错了表现是 undefined 而不是报错：__AUDIT 未定义、__TODO 读不到都会静默降级'

Test-Case CON-006 '契约' 'CSP 仍封死直连' high {
    $html = Read-Raw (Join-Path (Get-DshRoot) 'wallpaper\index.html')
    Assert-Match $html "connect-src\s*'none'" 'CSP connect-src'
    Assert-Match $html "object-src\s*'none'" 'CSP object-src'
    Assert-Match $html "base-uri\s*'none'" 'CSP base-uri'
    'CSP 的 connect-src / object-src / base-uri 仍为 none'
} -Hint "别删 connect-src 'none'：删了也变不出 fetch（还有 Chromium 私有网络限制），只会让人误判"

Test-Case CON-007 '契约' '壁纸侧不出现 fetch/XHR' high {
    $dir = Join-Path (Get-DshRoot) 'wallpaper'
    $hits = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.js' -File)) {
        if ($f.Name -eq 'app.js') { continue }
        $txt = Read-Raw $f.FullName
        if ($txt -match '\bfetch\s*\(') { $hits += ($f.Name + ':fetch') }
        if ($txt -match '\bXMLHttpRequest\b') { $hits += ($f.Name + ':XHR') }
    }
    if ($hits.Count -gt 0) { throw ('出现直连写法（必被 CSP 拦死）：' + ($hits -join '、')) }
    '全部使用 JSONP(<script>) + GIF 信标(<img>)'
} -Hint '只能走两条老通道：插 <script src="…/x.js"> 读、new Image().src="…/x.gif" 写'

Test-Case CON-008 '契约' 'JSONP 变量名两头对齐' medium {
    $root = Get-DshRoot
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    # __HW / __WX 由两个采样进程写，不归代理管 —— 生产者要按真实写者去查
    $hwmon = Read-Raw (Join-Path $root 'drawer\hwmon.ps1')
    $wxmon = Read-Raw (Join-Path $root 'drawer\wxmon.ps1')
    $map = @(
        @{ Var = '__DSH_STATE'; Js = 'dsh.js'; Producers = @($agent) }
        @{ Var = '__MEDIA'; Js = 'media.js'; Producers = @($agent) }
        @{ Var = '__DOCK'; Js = 'dsh.js'; Producers = @($agent) }
        @{ Var = '__DSH_SCROLL'; Js = 'dsh.js'; Producers = @($agent) }
        @{ Var = '__DSH_LOG'; Js = 'dsh.js'; Producers = @($agent) }
        @{ Var = '__TODO'; Js = 'todo.js'; Producers = @($agent, (Read-Raw (Join-Path $root 'drawer\DesktopPage.ahk'))) }
        @{ Var = '__HW'; Js = 'hw.js'; Producers = @($hwmon) }
        @{ Var = '__WX'; Js = 'wx.js'; Producers = @($wxmon) }
    )
    $bad = @()
    foreach ($m in $map) {
        $prodHit = $false
        foreach ($p in $m.Producers) { if ($p -match [regex]::Escape($m.Var)) { $prodHit = $true } }
        if (-not $prodHit) { $bad += ('生产端无 ' + $m.Var) }
        $jsPath = Join-Path $root ('wallpaper\' + $m.Js)
        if (Test-Path -LiteralPath $jsPath) {
            if ((Read-Raw $jsPath) -notmatch [regex]::Escape($m.Var)) { $bad += ($m.Js + ' 侧无 ' + $m.Var) }
        }
    }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }
    ('8 个 JSONP / 数据变量名两端一致')
} -Hint '改名必须两端同时改：window.__X 是唯一契约，改一侧等于断链（且不报错）'

Test-Case CON-009 '契约' 'index.html 引用的脚本都存在' high {
    $root = Get-DshRoot
    $dir = Join-Path $root 'wallpaper'
    $html = Read-Raw (Join-Path $dir 'index.html')
    $refs = @([regex]::Matches($html, '<script\s+src="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    if ($refs.Count -eq 0) { throw 'index.html 里没有 <script src>，解析规则可能变了' }
    $miss = @()
    foreach ($r in $refs) {
        if ($r -match '^(https?:)?//') { continue }        # 外链不查（CSP 也禁止）
        if (-not (Test-Path -LiteralPath (Join-Path $dir $r))) { $miss += $r }
    }
    if ($miss.Count -gt 0) {
        throw ('引用了不存在的脚本：' + ($miss -join '、') + ' —— 页面会 404 一次，靠兜底才没白屏')
    }
    ('index.html 的 ' + $refs.Count + ' 个脚本引用全部存在')
} -Hint '新增脚本要同时进 wallpaper\ 与 Lively 运行时目录；漏一个就是 404（兜底会掩盖问题）'

Test-Case CON-010 '契约' 'PowerShell 5.1 兼容：不用 .NET Core 专有计时器' high {
    $root = Get-DshRoot
    $files = @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\\.git\\' })
    if ($files.Count -eq 0) { throw '没找到任何 .ps1，路径规则可能变了' }
    # 拼出来再匹配：本文件里不能出现这串原文，否则自己测自己永远失败
    $needle = '\[Environment\]::' + 'TickCount64'
    $disp = '[Environment]::' + 'TickCount64'
    $bad = @()
    foreach ($f in $files) {
        # 只看代码行：注释里允许写「别再碰 TickCount64」这类说明，否则文档和测试对着干
        $code = (((Read-Raw $f.FullName) -split "\r?\n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
        if ($code -match $needle) { $bad += $f.FullName.Substring($root.Length).TrimStart('\') }
    }
    if ($bad.Count -gt 0) {
        throw (($bad -join '、') + ' 用了 ' + $disp + ' —— 5.1/.NET Framework 里它不存在，取值是 $null（不报错）')
    }
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    if ($agent -notmatch '\$script:clock\s*=.*Stopwatch') { throw 'dsh-agent.ps1 缺 $script:clock = [Diagnostics.Stopwatch]::StartNew()（缓存时钟的唯一来源）' }
    if ($agent -notmatch 'Cache-Get' -or $agent -notmatch 'ElapsedMilliseconds') { throw 'Cache-Get 没接 $script:clock.ElapsedMilliseconds，缓存会退回永不失效' }
    ('扫描 ' + $files.Count + ' 个 .ps1：无 TickCount64，缓存时钟走 Stopwatch')
} -Hint '本机只跑 Windows PowerShell 5.1：TickCount64 / [TimeProvider] 之类 .NET Core API 会静默变 $null → 缓存 age 恒为 0 → 面板永远显示第一次取到的旧内容'

Test-Case CON-011 '契约' '桥通道不吞向上滚 + 滚动立即生效' high {
    $root = Get-DshRoot
    $ahk = Read-Raw (Join-Path $root 'drawer\DesktopPage.ahk')
    $m = [regex]::Match($ahk, 'WheelBridgeMsg\(wParam,\s*lParam,\s*msg,\s*hwnd\)\s*\{(?<body>[\s\S]*?)\r?\n\}')
    if (-not $m.Success) { throw '找不到 WheelBridgeMsg 函数体，AHK 结构变了' }
    $body = $m.Groups['body'].Value
    if ($body -match '\(up \|\| !DesktopUnderCursor\(\)\)') {
        throw 'WheelBridgeMsg 又把 up 并进丢弃条件了 —— 抽屉关着时向上滚整条消失（面板只能向下滚）'
    }
    if ($body -notmatch 'WheelHandle\(up \? -1 : 1, "bridge"\)') {
        throw 'WheelBridgeMsg 的 curPage=0 分支不再把上下都交给 WheelHandle'
    }
    $js = Read-Raw (Join-Path $root 'wallpaper\dsh.js')
    if ($js -notmatch 'setTimeout\(scrollPoll,\s*40\)' -and $js -notmatch 'after\(40,\s*scrollPoll\)') { throw 'dsh.js 的 /scroll.js 轮询不是 40ms（80ms 时一格滚轮要等小半秒）' }
    $q = [regex]::Match($js, 'function queueScroll\(px\)\s*\{(?<q>[\s\S]*?)\r?\n  \}')
    if (-not $q.Success) { throw '找不到 queueScroll 函数体' }
    # 只看代码行：注释里会解释「为什么不排 setTimeout」，不能拿注释判失败
    $qcode = (($q.Groups['q'].Value -split "\r?\n") | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    if ($qcode -match 'setTimeout') { throw 'queueScroll 又排 setTimeout 了 —— 多等一帧就是「滚轮发黏」' }
    '桥通道上下都接线；/scroll.js 40ms；scrollTop 立即落'
} -Hint '2026-11-06 用户报「只能向下滚、延迟大、卡卡的」：根因是桥把 up 丢了（curPage=0 直接 return）+ 80ms 轮询 + 排一帧 setTimeout'

Test-Case CON-012 '契约' '热重载单入口：只走 /scroll.js，页面不裸重载' high {
    # 背景：Lively 的 WebView2 上 location.reload() 会白屏（panel-rect 不再更新 → 抽屉滚轮落点全错）。
    # 2026-11-11 合并前令牌有两条入口：/scroll.js（40ms）与 /state.js 的 reload 字段（1.2s + 500ms 缓存）。
    # 后者在「/scroll.js 已消费、缓存未过期」的半秒里会重复下发同一个令牌，是白屏旁路的根。
    # 现在只保留 /scroll.js 一条入口；页面侧没有任何 location.reload，老页面兜底只在代理注入段。
    $root = Get-DshRoot
    $js = Read-Raw (Join-Path $root 'wallpaper\dsh.js')
    $code = @(($js -split "\r?\n") | Where-Object { $_ -notmatch '^\s*(//|\*|/\*)' })
    $calls = @($code | Where-Object { $_ -match 'location\.reload\s*\(' })
    if ($calls.Count -gt 0) {
        throw ("dsh.js 里还有 $($calls.Count) 处裸 location.reload()；页面侧应零处：" + ($calls -join ' | '))
    }
    if ($js -match 'st\.reload') { throw '/state.js 的 reload 旁路又回来了（令牌应只走 /scroll.js）' }
    if ($js -notmatch 'window\.__DSH_RELOAD_OK') { throw '页面没有暴露 __DSH_RELOAD_OK 钩子' }

    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    $m = [regex]::Match($agent, 'function Invoke-ScrollJs\((?<b>[\s\S]*?)\r?\n\}')
    if (-not $m.Success) { throw '找不到 Invoke-ScrollJs 函数体' }
    if ($m.Groups[1].Value -notmatch 'window\.__DSH_RELOAD_OK') { throw 'Invoke-ScrollJs 不再调 window.__DSH_RELOAD_OK，软重载链路断了' }
    $st = [regex]::Match($agent, 'function Invoke-StateJs\((?<b>[\s\S]*?)\r?\n\}')
    if (-not $st.Success) { throw '找不到 Invoke-StateJs 函数体' }
    if ($st.Groups[1].Value -match 'Get-ReloadToken') { throw '/state.js 又读 reload 令牌了（第二个入口复活）' }
    $wj = [regex]::Match($agent, 'function Write-Js\((?<b>[\s\S]*?)\r?\n\}')
    if (-not $wj.Success) { throw '找不到 Write-Js 函数体' }
    if ($wj.Groups[1].Value -match ',reload:') { throw 'Write-Js 仍在输出 reload 字段' }
    '令牌只由 /scroll.js 下发；dsh.js 无 location.reload，/state.js 无 reload 字段'
} -Hint 'P3（2026-11-11）：合并 /state.js 与 /scroll.js 两条热重载入口，消除 500ms 缓存重复下发与白屏旁路'

Test-Case CON-013 '契约' '巡检结果落进桌面控制台（<<< 机器消息）' medium {
    # 用户要求：每天巡跑完，结果要出现在桌面 DSH 面板的会话里。
    # 走 dsh-run.log 的机器消息行：[HH:mm:ss] <<< 文本（>>> 是用户指令，不许混用）。
    $root = Get-DshRoot
    $js = Read-Raw (Join-Path $root 'wallpaper\dsh.js')
    $pl = [regex]::Match($js, 'function parseLog\(text\)\s*\{(?<b>[\s\S]*?)\r?\n  \}')
    if (-not $pl.Success) { throw '找不到 parseLog 函数体（会话解析结构变了）' }
    $body = $pl.Groups['b'].Value
    if ($body -notmatch '<<<') { throw 'parseLog 不认识 <<< 机器消息 —— 巡检结果会被粘到上一条回复里' }
    if ($body -notmatch "role: 'dsh', time: n\[1\]") { throw '<<< 没有生成带自己时间的 DSH 气泡（会继承上一条用户指令的时间）' }

    $night = Read-Raw (Join-Path $root 'tests\Nightly-Check.ps1')
    if ($night -notmatch 'function Send-ConsoleNote') { throw 'Nightly-Check.ps1 没有 Send-ConsoleNote（巡检结果不会进面板）' }
    $fn = [regex]::Match($night, 'function Send-ConsoleNote\s*\{(?<b>[\s\S]*?)\r?\n\}')
    $fb = $fn.Groups['b'].Value
    if ($fb -notmatch 'dsh-run\.log') { throw 'Send-ConsoleNote 不写 dsh-run.log —— 面板读不到' }
    if ($fb -notmatch '<<<') { throw 'Send-ConsoleNote 没用 <<<，巡检结果会被当成用户自己发的指令' }
    if ($night -notmatch 'Send-ConsoleNote -Text') { throw '巡检主流程没调用 Send-ConsoleNote' }
    '<<< 机器消息 + 巡检脚本写入 dsh-run.log 都接上了'
} -Hint '2026-11-06 用户要求：每天脚本跑完在桌面控制台告诉我结果。若面板把巡检结果画成"你"的气泡，说明 <<< 被写成了 >>>'

Test-Case CON-014 '契约' '巡检报告不乱码（git 输出按 UTF-8 解码）' medium {
    # PowerShell 5.1 默认按控制台代码页（简中=GBK）解码原生命令输出，
    # git 的 UTF-8 中文提交标题/路径会变成「琛ユ湰…」。必须在调 git 前把控制台输出编码切到 UTF-8。
    $root = Get-DshRoot
    $night = Read-Raw (Join-Path $root 'tests\Nightly-Check.ps1')
    if ($night -notmatch '\[Console\]::OutputEncoding\s*=\s*New-Object System\.Text\.UTF8Encoding') {
        throw 'Nightly-Check.ps1 没把 [Console]::OutputEncoding 切到 UTF-8 —— 报告里的中文提交标题会变乱码'
    }
    if ($night -notmatch 'core\.quotepath=false') {
        throw 'git 调用没带 -c core.quotepath=false —— 中文路径会显示成 \346\226\207 八进制转义'
    }
    'git 输出按 UTF-8 解码、中文路径不转义'
} -Hint '2026-11-06：报告里提交标题/路径乱码（琛ユ湰…），根因是 PS 5.1 拿 GBK 解 UTF-8 的 git stdout'
Test-Case CON-015 '契约' '会话区支持按住拖动滚动（原生滚动条在壁纸里拖不动）' medium {
    # 2026-11-06 用户反馈：滚轮好了，但鼠标拖动不生效。
    # 壁纸页（Lively WebView2）里原生滚动条收不到 mousedown，只能自己实现抓拽滚动。
    $root = Get-DshRoot
    $js = Read-Raw (Join-Path $root 'wallpaper\dsh.js')
    if ($js -notmatch "logEl\.addEventListener\('pointerdown'") { throw '会话区没有 pointerdown 抓拽入口 —— 鼠标还是拖不动' }
    if ($js -notmatch 'dragScroll\s*=\s*\{\s*y:') { throw 'pointerdown 没建立拖动状态（dragScroll）' }
    if ($js -notmatch 'Math\.abs\(dy\)\s*<\s*4') { throw '拖动没有启动阈值 —— 单击/点输入框会被误判成拖动' }
    if ($js -notmatch "'dsh-dragging'") { throw '拖动时没有加 dsh-dragging 类（光标/禁选词不会生效）' }
    if ($js -notmatch 'clampScroll\(dragScroll\.top - dy, logEl\)') { throw '拖动没有按位移改 scrollTop' }
    if ($js -notmatch 'window\.__DSH_GEN !== GEN') { throw '拖动监听没有 GEN 守卫 —— 软重载几次后会叠出一串僵尸监听' }
    # 滚轮通道必须还在（用户先确认的是滚轮）
    if ($js -notmatch "addEventListener\('wheel'") { throw '滚轮监听被弄丢了' }

    $css = Read-Raw (Join-Path $root 'wallpaper\todo.css')
    if ($css -notmatch '#dshLog\.dsh-dragging') { throw 'CSS 缺 .dsh-dragging 状态（拖动时光标/选词）' }
    if ($css -notmatch 'cursor:\s*grabbing') { throw '.dsh-dragging 没把光标切成 grabbing —— 用户看不出"抓着拖"' }
    if ($css -notmatch 'user-select:\s*none') { throw '.dsh-dragging 没禁选词，拖一下会满屏蓝' }
    $sb = [regex]::Match($css, '#dshPanel #dshLog::-webkit-scrollbar\s*\{(?<b>[^}]*)\}')
    if (-not $sb.Success) { throw '找不到日志区滚动条样式' }
    if ($sb.Groups['b'].Value -notmatch 'width:\s*1[2-9]px|width:\s*[2-9]\dpx') { throw '滚动条太窄（<12px），拖不准' }
    '拖动滚动（pointerdown + 阈值 + GEN 守卫）与 12px 滚动条都在'
} -Hint '2026-11-06：滚轮修好后用户报"不能用鼠标拖动"。壁纸 WebView2 里原生滚动条收不到 mousedown，必须自己实现抓拽 + 加宽滚动条'
Test-Case CON-016 '契约' '巡检推送：代理连不上就直连重试一次' medium {
    # 2026-11-06 用户要求：本地代理（127.0.0.1:7897）没开时，07:30 巡检的推送不要直接红。
    # 只对"连接类失败"兜底，rejected / 凭据错照旧上报，不能盲目绕过代理。
    $root = Get-DshRoot
    $night = Read-Raw (Join-Path $root 'tests\Nightly-Check.ps1')
    $fn = [regex]::Match($night, 'function Invoke-GitPush\s*\{(?<b>[\s\S]*?)\r?\n\}')
    if (-not $fn.Success) { throw 'Nightly-Check.ps1 没有 Invoke-GitPush —— 推送还是会因为代理没开直接失败' }
    $body = $fn.Groups['b'].Value
    # 注释里也会写 http.proxy=（解释原因），顺序/存在性检查只看代码行
    $code = (($body -split "\r?\n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if ($code -notmatch "http\.proxy=" -or $code -notmatch "https\.proxy=") {
        throw '直连重试没有清掉 http.proxy / https.proxy（git -c 两个都要清）'
    }
    if ($code -notmatch 'Failed to connect|Could not connect') {
        throw '没有按"连接失败"字样判断是否该直连重试 —— 会把 rejected 之类也重试一遍'
    }
    $iGuard = $code.IndexOf('notmatch $proxyish')
    $iDirect = $code.IndexOf('http.proxy=')
    if ($iGuard -lt 0 -or $iDirect -lt 0 -or $iGuard -gt $iDirect) {
        throw '直连重试不在"连接类失败"判断之后 —— 等于无条件绕过代理'
    }
    # Invoke-GitPush 内部当然会调 Invoke-Git @('push'…)；这里只查推送段本身走没走兜底函数
    if ($night -notmatch 'Invoke-GitPush -Remote \$Remote -Branch \$Branch') { throw '推送段没有调用 Invoke-GitPush' }
    '推送失败先按连接错误判断，再 -c http.proxy= 直连重试一次'
} -Hint '2026-11-06 代理没开时巡检推送会红；只对 connect 类失败兜底，其它失败照旧报'
Test-Case CON-017 '契约' '热重载令牌：两条路径同源判据 + 先清后发' high {
    # 2026-11-07 实测：page-reload.txt 存在但内容为空时，/scroll.js 照样下发软重载（实测 True,False,False）。
    # 判据必须看有效数字（Get-ReloadToken -gt 0），不能看文件在不在；且必须先清令牌、确认清掉了再下发。
    $root = Get-DshRoot
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    $m = [regex]::Match($agent, 'function Invoke-ScrollJs\((?<b>[\s\S]*?)\r?\n\}')
    if (-not $m.Success) { throw '找不到 Invoke-ScrollJs 函数体' }
    $body = $m.Groups['b'].Value
    $code = (($body -split "\r?\n") | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"

    if ($code -notmatch '\(Get-ReloadToken\)\s*-gt\s*0') {
        throw '触发判据不是 Get-ReloadToken > 0 —— 又退回「文件存在就发」了（空文件会无限重插 dsh.js）'
    }
    if ($code -match 'if\s*\(\s*Test-Path\s+\$reloadFile\s*\)\s*\{') {
        throw '还在用「Test-Path 文件存在」当触发判据（和 /state.js 的 Get-ReloadToken 不同源）'
    }
    $iClear = $code.IndexOf('Remove-Item -LiteralPath $reloadFile')
    $iEmit = $code.IndexOf('__DSH_RELOAD_OK')
    if ($iClear -lt 0) { throw 'Invoke-ScrollJs 不再清令牌 —— 会每 40ms 重复下发' }
    if ($iEmit -lt 0) { throw 'Invoke-ScrollJs 不再调 window.__DSH_RELOAD_OK，软重载链路断了' }
    if ($iClear -gt $iEmit) { throw '先下发后清令牌：清不掉就开始无限重插（顺序必须是先清后发）' }
    if ($code -notmatch 'if\s*\(\s*\$cleared\s*\)') { throw '下发没有 $cleared 这道闸 —— 清不掉也照发' }

    # 活体复现（只动令牌文件，不弹窗、不动桌面）：空文件必须一次软重载都不发
    if (-not (Test-DshApiUp)) { return @{ Status = 'warn'; Detail = '静态契约通过；代理未在线，活体复现跳过' } }
    $rf = Join-Path $env:LOCALAPPDATA 'DesktopPage\page-reload.txt'
    $logF = Join-Path (Get-DshInstall) 'dsh-agent.log'
    $enc = New-Object System.Text.UTF8Encoding($false)

    # 令牌的消费者不止本进程：壁纸那边 40ms 一轮 /scroll.js，写下去之后大概率是页面那一轮先取走
    # （2026-11-15 10:10 实测：连写 5 个令牌全被页面抢走，本进程一次都没拿到 __DSH_RELOAD_OK，
    #  旧判据于是判红 —— 而链路本身是好的，页面当场就软重载了）。
    # 所以判据改成「一个令牌恰好触发一次软重载」：代理每发一次都会写一行
    # 'scroll: page-reload emitted'，谁抢到都算数，本进程能不能抢到不影响结论。
    function Count-Emits {
        if (-not (Test-Path -LiteralPath $logF)) { return 0 }
        try { $t = [System.IO.File]::ReadAllText($logF, [System.Text.Encoding]::UTF8) } catch { return -1 }
        return ([regex]::Matches($t, 'scroll: page-reload emitted')).Count
    }

    try {
        Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 120
        $base = Count-Emits
        if ($base -lt 0) { throw '读不到 dsh-agent.log，没法确认软重载到底有没有下发' }

        [System.IO.File]::WriteAllText($rf, '', $enc)
        $hitEmpty = 0
        for ($i = 0; $i -lt 2; $i++) {
            $r = Invoke-DshHttp -Path '/scroll.js' -TimeoutMs 2000
            if ($r.Ok -and $r.Body -match '__DSH_RELOAD_OK') { $hitEmpty++ }
        }
        Start-Sleep -Milliseconds 120
        $afterEmpty = Count-Emits
        if ($hitEmpty -gt 0) { throw "空令牌文件仍下发了软重载 $hitEmpty 次 —— 清不掉令牌的机器会无限重插 dsh.js" }
        if ($afterEmpty -gt $base) { throw ("空令牌文件被当成真令牌：日志里多发了 " + ($afterEmpty - $base) + " 次软重载（页面轮询抢到的那一路也一样）") }

        # 真令牌：必须恰好发一次，发完立刻失效（再发就会把 dsh.js 重插两份）
        Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 120
        $base = Count-Emits
        $sz0 = (Get-Item -LiteralPath $logF).Length
        [System.IO.File]::WriteAllText($rf, [string][long][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), $enc)
        $mine = $false
        for ($i = 0; $i -lt 8 -and -not $mine; $i++) {
            $r1 = Invoke-DshHttp -Path '/scroll.js' -TimeoutMs 2000
            if ($r1.Ok -and $r1.Body -match '__DSH_RELOAD_OK') { $mine = $true } else { Start-Sleep -Milliseconds 25 }
        }
        $gone = $false
        for ($i = 0; $i -lt 15 -and -not $gone; $i++) {
            if (-not (Test-Path -LiteralPath $rf)) { $gone = $true } else { Start-Sleep -Milliseconds 60 }
        }
        if (-not $gone) { throw '真令牌写下去 1 秒内没人消费 —— /scroll.js 已经不再读令牌了（热重载链路断了）' }
        Start-Sleep -Milliseconds 150
        if ((Get-Item -LiteralPath $logF).Length -lt $sz0) { throw 'dsh-agent.log 在用例执行期间被轮转，软重载次数没法对齐（重跑一遍）' }
        $after = Count-Emits
        if ($after -ne ($base + 1)) {
            throw ("一个令牌触发了 " + ($after - $base) + " 次软重载（必须恰好 1 次）：0 = 链路断了，>1 = 页面会被重插多份 dsh.js")
        }
        for ($i = 0; $i -lt 3; $i++) {
            $r2 = Invoke-DshHttp -Path '/scroll.js' -TimeoutMs 2000
            if ($r2.Ok -and $r2.Body -match '__DSH_RELOAD_OK') { throw '同一个令牌下发了两次 —— 页面会被重插两份 dsh.js' }
        }
        $by = $(if ($mine) { '本进程' } else { '页面轮询' })
        ('判据看有效数字 + 先清后发；空令牌 0 次下发，真令牌恰好 1 次（这次由' + $by + '取到）')
    } finally {
        try { if (Test-Path -LiteralPath $rf) { Remove-Item -LiteralPath $rf -Force -ErrorAction SilentlyContinue } } catch { }
    }
} -Hint '2026-11-07：Test-Path 判空文件也会发软重载；清不掉令牌时 /scroll.js 40ms 一轮无限重插 dsh.js'

Test-Case CON-018 '契约' '图标启动：带参快捷方式也必须走代理/队列' high {
    # 2026-11-08 复现：点「明日方舟：终末地」弹「Load launcher failed, module init error」。
    # audit.log 是 via=run，代理侧连 /launchpath.gif 的请求都没有 —— LaunchItem 里
    # `if (args = "")` 把带参快捷方式挡在代理之外，直接 AHK Run；鹰角启动器的保护模块
    # 按进程祖先拒绝初始化。桌面还有明日方舟（--game=Arknights --reason=4）、
    # 守望先锋（--productcode=pro）等带参快捷方式，都是同一个口子。
    $root = Get-DshRoot
    $ahk = Read-Raw (Join-Path $root 'drawer\DesktopPage.ahk')
    $m = [regex]::Match($ahk, '(?s)LaunchItem\(path\)\s*\{(.*?)\r?\n\}')
    if (-not $m.Success) { throw '找不到 LaunchItem 函数体（函数名或被拆了？）' }
    $body = $m.Groups[1].Value
    # 注释里会写旧写法（`if (args = "")`），判据只看代码行
    $code = (($body -split "\r?\n") | Where-Object { $_ -notmatch '^\s*;' }) -join "`n"

    if ($code -match 'if\s*\(\s*args\s*=\s*""\s*\)') {
        throw 'LaunchItem 还按 args="" 决定走不走代理 —— 带参快捷方式会绕过代理，鹰角启动器必弹 module init error'
    }
    $iTitle = $code.IndexOf('launch: no running instance')
    $iAgent = $code.LastIndexOf('AgentLaunch(path)')
    $iQueue = $code.IndexOf('QueueLaunch(path)')
    $iRun = $code.IndexOf('"ok=1 via=run path=" Aq(path) " pid="')
    if ($iTitle -lt 0) { throw '找不到"无实例"分支 —— LaunchItem 结构被改了，测试要跟着改' }
    if ($iAgent -lt 0 -or $iAgent -lt $iTitle) {
        throw '代理调用不在"无实例"分支之后 —— 带参/无参没有统一走代理'
    }
    if ($iQueue -lt 0 -or $iQueue -lt $iTitle) { throw '启动队列兜底不见了（代理挂掉时会退回 AHK 直跑）' }
    if ($iRun -lt 0) { throw '找不到最后的直连兜底 —— 测试要跟着改' }
    if ($iQueue -gt $iRun) { throw '顺序错了：队列必须在直连兜底之前' }
    if ($code -notmatch 'AgentLaunch\(path\)') { throw '代理调用消失' }
    '带参快捷方式不再绕过代理：代理 → 队列 → 直连兜底，顺序正确'
} -Hint '2026-11-08：明日方舟：终末地（--game=Endfield --reason=4）点一次弹一次 module init error；修好后带参 ≠ 直跑'

Test-Case CON-019 '契约' 'rect 零矩形三端约定：隐藏控制台 = 0 0 0 0' high {
    # 连续三轮的「右侧栏滚轮没反应」：控制台隐藏后页面不再上报（display:none 量出 0×0），
    # 代理又把 w=0 当坏数据丢掉，AHK 于是永远拿着上一次的矩形，滚轮继续走 act=console。
    # 约定：页面显式发 0 0 0 0；代理接受并原子落盘；AHK 读到零矩形就判定「不在控制台上」。
    $root = Get-DshRoot
    $js = Read-Raw (Join-Path $root 'wallpaper\dsh.js')
    $ps = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    $ahk = Read-Raw (Join-Path $root 'drawer\DesktopPage.ahk')
    $bad = @()

    if ($js -notmatch "'x=0&y=0&w=0&h=0'") { $bad += 'dsh.js 没有「控制台隐藏 → 零矩形」上报分支' }
    $iOff = $js.IndexOf('else if (!consoleOn())')
    if ($iOff -ge 0) {
        $iElse = $js.IndexOf('} else {', $iOff)
        if ($iElse -gt $iOff) {
            $seg = $js.Substring($iOff, $iElse - $iOff)
            if ($seg -match 'aside\.getBoundingClientRect') { $bad += 'dsh.js 的隐藏分支仍退回 aside（右侧导航栏会把滚轮继续吞掉）' }
        }
    }
    if ($js -notmatch 'syncConsole[\s\S]{0,400}reportRect\(\)') { $bad += 'syncConsole 没有在开关变化后立即上报矩形' }

    if ($ps -notmatch '\$rw -le 0') { $bad += '代理没有把负数/零宽归一成零矩形' }
    if ($ps -notmatch '\$rw -eq 0 -or \$rw -gt 200') { $bad += '代理仍用 w>200 当有效性闸 —— w=0 会被丢掉' }

    if ($ahk -notmatch 'if \(Integer\(parts\[3\]\) <= 0\)') { $bad += 'AHK PanelRect 仍把零矩形当坏数据回退 430px' }
    if ($ahk -notmatch 'if \(r\[3\] <= 0 \|\| r\[4\] <= 0\)') { $bad += 'AHK ConsoleUnderCursor 没有对零矩形早退' }

    if ($bad.Count -gt 0) { throw ($bad -join '；') }
    '三端同约定：页面发 0 0 0 0、代理接受、AHK 判「不在控制台」'
} -Hint '2026-11-11：w=0 连续第三轮挂账；只改一端仍会回退到旧矩形，三端必须同时认这个约定'
Test-Case CON-020 '契约' 'DockAdd 单写者：AHK 只发 op=add，不再直写 dock.txt' high {
    # P2（2026-11-11）：dock.txt 原来有两个写者 —— 代理的 Save-Dock（读旧→tmp→覆盖）
    # 与 AHK DockAdd 的 FileAppend。代理刚删完一项并覆盖，AHK 紧接着按旧内容追加，
    # 删除就被静默回滚。现在 AHK 只发 /dock.gif?op=add，查重/限 6/落盘全在代理里。
    $root = Get-DshRoot
    $ahk = Read-Raw (Join-Path $root 'drawer\DesktopPage.ahk')
    $m = [regex]::Match($ahk, '(?ms)^DockAdd\(it\)\s*\{(?<b>.*?)^\}')
    if (-not $m.Success) { throw '找不到 DockAdd 函数体' }
    $b = $m.Groups['b'].Value
    if ($b -match 'FileAppend') { throw 'DockAdd 还在直写 dock.txt（第二写者会和代理的原子覆盖抢文件）' }
    if ($b -match 'DockFile\(\)') { throw 'DockAdd 还在自己拼 dock.txt 路径' }
    if ($b -notmatch 'AgentDockAdd\(') { throw 'DockAdd 没有把添加动作交给代理' }
    $d = [regex]::Match($ahk, '(?ms)^AgentDockAdd\(path, name, iconName\)\s*\{(?<b>.*?)^\}')
    if (-not $d.Success) { throw '找不到 AgentDockAdd' }
    $db = $d.Groups['b'].Value
    if ($db -notmatch 'op=add') { throw 'AgentDockAdd 没带 op=add' }
    if ($db -notmatch 'UrlEncodePath') { throw 'AgentDockAdd 没对中文路径做百分号编码' }
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    $g = [regex]::Match($agent, 'function Invoke-DockGif\((?<b>[\s\S]*?)\r?\n\}')
    if (-not $g.Success) { throw '找不到 Invoke-DockGif' }
    $gb = $g.Groups['b'].Value
    if ($gb -notmatch "op=add") { throw '代理 Invoke-DockGif 没有 op=add 分支' }
    if ($gb -notmatch 'Save-Dock') { throw 'op=add 没有走原子 Save-Dock' }
    if ($gb -notmatch 'Count -ge 6') { throw 'op=add 没有 6 项上限检查' }
    if ($gb -notmatch 'Get-UrlParam') { throw 'op=add 没有解析 n/i 参数' }
    if (-not $gb.Contains('i=(-?\d+)(?:&|$)')) { throw 'op=del 的整数 i 没有锚定行尾：图标名 i=9831016285b4.png 会被当 Int32 溢出，整条 add 返回 {"ok":false}' }
    'DockAdd 单写者：AHK 发 op=add，代理查重 / 限 6 / 原子落盘'
} -Hint 'P2（2026-11-11）：AHK FileAppend 与代理 tmp+Move 并发时，代理会把刚追加的那条覆盖掉'

Test-Case CON-021 '契约' '组件契约表与路由表对齐' medium {
    # drawer\components.md 是三份组件之间的对外契约表。加接口时只改代码、不看它，
    # 这张表就会静默漂 —— 2026-11-20 实测它缺 /log.js /reload.gif /dbg.gif /iconbuild.gif
    # /icons.gif 五条，还写着「抽屉出站 /scroll.gif?d=」（抽屉根本不发，它直接追加 scroll.dat）。
    # 排障时照着它查「谁调这条接口」会查不到，所以把这张表也钉住（与 CON-004 同级，管的是另一份文档）。
    $t = Contract-RouteTable
    $doc = Read-Raw (Join-Path (Get-DshRoot) 'drawer\components.md')
    $m = [regex]::Match($doc, '\*\*路由\*\*：(.+?)(?:<br>|\r?\n)')
    if (-not $m.Success) { throw 'components.md 里找不到「**路由**：…」那一行（契约表的锚点被改了）' }
    $line = $m.Groups[1].Value

    $known = @($t.Routes | ForEach-Object { $_.TrimEnd('*') } | Sort-Object -Unique)
    $docSet = @()
    foreach ($mm in [regex]::Matches($line, '/[a-z]+\.(?:gif|js)|/state\b|/icon/')) { $docSet += $mm.Value }
    $docSet = @($docSet | Sort-Object -Unique)

    $undoc = @($known | Where-Object { $docSet -notcontains $_ })
    $dead = @($docSet | Where-Object { $known -notcontains $_ })

    if ($undoc.Count -gt 0 -or $dead.Count -gt 0) {
        $msg = @()
        if ($undoc.Count -gt 0) { $msg += ('契约表漏了 ' + $undoc.Count + ' 条：' + ($undoc -join '、')) }
        if ($dead.Count -gt 0) { $msg += ('契约表写了路由表里没有的：' + ($dead -join '、')) }
        throw (($msg -join '；') + ' —— 现在共 ' + $known.Count + ' 条路由')
    }
    ('组件契约表与路由表一致（' + $known.Count + ' 条）')
} -Hint '加路由 = $script:ROUTES 一行 + components.md 路由行 + 项目地图 §3 + 测试；三处缺一处就会漂'

Test-Case CON-022 '契约' 'summon 命令表四处对齐（代码 / 契约表 / 速查表 / 数据文件）' medium {
    # summon.cmd 是抽屉唯一的「文件召唤」入口（不依赖键鼠钩子）。同一批命令写在四个地方：
    #   ① drawer\DesktopPage.ahk 的 $SUMMON_CMDS —— 真相
    #   ② drawer\components.md 的「**文件命令**：」那半句
    #   ③ 项目地图 §6.1 的故障速查表
    #   ④ 项目地图 §5 的 `summon.cmd` 数据文件行
    # 2026-11-21 实测 ④ 少了 rescan / rollback / snaptest 三条（11-14 才加的快照回滚与重扫），
    # 照着 §5 排障的人会以为抽屉没有这两个入口。CON-021 只管「路由」那一行，这里管命令表。
    $ahk = Read-Raw (Join-Path (Get-DshRoot) 'drawer\DesktopPage.ahk')
    $mapM = [regex]::Match($ahk, '(?s)global\s+SUMMON_CMDS\s*:=\s*Map\((.*?)\r?\n\)')
    if (-not $mapM.Success) { throw 'DesktopPage.ahk 里找不到 $SUMMON_CMDS 表（锚点被改了）' }
    $cmds = @()
    $fns = @()
    foreach ($m in [regex]::Matches($mapM.Groups[1].Value, '"([^"]+)"\s*,\s*\{\s*fn:\s*([A-Za-z0-9_]+)')) {
        $cmds += $m.Groups[1].Value
        $fns += $m.Groups[2].Value
    }
    $cmds = @($cmds | Sort-Object -Unique)
    if ($cmds.Count -lt 3) { throw ('$SUMMON_CMDS 只解析出 ' + $cmds.Count + ' 条命令，解析规则和代码对不上了') }

    # 每个命令的处理函数必须真的存在（改名或删函数后，表里那条就成了死引用）
    $deadFn = @($fns | Sort-Object -Unique | Where-Object { $ahk -notmatch ('(?m)^[ \t]*' + [regex]::Escape($_) + '[ \t]*\(') })
    if ($deadFn.Count -gt 0) { throw ('$SUMMON_CMDS 指向了不存在的函数：' + ($deadFn -join '、')) }

    # 文档里一条命令可能写成 `foldertest=<路径>` / `log=<N>`，比对前把 <> 占位值抹掉
    function script:Resolve-SummonToken([string]$t) {
        $t = $t.Trim().Trim('`').Trim()
        $t = $t -replace '=<[^>]*>\s*$', '='
        return $t
    }
    function script:Split-SummonTokens([string]$s) {
        $o = @()
        foreach ($p in ($s -split '/')) {
            $x = Resolve-SummonToken $p
            if ($x -and $x -match '^[a-z]') { $o += $x }
        }
        return @($o | Sort-Object -Unique)
    }

    $msg = @()

    $doc = Read-Raw (Join-Path (Get-DshRoot) 'drawer\components.md')
    $dm = [regex]::Match($doc, '\*\*文件命令\*\*：.+?（(.+?)，表在')
    if (-not $dm.Success) { throw 'components.md 里找不到「**文件命令**：…（…，表在 `SUMMON_CMDS`）」那句（锚点被改了）' }
    $docCmds = Split-SummonTokens $dm.Groups[1].Value

    $map = Read-Raw (Join-Path (Get-DshRoot) 'docs\项目地图.md')
    $s61 = [regex]::Match($map, '(?s)### 6\.1.*?(?=\r?\n### 6\.2)')
    if (-not $s61.Success) { throw '项目地图 里找不到 §6.1 那段（锚点被改了）' }
    $quick = @()
    foreach ($row in [regex]::Matches($s61.Value, '(?m)^\|[ \t]*([^|\r\n]+?)[ \t]*\|')) {
        $cell = $row.Groups[1].Value
        if ($cell -match '^内容$' -or $cell -match '^-+$') { continue }
        $quick += Split-SummonTokens $cell
    }
    $quick = @($quick | Sort-Object -Unique)

    foreach ($pair in @(@{ Name = 'components.md 的文件命令'; Set = $docCmds }, @{ Name = '项目地图 §6.1 速查表'; Set = $quick })) {
        $miss = @($cmds | Where-Object { $pair.Set -notcontains $_ })
        $extra = @($pair.Set | Where-Object { $cmds -notcontains $_ })
        if ($miss.Count -gt 0) { $msg += ($pair.Name + ' 漏了 ' + $miss.Count + ' 条：' + ($miss -join '、')) }
        if ($extra.Count -gt 0) { $msg += ($pair.Name + ' 写了表里没有的：' + ($extra -join '、')) }
    }

    # §5 那一列允许写 `<路径>` 占位、也允许 `edge=0|1` 合并写法，所以只要求命令名被提到
    $s5 = [regex]::Match($map, '(?m)^\|[ \t]*`summon\.cmd`[ \t]*\|.*$')
    if (-not $s5.Success) { throw '项目地图 §5 里找不到 `summon.cmd` 那一行' }
    $bare = @($cmds | ForEach-Object { ($_ -replace '=.*$', '') } | Sort-Object -Unique)
    $miss5 = @($bare | Where-Object { $s5.Value -notmatch [regex]::Escape($_) })
    if ($miss5.Count -gt 0) { $msg += ('项目地图 §5 的 summon.cmd 行没提到：' + ($miss5 -join '、')) }

    if ($msg.Count -gt 0) { throw (($msg -join '；') + ' —— 真相现在共 ' + $cmds.Count + ' 条命令') }
    ('summon 命令表四处一致（' + $cmds.Count + ' 条，处理函数都在）')
} -Hint '加 summon 命令 = $SUMMON_CMDS 一行 + Summon_CmdXxx 函数 + components.md 文件命令 + 项目地图 §5 与 §6.1'
Test-Case CON-023 '契约' 'summon 前缀命令：prefix 字段与 SummonTick 匹配逻辑一致' medium {
    # $SUMMON_CMDS 里每条命令都带 prefix 字段，它决定这条命令怎么被匹配：
    #   prefix: false → 只走精确匹配（SUMMON_CMDS.Has(cmd)），写的时候必须一字不差
    #   prefix: true  → 精确匹配落空后再走前缀匹配，log=200 里的 200 就是参数
    # 这个字段此前没有任何判据盯着。把它从 true 改成 false，log=200 立刻永久不可达
    # （Has('log=200') 落空、前缀分支又被 if !e.prefix 跳过），而 SummonTick 对未知命令
    # 是静默忽略、日志干净 —— 表现成「写了 summon.cmd 没反应」，跟文件通道坏了长得一样。
    $ahk = Read-Raw (Join-Path (Get-DshRoot) 'drawer\DesktopPage.ahk')
    $mapM = [regex]::Match($ahk, '(?s)global\s+SUMMON_CMDS\s*:=\s*Map\((.*?)\r?\n\)')
    if (-not $mapM.Success) { throw 'DesktopPage.ahk 里找不到 $SUMMON_CMDS 表（锚点被改了）' }
    $body = $mapM.Groups[1].Value

    # 条目总数用「"名字", {」计：解析结果必须一条不少（格式一变宁可报错，不要静默少数）
    $declared = ([regex]::Matches($body, '"[^"]+"\s*,\s*\{')).Count
    $rows = @()
    foreach ($m in [regex]::Matches($body, '"([^"]+)"\s*,\s*\{\s*fn:\s*([A-Za-z0-9_]+)\s*,\s*prefix:\s*(true|false)')) {
        $rows += [pscustomobject]@{ Name = $m.Groups[1].Value; Fn = $m.Groups[2].Value; Prefix = ($m.Groups[3].Value -eq 'true') }
    }
    if ($rows.Count -eq 0) { throw '$SUMMON_CMDS 一条都没解析出来（解析规则和代码对不上了）' }
    if ($rows.Count -ne $declared) { throw ('$SUMMON_CMDS 有 ' + $declared + ' 条，只解析出 ' + $rows.Count + ' 条 —— 有条目缺 fn 或 prefix 字段，那条命令会静默走不到') }

    $msg = @()

    # ---- ① 静态形状：SummonTick 必须仍是「先精确、再只对 prefix 走前缀」----
    $st = [regex]::Match($ahk, '(?ms)^SummonTick\(\)\s*\{(.*?)^\}')
    if (-not $st.Success) { throw 'DesktopPage.ahk 里找不到 SummonTick() 函数体（锚点被改了）' }
    $stBody = $st.Groups[1].Value
    $iExact = $stBody.IndexOf('SUMMON_CMDS.Has(cmd)')
    $iLoop = $stBody.IndexOf('for name, e in SUMMON_CMDS')
    if ($iExact -lt 0) { $msg += 'SummonTick 里没有精确匹配分支（SUMMON_CMDS.Has(cmd)）—— 无参命令会全落到前缀匹配上' }
    if ($iLoop -lt 0) { $msg += 'SummonTick 里没有 for name, e in SUMMON_CMDS 前缀匹配循环' }
    if ($iExact -ge 0 -and $iLoop -ge 0 -and $iExact -gt $iLoop) { $msg += 'SummonTick 的前缀循环跑在精确匹配前面 —— 短命令会抢走长命令（log= 抢 log=200）' }
    if ($stBody -notmatch '(?m)^\s*if\s*!\s*e\.prefix\s*$') { $msg += 'SummonTick 的前缀循环不再过滤 e.prefix —— 所有命令都变前缀匹配（diagx 也会触发 diag）' }
    elseif ($stBody -notmatch '(?m)^\s*if\s*!\s*e\.prefix\s*\r?\n\s*continue\s*$') { $msg += 'SummonTick 的 if !e.prefix 后面没有紧接 continue，前缀循环会继续往下走' }
    if ($stBody -notmatch 'SubStr\(cmd,\s*1,\s*StrLen\(name\)\)\s*=\s*name') { $msg += 'SummonTick 的前缀比较不再是 SubStr(cmd, 1, StrLen(name)) = name' }
    if ($stBody -notmatch 'SubStr\(cmd,\s*StrLen\(name\)\s*\+\s*1\)') { $msg += 'SummonTick 取参数不再是 SubStr(cmd, StrLen(name) + 1)' }

    # ---- ② 表自洽：prefix 的取值必须与名字写法对得上 ----
    foreach ($r in $rows) {
        if ($r.Prefix -and -not $r.Name.EndsWith('=')) {
            $msg += ('"' + $r.Name + '" 标了 prefix: true 却不以 = 结尾 —— 任何以它开头的输入都会被吞掉')
        }
        if (-not $r.Prefix -and $r.Name.EndsWith('=')) {
            $msg += ('"' + $r.Name + '" 带 = 却是 prefix: false —— 参数永远进不来，只有一字不差写 "' + $r.Name + '" 才命中')
        }
    }
    for ($i = 0; $i -lt $rows.Count; $i++) {
        for ($j = 0; $j -lt $rows.Count; $j++) {
            if ($i -eq $j) { continue }
            if ($rows[$i].Name.Length -lt $rows[$j].Name.Length -and $rows[$j].Name.StartsWith($rows[$i].Name)) {
                $msg += ('"' + $rows[$i].Name + '" 是 "' + $rows[$j].Name + '" 的前缀 —— 结果依赖声明顺序，改成后者先声明就会抢走前者')
            }
        }
    }

    # ---- ③ 可达性模拟：按 SummonTick 的真实顺序跑一遍，每条命令的样本必须命中自己 ----
    function script:Resolve-SummonCmd([string]$cmd, $table) {
        foreach ($e in $table) { if ($e.Name -eq $cmd) { return $e } }      # 精确（Map 键查找）
        foreach ($e in $table) {                                            # 前缀（只对 prefix:true）
            if (-not $e.Prefix) { continue }
            if ($cmd.StartsWith($e.Name)) { return $e }
        }
        return $null
    }
    foreach ($r in $rows) {
        $sample = if ($r.Prefix) { $r.Name + 'SAMPLE' } else { $r.Name }
        $hit = Resolve-SummonCmd $sample $rows
        if (-not $hit) { $msg += ('"' + $sample + '" 一条路径都命中不了（这条命令实际不可用）') }
        elseif ($hit.Name -ne $r.Name) { $msg += ('"' + $sample + '" 命中的是 "' + $hit.Name + '" 而不是 "' + $r.Name + '"') }
    }

    $nPrefix = @($rows | Where-Object { $_.Prefix }).Count
    if ($msg.Count -gt 0) { throw (($msg -join '；') + ' —— 表里共 ' + $rows.Count + ' 条（prefix:true ' + $nPrefix + ' 条）') }
    ('前缀语义一致（' + $rows.Count + ' 条命令：prefix:true ' + $nPrefix + ' 条，每条都能唯一命中自己）')
} -Hint '带参命令写成 "xxx=" + prefix: true；无参命令写成 "xxx" + prefix: false。改 prefix 前先想清楚 SummonTick 是先精确、再只对 prefix 走前缀'
