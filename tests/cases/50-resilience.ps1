#requires -Version 5.1
<#
  50-resilience.ps1 —— 健壮性与容量
  这套系统是"长期常驻"的：一次泄漏不会立刻炸，但跑一周就会变成
  「面板莫名其妙不更新」「点图标排进队列」这类找不到原因的毛病。
  这一组专门看"时间维度"上的风险：日志会不会涨爆、队列会不会堵死、
  备份会不会堆成山、看门狗是不是在反复杀进程。
#>

function Res-ReadLog([string]$path, [int]$maxLines = 300) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        # start-all.log 是 UTF-16（vbs 写的），其余是 UTF-8：按 BOM 判
        $b = Read-FirstBytes $path 2
        $enc = if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { [System.Text.Encoding]::Unicode } else { [System.Text.Encoding]::UTF8 }
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            $sr = New-Object System.IO.StreamReader($fs, $enc)
            $all = $sr.ReadToEnd(); $sr.Dispose()
        } finally { $fs.Dispose() }
        $lines = @($all -split "`r?`n" | Where-Object { $_ -ne '' })
        if ($lines.Count -gt $maxLines) { $lines = @($lines[($lines.Count - $maxLines)..($lines.Count - 1)]) }
        return $lines
    } catch { return @() }
}

function Res-Size([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return -1 }
    return (Get-Item -LiteralPath $path).Length
}

function Res-KB([long]$b) { return ([math]::Round($b / 1KB, 1).ToString() + 'KB') }

Test-Case RES-001 '健壮' '无轮转的日志会无限增长' medium {
    $inst = Get-DshInstall
    $root = Get-DshRoot
    if (-not (Test-Path -LiteralPath $inst)) { return (Test-DshAbort) }
    $watch = @(
        @{ File = 'wheel.log'; Writer = 'drawer\DesktopPage.ahk' }
        @{ File = 'dsh-run.log'; Writer = 'drawer\dsh-agent.ps1' }
    )
    $rows = @()
    $big = @()
    foreach ($w in $watch) {
        $sz = Res-Size (Join-Path $inst $w.File)
        if ($sz -lt 0) { continue }
        $rows += ($w.File + '=' + (Res-KB $sz))
        if ($sz -gt 1MB) { $big += ($w.File + ' 已 ' + (Res-KB $sz)) }
    }
    # 尺寸只是"有没有爆"的证据；真正的判据是"写入方有没有轮转逻辑"——
    # 一个刚建的空日志也满足尺寸要求，但那不代表它有上限。
    $noCap = @()
    $ahk = Read-Raw (Join-Path $root 'drawer\DesktopPage.ahk')
    if ($ahk -notmatch 'WPLOG_MAX') { $noCap += 'wheel.log 没有尺寸阈值（WPLOG_MAX）' }
    elseif ($ahk -notmatch 'FileMove\(wpath,\s*wpath\s*"\.1"') { $noCap += 'wheel.log 有阈值但没做 FileMove 轮转' }
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    $rotDirect = ($agent -match 'Move-Item[^\r\n]*\$logFile[^\r\n]*-Force')
    $rotLoop = (($agent -match '@\(\$logFile[^\r\n]*\)') -and ($agent -match 'Move-Item[^\r\n]*\$f[^\r\n]*-Force'))
    if (-not ($rotDirect -or $rotLoop)) { $noCap += 'dsh-run.log 没有轮转（Start-Run 里缺 Move-Item $logFile .1，或循环版 @($logFile,$errFile)）' }
    if ($big.Count -gt 0) { throw ($big -join '、' + ' —— 超过 1MB，长期运行会把磁盘和读取速度拖住') }
    if ($noCap.Count -gt 0) {
        return @{ Status = 'warn'; Detail = (($rows -join '，') + ' —— ' + ($noCap -join '；')) }
    }
    if ($rows.Count -eq 0) { return '两份日志都还没生成（轮转逻辑已在位）' }
    (($rows -join '，') + ' —— 均为 256KB 轮转（超限改名 .1，不删文件）')
} -Hint '给 wheel.log / dsh-run.log 加 256KB 轮转（照 AuditLog 的写法：字节累加 + FileMove 改名）'

Test-Case RES-002 '健壮' '有上限的日志未超限' medium {
    $inst = Get-DshInstall
    if (-not (Test-Path -LiteralPath $inst)) { return (Test-DshAbort) }
    $bad = @()
    $rows = @()
    foreach ($c in @(
            @{ File = 'dsh-agent.log'; Limit = 262144 }
            @{ File = 'agent-watch.log'; Limit = 262144 }
            @{ File = 'ensure-all.log'; Limit = 262144 }
            @{ File = 'audit.log'; Limit = 2097152 }
        )) {
        $sz = Res-Size (Join-Path $inst $c.File)
        if ($sz -lt 0) { continue }
        $rows += ($c.File + '=' + (Res-KB $sz))
        if ($sz -gt $c.Limit) { $bad += ($c.File + ' ' + (Res-KB $sz) + ' > 上限 ' + (Res-KB $c.Limit)) }
    }
    if ($bad.Count -gt 0) { throw ($bad -join '、' + ' —— 上限逻辑没生效') }
    ($rows -join '，')
} -Hint '上限判断要在每次追加前做；轮转用 FileMove 覆盖（本机安全策略会拦 Remove-Item）'

Test-Case RES-003 '健壮' '安装目录备份文件没堆成山' low {
    $inst = Get-DshInstall
    if (-not (Test-Path -LiteralPath $inst)) { return (Test-DshAbort) }
    $baks = @(Get-ChildItem -LiteralPath $inst -File | Where-Object { $_.Name -match '\.bak' })
    if ($baks.Count -eq 0) { return '没有备份残留' }
    $tot = ($baks | Measure-Object -Property Length -Sum).Sum
    $names = ($baks | Sort-Object Length -Descending | Select-Object -First 3 | ForEach-Object { $_.Name }) -join '、'
    if ($baks.Count -gt 8) {
        return @{ Status = 'warn'; Detail = ($baks.Count.ToString() + ' 个备份共 ' + (Res-KB $tot) + '，最大的：' + $names + ' —— 该清理了') }
    }
    ($baks.Count.ToString() + ' 个备份共 ' + (Res-KB $tot))
} -Hint '保留最近 2 份即可；旧备份放 _backup_日期\ 而不是安装目录'

Test-Case RES-004 '健壮' '启动队列没有残留' high {
    $q = Join-Path (Get-DshInstall) 'launch-queue.txt'
    if (-not (Test-Path -LiteralPath $q)) { return '队列文件不存在（无残留）' }
    $sz = (Get-Item -LiteralPath $q).Length
    if ($sz -gt 0) {
        throw ('launch-queue.txt 有 ' + $sz + 'B 残留 —— 代理/看门狗都没在消费，用户看到的是「点图标弹已排入启动队列」')
    }
    '队列文件存在但为空（正常）'
} -Hint '队列由 ensure-all 每 2 分钟消费一次；有残留先看 agent-watch.log 是不是在反复杀代理'

