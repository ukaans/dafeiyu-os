#requires -Version 5.1
<#
  10-static.ps1 —— 静态完整性
  这一组不碰运行中的系统，只回答一个问题：
  「源码本身是不是完好、可移植、符合这套系统的编码契约？」
  它们挂了，后面所有运行时测试的结论都不可信。
#>

function Static-EncKind([string]$path) {
    $b = Read-FirstBytes $path 3
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return 'utf8bom' }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return 'utf16le' }
    return 'plain'
}

function Static-Sha([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

# 去掉 UTF-8 BOM 后的哈希：用来区分"内容真不同"和"只差一个 BOM"
function Static-ShaNoBom([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $b = [System.IO.File]::ReadAllBytes($path)
    $start = 0
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $start = 3 }
    $ms = New-Object System.IO.MemoryStream
    $ms.Write($b, $start, $b.Length - $start)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash($ms.ToArray())
    $ms.Dispose(); $sha.Dispose()
    return ([System.BitConverter]::ToString($hash) -replace '-', '')
}

# 会被 install.ps1 拷进 %LOCALAPPDATA%\DesktopPage 的文件：
# 源工程与运行时副本不一致 = 改了半天其实跑的还是旧代码，是这套系统最常见的"幽灵故障"。
$script:StaticRuntimePairs = @(
    'DesktopPage.ahk', 'dsh-agent.ps1', 'agent-watch.ps1', 'ensure-all.ps1', 'ensure-all.vbs',
    'agent-config.ps1', 'start-all.vbs', 'hwmon.ps1', 'wxmon.ps1', 'Build-IconCache.ps1', 'DesktopIcons.ps1',
    'DesktopPositions.ps1', 'dock-add-host.ps1', 'dock-add.ps1', 'wheel-bridge.ps1', 'npix.exe', 'AutoHotkey64.exe'
)

Test-Case STA-001 '静态' '核心文件齐全' high {
    $root = Get-DshRoot
    $need = @(
        'drawer\DesktopPage.ahk', 'drawer\dsh-agent.ps1', 'drawer\agent-watch.ps1',
        'drawer\agent-config.ps1', 'drawer\ensure-all.ps1', 'drawer\ensure-all.vbs', 'drawer\start-all.vbs',
        'drawer\hwmon.ps1', 'drawer\wxmon.ps1', 'drawer\DesktopIcons.ps1',
        'drawer\DesktopPositions.ps1', 'drawer\Build-IconCache.ps1', 'drawer\dock-add-host.ps1',
        'drawer\AutoHotkey64.exe',
        'wallpaper\index.html', 'wallpaper\dsh.js', 'wallpaper\media.js', 'wallpaper\todo.js',
        'wallpaper\hw.js', 'wallpaper\wx.js', 'wallpaper\audit.js', 'wallpaper\audio-host.js',
        'install.ps1', 'uninstall.ps1', 'verify.ps1'
    )
    $miss = @($need | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
    if ($miss.Count -gt 0) { throw ('缺失 ' + $miss.Count + ' 个：' + ($miss -join '、')) }
    ('全部 ' + $need.Count + ' 个核心文件在位')
} -Hint '从备份或 Git 恢复缺失文件；不建议用安装目录副本反推源码'

Test-Case STA-002 '静态' '编码契约' high {
    $root = Get-DshRoot
    $bad = @()

    # .ps1 必须 UTF-8 with BOM：PS 5.1 在 ACP=936 下读无 BOM 的 UTF-8 会按 GBK 解，中文注释会
    # 变成乱码，遇到「；」「，」这类全角字符还可能直接解析失败（历史事故：脚本语法错但看不出）。
    $ps1 = @()
    $ps1 += @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File)
    $ps1 += @(Get-ChildItem -LiteralPath (Join-Path $root 'drawer') -Filter '*.ps1' -File)
    $ps1 += @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.ps1' -File -Recurse)
    foreach ($f in $ps1) {
        if ((Static-EncKind $f.FullName) -ne 'utf8bom') { $bad += ($f.Name + '(PS 缺 BOM)') }
    }

    # .vbs 必须是 UTF-16LE：cscript/wscript 按 ANSI 读无 BOM 的 UTF-8，中文路径会乱码
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'drawer') -Filter '*.vbs' -File)) {
        if ((Static-EncKind $f.FullName) -ne 'utf16le') { $bad += ($f.Name + '(VBS 非 UTF-16LE)') }
    }

    # .ahk 必须 UTF-8 无 BOM：AHK v2 遇到 BOM 会把首行吃掉，常见表现是第一行 global 声明失效
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'drawer') -Filter '*.ahk' -File)) {
        if ((Static-EncKind $f.FullName) -ne 'plain') { $bad += ($f.Name + '(AHK 带了 BOM)') }
    }

    if ($bad.Count -gt 0) { throw (($bad -join '、') + ' —— 共 ' + $ps1.Count + ' 个 ps1 受检') }
    ('ps1×' + $ps1.Count + ' 带 BOM、vbs UTF-16LE、ahk 无 BOM，全部符合')
} -Hint '.ps1 用 UTF-8 with BOM 另存；.vbs 用 UTF-16LE；.ahk 用 UTF-8 无 BOM'

