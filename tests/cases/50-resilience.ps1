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