Test-Case RES-005 '健壮' '数据落盘使用原子替换' medium {
    $root = Get-DshRoot
    $bad = @()

    # PowerShell 侧：WriteAllText 到 *.tmp → Move-Item -Force 覆盖（Move-Item 同卷是改名，原子）
    $hw = Read-Raw (Join-Path $root 'drawer\hwmon.ps1')
    if ($hw -notmatch 'hw-data\.tmp') { $bad += 'hwmon.ps1 没写 tmp 文件' }
    elseif ($hw -notmatch 'Move-Item[^\r\n]*-Destination\s+\$outFile[^\r\n]*-Force') { $bad += 'hwmon.ps1 没把 tmp 原子覆盖到 hw-data.js' }

    $wx = Read-Raw (Join-Path $root 'drawer\wxmon.ps1')
    if ($wx -notmatch 'wx-data\.tmp') { $bad += 'wxmon.ps1 没写 tmp 文件' }
    elseif ($wx -notmatch 'Move-Item[^\r\n]*-Destination\s+\$outFile[^\r\n]*-Force') { $bad += 'wxmon.ps1 没把 tmp 原子覆盖到 wx-data.js' }

    # AHK 侧：FileAppend(tmp) → FileMove(tmp, path, 1)
    $ahk = Read-Raw (Join-Path $root 'drawer\DesktopPage.ahk')
    if ($ahk -notmatch 'FileMove\(tmp,\s*path,\s*1\)') { $bad += 'DesktopPage.ahk 缺 tmp+FileMove 原子写' }

    # 代理侧三份「用户能看见的」数据：todo.txt（抽屉读）、todo-data.js（壁纸 <script> 加载）、
    # dock.txt（AHK 与代理共读）。直接 WriteAllText 会有一瞬文件是空/半个，
    # 撞上就是「待办空一片 / 快捷启动少几项」——2026-11-05 夜间补齐。
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    foreach ($pair in @(
            @{ Name = 'todo.txt'; Tmp = '\$todoTxt\s*\+\s*''\.tmp'''; Dst = 'Destination\s+\$todoTxt' }
            @{ Name = 'todo-data.js'; Tmp = '\$todoJs\s*\+\s*''\.tmp'''; Dst = 'Destination\s+\$todoJs' }
            @{ Name = 'dock.txt'; Tmp = '\$dockFile\s*\+\s*''\.tmp'''; Dst = 'Destination\s+\$dockFile' }
        )) {
        if ($agent -notmatch $pair.Tmp) { $bad += ('dsh-agent.ps1 写 ' + $pair.Name + ' 没走 tmp') }
        elseif ($agent -notmatch ('Move-Item[^\r\n]*' + $pair.Dst + '[^\r\n]*-Force')) { $bad += ('dsh-agent.ps1 写 ' + $pair.Name + ' 没做原子覆盖') }
    }

    if ($bad.Count -gt 0) { throw ($bad -join '；') }
    'hw-data / wx-data / layout / todo / todo-data / dock 六处都是 tmp + 原子覆盖'
} -Hint '不要用「先删再写」：进程被杀就丢布局；tmp 要同盘同目录（跨盘 Move 会退化成复制+删除）'

Test-Case RES-006 '健壮' 'panel-rect 内容合法' low {
    $p = Join-Path (Get-DshInstall) 'panel-rect.txt'
    if (-not (Test-Path -LiteralPath $p)) { return @{ Status = 'skip'; Detail = '还没上报过（壁纸没打开时正常）' } }
    $line = (Read-Raw $p).Trim()
    $parts = @($line -split '\s+' | Where-Object { $_ -ne '' })
    if ($parts.Count -ne 4) { throw ('应为 4 个整数，实际 ' + $parts.Count + ' 个：' + $line) }
    foreach ($x in $parts) {
        $n = 0
        if (-not [int]::TryParse($x, [ref]$n)) { throw ('出现非整数：' + $x) }
        if ($n -lt 0 -or $n -gt 10000) { throw ('值超出 0..10000 万分比范围：' + $x) }
    }
    ('panel-rect = ' + $line + '（有效万分比）')
} -Hint 'dsh.js reportRect() 把屏幕坐标换算成万分比；超出范围通常说明除数写错'

Test-Case RES-007 '健壮' '看门狗没有在反复重启代理' high {
    $inst = Get-DshInstall
    $lines = Res-ReadLog (Join-Path $inst 'agent-watch.log') 400
    if ($lines.Count -eq 0) { return @{ Status = 'skip'; Detail = 'agent-watch.log 为空' } }

    $failed = @($lines | Where-Object { $_ -match 'restart FAILED' })
    if ($failed.Count -gt 0) { throw ('出现 restart FAILED：' + $failed[-1]) }

    # 单次重启是正常自愈，连续重启才是问题（代理起来了又死 → 端口占用/脚本崩/心跳不刷新）。
    # 所以判据不是"总数"，而是"10 分钟内 ≥3 次"这种风暴形态。
    $now = Get-Date
    $times = @()
    foreach ($l in $lines) {
        if ($l -notmatch 'restart') { continue }
        $m = [regex]::Match($l, '(\d{2})-(\d{2})\s+(\d{2}):(\d{2}):(\d{2})')
        if (-not $m.Success) { continue }
        $txt = ($m.Groups[1].Value + '-' + $m.Groups[2].Value + ' ' +
            $m.Groups[3].Value + ':' + $m.Groups[4].Value + ':' + $m.Groups[5].Value)
        try {
            $dt = [datetime]::ParseExact($txt, 'MM-dd HH:mm:ss', $null)
            if ($dt -gt $now.AddDays(1)) { $dt = $dt.AddYears(-1) }   # 跨年
            if (($now - $dt).TotalHours -le 24) { $times += $dt }
        } catch { }
    }
    $times = @($times | Sort-Object)
    if ($times.Count -eq 0) { return ('末 ' + $lines.Count + ' 行无重启记录（24h 内）') }

    $burst = $null
    for ($i = 0; $i -lt $times.Count; $i++) {
        $end = $times[$i].AddMinutes(10)
        $win = @($times | Where-Object { $_ -ge $times[$i] -and $_ -le $end })
        if ($win.Count -ge 3) {
            $burst = ($win[0].ToString('MM-dd HH:mm') + '~' + $win[-1].ToString('HH:mm') + ' 共 ' + $win.Count + ' 次')
            break
        }
    }
    if ($burst) {
        # 风暴是否"还在发生"才是这条用例要回答的问题。24h 窗口里躺着的样子完全一样：
        # 昨晚调试时手动重启 5 次会留 4 小时，若只看"有过风暴"会把正常状态一直标黄，
        # 黄色一多就没人看了。判据改为：最近一次重启在 60 分钟内 → 仍在风暴中。
        $sinceLast = ($now - $times[-1]).TotalMinutes
        if ($sinceLast -le 60) {
            return @{ Status = 'warn'; Detail = ('10 分钟内连续重启：' + $burst + '，最近一次在 ' + [int]$sinceLast + ' 分钟前 —— 代理起来了又死，不是偶发') }
        }
        return ('历史风暴 ' + $burst + '，最近一次重启在 ' + [int]$sinceLast + ' 分钟前，此后无重启 —— 判定已恢复')
    }
    ('24h 内重启 ' + $times.Count + ' 次，未出现 10 分钟 3 次的风暴（最近一次 ' + [int]($now - $times[-1]).TotalMinutes + ' 分钟前）')
} -Hint '连着重启先看心跳是否空闲不刷新、端口是否被旧实例占着（Start 有 30 次重试）、以及 dsh-agent.log 尾部'

