param()
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root = Join-Path $env:LOCALAPPDATA 'DesktopPage'
$dock = Join-Path $root 'dock.txt'
$tsv  = Join-Path $root 'items.tsv'

$dlg = New-Object System.Windows.Forms.OpenFileDialog
$dlg.Title = '选择要加入快捷启动栏的程序（可多选，最多 6 个）'
$dlg.Multiselect = $true
$dlg.Filter = '程序与快捷方式 (*.lnk;*.exe)|*.lnk;*.exe|所有文件 (*.*)|*.*'
try { $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop') } catch { }

# 透明 TopMost 宿主窗口：让选择框出现在最前，不被壁纸/桌面挡住
$owner = New-Object System.Windows.Forms.Form
$owner.Text = 'dock-picker'
$owner.FormBorderStyle = 'None'
$owner.ShowInTaskbar = $false
$owner.StartPosition = 'Manual'
$owner.Location = New-Object System.Drawing.Point(0, 0)
$owner.Size = New-Object System.Drawing.Size(1, 1)
$owner.TopMost = $true
$owner.Opacity = 0.01
$owner.Show()
$owner.Activate()

$res = $dlg.ShowDialog($owner)
$owner.Close()
if ($res -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }

$rows = @()
if (Test-Path $dock) { $rows = @(Get-Content $dock -Encoding UTF8 | Where-Object { $_ -ne '' }) }

foreach ($f in $dlg.FileNames) {
    if ($rows.Count -ge 6) { break }
    $dup = $false
    foreach ($r in $rows) { if ($r.StartsWith($f + '|')) { $dup = $true } }
    if ($dup) { continue }

    $icon = ''
    $hit = $null
    if (Test-Path $tsv) {
        $hit = @(Get-Content $tsv -Encoding UTF8 | Where-Object { $_.StartsWith($f + "`t") }) | Select-Object -First 1
    }
    if (-not $hit) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Build-IconCache.ps1') -AddPath $f | Out-Null
        if (Test-Path $tsv) {
            $hit = @(Get-Content $tsv -Encoding UTF8 | Where-Object { $_.StartsWith($f + "`t") }) | Select-Object -First 1
        }
    }
    if ($hit) { $icon = [System.IO.Path]::GetFileName((($hit -split "`t")[2])) }
    $name = [System.IO.Path]::GetFileNameWithoutExtension($f)
    $rows += ($f + '|' + $name + '|' + $icon)
}
[System.IO.File]::WriteAllLines($dock, $rows, (New-Object System.Text.UTF8Encoding($false)))