Test-Case STA-003 '静态' '壁纸 JS 语法' high {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if (-not $node) { return @{ Status = 'skip'; Detail = '没找到 node，跳过 JS 语法检查' } }
    $dir = Join-Path (Get-DshRoot) 'wallpaper'
    $bad = @()
    $cnt = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.js' -File)) {
        $cnt++
        $o = & $node.Source --check $f.FullName 2>&1
        if ($LASTEXITCODE -ne 0) {
            $msg = (@($o) | Select-Object -First 2) -join ' '
            $bad += ($f.Name + ' → ' + $msg)
        }
    }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }
    ('node --check 通过 ' + $cnt + ' 个 JS')
} -Hint '语法错会让整个面板白屏；改完先 node --check 再重启 Lively'

Test-Case STA-004 '静态' 'PowerShell 语法' high {
    $root = Get-DshRoot
    $files = @()
    $files += @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File)
    $files += @(Get-ChildItem -LiteralPath (Join-Path $root 'drawer') -Filter '*.ps1' -File)
    $files += @(Get-ChildItem -LiteralPath (Join-Path $root 'tests') -Filter '*.ps1' -File -Recurse)
    $bad = @()
    foreach ($f in $files) {
        $tokens = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
        if ($errs -and $errs.Count -gt 0) {
            $bad += ($f.Name + ' (' + $errs.Count + ' 处：' + $errs[0].Message + ')')
        }
    }
    if ($bad.Count -gt 0) { throw ($bad -join '；') }
    ('Parser::ParseFile 通过 ' + $files.Count + ' 个脚本')
} -Hint '改完 .ps1 必须过 Parser::ParseFile，$errs.Count 为 0 才算写完'

Test-Case STA-005 '静态' '源工程与运行时副本一致' high {
    $root = Get-DshRoot
    $inst = Get-DshInstall
    if (-not (Test-Path -LiteralPath $inst)) { return @{ Status = 'skip'; Detail = '运行时目录不存在（还没安装）' } }
    $diff = @()
    foreach ($n in $script:StaticRuntimePairs) {
        $s = Join-Path (Join-Path $root 'drawer') $n
        $d = Join-Path $inst $n
        if (-not (Test-Path -LiteralPath $s)) { continue }
        if (-not (Test-Path -LiteralPath $d)) { $diff += ($n + '(运行时缺失)'); continue }
        $hs = Static-Sha $s; $hd = Static-Sha $d
        if ($hs -ne $hd) {
            $ls = (Get-Item -LiteralPath $s).Length
            $ld = (Get-Item -LiteralPath $d).Length
            $t = (Get-Item -LiteralPath $s).LastWriteTime.ToString('MM-dd HH:mm')
            # 只差 BOM 的情况单独标出来：扣掉 BOM 后字节一致 → 部署漏了但逻辑没变，
            # 排障优先级低于"代码真不一样"
            if ((Static-ShaNoBom $s) -eq (Static-ShaNoBom $d)) {
                $diff += ("$n(仅 BOM 差异：源码 ${ls}B/$t vs 运行时 ${ld}B)")
            } else {
                $diff += ("$n(内容不同：源码 ${ls}B/$t vs 运行时 ${ld}B)")
            }
        }
    }
    if ($diff.Count -gt 0) {
        throw ('未同步 ' + $diff.Count + ' 个：' + ($diff -join '、') + ' —— 现在跑的是旧代码')
    }
    '运行时副本与源码逐字节一致'
} -Hint '把改动拷到 %LOCALAPPDATA%\DesktopPage 后重启；只改源工程等于没改'

