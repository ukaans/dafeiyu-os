#requires -Version 5.1
<#
  大肥鱼桌面系统 —— 漏洞与风险测试模块（入口）

  用法：
    powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
    powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Case SEC        # 只跑安全类
    powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Case WF-003      # 只跑单个用例
    powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Severity high     # 只跑高危
    powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Intrusive         # 允许改写桌面状态

  退出码 = high/medium 级别的失败用例数（0 = 可以放心）
  报告：
    tests\out\last-report.json   ← 机器读（夜间自动修复的输入）
    tests\out\last-report.md     ← 人读
    tests\out\history\<时间>.json ← 趋势与"今天修好了什么"

  安全边界（重要）：
    默认只做「只读探测 + 静态分析」，不重启任何进程、不打开抽屉、不改待办与面板矩形。
    会改动桌面可见状态的用例一律标 -Intrusive，必须显式开启。
#>
[CmdletBinding()]
param(
    [string]$Case = '*',
    [ValidateSet('all', 'high', 'medium', 'low')][string]$Severity = 'all',
    [switch]$Intrusive,
    [switch]$Quiet,
    [string]$OutDir,
    [string]$InstallDir,
    [string]$WallpaperDir,
    [switch]$NoReport
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $root 'drawer'))) { throw "找不到源工程：$root（tests\ 必须在项目根目录下）" }

$install = if ($InstallDir) { $InstallDir } else { Join-Path $env:LOCALAPPDATA 'DesktopPage' }
if (-not $OutDir) { $OutDir = Join-Path $PSScriptRoot 'out' }

# 壁纸目录：与 hwmon/wxmon/dsh-agent 同一套解析顺序，避免测试看错目录
function Resolve-WallpaperDir([string]$forced) {
    if ($forced) { return $forced }
    if ($env:DSH_WALLPAPER) { return $env:DSH_WALLPAPER }
    try {
        $lay = Join-Path $env:LOCALAPPDATA 'Lively Wallpaper\WallpaperLayout.json'
        if (Test-Path $lay) {
            $j = [System.IO.File]::ReadAllText($lay, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($it in @($j)) {
                $p = [string]$it.LivelyInfoPath
                if ($p -and (Test-Path (Join-Path $p 'dsh.js'))) { return $p }
            }
        }
    } catch { }
    try {
        $base = Join-Path $env:LOCALAPPDATA 'Lively Wallpaper\Library\wallpapers'
        $hit = Get-ChildItem $base -Directory -ErrorAction Stop |
            Where-Object { Test-Path (Join-Path $_.FullName 'dsh.js') } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    } catch { }
    return ''
}

$wall = Resolve-WallpaperDir $WallpaperDir

. (Join-Path $PSScriptRoot 'lib\DshTest.ps1')

Initialize-DshTest -Context @{ Root = $root; Install = $install; Wall = $wall; Tests = $PSScriptRoot } -Options @{
    Case      = $Case
    Severity  = $Severity
    Intrusive = [bool]$Intrusive
    Quiet     = [bool]$Quiet
}

# 端口从唯一配置源读，避免测试自己也写死一份（否则改端口时测试和实现一起错）
try {
    $cfgSrc = [System.IO.File]::ReadAllText((Join-Path $root 'drawer\agent-config.ps1'), [System.Text.Encoding]::UTF8)
    if ($cfgSrc -match '(?m)^\s*\$AgentPort\s*=\s*(\d+)') {
        Set-DshApiPort ([int]$matches[1])
    } else {
        $liveP = Join-Path $install 'agent-port.txt'
        if (Test-Path -LiteralPath $liveP) { Set-DshApiPort ([int]((Get-Content -LiteralPath $liveP -Raw).Trim())) }
    }
} catch { }

if (-not $Quiet) {
    Write-Host ''
    Write-Host '================ 大肥鱼桌面系统 · 测试模块 ================' -ForegroundColor Cyan
    Write-Host ("源工程  ：" + $root)
    Write-Host ("运行时  ：" + $install)
    Write-Host ("壁纸目录：" + $(if ($wall) { $wall } else { '(未解析到)' }))
    Write-Host ("代理    ：" + (Get-DshApiBase))
    Write-Host ("模式    ：" + $(if ($Intrusive) { 'Intrusive（会改动桌面可见状态）' } else { 'Safe（只读探测 + 静态分析）' }))
    Write-Host ''
}

# ---- 按文件名顺序加载用例：10 静态 → 20 契约 → 30 安全 → 40 运行时 → 50 健壮性 → 60 数据
$caseFiles = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'cases') -Filter '*.ps1' | Sort-Object Name)
foreach ($f in $caseFiles) {
    if (-not $Quiet) { Write-Host ('-- ' + $f.BaseName) -ForegroundColor DarkCyan }
    . $f.FullName
}

$report = $null
if (-not $NoReport) {
    $report = New-DshTestReport -OutDir $OutDir
    $sum = $report.Summary
} else {
    $sum = Get-DshTestSummary
}

if (-not $Quiet) {
    Write-Host ''
    Write-Host '================ 结果 ================' -ForegroundColor Cyan
    Write-Host ("通过 {0}　失败 {1}（高 {2} / 中 {3} / 低 {4}）　警告 {5}　跳过 {6}　合计 {7}" -f `
        $sum.Pass, $sum.Fail, $sum.FailHigh, $sum.FailMedium, $sum.FailLow, $sum.Warn, $sum.Skip, $sum.Total)
    Write-Host ("耗时 {0:N1}s" -f ($sum.DurationMs / 1000))
    if ($report) {
        Write-Host ("报告：" + $report.Markdown)
        Write-Host ("数据：" + $report.Json)
        if ($report.NewFails.Count -gt 0) { Write-Host ("新增失败：" + ($report.NewFails -join ', ')) -ForegroundColor Red }
        if ($report.Fixed.Count -gt 0) { Write-Host ("对比上次已修复：" + ($report.Fixed -join ', ')) -ForegroundColor Green }
    }
    if ($sum.Blocking -eq 0) {
        Write-Host '没有高/中危失败项。' -ForegroundColor Green
    } else {
        Write-Host ("有 $($sum.Blocking) 项高/中危失败，见上面 [FAIL]。") -ForegroundColor Yellow
    }
    Write-Host ''
}

exit $sum.Blocking
