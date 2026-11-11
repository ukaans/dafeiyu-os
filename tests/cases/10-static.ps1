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
    'DesktopPositions.ps1', 'dock-add-host.ps1', 'dock-add.ps1', 'npix.exe', 'AutoHotkey64.exe'
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