Test-Case STA-006 '静态' '上游不可改文件基线' medium {
    $root = Get-DshRoot
    # 这五个文件是上游产物，改了难恢复：app.js 是压缩代码、两个 css 是上游样式、
    # 两个 exe 是运行时/截图工具。基线首次运行自动生成，之后只比对。
    $locked = @(
        'wallpaper\app.js', 'wallpaper\style.css', 'wallpaper\layout.css',
        'drawer\AutoHotkey64.exe', 'drawer\npix.exe'
    )
    $basePath = Join-Path (Join-Path (Get-DshTestsDir) 'baseline') 'locked-hashes.json'

    $now = [ordered]@{}
    foreach ($rel in $locked) {
        $p = Join-Path $root $rel
        if (Test-Path -LiteralPath $p) { $now[$rel] = Static-Sha $p }
    }

    if (-not (Test-Path -LiteralPath $basePath)) {
        $dir = Split-Path -Parent $basePath
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        ($now | ConvertTo-Json) | Set-Content -LiteralPath $basePath -Encoding UTF8
        return @{ Status = 'skip'; Detail = ('已建立基线 ' + $now.Count + ' 项：' + $basePath) }
    }

    $base = Read-Raw $basePath | ConvertFrom-Json
    $changed = @()
    foreach ($k in $now.Keys) {
        $old = [string]$base.$k
        if ($old -and $old -ne $now[$k]) { $changed += $k }
    }
    if ($changed.Count -gt 0) { throw ('上游文件被改动：' + ($changed -join '、')) }
    ('上游 ' + $now.Count + ' 个文件与基线一致')
} -Hint '要改外观请在 todo.css / index.html 里加规则，别动 app.js 与上游 css'

Test-Case STA-007 '静态' 'app.js 依赖的节点 id 未被删' high {
    $root = Get-DshRoot
    $ids = @('#musicPanel', '#musicStatus', '#consolePanel', '#topResources', '#layoutStatus', '#taskbarStatus')
    $html = Read-Raw (Join-Path $root 'wallpaper\index.html')
    $miss = @()
    foreach ($i in $ids) {
        $bare = $i.TrimStart('#')
        $esc = [regex]::Escape($bare)
        # 单双引号各判一次，避免在单引号字符串里拼引号（PS 的 '' 转义极易写错）
        $hit1 = $html -match ('id\s*=\s*"' + $esc + '"')
        $hit2 = $html -match ("id\s*=\s*'" + $esc + "'")
        if (-not ($hit1 -or $hit2)) { $miss += $i }
    }
    if ($miss.Count -gt 0) { throw ('index.html 里少了 ' + ($miss -join '、') + ' —— app.js 会抛 null 异常，立绘/时钟全挂') }
    'app.js 依赖的 6 个节点 id 都在'
} -Hint '改 index.html 可以动结构，但这 6 个 id 必须保留（app.js 直接 getElementById）'

Test-Case STA-008 '静态' '源码无个人绝对路径' low {
    $root = Get-DshRoot
    $hits = @()
    $files = @()
    $files += @(Get-ChildItem -LiteralPath (Join-Path $root 'drawer') -File | Where-Object { $_.Extension -in @('.ps1', '.ahk', '.vbs') })
    $files += @(Get-ChildItem -LiteralPath (Join-Path $root 'wallpaper') -File | Where-Object { $_.Extension -eq '.js' })
    $files += @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Extension -eq '.ps1' })
    foreach ($f in $files) {
        if ($f.Name -eq 'app.js') { continue }
        $t = Read-Raw $f.FullName
        # C:\Users\Public\Desktop 是系统公共桌面，合法
        $probe = $t -replace '(?i)C:\\\\?Users\\\\?Public', 'PUBLIC'
        if ($probe -match '[A-Za-z]:\\\\?Users\\\\?[A-Za-z0-9._-]+') { $hits += $f.Name }
    }
    if ($hits.Count -gt 0) { throw ('出现个人绝对路径：' + ($hits -join '、') + '（换机器会坏）') }
    ('扫描 ' + $files.Count + ' 个文件，未发现个人绝对路径')
} -Hint '用 $env:LOCALAPPDATA / Resolve-WallpaperDir() 代替写死路径'

