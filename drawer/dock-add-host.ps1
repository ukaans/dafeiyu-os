$ErrorActionPreference = 'Stop'
# 常驻的「快捷启动栏 - 添加」窗口宿主：
# 预先加载 WinForms，触发文件一出现就立刻弹选择框（冷启动 ms 级）
$root = Join-Path $env:LOCALAPPDATA 'DesktopPage'
$trigger = Join-Path $root 'dock-add.trigger'
$state = Join-Path $root 'dock-add.state'
$dock = Join-Path $root 'dock.txt'
$tsv = Join-Path $root 'items.tsv'

try {
    $mtx = New-Object System.Threading.Mutex($false, 'Global\DesktopPage_dockpick')
    if (-not $mtx.WaitOne(0)) { exit 0 }
} catch { }

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch { exit 1 }

function Write-Atomic([string]$path, [string]$text) {
    # tmp + Move-Item 覆盖（与代理的 Save-Dock / hwmon 同一范式）。
    # dock.txt 与 dock-add.state 都有人高频读：代理的 Get-Dock 每次 /dock.js 都读 dock.txt
    # （壁纸左侧那 6 格），/launchpath.gif 的白名单也读它；dock-add.state 则每轮 /dock.js 读一次
    # 来判断「选择框还开着」。直写是「先截断成 0 字节再补齐」，撞上读者就是「快捷启动少几项」
    # 或 busy 误判成 0。写不动就抛给调用方，由它决定这一轮不写，绝不退回直写。
    $tmp = $path + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}
function Set-State([string]$s) {
    try { Write-Atomic $state $s } catch { }
}
Set-State 'idle'

function Add-Paths([string[]]$paths) {
    $rows = @()
    if (Test-Path $dock) { $rows = @([System.IO.File]::ReadAllLines($dock, [Text.Encoding]::UTF8) | Where-Object { $_ -ne '' }) }
    foreach ($f in $paths) {
        if ($rows.Count -ge 6) { break }
        $dup = $false
        foreach ($r in $rows) { if ($r.StartsWith($f + '|')) { $dup = $true } }
        if ($dup) { continue }
        $icon = ''
        $hit = $null
        if (Test-Path $tsv) {
            $hit = @([System.IO.File]::ReadAllLines($tsv, [Text.Encoding]::UTF8) | Where-Object { $_.StartsWith($f + "`t") }) | Select-Object -First 1
        }
        if (-not $hit) {
            try { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Build-IconCache.ps1') -AddPath $f | Out-Null } catch { }
            if (Test-Path $tsv) {
                $hit = @([System.IO.File]::ReadAllLines($tsv, [Text.Encoding]::UTF8) | Where-Object { $_.StartsWith($f + "`t") }) | Select-Object -First 1
            }
        }
        if ($hit) { $icon = [System.IO.Path]::GetFileName((($hit -split "`t")[2])) }
        $name = [System.IO.Path]::GetFileNameWithoutExtension($f)
        $rows += ($f + '|' + $name + '|' + $icon)
    }
    # 原子写：dock.txt 由代理 / 壁纸 / 本宿主三方共读（见 Write-Atomic 的注释）。
    # WriteAllLines 的换行与 AppendLine 一致（都是 CRLF），内容格式不变。
    $sb = New-Object System.Text.StringBuilder
    foreach ($r in $rows) { [void]$sb.AppendLine($r) }
    try { Write-Atomic $dock $sb.ToString() } catch { }
}

while ($true) {
    Start-Sleep -Milliseconds 120
    if (-not (Test-Path $trigger)) { continue }
    try { Remove-Item $trigger -Force } catch { continue }
    Set-State 'open'
    try {
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = '选择要加入快捷启动栏的程序（可多选，最多 6 个）'
        $dlg.Multiselect = $true
        $dlg.Filter = '程序与快捷方式 (*.lnk;*.exe)|*.lnk;*.exe|所有文件 (*.*)|*.*'
        try { $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop') } catch { }
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
        $picked = @($dlg.FileNames)
        $owner.Close()
        $dlg.Dispose()
        if ($res -eq [System.Windows.Forms.DialogResult]::OK -and $picked.Count -gt 0) {
            Add-Paths $picked
        }
    } catch { }
    Set-State 'idle'
}
