<#
  大肥鱼桌面系统 卸载脚本
  用法：
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1          # 停进程 + 删计划任务，保留文件
    powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -Purge   # 连同安装目录与壁纸一起删除
#>
[CmdletBinding()]
param(
    [string]$InstallDir    = (Join-Path $env:LOCALAPPDATA 'DesktopPage'),
    [string]$WallpaperName = '大肥鱼桌面系统',
    [string]$LivelyLibrary = '',
    [switch]$Purge
)
$ErrorActionPreference = 'Continue'

function Say([string]$m) { Write-Host $m }

Say "== 停止相关进程"
Get-Process -Name 'AutoHotkey64' -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'dsh-agent\.ps1|hwmon\.ps1|wxmon\.ps1|dock-add-host\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1
Say "  已停止抽屉与后台采样进程（Lively 未动）"

Say "== 删除计划任务"
$out = & schtasks.exe /delete /tn 'DesktopPage Autostart' /f 2>&1
Say ("  " + ($out | Out-String).Trim())
# 兜底巡检任务必须一起删：否则卸载后它每 2 分钟还会把抽屉/代理重新拉起来
$out2 = & schtasks.exe /delete /tn 'DesktopPage Ensure' /f 2>&1
Say ("  " + ($out2 | Out-String).Trim())

if ($Purge) {
    Say "== 删除抽屉目录"
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force; Say ("  已删 " + $InstallDir) }

    Say "== 删除壁纸"
    $lib = $LivelyLibrary
    if (-not $lib) {
        foreach ($c in @(
            (Join-Path $env:LOCALAPPDATA 'Lively Wallpaper\Library\wallpapers'),
            (Join-Path $env:APPDATA 'Lively Wallpaper\Library\wallpapers'))) {
            if (Test-Path $c) { $lib = $c; break }
        }
    }
    if ($lib) {
        $wd = Join-Path $lib $WallpaperName
        if (Test-Path $wd) { Remove-Item $wd -Recurse -Force; Say ("  已删 " + $wd) }
    }
} else {
    Say "== 保留文件（要连目录一起删，加 -Purge 重跑）"
}
Say "完成。若 Lively 里还挂着本壁纸，打开 Lively 换成别的壁纸即可。"
