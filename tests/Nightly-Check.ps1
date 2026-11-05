#Requires -Version 5.1
<#
.SYNOPSIS
    每日 07:30 巡检：看昨晚别的智能体对桌面系统做了什么（测试 + 重构），
    确认没有严重缺陷后把重构内容推送到 dev 分支，并生成一份中文汇报。

.DESCRIPTION
    判定口径（硬规则）：
      1. 只碰 dev 分支。main 分支一律不动（main 只由人放行）。
      2. 「严重缺陷」= tests\Run-Tests.ps1 退出码非 0（退出码本就等于高/中危失败数），
         或报告里 高>0 / 中>0。有严重缺陷 → 不推送、退出码 1。
      3. 工作区有未提交改动时：先跑测试，测试通过才提交（默认 -CommitDirty），
         失败就原样留着不提交。
      4. 推送失败（凭据/网络）→ 报告里写清楚，退出码 2，不重试。

    产出：
      <OutDir>\<yyyy-MM-dd>.md   当天汇报（人看）
      <OutDir>\latest.md         最新一份（方便随时打开）
      <OutDir>\nightly.log       运行日志（追加）

.PARAMETER DryRun
    只体检不推送、不提交（用来手工验证脚本本身）。

.PARAMETER NoNotify
    不发 Windows 通知（默认发）。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Nightly-Check.ps1 -DryRun

.NOTES
    计划任务：`大肥鱼 每日巡检`（每天 07:30，见 tests\Register-Nightly.ps1）。