Test-Case RES-008 '健壮' '启动链没有失败记录' high {
    $inst = Get-DshInstall
    $lines = Res-ReadLog (Join-Path $inst 'start-all.log') 300
    if ($lines.Count -eq 0) { return @{ Status = 'skip'; Detail = 'start-all.log 还没生成（没通过计划任务启动过）' } }

    # 判据必须是「最近一轮」，不能拿末尾 N 行一刀切：一轮启动只写 4~6 行，
    # 四十行窗口里能同时躺着好几轮，一次失败会连着红七八轮 —— 而红/黄一多就没人看了
    # （同一个坑 RES-007 已经踩过一次，那边也是改成"最近一次"）。
    # 所以按 "start: appDir=" 切轮次，只看最近一轮能判的：
    #   有 done            → 成功，再确认这一轮没有 STILL DOWN
    #   没 done 且 > 120s  → 卡住了（2026-11-05 的 start-all.vbs 漏 Dim 就是这样：wscript
    #                        弹了个不可见模态框，日志停在中间，计划任务一直 Running）
    #   没 done 且 ≤ 120s  → 这一轮还在跑（只跳过最新那一轮，更早的轮次照样要判）
    $rounds = @()
    $cur = $null
    foreach ($l in $lines) {
        if ($l -match 'start:\s*appDir=') { if ($cur) { $rounds += , @($cur) }; $cur = @($l) }
        elseif ($cur) { $cur += $l }
    }
    if ($cur) { $rounds += , @($cur) }
    if ($rounds.Count -eq 0) { return @{ Status = 'skip'; Detail = 'start-all.log 里没有轮次标记（start: appDir=）' } }

    # 从最新一轮往回找「第一个能判的轮次」：最新一轮若刚开始（≤120s 还没 done）就先跳过，
    # 免得把"正在进行"误报成"卡住"；更早的轮次不论有没有 done 都要判。
    $judged = $null
    for ($i = $rounds.Count - 1; $i -ge 0; $i--) {
        $r = @($rounds[$i])
        $startAt = $null
        if ($r[0] -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') {
            try { $startAt = [datetime]::ParseExact($matches[1], 'yyyy-MM-dd HH:mm:ss', $null) } catch { $startAt = $null }
        }
        $ageSec = 999999.0
        if ($startAt) { $ageSec = ((Get-Date) - $startAt).TotalSeconds }
        $hasDone = [bool]($r -match 'done\s*$')

        if (-not $hasDone -and $i -eq ($rounds.Count - 1) -and $ageSec -le 120) { continue }  # 还在跑，先不下结论
        $down = @($r -match 'STILL DOWN')
        if ($down.Count -gt 0) { throw ('启动链最近有 STILL DOWN：' + $down[-1]) }
        if (-not $hasDone) {
            throw ('启动链最近一轮卡住了（已 ' + [int]$ageSec + ' 秒没走到 done，计划任务会一直 Running）：' + $r[-1])
        }
        $judged = $r
        break
    }
    if (-not $judged) { return @{ Status = 'skip'; Detail = '最新一轮还在跑，窗口内没有可判的轮次' } }
    ('最近一轮启动走到 done，无 STILL DOWN（本轮 ' + $judged.Count + ' 行；窗口内共 ' + $rounds.Count + ' 轮）')
} -Hint 'STILL DOWN 说明某件套没起来；按顺序手动拉一次并看对应日志；卡住（没 done）看 wscript 有没有弹模态错误框、start-all.vbs 有没有漏 Dim'

Test-Case RES-009 '健壮' '采样进程在持续写数据' medium {
    $wall = Get-DshWall
    if (-not $wall -or -not (Test-Path -LiteralPath $wall)) { return @{ Status = 'skip'; Detail = '没解析到壁纸目录' } }
    $bad = @()
    $rows = @()
    foreach ($c in @(
            @{ File = 'hw-data.js'; MaxAgeSec = 15 }
            @{ File = 'wx-data.js'; MaxAgeSec = 330 }
        )) {
        $p = Join-Path $wall $c.File
        if (-not (Test-Path -LiteralPath $p)) { $bad += ($c.File + ' 不存在'); continue }
        $age = ((Get-Date) - (Get-Item -LiteralPath $p).LastWriteTime).TotalSeconds
        $rows += ($c.File + ' ' + [int]$age + 's')
        if ($age -gt $c.MaxAgeSec) { $bad += ($c.File + ' 已 ' + [int]$age + 's 没更新（阈值 ' + $c.MaxAgeSec + 's）') }
    }
    if ($bad.Count -gt 0) { throw ($bad -join '、' + ' —— 面板会一直是 --') }
    ($rows -join '，')
} -Hint 'hwmon 2s 一轮、wxmon 300s 一轮；没更新先看对应 pid 与 Resolve-WallpaperDir() 解析到的目录'

