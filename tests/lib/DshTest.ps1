#requires -Version 5.1
<#
  DshTest.ps1 —— 大肥鱼桌面系统 · 微型测试框架

  设计原则（为什么不用 Pester）：
    1) 目标机是 PowerShell 5.1，不保证装了 Pester（Win10/11 自带的 3.4 与 5.x 语法不兼容）；
    2) 这套系统的测试七成是「静态契约 + 本机 HTTP 探测」，不需要 mock 与 fixture；
    3) 报告要给"人"和"夜里自动跑的 AI"两种读者，字段必须固定、可机读。

  用例的三种结局：
    pass  —— 断言全过
    fail  —— 断言失败（throw 出来即 fail），退出码按 high/medium 的 fail 数计
    warn  —— 不符合最佳实践但可以运行（设计取舍 / 需要在白天人工确认）
    skip  —— 前置条件不满足（进程没起、需要 -Intrusive），不算失败

  用例写法：
    Test-Case CON-001 '契约' '端口五处一致' high {
        ...                       # 断言失败就 throw '原因'
        "端口全部为 17433"         # 返回字符串 = pass 时的明细
    } -Hint '改端口要同时改 5 处'

  要 warn/skip 时返回哈希表：@{ Status='warn'; Detail='…' }
#>

$script:DshTestState = @{
    Results = (New-Object System.Collections.ArrayList)
    Ctx     = @{}
    Opts    = @{ Case = '*'; Severity = 'all'; Intrusive = $false; Quiet = $false }
    Started = (Get-Date)
    Seq     = 0
}

# ---------------------------------------------------------------- 初始化 / 上下文

function Initialize-DshTest {
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [hashtable]$Options
    )
    $script:DshTestState.Ctx = $Context
    $script:DshTestState.Results.Clear()
    $script:DshTestState.Started = Get-Date
    $script:DshTestState.Seq = 0
    if ($Options) { foreach ($k in $Options.Keys) { $script:DshTestState.Opts[$k] = $Options[$k] } }
}

function Get-DshRoot    { return [string]$script:DshTestState.Ctx.Root }
function Get-DshInstall { return [string]$script:DshTestState.Ctx.Install }
function Get-DshWall    { return [string]$script:DshTestState.Ctx.Wall }
# 注意：用例文件里不能用 $PSScriptRoot —— 函数从别的脚本调用时它指向调用方，不可靠。
# 需要 tests\ 目录一律走这个。
function Get-DshTestsDir { return [string]$script:DshTestState.Ctx.Tests }
function Get-DshOpt([string]$k) { return $script:DshTestState.Opts[$k] }

function Join-Dsh([string]$base, [string]$rel) { return (Join-Path $base $rel) }

# 直接读源码（不经过 cmdlet 编码猜测）：.ps1 里中文注释多，Get-Content 在 ACP=936 下会乱码
function Read-Raw([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { throw ("文件不存在：" + $path) }
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Read-FirstBytes([string]$path, [int]$n = 4) {
    $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $buf = New-Object byte[] $n
        $read = $fs.Read($buf, 0, $n)
        if ($read -lt $n) { return $buf[0..($read - 1)] }
        return $buf
    } finally { $fs.Dispose() }
}

# ---------------------------------------------------------------- 断言

function Fail([string]$message) { throw $message }

function Assert-True([bool]$cond, [string]$message) { if (-not $cond) { throw $message } }

function Assert-Equal($actual, $expected, [string]$what) {
    if ("$actual" -ne "$expected") { throw ("$what：期望 [$expected]，实际 [$actual]") }
}

function Assert-Match([string]$text, [string]$pattern, [string]$what) {
    if ($text -notmatch $pattern) { throw ("$what：文本里没匹配到 /$pattern/") }
}

function Assert-NotMatch([string]$text, [string]$pattern, [string]$what) {
    if ($text -match $pattern) { throw ("$what：出现了不允许的 /$pattern/（命中：" + $Matches[0] + "）") }
}

function Assert-File([string]$path, [string]$what = '文件') {
    if (-not (Test-Path -LiteralPath $path)) { throw ("$what 不存在：" + $path) }
}

# ---------------------------------------------------------------- 本机 HTTP 探测

$script:DshHttpBase = 'http://127.0.0.1:17433'

function Set-DshApiPort([int]$port) { $script:DshHttpBase = "http://127.0.0.1:$port" }
function Get-DshApiBase { return $script:DshHttpBase }

<#
  为什么要自己写 HttpWebRequest 而不用 Invoke-WebRequest：
    · IWR 在 PS5.1 会走 IE 引擎解析（-UseBasicParsing 也慢），单次 20~40ms，测不出 200ms 红线；
    · 这台机器的 HTTPS_PROXY/https_proxy 环境变量会让 IWR/HttpClient 走代理，打 127.0.0.1 时随机失败。
  返回固定结构，避免用例里到处 try/catch。
#>
function Invoke-DshHttp {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('GET', 'OPTIONS', 'HEAD')][string]$Method = 'GET',
        [int]$TimeoutMs = 3000
    )
    $url = $script:DshHttpBase + $Path
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = @{
        Ok = $false; Status = 0; Ms = 0; Bytes = 0
        Body = ''; ContentType = ''; Error = ''; Url = $url
    }
    try {
        $req = [System.Net.HttpWebRequest]::Create($url)
        $req.Method = $Method
        $req.Timeout = $TimeoutMs
        $req.ReadWriteTimeout = $TimeoutMs
        $req.Proxy = $null                     # 关键：绕开环境里的代理变量
        $req.KeepAlive = $false
        $req.UserAgent = 'DshTest/1.0'
        $resp = $req.GetResponse()
        try {
            $out.Status = [int]$resp.StatusCode
            $out.ContentType = [string]$resp.ContentType
            $stream = $resp.GetResponseStream()
            $ms = New-Object System.IO.MemoryStream
            $buf = New-Object byte[] 8192
            while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
            $bytes = $ms.ToArray()
            $ms.Dispose()
            $out.Bytes = $bytes.Length
            if ($bytes.Length -gt 0) { $out.Body = [System.Text.Encoding]::UTF8.GetString($bytes) }
            $out.Ok = $true
        } finally { $resp.Close() }
    } catch [System.Net.WebException] {
        $we = $_.Exception
        if ($we.Response) {
            try { $out.Status = [int]$we.Response.StatusCode } catch { }
        }
        $out.Error = $we.Message
    } catch {
        $out.Error = $_.Exception.Message
    }
    $sw.Stop()
    $out.Ms = [int]$sw.ElapsedMilliseconds
    return $out
}