#>
[CmdletBinding()]
param(
    [string]$Repo = 'E:\DSHWORK\repo\大肥鱼操作系统',
    [string]$Branch = 'dev',
    [string]$Remote = 'origin',
    [string]$OutDir = 'E:\DSHWORK\nightly',
    [switch]$DryRun,
    [switch]$NoNotify,
    [switch]$NoCommitDirty,
    [switch]$NoAi
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------- 基础设施 ----------
$script:LogFile = $null
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

function Invoke-Git {
    param([string[]]$Arguments, [switch]$AllowFail)
    # git 会往 stderr 写进度；ErrorActionPreference=Stop 下会被当成终止错误，必须临时放行
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $Repo @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $text = (($out | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($code -ne 0 -and -not $AllowFail) {
        throw "git $($Arguments -join ' ') 失败（exit=$code）：$text"
    }
    return [pscustomobject]@{ Code = $code; Text = $text }
}

function Get-TestStats {
    param([string]$Text)
    $stats = [pscustomobject]@{ Passed = -1; Failed = -1; High = -1; Mid = -1; Low = -1; Warn = -1; Skip = -1; Raw = $null }
    $line = ($Text -split "`n") | Where-Object { $_ -match '通过\s*\d+\s*失败' } | Select-Object -Last 1
    if ($line) {
        $stats.Raw = $line.Trim()
        if ($line -match '通过\s*(\d+)') { $stats.Passed = [int]$Matches[1] }
        if ($line -match '失败\s*(\d+)') { $stats.Failed = [int]$Matches[1] }
        if ($line -match '高\s*(\d+)')    { $stats.High = [int]$Matches[1] }
        if ($line -match '中\s*(\d+)')    { $stats.Mid = [int]$Matches[1] }
        if ($line -match '低\s*(\d+)')    { $stats.Low = [int]$Matches[1] }
        if ($line -match '警告\s*(\d+)')  { $stats.Warn = [int]$Matches[1] }
        if ($line -match '跳过\s*(\d+)')  { $stats.Skip = [int]$Matches[1] }
    }
    return $stats
}

function Send-Toast {
    param([string]$Title, [string]$Body)
    try {
        $appId = 'Microsoft.Windows.PowerShell'
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
        $xml = @"
<toast><visual><binding template="ToastGeneric">
<text>$([System.Security.SecurityElement]::Escape($Title))</text>
<text>$([System.Security.SecurityElement]::Escape($Body))</text>
</binding></visual></toast>
"@
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml($xml)
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        Write-Log "通知发送失败（不影响巡检结果）：$($_.Exception.Message)" 'WARN'
    }
}

# ---------- 质量点评 ----------
function Get-RiskHits {
    param([string[]]$Files)
    $patterns = @(
        @{ Name = '抽屉主脚本 DesktopPage.ahk'; Rx = '^drawer/DesktopPage\.ahk$' },
        @{ Name = '代理 dsh-agent.ps1';        Rx = '^drawer/dsh-agent\.ps1$' },
        @{ Name = '启动链 start-all.vbs';      Rx = '^drawer/start-all\.vbs$' },
        @{ Name = '巡检 ensure-all.ps1';       Rx = '^drawer/ensure-all\.ps1$' },
        @{ Name = '滚轮桥 wheel-bridge.ps1';   Rx = '^drawer/wheel-bridge\.ps1$' },
        @{ Name = '安装脚本 install.ps1';      Rx = '^install\.ps1$' },
        @{ Name = '壁纸页 wallpaper/**';       Rx = '^wallpaper/' }
    )
    $hits = @()
    foreach ($p in $patterns) {
        $hit = $Files | Where-Object { $_ -match $p.Rx }
        if ($hit) { $hits += $p.Name }
    }
    return $hits
}

function Get-PrevTestStats {
    param([string]$Path)
    $out = [pscustomobject]@{ Passed = -1; Warn = -1; Failed = -1; Date = '' }
    if (-not (Test-Path $Path)) { return $out }
    try {
        $txt = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ($txt -match '\| 回归测试 \| ([^|]+)\|') {
            $line = $Matches[1]
            if ($line -match '通过\s*(\d+)') { $out.Passed = [int]$Matches[1] }
            if ($line -match '警告\s*(\d+)') { $out.Warn = [int]$Matches[1] }
            if ($line -match '失败\s*(\d+)') { $out.Failed = [int]$Matches[1] }
        }
        if ($txt -match '# 桌面系统夜间巡检 · (\d{4}-\d{2}-\d{2})') { $out.Date = $Matches[1] }
    } catch { }
    return $out
}

function Invoke-AiReview {
    # 用独立进程 + 硬超时：Start-Job 里调 dsh.cmd 会卡死（实测 >180s 不返回），Start-Process 正常（2~4s）
    param([string]$PromptText, [int]$TimeoutSec = 180, [string]$WorkDir)
    $dsh = 'E:\DSH\dsh.cmd'
    $helper = Join-Path $PSScriptRoot 'ai-review.ps1'
    $ps5 = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path $ps5)) { $ps5 = 'C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe' }
    if ($NoAi) { return [pscustomobject]@{ Ok = $false; Text = ''; Note = '已跳过 AI 点评（-NoAi）' } }
    if (-not (Test-Path $dsh)) { return [pscustomobject]@{ Ok = $false; Text = ''; Note = '已跳过 AI 点评（找不到 dsh.cmd）' } }
    if (-not (Test-Path $helper)) { return [pscustomobject]@{ Ok = $false; Text = ''; Note = '已跳过 AI 点评（缺 tests\ai-review.ps1）' } }

    $proc = $null
    $tmp = Join-Path $WorkDir '.ai'
    $stamp = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $pf = Join-Path $tmp "prompt-$stamp.txt"
    $of = Join-Path $tmp "out-$stamp.txt"
    try {
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        [System.IO.File]::WriteAllText($pf, $PromptText, (New-Object System.Text.UTF8Encoding($false)))
        $proc = Start-Process -FilePath $ps5 -PassThru -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $helper + '"'),
            '-PromptFile', ('"' + $pf + '"'), '-OutFile', ('"' + $of + '"')
        )
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            return [pscustomobject]@{ Ok = $false; Text = ''; Note = "AI 点评超时（>${TimeoutSec}s）" }
        }
        $text = ''
        if (Test-Path $of) { $text = ([System.IO.File]::ReadAllText($of, [System.Text.Encoding]::UTF8)).Trim() }
        if ($text) { return [pscustomobject]@{ Ok = $true; Text = $text; Note = '' } }
        return [pscustomobject]@{ Ok = $false; Text = ''; Note = 'AI 没返回内容' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Text = ''; Note = "AI 点评失败：$($_.Exception.Message)" }
    } finally {
        if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
        foreach ($x in @($pf, $of)) { if (Test-Path $x) { Remove-Item $x -Force -ErrorAction SilentlyContinue } }
    }
}