Test-Case RES-010 '健壮' '滚轮意图队列有上限' medium {
    # scroll.dat 是「抽屉写一行、壁纸每 80ms 取走并清空」的意图队列。
    # 消费方一停（Lively 没起 / 壁纸页报错 / 页面脚本挂了），它就只增不减；
    # 而 Take-Scroll 是整份 ReadAllText —— 单线程代理会被这一条队列拖死，
    # 表现成「所有接口一起变慢」，正是铁律里最贵的那种故障。
    $root = Get-DshRoot
    $inst = Get-DshInstall
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')

    # 取某个函数的源码段（到下一个顶层 function 为止）
    $body = {
        param($code, $fn)
        $i = $code.IndexOf('function ' + $fn)
        if ($i -lt 0) { return '' }
        $j = $code.IndexOf("`nfunction ", $i + 1)
        if ($j -lt 0) { $j = $code.Length }
        return $code.Substring($i, $j - $i)
    }

    $gif = & $body $agent 'Invoke-ScrollGif'
    $take = & $body $agent 'Take-Scroll'
    $bad = @()
    # 判据只看"有没有上限分支"，不锁死具体写法（阈值/清空方式都可以演进）
    if ($agent -notmatch '\$script:SCROLL_MAX\s*=\s*\d+') { $bad += '没有 SCROLL_MAX 阈值定义' }
    if ($gif -notmatch 'SCROLL_MAX') { $bad += 'Invoke-ScrollGif 写入前不检查尺寸（无限追加）' }
    if ($gif -notmatch 'WriteAllText') { $bad += 'Invoke-ScrollGif 超限时没有清空动作' }
    if ($take -notmatch '1MB') { $bad += 'Take-Scroll 没有超大文件兜底（外部写入会拖死主循环）' }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }

    $sz = Res-Size (Join-Path $inst 'scroll.dat')
    $szTxt = if ($sz -lt 0) { '当前无残留' } else { Res-KB $sz }
    if ($sz -gt 1MB) { throw ('scroll.dat 已达 ' + (Res-KB $sz) + '，超过 1MB 兜底阈值') }
    ('写入方 64KB 截断 + 读取方 1MB 兜底都在；scroll.dat ' + $szTxt)
} -Hint 'scroll.dat 是瞬时意图队列，旧意图无重放价值；超限直接丢弃，别为了几条过期滚动拖慢整条单线程'

Test-Case RES-011 '健壮' '启动队列：删掉才算消费（否则会重复启动）' medium {
    # launch-queue.txt 是「抽屉点图标 → 代理没在 → 写一行 → 看门狗/巡检代跑」的一次性队列。
    # 原来的消费方都是 Remove-Item -Force -ErrorAction SilentlyContinue：
    #   agent-watch.ps1 的 $ErrorActionPreference 是 SilentlyContinue、ensure-all.ps1 干脆没设（默认 Continue），
    #   所以「删失败」既抛不出来也不记日志 —— 队列文件还在，下一次 tick 把同一批路径再启动一遍。
    # 看门狗是 1 秒一轮：AHK 正开着句柄追加（FileAppend）的那一瞬就能让程序被连开好几次；
    # 若被策略长期拦住，则是永远重复启动。所以判据是「先证明消费掉了，再启动」。
    $root = Get-DshRoot
    $bad = @()
    foreach ($f in @('drawer\agent-watch.ps1', 'drawer\ensure-all.ps1')) {
        $src = Read-Raw (Join-Path $root $f)
        $name = Split-Path $f -Leaf
        if ($src -match 'Remove-Item\s+\$queueFile') {
            $bad += ($name + ' 仍在用 Remove-Item 消费队列（失败时静默，队列留着会被反复重放）')
        }
        if ($src -notmatch '\[System\.IO\.File\]::Delete\(\$queueFile\)') {
            $bad += ($name + ' 没有主动删除队列')
        }
        if ($src -notmatch 'Test-Path\s+\$queueFile') {
            $bad += ($name + ' 删完不复核（删没删掉都不知道）')
        }
        if ($src -notmatch '\$consumed') {
            $bad += ($name + ' 没有 $consumed 消费闸')
        }
        if (($src -notmatch 'if\s*\(\s*-not\s+\$consumed\s*\)') -and ($src -notmatch '\$\(if\s*\(\s*\$consumed\s*\)')) {
            $bad += ($name + ' 的启动循环没被消费闸挡住')
        }
    }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }
    $q = Join-Path (Get-DshInstall) 'launch-queue.txt'
    if (Test-Path -LiteralPath $q) {
        $sz = (Get-Item -LiteralPath $q).Length
        return @{ Status = 'warn'; Detail = ('静态判据齐全，但队列当前有 ' + $sz + 'B 残留（RES-004 会单独判）') }
    }
    'watch / ensure 两处都是「删掉才算消费，消费不了这一轮不启动」；当前无残留'
} -Hint '消费型文件（队列 / 触发文件）不能用「静默删除 + 照旧执行」：删除失败时动作会被反复重放'

Test-Case RES-012 '健壮' '信标落盘也原子替换（panel-rect / summon.cmd）' medium {
    # 这两个文件都是「代理写、另一进程每 400ms 读」的高频小文件：
    #   panel-rect.txt → AHK PanelRect()（读到空/半个就掉进兜底矩形，滚轮落点错）
    #   summon.cmd     → AHK SummonTick()（**读完无论读成什么都会删文件**，读到空 = 命令被静默吞掉）
    # 直接 WriteAllText 是「先截断成 0 字节、再补齐」；改名替换没有这个中间态。
    $root = Get-DshRoot
    $inst = Get-DshInstall
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    $body = {
        param($code, $fn)
        $i = $code.IndexOf('function ' + $fn)
        if ($i -lt 0) { return '' }
        $j = $code.IndexOf("`nfunction ", $i + 1)
        if ($j -lt 0) { $j = $code.Length }
        return $code.Substring($i, $j - $i)
    }
    $rect = & $body $agent 'Invoke-RectGif'
    $sum = & $body $agent 'Invoke-SummonGif'
    $bad = @()

    if (-not $rect) { $bad += '找不到 Invoke-RectGif' }
    else {
        if ($rect -match 'WriteAllText\(\s*\$rectFile') { $bad += 'Invoke-RectGif 仍直写 panel-rect.txt' }
        if ($rect -notmatch '\$rt\b') { $bad += 'Invoke-RectGif 没有 tmp 变量' }
        if ($rect -notmatch 'Move-Item[^\r\n]*-Destination\s+\$rectFile[^\r\n]*-Force') { $bad += 'Invoke-RectGif 没有把 tmp 原子覆盖到 panel-rect.txt' }
    }
    if (-not $sum) { $bad += '找不到 Invoke-SummonGif' }
    else {
        if ($sum -match 'WriteAllText\(\(Join-Path \$appDir ''summon\.cmd''\)') { $bad += 'Invoke-SummonGif 仍直写 summon.cmd' }
        if ($sum -notmatch '\$st\b') { $bad += 'Invoke-SummonGif 没有 tmp 变量' }
        if ($sum -notmatch 'Move-Item[^\r\n]*-Destination\s+\$sf[^\r\n]*-Force') { $bad += 'Invoke-SummonGif 没有把 tmp 原子覆盖到 summon.cmd' }
    }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }

    # 活体探针：一边连打 /rect.gif（内容取文件当前值，幂等、不改实际矩形），一边高频读文件；
    # 读到「空 / 字段不足 4 个」就说明还有保留直写的路径。
    $rp = Join-Path $inst 'panel-rect.txt'
    $samples = 0
    $badReads = 0
    if (Test-Path -LiteralPath $rp) {
        $parts = @(((Read-Raw $rp).Trim()) -split '\s+' | Where-Object { $_ -ne '' })
        if ($parts.Count -eq 4) {
            $qs = '/rect.gif?x=' + $parts[0] + '&y=' + $parts[1] + '&w=' + $parts[2] + '&h=' + $parts[3]
            for ($i = 0; $i -lt 30; $i++) {
                [void](Invoke-DshHttp -Path $qs -TimeoutMs 2000)
                for ($k = 0; $k -lt 6; $k++) {
                    $t = ''
                    try { $t = [System.IO.File]::ReadAllText($rp) } catch { continue }
                    $samples++
                    $pp = @($t.Trim() -split '\s+' | Where-Object { $_ -ne '' })
                    if ($pp.Count -ne 4) { $badReads++ }
                }
            }
        }
    }
    if ($badReads -gt 0) { throw ('并发采样 ' + $samples + ' 次，有 ' + $badReads + ' 次读到空/不完整 —— 仍有非原子写路径') }
    ('两处都是 tmp + 原子覆盖；并发采样 ' + $samples + ' 次未读到空/不完整')
} -Hint '改名替换（Move-Item -Force / FileMove）不会出现「存在但为空」；改不动就这一轮不写，别退回直写'

