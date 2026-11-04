#requires -Version 5.1
<#
  30-security.ps1 —— 安全风险
  这套系统的攻击面很窄但不为零：一个监听 127.0.0.1 的 HTTP 服务、
  一堆能把任意路径变成"启动"和"写文件"的信标。任何本机进程、任何能发 <img> 的页面
  都可能打到它。这一组专门验证「输入不可信」这条线有没有守住。

  默认只跑只读探测 + 一条审计自测行（会在 audit.log 留一行 selftest，可 grep 掉）。
  真正会写待办/面板矩形的用例标了 -Intrusive。
#>

function Sec-ReadShared([string]$path, [int]$maxLines = 300) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $fs = $null
    try {
        # 这些日志正被别的进程追加：必须带 ReadWrite 共享，否则一读就抛占用
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $all = $sr.ReadToEnd()
        $sr.Dispose()
        $lines = @($all -split "`r?`n")
        if ($lines.Count -gt $maxLines) { $lines = @($lines[($lines.Count - $maxLines)..($lines.Count - 1)]) }
        return $lines
    } catch {
        return @()
    } finally {
        if ($fs) { try { $fs.Dispose() } catch { } }
    }
}

Test-Case SEC-001 '安全' '图标接口挡住路径穿越' high {
    if (-not (Test-DshApiUp)) { return (Test-DshAbort) }
    # /icon/ 是唯一带"文件尾巴"的接口。它靠把非白名单字符全删掉来防穿越，
    # 这条用例就是验证那行 replace 真的生效（历史上有人顺手删过类似的过滤）。
    $probes = @(
        '/icon/..%2F..%2Fstart-all.vbs',
        '/icon/....//....//start-all.vbs',
        '/icon/%2e%2e%2f%2e%2e%2fdsh-agent.ps1',
        '/icon/..%5C..%5CDesktopPage.ps1'
    )
    $leaks = @()
    foreach ($p in $probes) {
        $r = Invoke-DshHttp -Path $p -TimeoutMs 2500
        if (-not $r.Ok) { continue }
        $b = [string]$r.Body
        if ($b -match 'WScript\.CreateObject|#requires -Version|\[CmdletBinding\(\)\]|DesktopPage_agentwatch') {
            $leaks += ($p + ' → 返回了文件内容')
        }
    }
    if ($leaks.Count -gt 0) { throw ($leaks -join '；') }
    ('4 种穿越写法全部被挡（未泄露文件内容）')
} -Hint "Invoke-IconPath 里那句 `$fn -replace '[^A-Za-z0-9._-]', '' 是唯一防线，别删"

Test-Case SEC-002 '安全' '未知路由不泄露内部信息' medium {
    if (-not (Test-DshApiUp)) { return (Test-DshAbort) }
    $r = Invoke-DshHttp -Path '/nope-route.gif' -TimeoutMs 2500
    if (-not $r.Ok) { throw ('请求失败：' + $r.Error) }
    $b = [string]$r.Body
    Assert-Match $b '"ok"\s*:\s*false' '未知路由响应体'
    Assert-NotMatch $b '(?i)exception|stack\s*trace|at line \d|C:\\\\Users|PS C:' '未知路由响应体'
    ('200 + {"ok":false}，无堆栈/路径泄露')
} -Hint '异常一律回 {"ok":false}：错误细节只进 dsh-agent.log，不回给调用方'

Test-Case SEC-003 '安全' '审计行不能被注入伪造' high {
    if (-not (Test-DshApiUp)) { return (Test-DshAbort) }
    $audit = Join-Path (Get-DshInstall) 'audit.log'
    if (-not (Test-Path -LiteralPath $audit)) { return @{ Status = 'skip'; Detail = 'audit.log 还没生成' } }

    $forged = '2099-01-01 00:00:00.000 [AHK ] fake-forged-line'
    $q = '/audit.gif?e=SELFTEST-INJECT&k=' + [System.Uri]::EscapeDataString($forged) + '&_=' + [DateTime]::Now.Ticks
    $r = Invoke-DshHttp -Path $q -TimeoutMs 2500
    if (-not $r.Ok) { throw ('信标请求失败：' + $r.Error) }
    Start-Sleep -Milliseconds 250

    $lines = Sec-ReadShared $audit 200
    $bad = @($lines | Where-Object { $_ -match '^2099-01-01' -or $_ -match '\[AHK \]\s+fake-forged-line' })
    if ($bad.Count -gt 0) { throw ('审计被注入：' + $bad[0] + ' —— %0A 能伪造整行日志，事后排查会被带偏') }
    ('注入 1 行未成功（换行/方括号均被剥离），audit.log 末 ' + $lines.Count + ' 行完好')
} -Hint "Invoke-AuditGif 里 `$ae -replace '[\[\]\r\n\t]','' + 截断 32/200 是唯一防线"