function Get-QualityReview {
    param([object]$Commits, [object]$TestStats, [int]$AheadCount, [string]$Range = 'origin/dev..dev')
    $r = [pscustomobject]@{
        HasContent = $false
        Files = @(); Stat = ''; Additions = 0; Deletions = 0; Changed = 0
        TouchedTests = $false; TouchedDocs = $false; RiskFiles = @()
        Prev = $null; Score = -1; Verdict = ''
        AiText = ''; AiNote = ''
    }
    if (-not $Range) { return $r }

    $range = $Range
    $r.Files = @((Invoke-Git @('diff','--name-only',$range) -AllowFail).Text -split "\r?\n" | Where-Object { $_.Trim() })
    $r.Stat = (Invoke-Git @('diff','--shortstat',$range) -AllowFail).Text
    if ($r.Stat -match '(\d+) files? changed') { $r.Changed = [int]$Matches[1] }
    if ($r.Stat -match '(\d+) insertions?') { $r.Additions = [int]$Matches[1] }
    if ($r.Stat -match '(\d+) deletions?') { $r.Deletions = [int]$Matches[1] }
    $r.TouchedTests = [bool]($r.Files | Where-Object { $_ -match '^tests/' })
    $r.TouchedDocs = [bool]($r.Files | Where-Object { $_ -match '^(docs/|.*\.md$)' })
    $r.RiskFiles = Get-RiskHits -Files $r.Files
    $r.Prev = Get-PrevTestStats -Path $latestPath
    $r.HasContent = $true

    # 确定性评分：从 10 分往下扣，扣分理由逐条记下来
    $score = 10
    $why = @()
    if (-not $r.TouchedTests) { $score -= 3; $why += '改了代码但没动/没加测试用例（-3）' }
    if ($r.RiskFiles.Count -gt 0) { $score -= 2; $why += ('动了高风险文件：' + ($r.RiskFiles -join '、') + '（-2）') }
    if (-not $r.TouchedDocs) { $score -= 1; $why += '没同步文档（-1）' }
    if ($r.Prev.Passed -gt 0 -and $TestStats.Passed -ge 0 -and $TestStats.Passed -lt $r.Prev.Passed) {
        $score -= 2; $why += ("用例通过数从 $($r.Prev.Passed) 掉到 $($TestStats.Passed)（-2）")
    }
    if ($r.Prev.Warn -ge 0 -and $TestStats.Warn -gt $r.Prev.Warn) {
        $score -= 1; $why += ("警告数从 $($r.Prev.Warn) 涨到 $($TestStats.Warn)（-1）")
    }
    if ($r.Changed -gt 15) { $score -= 1; $why += ("单轮改了 $($r.Changed) 个文件（-1）") }
    if (($r.Additions + $r.Deletions) -gt 1500) { $score -= 1; $why += ("单轮 diff 超 1500 行（-1）") }
    if ($score -lt 0) { $score = 0 }
    $r.Score = $score
    $r.Verdict = if ($score -ge 8) { '可接受（自动推送）' } elseif ($score -ge 5) { '可接受，但建议人扫一眼' } else { '建议人工复核' }
    $r | Add-Member -NotePropertyName Reasons -NotePropertyValue $why -Force

    # AI 点评（可关：-NoAi）
    if ($NoAi) {
        $r.AiNote = '已跳过 AI 点评（-NoAi）'
        return $r
    }
    $commitLines = ($Commits | ForEach-Object { "- $($_.Hash) $($_.When) $($_.Subject)" }) -join "`n"
    $fileLines = ($r.Files | Select-Object -First 25) -join "`n"
    # 关键：点评只用内联 diff，禁止调用工具（让 AI 自己读仓库要跑几分钟、烧几十万 token）
    $diffText = (Invoke-Git @('diff','--unified=2',$range) -AllowFail).Text
    if (-not $diffText) { $diffText = '(无 diff 文本)' }
    # 截断策略：头尾各留一半，中间用省略标记——只留头部会只看到删除侧，模型会误判
    $diffCap = 7000
    $diffNote = ''
    if ($diffText.Length -gt $diffCap) {
        $half = [int]($diffCap / 2)
        $headPart = $diffText.Substring(0, $half)
        $tailPart = $diffText.Substring($diffText.Length - $half)
        $diffText = $headPart + "`n…（中间省略 " + ($diffText.Length - $diffCap) + " 字符）…`n" + $tailPart
        $diffNote = '（diff 超长，已保留头尾各 ' + $half + ' 字符）'
    }
    $prompt = @"
你是严谨的代码评审人，评审「大肥鱼桌面系统」（PowerShell 5.1 + AutoHotkey v2，单线程本地代理 + 文件耦合）。
本轮改动（未推送提交数 $AheadCount）：

$commitLines

改动文件：
$fileLines

规模：$($r.Stat)
回归结果：$($TestStats.Raw)

下面是本轮 diff$diffNote：

$diffText

要求：
1. 只根据上面这段内容点评，不要调用任何工具，不要读文件、不要跑命令。
2. 输出不超过 200 字的中文点评，分三小段，每段一句话：
   【实质】这轮到底改了什么机制（不要复述 commit 标题）
   【风险】最值得担心的一个点（具体到文件/行为；没有就写「未发现明显风险」）
   【建议】保留 / 补测试 / 回退，三选一并给一句理由
3. 不要客套话，不要 checklist，直接给三小段。
"@
    $ai = Invoke-AiReview -PromptText $prompt -WorkDir $OutDir
    $r.AiText = $ai.Text
    $r.AiNote = $ai.Note
    return $r
}
# ---------- 主流程 ----------
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$script:LogFile = Join-Path $OutDir 'nightly.log'
$today = Get-Date -Format 'yyyy-MM-dd'
$reportPath = Join-Path $OutDir "$today.md"
$latestPath = Join-Path $OutDir 'latest.md'

