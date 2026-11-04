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
    ('7 个 JSONP / 数据变量名两端一致')
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