Test-Case STA-010 '静态' 'Write-Js 只拼一次 dbg 键' high {
    $p = Join-Path (Get-DshRoot) 'drawer\dsh-agent.ps1'
    $t = Read-Raw $p
    $n = ([regex]::Matches($t, [regex]::Escape("Append(',dbg:')"))).Count
    # 2026-11-14 离线事故：18c57d5 把 reload 那行改成 ',dbg:'，而下一行本来就是 ',dbg:'，
    # 输出 dbg:,dbg:false —— 整条赋值语法错误，__DSH_STATE 未定义，控制台永久「离线」。
    if ($n -ne 1) { throw ("Append(',dbg:') 出现 " + $n + ' 次，必须恰好 1 次') }
    # 顺带守住参数顺序：Write-Js 的形参个数与调用处实参个数必须一致
    $sig = [regex]::Match($t, 'function Write-Js\(([^)]*)\)')
    if (-not $sig.Success) { throw '找不到 Write-Js 定义' }
    $argc = @($sig.Groups[1].Value.Split(',')).Count
    $call = [regex]::Match($t, 'Write-Js\s+(\$ctx[^\r\n]*)')
    if (-not $call.Success) { throw '找不到 Write-Js 调用点' }
    $passed = @($call.Groups[1].Value.Trim().Split(' ')).Count
    if ($argc -ne $passed) { throw ('Write-Js 形参 ' + $argc + ' 个，调用传了 ' + $passed + ' 个') }
    ('dbg 键 1 处；Write-Js 形参/实参一致（' + $argc + ' 个）')
} -Hint 'JSONP 响应里任何重复键/空值都会让整条赋值语法错误；改签名必须同步改调用点'

Test-Case STA-011 '静态' '图标缓存先编译后落盘' high {
    $t = Read-Raw (Join-Path (Get-DshRoot) 'drawer\Build-IconCache.ps1')
    $addType = $t.IndexOf('Add-Type -ReferencedAssemblies')
    $firstDel = $t.IndexOf('Remove-Item $iconDir')
    $stage = $t.IndexOf('icons.new-')
    # 00:25 事故：脚本先 Remove-Item icons\ 再 Add-Type；Low IL 下 Add-Type 失败 → 图标永久空。
    # 契约：编译必须在任何删除之前；全量模式必须走暂存目录 + 原子换入。
    if ($addType -lt 0) { throw '找不到 Add-Type' }
    if ($firstDel -ge 0 -and $firstDel -lt $addType) { throw 'Add-Type 之前就删了 icons\（失败即永久空目录）' }
    if ($stage -lt 0) { throw '全量模式没有暂存目录（icons.new-<pid>）' }
    if ($t -notmatch 'Move-Item -LiteralPath \$iconDir -Destination \$bak') { throw '没有「旧 icons 改名备份」这一步，换入失败无法回滚' }
    '编译先行 + 暂存换入 + 失败回滚 三步齐全'
} -Hint '重扫在 Low IL 抽屉里必失败；脚本必须幂等失败，绝不能毁掉现有图标'
Test-Case STA-012 '静态' '重命名框必须压在覆盖层上面' high {
    $t = Read-Raw (Join-Path (Get-DshRoot) 'drawer\DesktopPage.ahk')
    $m = [regex]::Match($t, '(?s)RenameFolder\(f\)\s*\{(.*?)\r?\n\}')
    if (-not $m.Success) { throw '找不到 RenameFolder 函数体' }
    $b = $m.Groups[1].Value
    # 2026-11-14 用户反馈「建了文件夹之后不能重命名」：重命名框和文件夹弹窗共用 gFolderGui，
    # 覆盖层 gOverlay 是全屏 TOPMOST 点击层，不撤掉/不抬 z 序就会被压住，点了像没反应。
    if ($b -notmatch 'HideOverlay\(\)') { throw 'RenameFolder 没有先撤掉覆盖层（重命名框会被全屏点击层压住）' }
    $iShow = $b.IndexOf('.Show(')
    $iTop = $b.IndexOf('SetWindowPos')
    if ($iShow -lt 0) { throw 'RenameFolder 没有 Show 对话框' }
    if ($iTop -lt 0 -or $iTop -lt $iShow) { throw 'Show 之后没有把重命名框抬到 TOPMOST 顶端' }
    if ($b -notmatch 'HideOverlay\(\)[\s\S]*\.Show\(') { throw '先 HideOverlay 再 Show 的顺序被调换了' }
    '覆盖层先撤、对话框后抬顶'
} -Hint '重命名框点击无效的根因：全屏 TOPMOST 覆盖层在看守点击'