Write-Log ('=' * 60)
Write-Log ("巡检开始 repo=$Repo branch=$Branch dryrun=$([bool]$DryRun)")

$report = [ordered]@{
    Date        = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    Commits     = @()
    DirtyFiles  = @()
    TestRaw     = ''
    TestExit    = -1
    Stats       = $null
    Severe      = $false
    SevereWhy   = @()
    Pushed      = '否'
    PushDetail  = ''
    Committed   = '否'
    CommitHash  = ''
    Head        = ''
    Summary     = ''
}

try {
    if (-not (Test-Path (Join-Path $Repo '.git'))) { throw "不是 git 仓库：$Repo" }

    # 0) 分支守卫：绝不碰 main
    $current = (Invoke-Git @('branch','--show-current')).Text
    if ($current -eq 'main') { throw '当前在 main 分支上，巡检脚本拒绝运行（main 只由人放行）。请先切回 dev。' }
    if ($current -ne $Branch) {
        $dirtyNow = (Invoke-Git @('status','--porcelain')).Text
        if ($dirtyNow) { throw "当前不在 $Branch（在 $current）且工作区不干净，脚本不动它，请人工处理。" }
        Write-Log "当前在 $current，切到 $Branch"
        $null = Invoke-Git @('checkout',$Branch)
        $current = $Branch
    }

    # 1) 拉远端状态
    $null = Invoke-Git @('fetch',$Remote,'--prune') -AllowFail
    $remoteRef = "$Remote/$Branch"
    $hasRemote = (Invoke-Git @('rev-parse','--verify','--quiet',$remoteRef) -AllowFail).Code -eq 0

    # 2) 未推送提交（= 昨晚别人的重构）
    if ($hasRemote) {
        $range = "$remoteRef..$Branch"
        $logText = (Invoke-Git @('log','--no-merges','--pretty=format:%h|%ad|%s','--date=format:%m-%d %H:%M',$range) -AllowFail).Text
        if ($logText) {
            $report.Commits = @($logText -split "\r?\n" | Where-Object { $_ -match '\|' } | ForEach-Object {
                $p = $_ -split '\|', 3
                [pscustomobject]@{ Hash = $p[0].Trim(); When = $p[1].Trim(); Subject = $p[2].Trim() }
            })
        }
    } else {
        Write-Log "远端分支 $remoteRef 还不存在，本次只看本地" 'WARN'
    }

    # 3) 工作区未提交改动
    $dirty = (Invoke-Git @('status','--porcelain')).Text
    if ($dirty) {
        $report.DirtyFiles = @($dirty -split "\r?\n" | Where-Object { $_.Trim() })
        Write-Log ("工作区有 {0} 个未提交改动" -f $report.DirtyFiles.Count) 'WARN'
    }

    # 4) 跑回归
    Write-Log '跑 tests\Run-Tests.ps1 …'
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $testOut = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Repo 'tests\Run-Tests.ps1') 2>&1 | Out-String
    $report.TestExit = $LASTEXITCODE
    $report.Stats = Get-TestStats -Text $testOut
    $report.TestRaw = if ($report.Stats.Raw) { $report.Stats.Raw } else { ($testOut -split "`n" | Select-Object -Last 3) -join ' / ' }
    Write-Log ("回归结果 exit={0} :: {1}" -f $report.TestExit, $report.TestRaw)

    # 5) 严重缺陷判定
    if ($report.TestExit -ne 0) { $report.Severe = $true; $report.SevereWhy += "测试退出码 $($report.TestExit)（=高/中危失败数）" }
    if ($report.Stats.High -gt 0) { $report.Severe = $true; $report.SevereWhy += "高危失败 $($report.Stats.High) 项" }
    if ($report.Stats.Mid -gt 0)  { $report.Severe = $true; $report.SevereWhy += "中危失败 $($report.Stats.Mid) 项" }
    if ($report.Stats.Passed -lt 0) { $report.Severe = $true; $report.SevereWhy += '没能从输出里解析出结果行（可能整个测试跑挂了）' }

    # 6) 有严重缺陷：什么都不动
    if ($report.Severe) {
        $report.Summary = '发现严重缺陷，**没有推送**，dev 分支保持原样，等人工处理。'
        Write-Log ("严重缺陷，跳过提交与推送：{0}" -f ($report.SevereWhy -join '；')) 'ERROR'
    } else {
        # 6a) 未提交改动 → 先提交（测试已通过）
        if ($report.DirtyFiles.Count -gt 0) {
            if ($NoCommitDirty -or $DryRun) {
                Write-Log '有未提交改动，但本次不做提交（NoCommitDirty/DryRun）' 'WARN'
                $report.Committed = '未提交（保持工作区原样）'
            } else {
                $null = Invoke-Git @('add','-A')
                $msg = "chore(nightly): 自动提交 $today 巡检前的未提交改动（测试已通过）"
                $null = Invoke-Git @('commit','-m',$msg)
                $report.Committed = '是'
                $report.CommitHash = (Invoke-Git @('rev-parse','--short','HEAD')).Text
                Write-Log "已提交未提交改动：$($report.CommitHash)"
            }
        }

        # 6b) 推送 dev
        if ($hasRemote) {
            $report.PreRemoteSha = (Invoke-Git @('rev-parse','--verify',$remoteRef) -AllowFail).Text
            $ahead = (Invoke-Git @('rev-list','--count',"$remoteRef..$Branch") -AllowFail).Text
            $aheadN = 0; [int]::TryParse($ahead, [ref]$aheadN) | Out-Null
            if ($aheadN -eq 0) {
                $report.Pushed = '无需推送（dev 与远端一致）'
                $report.Summary = 'dev 没有新提交，测试全绿，**无需推送**。'
                Write-Log 'dev 与远端一致，无需推送'
            } elseif ($DryRun) {
                $report.Pushed = "未推送（DryRun，本应有 $aheadN 个提交待推）"
                $report.Summary = "体检通过；DryRun 模式，未推送 $aheadN 个提交。"
                Write-Log "DryRun：本应推送 $aheadN 个提交"
            } else {
                $env:GIT_TERMINAL_PROMPT = '0'
                $push = Invoke-Git @('push',$Remote,"${Branch}:${Branch}") -AllowFail
                if ($push.Code -eq 0) {
                    $report.Pushed = "已推送 $aheadN 个提交 → $remoteRef"
                    $report.Summary = "测试全绿、无严重缺陷，已把昨晚的重构推到 dev（$aheadN 个提交）。**main 未动**。"
                    Write-Log "推送成功：$remoteRef（$aheadN 个提交）"
                } else {
                    $report.Pushed = '推送失败'
                    $report.PushDetail = $push.Text
                    $report.Summary = '测试全绿，但**推送失败**（凭据/网络），dev 本地已就绪，等人工重试。'
                    Write-Log "推送失败：$($push.Text)" 'ERROR'
                }
            }
        } else {
            $report.Pushed = '远端分支不存在，未推送'
            $report.Summary = '远端还没有 dev 分支，未推送（需要人工建一次远端分支）。'
        }
    }

    $report.Head = (Invoke-Git @('log','-1','--pretty=format:%h %s') -AllowFail).Text
}
catch {
    $report.Severe = $true
    $report.SevereWhy += $_.Exception.Message
    $report.Summary = "巡检本身出错：$($_.Exception.Message)"
    Write-Log "巡检异常：$($_.Exception.Message)" 'ERROR'
}

