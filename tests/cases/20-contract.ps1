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

Test-Case CON-001 '契约' '代理端口各处一致' high {
    $root = Get-DshRoot
    # 只找 127.0.0.1:<port> 这个形态，不绑死 "API = '...'" 的写法：
    # 2026-11-03 起壁纸侧抽出 api.js 统一管 URL，dsh.js 变成 (window.__API||{}).url || '...'，
    # 绑死写法的正则会在重构后误报。
    $map = [ordered]@{}
    $files = @(
        @{ File = 'drawer\dsh-agent.ps1'; Label = 'dsh-agent'; Pattern = '(?m)^\s*\[int\]\$Port\s*=\s*(\d+)' }
        @{ File = 'drawer\agent-watch.ps1'; Label = 'agent-watch'; Pattern = '\[int\]\$Port\s*=\s*(\d+)' }
        @{ File = 'drawer\ensure-all.ps1'; Label = 'ensure-all'; Pattern = 'TestPort\s+(\d+)' }
        @{ File = 'drawer\DesktopPage.ahk'; Label = 'AHK' }
        @{ File = 'wallpaper\api.js'; Label = 'api.js' }
        @{ File = 'wallpaper\dsh.js'; Label = 'dsh.js' }
        @{ File = 'wallpaper\media.js'; Label = 'media.js' }
        @{ File = 'wallpaper\todo.js'; Label = 'todo.js' }
        @{ File = 'wallpaper\audit.js'; Label = 'audit.js' }
    )
    foreach ($f in $files) {
        $p = Join-Path $root $f.File
        if (-not (Test-Path -LiteralPath $p)) { throw ('缺文件：' + $f.File) }
        $t = Read-Raw $p
        # 默认找 URL 形态；两个看门狗脚本只存端口号（不拼 URL），单独给正则
        $pat = if ($f.ContainsKey('Pattern')) { $f.Pattern } else { '127\.0\.0\.1:(\d{4,5})' }
        $set = @([regex]::Matches($t, $pat) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        if ($set.Count -eq 0) { throw ($f.Label + '：在 ' + $f.File + ' 里找不到端口（正则 /' + $pat + '/）') }
        $map[$f.Label] = ($set -join '/')
    }
    $distinct = @($map.Values | ForEach-Object { $_ -split '/' } | Sort-Object -Unique)
    if ($distinct.Count -gt 1) {
        $desc = ($map.Keys | ForEach-Object { $_ + '=' + $map[$_] }) -join '，'
        throw ('端口不一致（' + $distinct.Count + ' 种）：' + $desc)
    }
    ('九处端口统一为 ' + $distinct[0])
} -Hint '端口没有统一配置项：改端口必须同时改这 9 处 + verify.ps1'

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

Test-Case CON-012 '契约' '热重载只走软重载（不硬刷页面）' high {
    # 背景：Lively 的 WebView2 上 location.reload() 会白屏（panel-rect 不再更新 → 抽屉滚轮落点全错）。
    # 令牌有两个入口：/scroll.js（40ms 搭便车）与 /state.js 的 reload 字段（1.2s，带 500ms 缓存）。
    # 2026-11-06 只改了前者，后者仍硬刷 —— 且「/scroll.js 已消费、/state.js 缓存未过期」那半秒
    # 里页面照样能收到同一个令牌，所以那条硬刷路径真实可达。
    $root = Get-DshRoot
    $js = Read-Raw (Join-Path $root 'wallpaper\dsh.js')
    # 只判代码行：注释里本来就会提到 location.reload（解释为什么不许用）
    $code = @(($js -split "\r?\n") | Where-Object { $_ -notmatch '^\s*(//|\*|/\*)' })
    $calls = @($code | Where-Object { $_ -match 'location\.reload\s*\(' })
    if ($calls.Count -gt 1) {
        throw ("dsh.js 里有 $($calls.Count) 处裸 location.reload()，只允许 softReload() 里那 1 处老页面兜底：`n" + ($calls -join "`n"))
    }
    # 先查真正的旁路（/state.js 那条），它才是历史上漏掉的那个入口
    $st = [regex]::Match($js, 'if \(st\.reload && st\.reload !== lastReload\)\s*\{(?<b>[\s\S]*?)\r?\n      \}')
    if (-not $st.Success) { throw '找不到 /state.js 的 reload 令牌分支（st.reload 判断）' }
    $stBody = $st.Groups['b'].Value
    if ($stBody -match 'location\.reload') { throw '/state.js 的令牌分支又直接 location.reload() 了 —— 这是条会白屏的旁路' }
    if ($stBody -notmatch 'softReload\(') { throw '/state.js 的令牌分支没有调用 softReload()' }
    $sr = [regex]::Match($js, 'function softReload\(tag\)\s*\{(?<b>[\s\S]*?)\r?\n  \}')
    if (-not $sr.Success) { throw '找不到 softReload() 函数体 —— 热重载又被摊成两套写法了' }
    $srBody = $sr.Groups['b'].Value
    if ($srBody -notmatch '__DSH_RELOAD_OK') { throw 'softReload() 没有先试 __DSH_RELOAD_OK —— 有钩子的页面也会被硬刷成白屏' }
    if ($calls.Count -eq 1 -and $srBody -notmatch 'location\.reload\s*\(') {
        throw '那唯一一处 location.reload() 不在 softReload() 里'
    }
    # 代理侧：/scroll.js 必须优先调钩子，只给老页面留兜底
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    $m = [regex]::Match($agent, 'function Invoke-ScrollJs\((?<b>[\s\S]*?)\r?\n\}')
    if (-not $m.Success) { throw '找不到 Invoke-ScrollJs 函数体' }
    if ($m.Groups[1].Value -notmatch 'window\.__DSH_RELOAD_OK') { throw 'Invoke-ScrollJs 不再调 window.__DSH_RELOAD_OK，软重载链路断了' }
    '两条令牌入口（/scroll.js、/state.js）都走 softReload；裸 location.reload 只剩 1 处老页面兜底'
} -Hint '2026-11-06：热重载改软重载时只改了 /scroll.js 那条，/state.js 的 reload 字段仍 location.reload()；加上 500ms 令牌缓存，这条白屏旁路真实可达'

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