Test-Case RES-013 '健壮' '滚轮意图：读到≠取走，清不掉不许重复消费' medium {
    # scroll.dat 是「抽屉写一行（/scroll.gif 或 AHK AgentScroll）、壁纸每 40ms 取走」的意图队列。
    # 原来的 Take-Scroll 是「读 → File::Delete → 不管删没删掉都返回读数」：
    # 删除失败时（写方还持有句柄 / 杀软扫描 / 安全策略）同一批意图 40ms 后又被读一遍，
    # 用户感觉「滚一格跳两格」，而日志干干净净 —— 删除失败的异常被 catch 吞掉了。
    # 判据：先清后发 —— 清不掉这一轮返回 0（内容还在文件里，下一轮再取），绝不重复下发。
    $root = Get-DshRoot
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    $body = {
        param($code, $fn)
        $i = $code.IndexOf('function ' + $fn)
        if ($i -lt 0) { return '' }
        $j = $code.IndexOf("`nfunction ", $i + 1)
        if ($j -lt 0) { $j = $code.Length }
        return $code.Substring($i, $j - $i)
    }
    $take = & $body $agent 'Take-Scroll'
    if (-not $take) { throw '找不到 Take-Scroll' }

    $bad = @()
    if ($take -notmatch '\[System\.IO\.File\]::Delete\(\$scrollDat\)') { $bad += 'Take-Scroll 不正视删除（仍指望一次读走就完事）' }
    if ($take -notmatch 'Test-Path\s+\$scrollDat') { $bad += 'Take-Scroll 删完不复核（删没删掉都不知道 → 会重复消费）' }
    if ($take -notmatch '\$cleared') { $bad += 'Take-Scroll 没有 $cleared 清空闸' }
    if ($take -notmatch 'if\s*\(\s*-not\s+\$cleared\s*\)[\s\S]*?return\s+0') { $bad += '$cleared 闸没挡住下发（清不掉时照样把读数返回）' }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }

    # 活体（函数级）：把 Take-Scroll 单独取出来，在临时目录里跑 ——
    # 不碰真实 scroll.dat、不占端口、不影响正在跑的代理。
    $tmp = Join-Path $env:TEMP ('dsh_scroll_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $tmp -Force)
    try {
        $probe = {
            param($src, $dir)
            $appDir = $dir
            function Agent-Log([string]$m) { }
            . ([scriptblock]::Create($src))
            $f = Join-Path $dir 'scroll.dat'
            # ① 正常路径：三条意图一次取走（+2+3-1=4），文件必须消失
            [System.IO.File]::WriteAllText($f, "+2`r`n+3`r`n-1`r`n")
            $a = Take-Scroll
            $gone1 = -not (Test-Path -LiteralPath $f)
            # ② 占住句柄：只允许别人读，不允许写/删（等价于「删除会失败」的那个时刻）
            [System.IO.File]::WriteAllText($f, "+5`r`n")
            $fs = [System.IO.File]::Open($f, 'Open', 'Read', 'Read')
            try {
                $b = Take-Scroll
                $c = Take-Scroll
                $still = Test-Path -LiteralPath $f
            } finally { $fs.Dispose() }
            # ③ 放开句柄：这 1 条意图只能被交付一次
            $d = Take-Scroll
            $gone2 = -not (Test-Path -LiteralPath $f)
            return [pscustomobject]@{ A = $a; Gone1 = $gone1; B = $b; C = $c; Still = $still; D = $d; Gone2 = $gone2 }
        }
        $r = & $probe $take $tmp
    } finally {
        try { [System.IO.Directory]::Delete($tmp, $true) } catch { }
    }

    if ($r.A -ne 4) { throw ('正常路径没取到期望的增量（期望 4，实际 ' + $r.A + '）') }
    if (-not $r.Gone1) { throw '正常路径取走后 scroll.dat 还在（等于没消费）' }
    if ($r.B -ne 0 -or $r.C -ne 0) { throw ('文件清不掉时仍下发了意图（两次分别读 ' + $r.B + ' / ' + $r.C + '）—— 会被重复消费') }
    if (-not $r.Still) { throw '测试前提不成立：占住句柄期间 scroll.dat 竟然被删掉了' }
    if ($r.D -ne 5) { throw ('放开句柄后应恰好交付一次 5，实际 ' + $r.D) }
    if (-not $r.Gone2) { throw '放开句柄后意图仍没被清掉' }
    ('清不掉时 2 次轮询都返回 0、放开后恰好交付一次（' + $r.A + ' → 0/0 → ' + $r.D + '）')
} -Hint '「读到」不等于「取走」：消费型文件必须「清掉才算取走」，清不掉这一轮不发（内容留在文件里，下一轮再取）'

