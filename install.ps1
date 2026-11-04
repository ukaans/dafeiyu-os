<#
  大肥鱼桌面系统 一键安装脚本
  ------------------------------------------------------------------
  作用：
    1) 把 drawer\ 下的抽屉系统复制到 %LOCALAPPDATA%\DesktopPage
    2) 把 wallpaper\ 下的壁纸系统复制到 Lively 壁纸库
    3) 生成用户数据空模板（todo/dock/布局等）
    4) 注册两个计划任务：DesktopPage Autostart（登录自启）、DesktopPage Ensure（每 2 分钟兜底巡检）
    5) 立即启动整套系统（壁纸数据落点由 Lively 当前应用的壁纸自动决定，见脚本内注释）

  用法（普通 PowerShell 即可，不需要管理员）：
    powershell -ExecutionPolicy Bypass -File .\install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun          # 只打印计划，不落盘
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -LivelyLibrary "D:\Lively\Library\wallpapers"
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -DshRoot "E:\DSH"

  前提：已安装 Lively Wallpaper（https://www.rocksdanister.com/lively/）与 WebView2 运行时。
#>
[CmdletBinding()]
param(
    [string]$InstallDir    = (Join-Path $env:LOCALAPPDATA 'DesktopPage'),
    [string]$LivelyLibrary = '',
    [string]$WallpaperName = '大肥鱼桌面系统',
    [string]$DshRoot       = '',
    [switch]$SkipTask,
    [switch]$NoStart,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$pkg = Split-Path -Parent $MyInvocation.MyCommand.Path
$drawerSrc = Join-Path $pkg 'drawer'
$wallSrc   = Join-Path $pkg 'wallpaper'

function Say([string]$m) { Write-Host $m }
function Step([string]$m) { Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }
function Warn([string]$m) { Write-Host "!! $m" -ForegroundColor Yellow }

function Resolve-LivelyLibrary {
    param([string]$Hint)
    if ($Hint) {
        if (-not (Test-Path $Hint)) { New-Item -ItemType Directory -Path $Hint -Force | Out-Null }
        return (Resolve-Path $Hint).Path
    }
    $cands = @(
        (Join-Path $env:LOCALAPPDATA 'Lively Wallpaper\Library\wallpapers'),
        (Join-Path $env:APPDATA 'Lively Wallpaper\Library\wallpapers'),
        'E:\Lively Wallpaper\Library\wallpapers',
        (Join-Path $env:ProgramFiles 'Lively Wallpaper\Library\wallpapers')
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path } }
    return ''
}

Step "检查安装包内容"
if (-not (Test-Path (Join-Path $drawerSrc 'DesktopPage.ahk'))) { throw "安装包不完整：缺少 drawer\DesktopPage.ahk" }
if (-not (Test-Path (Join-Path $drawerSrc 'dsh-agent.ps1')))  { throw "安装包不完整：缺少 drawer\dsh-agent.ps1" }
if (-not (Test-Path (Join-Path $wallSrc 'index.html')))       { throw "安装包不完整：缺少 wallpaper\index.html" }
Say ("安装包目录 : " + $pkg)
Say ("抽屉安装到 : " + $InstallDir)
$lib = Resolve-LivelyLibrary $LivelyLibrary
if (-not $lib) {
    Warn "没有找到 Lively 壁纸库。请先安装 Lively Wallpaper，或用 -LivelyLibrary 指定 Library\wallpapers 路径。"
    Warn "本次将只安装抽屉系统，壁纸先复制到 $pkg\wallpaper-unused"
} else {
    Say ("壁纸安装到 : " + (Join-Path $lib $WallpaperName))
}

Step "安装抽屉系统"
$drawerFiles = @(
    'AutoHotkey64.exe','AutoHotkey64.exe.manifest','DesktopPage.ahk','dsh-agent.ps1',
    'npix.cs','npix.exe','npix.manifest','hwmon.ps1','wxmon.ps1','dock-add.ps1','dock-add-host.ps1',
    'DesktopIcons.ps1','DesktopPositions.ps1','Build-IconCache.ps1','recycle_tmp.ps1','start-all.vbs',
    'agent-watch.ps1','ensure-all.ps1','ensure-all.vbs','wheel-bridge.ps1'
)
if ($DryRun) {
    foreach ($f in $drawerFiles) { Say ("  [dry] copy " + $f) }
    Say ("  [dry] copy fonts\ -> " + (Join-Path $InstallDir 'fonts'))
    Say ("  [dry] copy icons\ -> " + (Join-Path $InstallDir 'icons'))
} else {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    foreach ($f in $drawerFiles) {
        $s = Join-Path $drawerSrc $f
        if (Test-Path $s) { Copy-Item $s (Join-Path $InstallDir $f) -Force } else { Warn "缺少 $f" }
    }
    foreach ($sub in @('fonts','icons')) {
        $s = Join-Path $drawerSrc $sub
        if (Test-Path $s) {
            $t = Join-Path $InstallDir $sub
            New-Item -ItemType Directory -Path $t -Force | Out-Null
            Copy-Item (Join-Path $s '*') $t -Recurse -Force
        }
    }
    foreach ($empty in @('layout.dat','hidden.dat','items.tsv','dock.txt','todo.txt')) {
        $p = Join-Path $InstallDir $empty
        if (-not (Test-Path $p)) { New-Item -ItemType File -Path $p -Force | Out-Null }
    }
    Say "  抽屉文件已就位"
}

