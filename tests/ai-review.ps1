<#
.SYNOPSIS
    Nightly-Check.ps1 的 AI 点评小工：读提示词文件 -> dsh headless（走 stdin）-> 写结果文件。
.NOTES
    为什么要单独起进程、为什么必须走 stdin：
    1) 在 Start-Job 里调 dsh.cmd 会卡住（实测 >180s 不返回），Start-Process 正常；
    2) cmd.exe 传参上限约 8191 字符且会把换行拆成多个参数，长提示词（内联 diff）会丢内容，
       表现为模型回「未收到 diff」。headless 支持 `-` 从 stdin 读任务，配合
       Start-Process -RedirectStandardInput 传文件，多行 + 中文都安全。
#>
param(
    [Parameter(Mandatory=$true)][string]$PromptFile,
    [Parameter(Mandatory=$true)][string]$OutFile
)
$ErrorActionPreference = 'Continue'

function Write-Result([string]$text) {
    [System.IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($false)))
}

$dshRoot = 'E:\DSH'
$binJs = Join-Path $dshRoot 'node_modules\@deepseek-ai\dsh\lib\bin.js'
$node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if (-not $node) { foreach ($c in @('E:\Nodejs\node.exe', "$env:ProgramFiles\nodejs\node.exe")) { if (Test-Path $c) { $node = $c; break } } }
if (-not (Test-Path $PromptFile)) { Write-Result ''; exit 3 }

$tmpOut = [System.IO.Path]::GetTempFileName()
$tmpErr = [System.IO.Path]::GetTempFileName()
try {
    if ($node -and (Test-Path $binJs)) {
        $env:DSH_ROOT = $dshRoot
        if (-not $env:DSH_HOME) { $env:DSH_HOME = Join-Path $dshRoot '.dsh' }
        # 不能用 Start-Process -RedirectStandardInput/-Output：本机 PS 5.1 的重定向分支抛
        # 「已添加项。字典中的关键字:“path”所添加的关键字:“Path”」（单独一行
        # Start-Process -FilePath cmd -RedirectStandardOutput 就能复现，与本脚本无关），
        # 结果是这个「AI 点评」小工一直静默退 5、输出 0 字节 —— 巡检报告里那一栏永远是空的。
        # 改用 ProcessStartInfo：stdin 写 UTF-8 字节，stdout/stderr 异步读，既不吃 8191 参数字符上限，
        # 也不会因为缓冲区写满而互锁。
        $promptText = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $node
        $psi.Arguments = ('"' + $binJs + '" --profile headless -')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $proc = [System.Diagnostics.Process]::Start($psi)
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($promptText)
            $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
            $proc.StandardInput.BaseStream.Flush()
            $proc.StandardInput.Close()
        } catch { }
        $done = $proc.WaitForExit(600000)
        if (-not $done) { try { $proc.Kill() } catch { }; Write-Result ''; exit 4 }
        $text = ''
        try { $text = [string]$outTask.Result } catch { }
        $errText = ''
        try { $errText = [string]$errTask.Result } catch { }
        if (-not $text -and $errText) {
            # 把 stderr 收进临时文件，排障时有东西可看（正文仍为空）。
            try { [System.IO.File]::WriteAllText($tmpErr, $errText, (New-Object System.Text.UTF8Encoding($false))) } catch { }
        }
    } else {
        # 兜底：走 dsh.cmd 的 stdin 模式
        $text = (Get-Content $PromptFile -Raw -Encoding UTF8 | & (Join-Path $dshRoot 'dsh.cmd') headless - 2>$null | Out-String)
    }
    $text = (($text -split "\r?\n") | Where-Object { $_ -and $_ -notmatch '^\s*dsh: ' -and $_ -notmatch '^\s*(thinking|reasoning)\b' }) -join "`n"
    Write-Result $text.Trim()
    exit 0
} catch {
    Write-Result ''
    exit 5
} finally {
    foreach ($x in @($tmpOut, $tmpErr)) { if (Test-Path $x) { Remove-Item $x -Force -ErrorAction SilentlyContinue } }
}