Test-Case STA-013 '静态' '重命名收尾要把覆盖层补回来' medium {
    $t = Read-Raw (Join-Path (Get-DshRoot) 'drawer\DesktopPage.ahk')
    if ($t -notmatch 'AfterRenameDialog\(\)') { throw '没有 AfterRenameDialog（确定/取消都要补覆盖层）' }
    foreach ($fn in 'ApplyRename', 'CloseRename') {
        $m = [regex]::Match($t, "(?s)$fn\([^)]*\)\s*\{(.*?)\r?\n\}")
        if (-not $m.Success) { throw "找不到 $fn 函数体" }
        if ($m.Groups[1].Value -notmatch 'AfterRenameDialog\(\)') { throw "$fn 结束时没有调用 AfterRenameDialog" }
    }
    # 文件夹弹窗身份不匹配时，FolderPopupWatch 不能把重命名框当"已关闭"来收尾
    $w = [regex]::Match($t, '(?s)FolderPopupWatch\(\)\s*\{(.*?)\r?\n\}')
    if (-not $w.Success) { throw '找不到 FolderPopupWatch' }
    # 已销毁的 Gui 不能直接摸 .Hwnd（会抛 `Gui has no window` 并让计时器永远收不了尾）
    if ($w.Groups[1].Value -notmatch 'try vis := DllCall\("IsWindowVisible"') { throw 'FolderPopupWatch 读 .Hwnd 没有 try 保护（BindOpen 销毁弹窗后会每 300ms 抛错）' }
    if ($w.Groups[1].Value -notmatch 'ObjPtr\(FOLDER_POPUP\) = ObjPtr\(gFolderGui\)') { throw 'FolderPopupWatch 没有按对象身份区分文件夹弹窗与重命名框' }
    if ($w.Groups[1].Value -notmatch 'if \(!isPopup and vis\)') { throw 'FolderPopupWatch 没有把可见的重命名框排除在外（会误判关闭并重新盖上覆盖层）' }
    '确定/取消都恢复覆盖层，监视计时器不误杀重命名框'
} -Hint '2026-11-14：重命名框借 gFolderGui 名字，监视器身份判断必须容它'
Test-Case STA-014 '静态' '点击层收尾后仍在最顶、无配对的鼠标抬起不收起抽屉' medium {
    $t = Read-Raw (Join-Path (Get-DshRoot) 'drawer\DesktopPage.ahk')

    # 1) RestoreOverlayForDrawer 必须和 ShowDrawer 一样：最后再把覆盖层抬回最顶。
    #    点击由覆盖层接收（抽屉只是画出来的），覆盖层被压在抽屉下面就"看得见、点不动"。
    $r = [regex]::Match($t, '(?s)RestoreOverlayForDrawer\(\)\s*\{(.*?)\r?\n\}')
    if (-not $r.Success) { throw '找不到 RestoreOverlayForDrawer' }
    $body = $r.Groups[1].Value
    $iDrawer = $body.IndexOf('gDrawer.Hwnd')
    $iLast = $body.LastIndexOf('EnsureOverlay()')
    if ($iDrawer -lt 0 -or $iLast -lt 0 -or $iLast -lt $iDrawer) { throw 'RestoreOverlayForDrawer 末尾没有把覆盖层抬回最顶（重命名后点不动）' }

    # 2) OnOverUp 必须先确认本次抬起有配对的 DOWN，否则重命名框关掉时飘过来的 UP 会收起抽屉。
    $u = [regex]::Match($t, '(?s)OnOverUp\(wParam, lParam, msg, hwnd\)\s*\{(.*?)\r?\n\}')
    if (-not $u.Success) { throw '找不到 OnOverUp' }
    $up = $u.Groups[1].Value
    $iGuard = $up.IndexOf('!OVER_DOWN')
    $iHide = $up.IndexOf('HideDrawer()')
    if ($iGuard -lt 0) { throw 'OnOverUp 没有 OVER_DOWN 配对检查（改完名字抽屉会自己关）' }
    if ($iHide -ge 0 -and $iHide -lt $iGuard) { throw 'OnOverUp 在配对检查之前就 HideDrawer()' }
    '覆盖层收尾抬回最顶；无配对的抬起被忽略'
} -Hint '2026-11-14：重命名一个之后要退出抽屉再进来才能改下一个的两条根因'