Step "安装壁纸系统"
if ($lib) {
    $wallDest = Join-Path $lib $WallpaperName
    if ($DryRun) {
        Say ("  [dry] copy wallpaper\* -> " + $wallDest)
    } else {
        New-Item -ItemType Directory -Path $wallDest -Force | Out-Null
        Copy-Item (Join-Path $wallSrc '*') $wallDest -Recurse -Force
        Say ("  壁纸文件已就位：" + $wallDest)
    }
}

Step "可选：记录 DSH 根目录"
# 说明：壁纸数据落点（DSH_WALLPAPER）故意不写死。三个采样脚本会自己按
# 「DSH_WALLPAPER → Lively WallpaperLayout.json 里当前应用的壁纸目录 → 库里含 dsh.js 的最新一份」
# 解析。机器上同时存在旧 ID 目录（如 dsqq0001.ab1）和新装的目录时，只有 Lively 自己
# 知道哪份在显示 —— 由它决定才不会把数据写到没显示的那份里。
Say "  壁纸数据落点由 Lively 当前应用的壁纸目录自动决定（无需设置 DSH_WALLPAPER）"
if ($DshRoot) {
    if ($DryRun) { Say ("  [dry] setx DSH_ROOT " + $DshRoot) }
    else {
        [Environment]::SetEnvironmentVariable('DSH_ROOT', $DshRoot, 'User')
        Say ("  已写入用户环境变量 DSH_ROOT=" + $DshRoot + "（新开的进程生效）")
    }
}

Step "注册开机自启计划任务"
$taskName = 'DesktopPage Autostart'
$vbs = Join-Path $InstallDir 'start-all.vbs'
$tr = 'wscript.exe "' + $vbs + '"'
# 兜底巡检任务：每 2 分钟跑一次 ensure-all.vbs，补上被外力杀掉的抽屉/看门狗/代理，
# 并消费抽屉在代理假死期间写下的 launch-queue.txt。没有它，一旦三件套被一起杀掉，
# 只有下次登录才会恢复（点了图标没反应的整体兜底就断在这一环）。
$ensureTaskName = 'DesktopPage Ensure'
$ensureVbs = Join-Path $InstallDir 'ensure-all.vbs'
$ensureTr = 'wscript.exe "' + $ensureVbs + '"'
if ($DryRun) {
    Say ("  [dry] schtasks /create /tn `"$taskName`" /tr `"$tr`" /sc onlogon /f")
    Say ("  [dry] schtasks /create /tn `"$ensureTaskName`" /tr `"$ensureTr`" /sc minute /mo 2 /f")
} elseif ($SkipTask) {
    Say "  已跳过（-SkipTask）"
} else {
    $out = & schtasks.exe /create /tn $taskName /tr $tr /sc onlogon /f 2>&1
    if ($LASTEXITCODE -eq 0) { Say "  计划任务已创建：$taskName" }
    else {
        Warn "计划任务创建失败（可能需要管理员）。可手动执行："
        Warn ("  schtasks /create /tn `"$taskName`" /tr `"$tr`" /sc onlogon /f")
        Warn ($out | Out-String)
    }
    if (Test-Path $ensureVbs) {
        $out2 = & schtasks.exe /create /tn $ensureTaskName /tr $ensureTr /sc minute /mo 2 /f 2>&1
        if ($LASTEXITCODE -eq 0) { Say "  计划任务已创建：$ensureTaskName（每 2 分钟兜底巡检）" }
        else {
            Warn "兜底巡检任务创建失败（不影响主体功能）。可手动执行："
            Warn ("  schtasks /create /tn `"$ensureTaskName`" /tr `"$ensureTr`" /sc minute /mo 2 /f")
            Warn ($out2 | Out-String)
        }
    } else {
        Warn "缺少 ensure-all.vbs，跳过兜底巡检任务"
    }
}

Step "立即启动"
if ($DryRun) {
    Say ("  [dry] wscript.exe " + $vbs)
} elseif ($NoStart) {
    Say "  已跳过启动（-NoStart）"
} else {
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WindowStyle Hidden
    Start-Sleep -Seconds 8
    $procs = Get-Process -Name 'AutoHotkey64','Lively' -ErrorAction SilentlyContinue
    Say ("  当前进程：" + (($procs | Select-Object -ExpandProperty Name) -join ', '))
}

Step "完成"
Say "  下一步："
Say "   1. 打开 Lively Wallpaper，在『已安装的壁纸』里选择「$WallpaperName」应用。"
Say "   2. 桌面右侧出现 DSH 面板、下方时钟条、左侧硬件/天气卡片即为成功。"
Say "   3. 把鼠标移到屏幕右下角向下滚一下（或按 Ctrl+Alt+Space）呼出桌面抽屉。"
Say "   4. 运行 .\verify.ps1 做一次自检。"