Test-Case SEC-004 '安全' '任意路径启动接口有防护' high {
    $t = Contract-RouteTable
    if ($t.Routes -notcontains '/launchpath.gif') { return @{ Status = 'skip'; Detail = '路由不存在（接口已下线）' } }
    $src = $t.Src
    # 这条接口接受任意路径并直接 Start-Process。任何本机进程（含用户正在浏览的页面发出的
    # <img> 信标）都能触发它 —— 等于给"打开任意 exe"开了一个无认证的口子。
    # 判定：有没有做来源校验（令牌/随机数/Referer/Origin 白名单）。
    $guard = ($src -match '(?i)X-DSH-Token|nonce|allowedorigin|Origin\s*-eq|Referer\s*-match')
    if (-not $guard) {
        return @{
            Status = 'warn'
            Detail = '/launchpath.gif 无任何来源校验：本机任意进程/页面发一个 <img> 就能拉起任意 exe'
        }
    }
    '存在来源校验'
} -Hint '建议加一次性令牌（启动时写 nonce 文件，壁纸读文件后再带上）；不加也要在文档里写明这是已知取舍'

Test-Case SEC-005 '安全' 'CSP 缺 script-src 收敛' medium {
    $html = Read-Raw (Join-Path (Get-DshRoot) 'wallpaper\index.html')
    $m = [regex]::Match($html, "Content-Security-Policy[\s\S]{0,300}?content=""([^""]+)""")
    if (-not $m.Success) { throw 'index.html 里找不到 CSP meta' }
    $csp = $m.Groups[1].Value
    if ($csp -notmatch 'script-src') {
        return @{
            Status = 'warn'
            Detail = 'CSP 没有 script-src：任何注入的 <script> 都能执行（file:// 页面被替换时无第二道防线）'
        }
    }
    if ($csp -notmatch 'http://127\.0\.0\.1:(\d+)') {
        return @{ Status = 'warn'; Detail = 'script-src 未放行 JSONP 源，插 <script src=代理> 会被拦' }
    }
    'CSP 已收敛 script-src 且放行 JSONP 源'
} -Hint "可加 script-src 'self' http://127.0.0.1:17433（JSONP 用的是 <script src>，必须放行）"

Test-Case SEC-006 '安全' '代理只监听本机回环' high {
    $src = Read-Raw (Join-Path (Get-DshRoot) 'drawer\dsh-agent.ps1')
    Assert-Match $src 'Prefixes\.Add\("http://127\.0\.0\.1:' '监听前缀'
    Assert-NotMatch $src 'Prefixes\.Add\("http://(\+|\*|0\.0\.0\.0)' '监听前缀'
    '监听前缀仅 127.0.0.1（不对局域网开放）'
} -Hint '别改成 + 或 0.0.0.0：这类"帮同事远程看看"的临时改动会长期留在机器上'

Test-Case SEC-007 '安全' '日志里没有密钥明文' high {
    $inst = Get-DshInstall
    $hits = @()
    foreach ($n in @('dsh-agent.log', 'audit.log', 'dsh-run.log', 'start-all.log')) {
        $p = Join-Path $inst $n
        foreach ($line in (Sec-ReadShared $p 400)) {
            if ($line -match 'sk-[A-Za-z0-9]{16,}') { $hits += $n; break }
        }
    }
    if ($hits.Count -gt 0) { throw ('这些日志里出现疑似 API Key：' + ($hits -join '、')) }
    ('检查 4 份日志共 ' + 400 + '×4 行，无 sk- 明文')
} -Hint '余额查询用的 key 在 E:\DSH\.dsh\.env；日志只能记 ok/fail，不能记请求头与 key'