Test-Case RES-014 '健壮' '文件召唤：删掉才算消费（AHK SummonTick）' medium {
    # 同 RES-013 的消费端，只是换到 AHK 侧：SummonTick 每 400ms 读 summon.cmd，
    # 原来「读完 → FileDelete → 无论删没删掉都派发」。删失败时（/summon.gif 刚 Move 完、
    # 杀软在扫、策略拦删）同一条命令每 400ms 重放一次 ——
    # `show`/`hide` 幂等还看不出来，`diag` 会刷日志、`foldertest=` 会反复弹窗，
    # 最坏的是 `log=N` 反复导出。所以要求「删完复核，删不掉这一轮不派发」。
    $root = Get-DshRoot
    $ahk = Read-Raw (Join-Path $root 'drawer\DesktopPage.ahk')
    $i = $ahk.IndexOf('SummonTick() {')
    if ($i -lt 0) { throw '找不到 SummonTick' }
    $j = $ahk.IndexOf("`n}", $i)
    if ($j -lt 0) { $j = $ahk.Length }
    $fn = $ahk.Substring($i, $j - $i)

    $bad = @()
    if ($fn -notmatch 'FileDelete\(SUMMON_FILE\)') { $bad += 'SummonTick 没有删除 summon.cmd' }
    # 复核必须挡在派发之前：FileDelete 之后、真正调用命令（SUMMON_CMDS 查表/前缀匹配）之前要有一道
    # 「文件还在就 return」。注意两个坑（本轮踩过）：
    #   ①函数头就有 `if !FileExist(SUMMON_FILE) return`，拿它当判据会永远是绿的；
    #   ②`if (cmd = "") return` 也在删除之后，同样会误判 —— 所以只认「FileExist 后面紧跟 return」。
    $di = $fn.IndexOf('FileDelete(SUMMON_FILE)')
    $ci = $fn.IndexOf('SUMMON_CMDS.Has')
    if ($di -lt 0 -or $ci -lt 0 -or $ci -le $di) {
        $bad += 'SummonTick 的删除不在派发之前'
    } else {
        $guard = $fn.Substring($di, $ci - $di)
        if ($guard -notmatch 'FileExist\(SUMMON_FILE\)[\s\S]{0,80}?return') {
            $bad += 'SummonTick 删不掉时没提前 return（照样派发 → 每 400ms 重放一次）'
        }
    }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }

    # 活体：走**文件通道**写一条 diag（和 RUN-011 同一条路）。
    # 不要用 /summon.gif：那条路由只认 d=1|hide，其余一律写 show —— 深夜会把抽屉弹开。
    $inst = Get-DshInstall
    if (-not (Get-Process -Name 'AutoHotkey64' -ErrorAction SilentlyContinue)) {
        return @{ Status = 'skip'; Detail = '抽屉没在跑（AutoHotkey64 不存在），活体部分跳过；静态判据已通过' }
    }
    $log = Join-Path $inst 'wheel.log'
    $countDiag = {
        param($p)
        if (-not (Test-Path -LiteralPath $p)) { return 0 }
        $fs = [System.IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
        try { $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8); $all = $sr.ReadToEnd(); $sr.Dispose() } finally { $fs.Dispose() }
        return @([regex]::Matches($all, 'diag:')).Count
    }
    $sf = Join-Path $inst 'summon.cmd'
    $before = & $countDiag $log
    [System.IO.File]::WriteAllText($sf, 'diag', (New-Object System.Text.UTF8Encoding($false)))
    $after = $before
    for ($k = 0; $k -lt 12; $k++) {
        Start-Sleep -Milliseconds 250
        $after = & $countDiag $log
        if ($after -gt $before) { break }
    }
    if ($after -le $before) {
        throw ('静态判据齐全，但活体 diag 没落地（diag 行 ' + $before + ' → ' + $after + '）—— 复核把正常命令也挡掉了')
    }
    if (Test-Path -LiteralPath $sf) { throw 'diag 落了日志，但 summon.cmd 没被消费掉（文件还在）' }
    ('SummonTick 删完复核、删不掉不派发；活体 diag 落地并被消费（diag 行 ' + $before + ' → ' + $after + '）')
} -Hint 'AHK 侧无法自动校验语法，这条只用静态文本 + 一条真实 diag 兜住「没把正常命令挡掉」'

Test-Case RES-015 '健壮' '审计轮转：三端共写，判据要对齐真实尺寸' medium {
    # audit.log 是三端共写的（[AHK ] / [API ] / [WEB ]）。实测 2331 行里 1999 行来自抽屉 ≈ 90%，
    # 代理只占 9%。轮转判据如果只累加「自己写进去的字节」，这个值就和真实尺寸脱钩：
    #   · 偏小 → 代理这辈子都到不了 2MB，它那段轮转形同虚设；
    #   · 偏大 → 别人（AHK 每 32 条会 FileGetSize 对齐）刚轮转完、文件归 0，它还以为快满，
    #            于是「提前轮转」一个很小的文件，把上一份真正的 2MB 历史 audit.log.1 覆盖掉。
    # AHK 侧一直有「每 32 条与真实尺寸对齐」；代理侧原来只有启动时取一次初值、此后只累加自己的字节。
    $root = Get-DshRoot
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    $i = $agent.IndexOf('function Write-Audit')
    if ($i -lt 0) { throw '找不到 Write-Audit' }
    $j = $agent.IndexOf("`nfunction ", $i + 1)
    if ($j -lt 0) { $j = $agent.Length }
    $fn = $agent.Substring($i, $j - $i)

    $bad = @()
    if ($fn -notmatch '\$script:auditWrites') { $bad += 'Write-Audit 没有写入计数（无从判断何时该对齐）' }
    if ($fn -notmatch '%\s*32') { $bad += 'Write-Audit 没有「每 32 条对齐一次」的节奏' }
    if ($fn -notmatch '(FileInfo|Get-Item)[\s\S]{0,80}\.Length') { $bad += 'Write-Audit 从不读真实文件尺寸（只累加自己的字节 = 判据脱钩）' }

    # 另一半：AHK 侧的对齐不能被悄悄删掉（否则这条不变式只剩一边，等于没有）
    $ahk = Read-Raw (Join-Path $root 'drawer\DesktopPage.ahk')
    $ai = $ahk.IndexOf('AuditLog(action, detail')
    if ($ai -lt 0) { throw '找不到 AHK 的 AuditLog' }
    $aj = $ahk.IndexOf("`n}", $ai)
    if ($aj -lt 0) { $aj = $ahk.Length }
    $afn = $ahk.Substring($ai, $aj - $ai)
    if ($afn -notmatch 'Mod\(AUDIT_WRITES,\s*32\)') { $bad += 'AHK AuditLog 丢了「每 32 条对齐」' }
    if ($afn -notmatch 'FileGetSize\(AUDIT_FILE\)') { $bad += 'AHK AuditLog 不再读真实尺寸（FileGetSize）' }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }

    # 活体（函数级）：把 Write-Audit 取出来在临时目录里跑 —— 不碰真实 audit.log、不占端口。
    # 造一个「本地计数器远远落后于真实尺寸」的时刻（别人写了 2.2MB，代理以为自己才写了 1KB），
    # 再补一条自己的写入：对齐过的实现必须当场轮转，没对齐的会让 2.2MB 那份继续躺着。
    $tmp = Join-Path $env:TEMP ('dsh_audit_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $tmp -Force)
    try {
        $r = & {
            param($src, $dir)
            $auditFile = Join-Path $dir 'audit.log'
            $script:auditEnc = New-Object System.Text.UTF8Encoding($false)
            $script:auditWrites = 31          # 下一条正好是第 32 条 → 触发对齐
            $script:auditBytes = 1000         # 陈旧值：只算自己的字节
            [System.IO.File]::WriteAllText($auditFile, ('x' * 2200000), (New-Object System.Text.UTF8Encoding($false)))
            . ([scriptblock]::Create($src))
            Write-Audit 'test' 'k=v'
            return [pscustomobject]@{
                Size   = (Get-Item -LiteralPath $auditFile).Length
                Rotated = Test-Path -LiteralPath ($auditFile + '.1')
            }
        } $fn $tmp
    } finally {
        try { [System.IO.Directory]::Delete($tmp, $true) } catch { }
    }
    if (-not $r.Rotated) { throw ('真实尺寸 2.2MB 超过 2MB 上限却没轮转（audit.log 仍有 ' + $r.Size + ' 字节）—— 判据只认自己的累加值') }
    if ($r.Size -ne 0) { throw ('轮转后 audit.log 应为空文件，实际 ' + $r.Size + ' 字节') }
    '两端都按真实尺寸对齐（每 32 条）；活体：陈旧计数器遇上 2.2MB 文件仍当场轮转'
} -Hint '三端共写的文件，任何一端的轮转判据都必须定期回到「真实文件尺寸」，只累加自己写的字节早晚会脱钩'