# ---------- 质量点评 ----------
$quality = $null
try {
    $qAhead = 0
    [int]::TryParse((Invoke-Git @('rev-list','--count','origin/dev..dev') -AllowFail).Text, [ref]$qAhead) | Out-Null
    $headSha = (Invoke-Git @('rev-parse','HEAD') -AllowFail).Text
    $qRange = ''
    if ($report.PreRemoteSha -and $report.PreRemoteSha -ne $headSha -and (Invoke-Git @('cat-file','-t',$report.PreRemoteSha) -AllowFail).Code -eq 0) {
        $qRange = "$($report.PreRemoteSha)..HEAD"      # 已经推上去了：评刚才那一批
    } elseif ($qAhead -gt 0) {
        $qRange = 'origin/dev..dev'                     # 还没推：评待推的
    } elseif ($report.DirtyFiles.Count -gt 0) {
        $qRange = 'HEAD'                                # 只有工作区：评未提交改动
    }
    $quality = Get-QualityReview -Commits $report.Commits -TestStats $report.Stats -AheadCount $qAhead -Range $qRange
} catch {
    $quality = [pscustomobject]@{ HasContent = $false; Score = -1; Verdict = ''; AiText = ''; AiNote = "质量点评计算失败：$($_.Exception.Message)"; Files = @(); Stat = ''; Reasons = @(); RiskFiles = @(); TouchedTests = $false; TouchedDocs = $false; Prev = $null }
    Write-Log "质量点评计算失败：$($_.Exception.Message)" 'WARN'
}
# ---------- 出报告 ----------
$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine("# 桌面系统夜间巡检 · $today")
$null = $sb.AppendLine('')
$null = $sb.AppendLine("> 生成时间：$($report.Date)　分支：``$Branch``　仓库：``$Repo``")
$null = $sb.AppendLine('')
$null = $sb.AppendLine('## 结论')
$null = $sb.AppendLine('')
$null = $sb.AppendLine($report.Summary)
$null = $sb.AppendLine('')
$null = $sb.AppendLine('| 项 | 结果 |')
$null = $sb.AppendLine('|---|---|')
$null = $sb.AppendLine("| 回归测试 | $($report.TestRaw) |")
$null = $sb.AppendLine("| 测试退出码 | $($report.TestExit)（0 = 无高/中危失败） |")
$null = $sb.AppendLine("| 严重缺陷 | $(if ($report.Severe) { '有 —— ' + ($report.SevereWhy -join '；') } else { '无' }) |")
$null = $sb.AppendLine("| 未提交改动 | $(if ($report.DirtyFiles.Count -gt 0) { $report.DirtyFiles.Count.ToString() + ' 个' } else { '无' }) |")
$null = $sb.AppendLine("| 自动提交 | $($report.Committed)$(if ($report.CommitHash) { '（' + $report.CommitHash + '）' }) |")
$null = $sb.AppendLine("| 推送到 dev | $($report.Pushed) |")
$null = $sb.AppendLine("| main 分支 | 未改动（按规矩只由人放行） |")
$null = $sb.AppendLine("| 质量点评 | $(if ($quality.HasContent) { "$($quality.Score)/10 · $($quality.Verdict)" } else { '本轮无待评审改动' }) |")
$null = $sb.AppendLine("| dev 当前 HEAD | $($report.Head) |")
$null = $sb.AppendLine('')