# 代理是否在线（不一定健康，只回答"能不能连上"）
function Test-DshApiUp {
    $r = Invoke-DshHttp -Path '/state.js' -TimeoutMs 1200
    return [bool]$r.Ok
}

# ---------------------------------------------------------------- 用例注册 / 执行

function Add-TestResult {
    param($Id, $Category, $Name, $Severity, $Status, $Detail, $Hint, $Ms)
    $script:DshTestState.Seq++
    $row = [ordered]@{
        Seq      = $script:DshTestState.Seq
        Id       = [string]$Id
        Category = [string]$Category
        Name     = [string]$Name
        Severity = [string]$Severity
        Status   = [string]$Status
        Detail   = [string]$Detail
        Hint     = [string]$Hint
        Ms       = [int]$Ms
    }
    [void]$script:DshTestState.Results.Add([pscustomobject]$row)

    if ($script:DshTestState.Opts.Quiet) { return }
    $tag = switch ($Status) {
        'pass' { ' OK ' }
        'fail' { 'FAIL' }
        'warn' { 'WARN' }
        'skip' { 'SKIP' }
        default { ' ???' }
    }
    $color = switch ($Status) {
        'pass' { 'Green' }
        'fail' { 'Red' }
        'warn' { 'Yellow' }
        default { 'DarkGray' }
    }
    $line = "[{0}] {1,-9} {2,-26} {3}" -f $tag, $Id, $Name, $Detail
    Write-Host $line -ForegroundColor $color
    if ($Status -eq 'fail' -and $Hint) { Write-Host ("        ↳ 建议：" + $Hint) -ForegroundColor DarkYellow }
}

function Test-Case {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('high', 'medium', 'low')][string]$Severity = 'medium',
        [Parameter(Mandatory)][scriptblock]$Body,
        [string]$Hint = '',
        [switch]$Intrusive
    )
    $opts = $script:DshTestState.Opts

    # ---- 过滤（-Case 支持 id / 名称片段 / 分类；-Severity 精确匹配）
    if ($opts.Case -and $opts.Case -ne '*') {
        $pat = [string]$opts.Case
        $hit = ($Id -like $pat) -or ($Name -like "*$pat*") -or ($Category -like "*$pat*")
        if (-not $hit) { return }
    }
    if ($opts.Severity -and $opts.Severity -ne 'all' -and $Severity -ne $opts.Severity) { return }

    if ($Intrusive -and -not $opts.Intrusive) {
        Add-TestResult $Id $Category $Name $Severity 'skip' '需要 -Intrusive（会改动桌面可见状态），默认不跑' $Hint 0
        return
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $status = 'pass'
    $detail = ''
    try {
        $r = & $Body
        if ($r -is [hashtable]) {
            if ($r.ContainsKey('Status') -and $r['Status']) { $status = [string]$r['Status'] }
            if ($r.ContainsKey('Detail') -and $r['Detail']) { $detail = [string]$r['Detail'] }
        } elseif ($null -ne $r) {
            $detail = [string]$r
        }
    } catch {
        $status = 'fail'
        $detail = $_.Exception.Message
    }
    $sw.Stop()
    Add-TestResult $Id $Category $Name $Severity $status $detail $Hint $sw.ElapsedMilliseconds
}