Test-Case RES-016 '健壮' '日志轮转：改名失败不许截空（历史不能和它唯一的备份一起丢）' medium {
    # 轮转是「改名 → 截空」两步，老写法两步之间没有依赖：
    #   Move-Item … -ErrorAction SilentlyContinue    ← 失败不抛、不记、不管
    #   WriteAllText($log, '')                       ← 照样执行
    # 于是改名失败时（AHK 正持有句柄追加 audit.log / 有人把 audit.log.1 开着看 /
    # 上一轮 dsh 还活着、cmd 的 >> 句柄占着 dsh-run.log / 杀软在扫）整份历史被抹成
    # 0 字节，而 .1 里还是上一代的内容 —— 恰好在最需要这份日志的时刻丢证据，
    # 而且 dsh-agent.log、audit.log、verify.ps1 三处都不会留下任何痕迹。
    # 实测：audit.log 2680000 字节 → 0，.1 仍是 15 字节的上一代。
    # 不变式：**改名成功才许截空**；没轮转成要把计数器拉回真实尺寸并留痕（下次再试）。
    $root = Get-DshRoot
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    $bad = @()

    # ---- 静态一：audit.log ----
    $i = $agent.IndexOf('function Write-Audit')
    if ($i -lt 0) { throw '找不到 Write-Audit' }
    $j = $agent.IndexOf("`nfunction ", $i + 1); if ($j -lt 0) { $j = $agent.Length }
    $fn = $agent.Substring($i, $j - $i)
    $ri = $fn.IndexOf('if ($script:auditBytes -gt 2097152)')
    if ($ri -lt 0) { throw 'Write-Audit 里找不到 2MB 轮转分支' }
    # 只看代码：注释里会原样引用旧写法（"Move-Item … SilentlyContinue / WriteAllText(…)"），
    # 不剥掉就会被自己的注释判成还没改（本轮踩过一次，RES-014 也踩过同型的坑）。
    $rot = ((($fn.Substring($ri)) -split "`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
    if ($rot -match 'Move-Item[^\r\n]*-ErrorAction\s+SilentlyContinue') { $bad += 'audit.log 轮转仍是「静默改名」（-ErrorAction SilentlyContinue），失败无从观察' }
    $trunc = $rot.IndexOf('WriteAllText($auditFile')
    $guard = $rot.IndexOf('if ($moved')
    if ($trunc -lt 0) { $bad += 'Write-Audit 的轮转分支里找不到截空（WriteAllText($auditFile）' }
    if ($guard -lt 0) { $bad += 'audit.log 轮转没有「改名成功」的闸（截空与改名之间无依赖）' }
    elseif ($guard -gt $trunc) { $bad += 'audit.log 的截空写在闸之前（改名失败照样截空 = 历史归零）' }
    if ($rot -notmatch 'Agent-Log') { $bad += 'audit.log 轮转失败不留痕（失败必须写一行 dsh-agent.log，否则又是静默失败）' }
    if ($rot -notmatch '(FileInfo|Get-Item)[\s\S]{0,80}\.Length') { $bad += 'audit.log 轮转失败后没把计数器拉回真实尺寸（下次一写就判空）' }

    # ---- 静态二：dsh-run.log / dsh-run.err.log ----
    $si = $agent.IndexOf('function Start-Run')
    if ($si -lt 0) { throw '找不到 Start-Run' }
    $sj = $agent.IndexOf("`nfunction ", $si + 1); if ($sj -lt 0) { $sj = $agent.Length }
    $srun = ((($agent.Substring($si, $sj - $si)) -split "`n") | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n"
    if ($srun -match 'Move-Item[^\r\n]*-ErrorAction\s+SilentlyContinue') { $bad += 'dsh-run.log 轮转仍是「静默改名」，上一轮 cmd 的 >> 句柄占着时失败照样截空' }
    $st = $srun.IndexOf('WriteAllText($f')
    $sg = $srun.IndexOf('if ($rotOk')
    if ($st -ge 0 -and ($sg -lt 0 -or $sg -gt $st)) { $bad += 'dsh-run.log 的截空没有「改名成功」的闸（$rotOk）' }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }

    # ---- 活体（函数级）：把 Write-Audit 取到临时目录里跑，不碰真实 audit.log、不占端口 ----
    # A 段：有人正开着 .1（只读句柄）→ 改名必然失败 → audit.log 必须原样留着
    # B 段：放开句柄再写一条 → 必须真的轮转（说明失败后还会重试）
    $tmp = Join-Path $env:TEMP ('dsh_rot_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory -Path $tmp -Force)
    try {
        $r = & {
            param($src, $dir)
            $auditFile = Join-Path $dir 'audit.log'
            $script:auditEnc = New-Object System.Text.UTF8Encoding($false)
            $script:auditWrites = 32          # 这一条正好触发「与真实尺寸对齐」
            $script:auditBytes = 3000000      # 已超 2MB 上限
            $script:auditRotSkipAt = [long]0
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($auditFile, ('y' * 2680000), $enc)
            $bak = $auditFile + '.1'
            [System.IO.File]::WriteAllText($bak, 'OLD-GENERATION', $enc)
            $bakBefore = (Get-Item -LiteralPath $bak).Length
            . ([scriptblock]::Create($src))
            $lock = [System.IO.File]::Open($bak, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            try { Write-Audit 'probe' 'k=1' } catch { }
            $kept = (Get-Item -LiteralPath $auditFile).Length
            $bakKept = (Get-Item -LiteralPath $bak).Length
            $lock.Dispose()
            Write-Audit 'probe' 'k=2'
            return [pscustomobject]@{
                Kept      = $kept
                BakKept   = $bakKept
                BakBefore = $bakBefore
                Size      = (Get-Item -LiteralPath $auditFile).Length
                Bak       = (Get-Item -LiteralPath $bak).Length
            }
        } $fn $tmp
    } finally {
        try { [System.IO.Directory]::Delete($tmp, $true) } catch { }
    }
    if ($r.Kept -lt 2680000) { throw ('改名失败时 audit.log 被截空了（' + $r.Kept + ' 字节，2.68MB 历史归零）—— 轮转两步之间没有依赖') }
    if ($r.BakKept -ne $r.BakBefore) { throw ('改名失败时 .1 也被动了（' + $r.BakKept + ' 字节，应为 ' + $r.BakBefore + '）') }
    if ($r.Bak -lt 2600000) { throw ('放开句柄后再写一条仍没轮转（.1 = ' + $r.Bak + ' 字节）—— 失败后不会重试') }
    if ($r.Size -ne 0) { throw ('轮转后 audit.log 应为空文件，实际 ' + $r.Size + ' 字节') }
    '两端都是「改名成功才截空」；活体：.1 被占用时 2.68MB 历史原样留着，放开后重试当场轮转'
} -Hint '轮转是「改名 + 截空」两步，第一步失败时第二步绝不能执行 —— 否则历史与它唯一的备份一起没了，而且哪儿都不报错'

Test-Case RES-017 '健壮' '审计轮转互斥：两个写者不能同时把 .1 覆盖成小文件' medium {
    # P2（2026-11-11）：audit.log 有两个轮转者（AHK AuditLog / 代理 Write-Audit）。
    # 两端同时越过 2MB 时，后一个 FileMove 会把对方刚写好的 .1 覆盖成一个很小的新文件，
    # 真正的 2MB 历史只剩内存里的旧计数 —— 静默丢证据。约定：共用命名互斥体，
    # 抢到锁后必须复检真实尺寸（等锁期间对方可能已经轮转完）。
    $root = Get-DshRoot
    $agent = Read-Raw (Join-Path $root 'drawer\dsh-agent.ps1')
    $ahk = Read-Raw (Join-Path $root 'drawer\DesktopPage.ahk')
    $bad = @()

    if ($agent -notmatch 'Global\\DesktopPage_audit') { $bad += '代理没有用 Global\DesktopPage_audit 互斥体' }
    $i = $agent.IndexOf('function Write-Audit')
    if ($i -lt 0) { throw '找不到 Write-Audit' }
    $j = $agent.IndexOf("`nfunction ", $i + 1); if ($j -lt 0) { $j = $agent.Length }
    $wb = $agent.Substring($i, $j - $i)
    if ($wb -notmatch 'auditMtx[\s\S]{0,160}WaitOne\(') { $bad += '代理轮转前没有在 auditMtx 上 WaitOne' }
    if ($wb -notmatch 'ReleaseMutex') { $bad += '代理轮转后没有 ReleaseMutex（异常一次就永久占锁）' }
    if ($wb -notmatch 'WaitOne\([\s\S]{0,500}FileInfo[\s\S]{0,100}\.Length') { $bad += '代理抢锁后没有复检真实尺寸' }

    if ($ahk -notmatch 'Global\\DesktopPage_audit') { $bad += 'AHK 没有用同一个互斥体名' }
    if ($ahk -notmatch 'CreateMutexW') { $bad += 'AHK 没有 CreateMutexW' }
    if ($ahk -notmatch 'WaitForSingleObject') { $bad += 'AHK 轮转前没有 WaitForSingleObject' }
    if ($ahk -notmatch 'ReleaseMutex') { $bad += 'AHK 轮转后没有 ReleaseMutex' }
    if ($ahk -notmatch 'WaitForSingleObject[\s\S]{0,500}FileGetSize\(AUDIT_FILE\)') { $bad += 'AHK 抢锁后没有复检 FileGetSize' }
    if ($ahk -notmatch 'FileMove\(AUDIT_FILE, AUDIT_FILE "\.1", 1\)') { $bad += 'AHK 的轮转改名不在锁内或写法变了' }

    if ($bad.Count -gt 0) { throw ($bad -join '；') }
    '两个轮转者共用 Global\DesktopPage_audit；抢锁后复检尺寸，不会再互覆盖 .1'
} -Hint 'P2（2026-11-11）：AHK 与代理同时越过 2MB 时，后一个会把 .1 覆盖成刚建的小文件，前一个 2MB 历史丢失'

Test-Case RES-018 '健壮' 'AHK 滚动写入有 64KB 上限；桥日志改名成功才截空' medium {
    # P3：AgentScroll 只追加不设上限，代理假死时 scroll.dat 能涨到几百 MB，下一次读盘卡住。
    # P2：wheel-bridge 的 C# 轮转原来是 File.Copy + 截空，两步之间崩掉会留下两份，
    # 主文件被截空后唯一完整的历史只剩 .1。改成 File.Replace/Move 后再建空。
    $root = Get-DshRoot
    $ahk = Read-Raw (Join-Path $root 'drawer\DesktopPage.ahk')
    $i = $ahk.IndexOf('AgentScroll(delta)')
    if ($i -lt 0) { throw '找不到 AgentScroll' }
    $j = $ahk.IndexOf("`n}", $i); if ($j -lt 0) { $j = $ahk.Length }
    $ab = $ahk.Substring($i, $j - $i)
    if ($ab -notmatch 'FileGetSize\(SCROLL_FILE\)\s*>\s*65536') { throw 'AgentScroll 没有 64KB 上限检查' }
    if ($ab -notmatch 'FileOpen\(SCROLL_FILE,\s*"w"') { throw 'AgentScroll 超限后没有截空' }

    $bridge = Read-Raw (Join-Path $root 'drawer\wheel-bridge.ps1')
    if ($bridge -match 'File\.Copy\(') { throw '桥日志轮转还是 File.Copy + 截空（非原子）' }
    if ($bridge -notmatch 'File\.Replace\(_logPath') { throw '桥日志轮转没有 File.Replace' }
    if ($bridge -notmatch 'File\.Move\(_logPath') { throw '桥日志轮转没有 File.Move 兜底' }
    $li = $bridge.IndexOf('public static void Log(string s)')
    if ($li -lt 0) { throw '找不到桥的 Log 函数' }
    $lj = $bridge.IndexOf('static void ReadTarget', $li); if ($lj -lt 0) { $lj = $bridge.Length }
    $lb = $bridge.Substring($li, $lj - $li)
    $iMove = $lb.IndexOf('File.Move(_logPath')
    $iTrunc = $lb.IndexOf('File.WriteAllText(_logPath, string.Empty)')
    if ($iTrunc -lt 0) { throw '桥日志轮转没有建空文件' }
    if ($iMove -ge 0 -and $iTrunc -lt $iMove) { throw '桥日志截空写在改名之前（改名失败就丢历史）' }
    '滚动文件 64KB 闸 + 桥日志改名成功才截空'
} -Hint 'P2/P3（2026-11-11）：scroll.dat 无上限会被假死代理撑爆；桥日志 File.Copy 非原子'