Test-Case SEC-008 '安全' '待办文本不能注入多行' medium {
    # 不碰真实 todo.txt：把 dsh-agent.ps1 复制到临时目录、换掉单实例互斥体名，
    # 用独立端口 + 只给子进程改的 LOCALAPPDATA 起一个一次性实例，注完立刻杀掉。
    #
    # 为什么不再是 -Intrusive：这条原来靠"备份→注一条→还原"验真实的 todo.txt，
    # 于是日常 Safe 模式永远跳过 —— 等于没人知道清洗到底在不在（2026-11-04 的日志
    # 就据此误判成"代码未修"，实际早就修了）。隔离实例既不改用户数据，又能真跑。
    $srcAgent = Join-Dsh (Get-DshRoot) 'drawer\dsh-agent.ps1'
    if (-not (Test-Path -LiteralPath $srcAgent)) { throw '源码里找不到 drawer\dsh-agent.ps1' }

    $tmp = Join-Path $env:TEMP ('dsh_sec008_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $app = Join-Path $tmp 'DesktopPage'
    [void][System.IO.Directory]::CreateDirectory($app)

    # 借一个空闲端口：先绑 0 拿到号再放开，真正 Listen 的是子进程
    $tl = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $tl.Start(); $port = [int]$tl.LocalEndpoint.Port; $tl.Stop()

    $code = [System.IO.File]::ReadAllText($srcAgent, [System.Text.Encoding]::UTF8)
    $mtxOld = "'Global\DesktopPage_dshagent'"
    if (-not $code.Contains($mtxOld)) { throw '找不到单实例互斥体名，隔离不了（代理结构变了？）' }
    $code = $code.Replace($mtxOld, "'Local\DesktopPage_dshagent_SEC008'")
    $dst = Join-Path $tmp 'agent-selftest.ps1'
    [System.IO.File]::WriteAllText($dst, $code, (New-Object System.Text.UTF8Encoding($true)))

    $todo = Join-Path $app 'todo.txt'
    [System.IO.File]::WriteAllLines($todo, [string[]]@('alpha task', 'beta task'), (New-Object System.Text.UTF8Encoding($false)))

    $proc = $null
    try {
        # 只让子进程看到临时 LOCALAPPDATA：它的 $appDir 落到临时目录，真实待办一个字都不动。
        # 用「改环境变量 → Start-Process → 立刻还原」而不是 ProcessStartInfo.EnvironmentVariables
        # （后者在本机 PS 5.1 上取到 null，赋值直接抛「无法对 Null 数组进行索引」）。
        $oldLad = $env:LOCALAPPDATA
        $env:LOCALAPPDATA = $tmp
        try {
            $proc = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dst, '-Port', "$port") `
                -WindowStyle Hidden -PassThru
        } finally {
            $env:LOCALAPPDATA = $oldLad
        }

        $up = $false
        for ($i = 0; $i -lt 50; $i++) {
            if ($proc.HasExited) { break }
            try {
                $tc = New-Object System.Net.Sockets.TcpClient
                $tc.Connect('127.0.0.1', $port); $tc.Close(); $up = $true; break
            } catch { Start-Sleep -Milliseconds 300 }
        }
        if (-not $up) { throw ('隔离实例没起来（端口 ' + $port + '），SEC-008 无法验证') }

        $before = @([System.IO.File]::ReadAllLines($todo)).Count
        $payload = [System.Uri]::EscapeDataString("SEC008`r`nINJECTED-BY-TEST")
        $req = [System.Net.WebRequest]::Create('http://127.0.0.1:' + $port + '/todo.gif?op=add&t=' + $payload)
        $req.Timeout = 3000
        try { $resp = $req.GetResponse(); $resp.Close() } catch { }
        Start-Sleep -Milliseconds 400

        $lines = @([System.IO.File]::ReadAllLines($todo))
        $delta = $lines.Count - $before
        if ($delta -gt 1) {
            throw ('待办从 ' + $before + ' 行涨到 ' + $lines.Count + ' 行：一次 add 写进了多行（换行未过滤）')
        }
        ('隔离实例 add 一次只增 ' + $delta + ' 行，%0A 注入被压成单行（末行：' + $lines[-1] + '）')
    } finally {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
        try { [System.IO.Directory]::Delete($tmp, $true) } catch { }
    }
} -Hint 'Invoke-TodoGif 应在入库前把 [\r\n] 压成空格；否则一条待办能伪造多条。用例走隔离实例，不写真实 todo.txt'