Test-Case STA-015 '静态' '天气城市按 IP 定时重解析（多家兜底 + 磁盘缓存）' medium {
    $t = Read-Raw (Join-Path (Get-DshRoot) 'drawer\wxmon.ps1')

    # 1) 不许再回到"启动只解析一次"：那就是换城市后永远显示旧城市的原因
    if ($t -match '位置只解析一次') { throw 'wxmon 又写成"位置只解析一次"了（换城市/挂代理后城市不会更新）' }

    # 2) 多家服务按顺序兜底：单家被墙/改接口/403 时不能整块退化成北京
    if ($t -notmatch 'function Resolve-IpLoc') { throw '找不到 Resolve-IpLoc' }
    foreach ($h in @('ipwho.is', 'ipinfo.io', 'ip-api.com')) {
        if ($t -notmatch [regex]::Escape($h)) { throw "Resolve-IpLoc 缺少兜底服务 $h" }
    }

    # 3) 主循环里必须按 TTL 重解析（不是只在进程启动时算一次）
    $w = [regex]::Match($t, '(?s)while \(\$true\)\s*\{(.*?)\r?\n\}')
    if (-not $w.Success) { throw '找不到主循环' }
    $body = $w.Groups[1].Value
    if ($body -notmatch 'Resolve-IpLoc') { throw '主循环里没有重解析位置（城市只在启动时算一次）' }
    if ($body -notmatch 'LOC_TTL') { throw '主循环里没有 TTL 判据' }
    if ($body -notmatch 'Get-WeatherUrl') { throw '位置变了但天气 URL 没重建' }

    # 4) 结果要落盘：解析服务偶发失败时用上次结果，而不是退回北京
    foreach ($k in @('wx-loc.json', 'function Save-Loc', 'function Load-Loc')) {
        if ($t -notmatch [regex]::Escape($k)) { throw "缺少位置缓存：$k" }
    }
    if ($t -notmatch '\$DEFAULT_LOC') { throw '缺少兜底默认位置定义' }
    '多家兜底 + TTL 重解析 + wx-loc.json 缓存'
} -Hint '2026-11-14：天气一直显示北京（进程启动时解析一次，之后永不更新）'
Test-Case STA-009 '静态' '壁纸文件与 Lively 运行目录一致' high {
    $root = Get-DshRoot
    $wall = Get-DshWall
    if (-not $wall -or -not (Test-Path -LiteralPath $wall)) {
        return @{ Status = 'skip'; Detail = '没解析到 Lively 壁纸目录（还没装/没应用）' }
    }
    # 生成物与 Lively 自己的元数据不参与比对：它们本来就该由采样/Lively 改写
    $skip = @(
        'hw-data.js', 'wx-data.js', 'todo-data.js',
        'LivelyInfo.json', 'project.json', 'integrity.json',
        'preview.gif', 'lively_p.gif', 'lively_t.png'
    )
    $diff = @()
    foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $root 'wallpaper') -File)) {
        if ($f.Extension -eq '.bak' -or $f.Name -match '\.bak') { continue }
        if ($skip -contains $f.Name) { continue }
        $d = Join-Path $wall $f.Name
        if (-not (Test-Path -LiteralPath $d)) { $diff += ($f.Name + '(运行时缺失)'); continue }
        if ((Static-Sha $f.FullName) -ne (Static-Sha $d)) {
            $diff += ($f.Name + '(内容不同 ' + $f.Length + 'B/' + (Get-Item -LiteralPath $d).Length + 'B)')
        }
    }
    if ($diff.Count -gt 0) {
        throw ('壁纸未同步 ' + $diff.Count + ' 个：' + ($diff -join '、') + ' —— 屏幕上跑的还是旧页面')
    }
    ('壁纸 ' + (@(Get-ChildItem -LiteralPath (Join-Path $root 'wallpaper') -File).Count) + ' 个文件与运行时一致')
} -Hint '壁纸改了要拷到 Lively 库那份（路径见 WallpaperLayout.json 的 LivelyInfoPath），再重启 Lively'