$null = $sb.AppendLine('## 质量点评')
$null = $sb.AppendLine('')
if ($quality.HasContent) {
    $null = $sb.AppendLine("**评分 $($quality.Score)/10 —— $($quality.Verdict)**")
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('| 客观指标 | 值 |')
    $null = $sb.AppendLine('|---|---|')
    $null = $sb.AppendLine("| 改动规模 | $($quality.Stat) |")
    $null = $sb.AppendLine("| 有没有跟着动测试/测试工具 | $(if ($quality.TouchedTests) { '有' } else { '**没有**（扣分项）' }) |")
    $null = $sb.AppendLine("| 有没有同步文档 | $(if ($quality.TouchedDocs) { '有' } else { '没有' }) |")
    $null = $sb.AppendLine("| 高风险文件 | $(if ($quality.RiskFiles.Count -gt 0) { $quality.RiskFiles -join '、' } else { '无' }) |")
    if ($quality.Prev -and $quality.Prev.Passed -ge 0) {
        $null = $sb.AppendLine("| 与上一轮比（$($quality.Prev.Date)） | 通过 $($quality.Prev.Passed) → $($report.Stats.Passed)　警告 $($quality.Prev.Warn) → $($report.Stats.Warn) |")
    }
    $null = $sb.AppendLine('')
    if ($quality.Reasons -and $quality.Reasons.Count -gt 0) {
        $null = $sb.AppendLine('扣分理由：')
        $null = $sb.AppendLine('')
        foreach ($rs in $quality.Reasons) { $null = $sb.AppendLine("- $rs") }
        $null = $sb.AppendLine('')
    } else {
        $null = $sb.AppendLine('这轮没有触发任何扣分项（带了测试、没碰高风险文件、文档同步了、用例数没退）。')
        $null = $sb.AppendLine('')
    }
    $null = $sb.AppendLine('### AI 点评')
    $null = $sb.AppendLine('')
    if ($quality.AiText) {
        foreach ($ln in ($quality.AiText -split "\r?\n")) {
            if ($ln.Trim()) { $null = $sb.AppendLine("> $($ln.Trim())") }
        }
    } else {
        $null = $sb.AppendLine("（未生成：$($quality.AiNote)）")
    }
    $null = $sb.AppendLine('')
} else {
    $null = $sb.AppendLine('本轮没有待评审的改动（dev 与远端一致，也没有新的未提交改动）。')
    $null = $sb.AppendLine('')
}
$null = $sb.AppendLine('## 昨晚的重构 / 改动（未推送提交）')
$null = $sb.AppendLine('')
if ($report.Commits.Count -gt 0) {
    $null = $sb.AppendLine('| 提交 | 时间 | 说明 |')
    $null = $sb.AppendLine('|---|---|---|')
    foreach ($c in $report.Commits) { $null = $sb.AppendLine("| ``$($c.Hash)`` | $($c.When) | $($c.Subject) |") }
} else {
    $null = $sb.AppendLine('（没有待推送的新提交）')
}
$null = $sb.AppendLine('')