# ---------------------------------------------------------------- 统计 / 报告

function Get-DshTestResults { return $script:DshTestState.Results }

function Get-DshTestSummary {
    $rows = $script:DshTestState.Results
    $s = [ordered]@{
        Total = $rows.Count; Pass = 0; Fail = 0; Warn = 0; Skip = 0
        FailHigh = 0; FailMedium = 0; FailLow = 0
        WarnHigh = 0
        Blocking = 0            # 退出码用：high + medium 的 fail
        DurationMs = 0
    }
    foreach ($r in $rows) {
        switch ($r.Status) {
            'pass' { $s.Pass++ }
            'fail' {
                $s.Fail++
                switch ($r.Severity) {
                    'high' { $s.FailHigh++; $s.Blocking++ }
                    'medium' { $s.FailMedium++; $s.Blocking++ }
                    'low' { $s.FailLow++ }
                }
            }
            'warn' { $s.Warn++; if ($r.Severity -eq 'high') { $s.WarnHigh++ } }
            'skip' { $s.Skip++ }
        }
    }
    $s.DurationMs = [int]((((Get-Date) - $script:DshTestState.Started).TotalMilliseconds))
    return $s
}

function Test-DshAbort {
    # 序言用例（进程/端口）挂了就没必要继续打运行时断言 —— 会刷出一屏连锁 FAIL
    return @{ Status = 'skip'; Detail = '前置条件不满足，跳过' }
}

function ConvertTo-MdCell([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '\|', '\|' -replace "`r?`n", ' ').Trim()
}

