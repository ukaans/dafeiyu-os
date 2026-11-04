#requires -Version 5.1
<#
  60-data.ps1 —— 数据完整性
  抽屉不查数据库，它查这几份纯文本：布局、图标索引、隐藏名单、真实桌面坐标、快捷启动。
  格式一歪，AHK 的解析会静默跳过整行（不报错），表现就是"图标少了几个"或"分组没了"。
  这一组逐份验格式 + 验引用是否还能落地。
#>

function Data-Lines([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $t = Read-Raw $path
    return @($t -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
}

Test-Case DAT-001 '数据' 'layout.dat 格式合法' medium {
    $p = Join-Path (Get-DshInstall) 'layout.dat'
    if (-not (Test-Path -LiteralPath $p)) { return @{ Status = 'skip'; Detail = 'layout.dat 不存在（还没拖过图标）' } }
    $lines = Data-Lines $p
    if ($lines.Count -eq 0) { throw 'layout.dat 是空的（抽屉会重扫桌面，用户自定义布局丢失）' }
    if ($lines[0].Trim() -ne 'V2') { throw ('首行应为 V2，实际「' + $lines[0] + '」—— 版本头不对会整份不认') }

    $bad = @()
    $pCnt = 0; $fCnt = 0
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $cols = $lines[$i] -split "`t"
        switch ($cols[0]) {
            'P' { $pCnt++; if ($cols.Count -lt 4) { $bad += ('第 ' + ($i + 1) + ' 行 P 项字段不足：' + $lines[$i]) } }
            'F' {
                $fCnt++
                if ($cols.Count -lt 6) { $bad += ('第 ' + ($i + 1) + ' 行 F 项字段不足（需 6 列）：' + $lines[$i]) }
                elseif ($cols[5] -eq '') { $bad += ('第 ' + ($i + 1) + ' 行 F 项没有成员') }
            }
            default { $bad += ('第 ' + ($i + 1) + ' 行前缀不认识：' + $cols[0]) }
        }
    }
    if ($bad.Count -gt 0) { throw (($bad | Select-Object -First 3) -join '；') }
    ('V2 头正确，' + $pCnt + ' 个图标 + ' + $fCnt + ' 个分组')
} -Hint '格式见项目地图 §5：P\t路径\tx\ty、F\tid\t名称\tx\ty\t成员1|成员2；坏行会被静默跳过'

Test-Case DAT-002 '数据' 'items.tsv 路径可落地' medium {
    $p = Join-Path (Get-DshInstall) 'items.tsv'
    if (-not (Test-Path -LiteralPath $p)) { return @{ Status = 'skip'; Detail = 'items.tsv 不存在（图标缓存没建过）' } }
    $lines = Data-Lines $p
    if ($lines.Count -eq 0) { throw 'items.tsv 是空的（抽屉里会一个图标都没有）' }
    $badCol = 0; $checked = 0; $missing = @()
    foreach ($l in $lines) {
        $cols = $l -split "`t"
        if ($cols.Count -lt 4) { $badCol++; continue }
        $checked++
        if ($cols[1] -and -not (Test-Path -LiteralPath $cols[1])) { $missing += $cols[0] }
    }
    if ($badCol -gt 0) { throw ($badCol.ToString() + ' 行列数不足 4（名称\t路径\t图标\t类型）') }
    $rate = if ($checked -gt 0) { [int](100 - ($missing.Count * 100 / $checked)) } else { 100 }
    if ($rate -lt 80) {
        throw ('有效路径仅 ' + $rate + '%（' + $missing.Count + '/' + $checked + ' 个已失效，例：' + (($missing | Select-Object -First 3) -join '、') + '）')
    }
    if ($missing.Count -gt 0) {
        return @{ Status = 'warn'; Detail = ($missing.Count.ToString() + ' 个路径已失效（' + $rate + '% 有效），抽屉里会留死图标') }
    }
    ($checked.ToString() + ' 个图标路径全部有效')
} -Hint '删了桌面文件后要 --rescan 重扫；死图标点下去没反应，最容易被当成"程序坏了"'

Test-Case DAT-003 '数据' 'hidden.dat 没有孤儿条目' low {
    $p = Join-Path (Get-DshInstall) 'hidden.dat'
    if (-not (Test-Path -LiteralPath $p)) { return @{ Status = 'skip'; Detail = 'hidden.dat 不存在（没有隐藏过图标）' } }
    $lines = Data-Lines $p
    if ($lines.Count -eq 0) { return '隐藏名单为空' }
    $orphan = @($lines | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($orphan.Count -gt 0) {
        return @{ Status = 'warn'; Detail = ($orphan.Count.ToString() + '/' + $lines.Count + ' 条已失效，例：' + (($orphan | Select-Object -First 2) -join '、')) }
    }
    ($lines.Count.ToString() + ' 条隐藏记录全部仍指向存在的文件')
} -Hint '孤儿条目无害但会让"恢复"操作找不回东西；--restore 可清空名单'

Test-Case DAT-004 '数据' 'dock.txt 不超上限且路径有效' medium {
    $p = Join-Path (Get-DshInstall) 'dock.txt'
    if (-not (Test-Path -LiteralPath $p)) { return @{ Status = 'skip'; Detail = 'dock.txt 不存在（没加过快捷启动）' } }
    $lines = Data-Lines $p
    if ($lines.Count -gt 6) { throw ($lines.Count.ToString() + ' 行，超过面板上限 6 行（第 7 项起画不出来）') }
    $bad = @(); $dead = @()
    foreach ($l in $lines) {
        $cols = $l -split '\|'
        if ($cols.Count -lt 2) { $bad += $l; continue }
        if ($cols[0] -and -not (Test-Path -LiteralPath $cols[0])) { $dead += $cols[1] }
    }
    if ($bad.Count -gt 0) { throw ('格式应为 路径|显示名|图标：' + ($bad -join '、')) }
    if ($dead.Count -gt 0) { return @{ Status = 'warn'; Detail = ('失效项：' + ($dead -join '、') + '（面板上点了没反应）') } }
    ($lines.Count.ToString() + ' 项，格式与路径都正常')
} -Hint 'dock.txt 由 dock-add-host.ps1 写；上限在写入端拦，别指望前端裁剪'

Test-Case DAT-005 '数据' '生成物 JS 语法合法' medium {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return @{ Status = 'skip'; Detail = '没找到 node' } }
    $wall = Get-DshWall
    if (-not $wall -or -not (Test-Path -LiteralPath $wall)) { return @{ Status = 'skip'; Detail = '没解析到壁纸目录' } }
    $bad = @()
    $n = 0
    foreach ($f in @('hw-data.js', 'wx-data.js', 'todo-data.js')) {
        $p = Join-Path $wall $f
        if (-not (Test-Path -LiteralPath $p)) { $bad += ($f + ' 缺失'); continue }
        $n++
        $o = & $node.Source --check $p 2>&1
        if ($LASTEXITCODE -ne 0) { $bad += ($f + ' → ' + ((@($o) | Select-Object -First 1) -join '')) }
    }
    if ($bad.Count -gt 0) { throw ('生成物语法错（壁纸整页脚本会挂）：' + ($bad -join '；')) }
    ($n.ToString() + ' 份生成物语法正常（hw/wx/todo-data.js）')
} -Hint '生成物是 window.__XXX = {...}; 采集中断可能写出半个对象 —— 写之前先在内存里拼完'

Test-Case DAT-006 '数据' 'desktop_positions.tsv 格式合法' low {
    $p = Join-Path (Get-DshInstall) 'desktop_positions.tsv'
    if (-not (Test-Path -LiteralPath $p)) { return @{ Status = 'skip'; Detail = 'desktop_positions.tsv 不存在（没同步过真实桌面）' } }
    $lines = Data-Lines $p
    if ($lines.Count -eq 0) { throw '文件为空' }
    $bad = 0
    foreach ($l in $lines) {
        $cols = $l -split "`t"
        if ($cols.Count -lt 3) { $bad++; continue }
        $x = 0; $y = 0
        if (-not [int]::TryParse($cols[1], [ref]$x) -or -not [int]::TryParse($cols[2], [ref]$y)) { $bad++ }
    }
    if ($bad -gt 0) { throw ($bad.ToString() + ' 行格式错（应为 路径\tx\ty）') }
    ($lines.Count.ToString() + ' 行坐标格式正常')
} -Hint '这份由 DesktopPositions.ps1 跨进程读 LVM_GETITEMPOSITION 生成；失败会返回 error: 且退出码 1'

Test-Case DAT-007 '数据' '图标缓存没有大面积缺失' low {
    $inst = Get-DshInstall
    $itemsP = Join-Path $inst 'items.tsv'
    $iconDir = Join-Path $inst 'icons'
    if (-not (Test-Path -LiteralPath $itemsP) -or -not (Test-Path -LiteralPath $iconDir)) {
        return @{ Status = 'skip'; Detail = '图标缓存还没建（items.tsv 或 icons\ 不存在）' }
    }
    $lines = Data-Lines $itemsP
    $ref = @()
    foreach ($l in $lines) {
        $c = $l -split "`t"
        if ($c.Count -ge 3 -and $c[2]) { $ref += (Split-Path -Leaf $c[2]) }
    }
    if ($ref.Count -eq 0) { return @{ Status = 'skip'; Detail = 'items.tsv 没引用图标文件' } }
    $miss = @($ref | Where-Object { -not (Test-Path -LiteralPath (Join-Path $iconDir $_)) })
    if ($miss.Count -gt 0) {
        $pct = [int](100 - ($miss.Count * 100 / $ref.Count))
        if ($pct -lt 90) { throw ($miss.Count.ToString() + '/' + $ref.Count + ' 个图标文件缺失（仅 ' + $pct + '% 可用），抽屉会显示空白格') }
        return @{ Status = 'warn'; Detail = ($miss.Count.ToString() + ' 个图标缺失，例：' + (($miss | Select-Object -First 3) -join '、')) }
    }
    ($ref.Count.ToString() + ' 个图标引用全部命中缓存文件')
} -Hint 'Build-IconCache.ps1 全量模式会清空 icons\；-AddPath 是追加模式，只补不删'