if ($report.Commits.Count -gt 0) {
    $null = $sb.AppendLine('### 改了哪些文件')
    $null = $sb.AppendLine('')
    # 推送成功后 origin/dev 已追上 dev，必须用推送前的远端 sha 才能算出这批的 stat
    $statRange = if ($report.PreRemoteSha) { "$($report.PreRemoteSha)..HEAD" } else { "$remoteRef...$Branch" }
    $stat = (Invoke-Git @('diff','--stat',$statRange) -AllowFail).Text
    if ($stat) { $null = $sb.AppendLine('```'); $null = $sb.AppendLine($stat); $null = $sb.AppendLine('```') }
    $null = $sb.AppendLine('')
}

if ($report.DirtyFiles.Count -gt 0) {
    $null = $sb.AppendLine('## 未提交改动（巡检时工作区里的）')
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('```')
    foreach ($f in $report.DirtyFiles) { $null = $sb.AppendLine($f) }
    $null = $sb.AppendLine('```')
    $null = $sb.AppendLine('')
}

if ($report.Severe) {
    $null = $sb.AppendLine('## 需要人看的地方')
    $null = $sb.AppendLine('')
    foreach ($w in $report.SevereWhy) { $null = $sb.AppendLine("- $w") }
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('报告细节：`tests\out\last-report.md`')
    $null = $sb.AppendLine('')
}

$md = $sb.ToString()
[System.IO.File]::WriteAllText($reportPath, $md, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($latestPath, $md, (New-Object System.Text.UTF8Encoding($false)))
Write-Log "报告：$reportPath"

# ---------- 通知 ----------
if (-not $NoNotify) {
    $title = if ($report.Severe) { '桌面系统巡检：发现严重缺陷（未推送）' } else { '桌面系统巡检：通过' }
    $body = @(
        ($report.Summary -replace '\*\*','')
        "测试：$($report.TestRaw)"
        "推送：$($report.Pushed)"
        "报告：$reportPath"
    ) -join "`n"
    Send-Toast -Title $title -Body $body
}

# ---------- 退出码 ----------
if ($report.Severe) { exit 1 }
if ($report.Pushed -eq '推送失败') { exit 2 }
exit 0