function New-DshTestReport {
    param(
        [Parameter(Mandatory)][string]$OutDir,
        [string]$Title = '大肥鱼桌面系统 · 测试报告'
    )
    if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
    $rows = $script:DshTestState.Results
    $sum = Get-DshTestSummary
    $now = Get-Date

    # ---------- JSON（机器读：夜里自动修复就靠它）
    $json = [ordered]@{
        schema    = 'dsh-test-report/1'
        title     = $Title
        startedAt = $script:DshTestState.Started.ToString('yyyy-MM-dd HH:mm:ss')
        finishedAt = $now.ToString('yyyy-MM-dd HH:mm:ss')
        durationMs = $sum.DurationMs
        root      = (Get-DshRoot)
        install   = (Get-DshInstall)
        wallpaper = (Get-DshWall)
        options   = $script:DshTestState.Opts
        summary   = $sum
        results   = @($rows)
    }
    $jsonPath = Join-Path $OutDir 'last-report.json'
    ($json | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    # ---------- 历史快照（趋势 + "今天修好了什么"）
    $histDir = Join-Path $OutDir 'history'
    if (-not (Test-Path -LiteralPath $histDir)) { [void](New-Item -ItemType Directory -Path $histDir -Force) }
    $stamp = $now.ToString('yyyy-MM-dd_HHmm')
    $histPath = Join-Path $histDir ($stamp + '.json')
    ($json | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $histPath -Encoding UTF8

    # ---------- 与上一次比对
    $prev = $null
    $prevFiles = @(Get-ChildItem -LiteralPath $histDir -Filter '*.json' | Sort-Object Name -Descending | Where-Object { $_.FullName -ne $histPath })
    if ($prevFiles.Count -gt 0) {
        try { $prev = (Read-Raw $prevFiles[0].FullName) | ConvertFrom-Json } catch { $prev = $null }
    }
    $newFailIds = @()
    $fixedIds = @()
    if ($prev) {
        $prevFail = @($prev.results | Where-Object { $_.Status -eq 'fail' } | ForEach-Object { $_.Id })
        $nowFail = @($rows | Where-Object { $_.Status -eq 'fail' } | ForEach-Object { $_.Id })
        $newFailIds = @($nowFail | Where-Object { $prevFail -notcontains $_ })
        $fixedIds = @($prevFail | Where-Object { $nowFail -notcontains $_ })
    }

    # ---------- Markdown（人读）
    $md = New-Object System.Collections.ArrayList
    [void]$md.Add('# ' + $Title)
    [void]$md.Add('')
    [void]$md.Add("> 生成时间：$($now.ToString('yyyy-MM-dd HH:mm:ss'))　耗时 $([math]::Round($sum.DurationMs/1000,1))s")
    [void]$md.Add("> 源工程：``$(Get-DshRoot)``　运行时：``$(Get-DshInstall)``　壁纸：``$(Get-DshWall)``")
    [void]$md.Add('')
    [void]$md.Add('## 总览')
    [void]$md.Add('')
    [void]$md.Add('| 通过 | 失败 | 警告 | 跳过 | 合计 | 其中高/中危失败 |')
    [void]$md.Add('|---:|---:|---:|---:|---:|---:|')
    [void]$md.Add("| $($sum.Pass) | $($sum.Fail) | $($sum.Warn) | $($sum.Skip) | $($sum.Total) | $($sum.FailHigh)/$($sum.FailMedium) |")
    [void]$md.Add('')

    if ($newFailIds.Count -gt 0) { [void]$md.Add('**本次新增失败**：' + (($newFailIds | ForEach-Object { "``$_``" }) -join '、')) }
    if ($fixedIds.Count -gt 0) { [void]$md.Add('**对比上次已修复**：' + (($fixedIds | ForEach-Object { "``$_``" }) -join '、')) }
    if ($newFailIds.Count -gt 0 -or $fixedIds.Count -gt 0) { [void]$md.Add('') }

    # 分类汇总
    [void]$md.Add('## 分类汇总')
    [void]$md.Add('')
    [void]$md.Add('| 分类 | 用例 | 通过 | 失败 | 警告 | 跳过 |')
    [void]$md.Add('|---|---:|---:|---:|---:|---:|')
    $cats = @($rows | Group-Object Category | Sort-Object Name)
    foreach ($g in $cats) {
        $p = @($g.Group | Where-Object { $_.Status -eq 'pass' }).Count
        $f = @($g.Group | Where-Object { $_.Status -eq 'fail' }).Count
        $w = @($g.Group | Where-Object { $_.Status -eq 'warn' }).Count
        $k = @($g.Group | Where-Object { $_.Status -eq 'skip' }).Count
        [void]$md.Add("| $($g.Name) | $($g.Count) | $p | $f | $w | $k |")
    }
    [void]$md.Add('')

    # 必须先处理的问题
    $hot = @($rows | Where-Object { $_.Status -eq 'fail' -and $_.Severity -ne 'low' })
    [void]$md.Add('## 待修问题（fail · 高/中危）')
    [void]$md.Add('')
    if ($hot.Count -eq 0) {
        [void]$md.Add('无。')
    } else {
        foreach ($r in ($hot | Sort-Object @{ Expression = { switch ($_.Severity) { 'high' { 0 } 'medium' { 1 } default { 2 } } } }, Id)) {
            [void]$md.Add("### $($r.Id)　$($r.Name)　[$($r.Severity)]")
            [void]$md.Add('')
            [void]$md.Add('- 现象：' + (ConvertTo-MdCell $r.Detail))
            if ($r.Hint) { [void]$md.Add('- 建议：' + (ConvertTo-MdCell $r.Hint)) }
            [void]$md.Add('')
        }
    }

    # 风险提示（warn）
    $war = @($rows | Where-Object { $_.Status -eq 'warn' })
    [void]$md.Add('## 风险与优化建议（warn）')
    [void]$md.Add('')
    if ($war.Count -eq 0) {
        [void]$md.Add('无。')
    } else {
        [void]$md.Add('| 编号 | 项目 | 严重级 | 现象 | 建议 |')
        [void]$md.Add('|---|---|---|---|---|')
        foreach ($r in $war) {
            [void]$md.Add("| $($r.Id) | $(ConvertTo-MdCell $r.Name) | $($r.Severity) | $(ConvertTo-MdCell $r.Detail) | $(ConvertTo-MdCell $r.Hint) |")
        }
    }
    [void]$md.Add('')

    # 全量明细
    [void]$md.Add('## 全量明细')
    [void]$md.Add('')
    [void]$md.Add('| 编号 | 分类 | 项目 | 级别 | 结果 | 明细 | 耗时ms |')
    [void]$md.Add('|---|---|---|---|---|---|---:|')
    foreach ($r in $rows) {
        [void]$md.Add("| $($r.Id) | $($r.Category) | $(ConvertTo-MdCell $r.Name) | $($r.Severity) | $($r.Status) | $(ConvertTo-MdCell $r.Detail) | $($r.Ms) |")
    }
    [void]$md.Add('')

    $mdPath = Join-Path $OutDir 'last-report.md'
    ($md -join "`r`n") | Set-Content -LiteralPath $mdPath -Encoding UTF8

    return [pscustomobject]@{
        Json       = $jsonPath
        Markdown   = $mdPath
        History    = $histPath
        Summary    = $sum
        NewFails   = $newFailIds
        Fixed      = $fixedIds
        ExitCode   = $sum.Blocking
    }
}
