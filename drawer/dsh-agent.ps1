param(
    [int]$Port = 17433
)
$ErrorActionPreference = 'SilentlyContinue'

# =============================================================================
#  dsh-agent.ps1 — 桌面系统本地代理
#  监听 http://127.0.0.1:17433 ，给壁纸页（file://）提供数据与动作接口。
#  页面不能 fetch（Chromium 私有网络策略），所以接口分两类：
#    · *.js  → 返回 window.__XXX=... 的一段脚本，页面用 <script src> 加载
#    · *.gif → 返回 1x1 透明 GIF 作为信标，页面用 <img src> 触发动作
#  路由表：
#    /state.js | /state ← window.__DSH_STATE {web,busy,bal,drawer,lines[],sig,err,reload,dbg}
#    /log.js            ← window.__DSH_LOG（整段 dsh-run.log，供页面渲染会话气泡）
#    /run.gif?t=        ← 让 DSH 跑一条指令（headless；stdout→dsh-run.log，stderr→dsh-run.err.log）
#    /launch.gif        ← DSH 没在跑时启动它
#    /open.gif          ← 用浏览器打开 DSH 网页
#    /clear.gif         ← 清空 dsh-run.log + dsh-run.err.log
#    /drawer.gif        ← 通过计划任务启动桌面抽屉（DesktopPage.ahk）
#    /rect.gif?x&y&w&h  ← 壁纸右侧控制台的屏幕矩形（万分比）→ panel-rect.txt
#    /scroll.gif?d=±1   ← 滚轮意图 → scroll.dat；/scroll.js ← 取走增量（并放行热重载令牌）
#    /reload.gif        ← 写 page-reload.txt：让壁纸页软重载（重插 dsh.js?hot=，不导航）
#    /dbg.gif?m=        ← 壁纸页调试信标 → dsh-debug.log（仅 dsh-debug.flag 存在时落盘）
#    /todo.gif?op=&t=   ← 待办增删改 → todo.txt + todo-data.js
#    /dock.js | /dock.gif?op=del&i= | /adddock.gif | /launchpath.gif?t= | /icon/<file>
#    /media.js | /media.gif?op=toggle|back|fwd  ← 当前播放（GSMTC 优先 + 网易云兜底）
#    /audit.gif?e=&k=   ← 壁纸侧统一审计信标（写进 audit.log，标签 [WEB ]）
# =============================================================================

# ===== 路径配置（换电脑时改这里，或用同名环境变量覆盖）=====
# DSH_ROOT        DSH 安装根目录（内含 dsh.cmd）
# DSH_WALLPAPER   Lively 壁纸目录（内含 index.html / todo-data.js）
$root = if ($env:DSH_ROOT) { $env:DSH_ROOT } else { 'E:\DSH' }
$dshCmd = Join-Path $root 'dsh.cmd'
$appDir = Join-Path $env:LOCALAPPDATA 'DesktopPage'
$logFile = Join-Path $appDir 'dsh-run.log'
# 2026-11-05：reasoning 走 stderr、最终回答走 stdout（dsh-headless 的契约），
# 所以把两股流分开落盘：面板只读 dsh-run.log（干净的「指令 + 回答」），
# 报错/思考过程进 dsh-run.err.log（同样 256KB 轮转，不再污染会话视图）。
$errFile = Join-Path $appDir 'dsh-run.err.log'
$dbgFile = Join-Path $appDir 'dsh-debug.log'
$dbgFlag = Join-Path $appDir 'dsh-debug.flag'
$reloadFile = Join-Path $appDir 'page-reload.txt'
$pidFile = Join-Path $appDir 'dsh-run.pid'
# 心跳文件：主循环每轮刷新一次时间戳。抽屉/start-all 用它区分
# 「进程还在但已经卡死」和「真的在服务」——只查 pid 会被假活骗过。
$hbFile = Join-Path $appDir 'dsh-agent.hb'
$tokenFile = Join-Path $root '.dsh\web-url.txt'
$envFile = Join-Path $root '.dsh\.env'
$wallDir = $env:DSH_WALLPAPER
if (-not $wallDir) {
    # ① 权威来源：Lively 的 WallpaperLayout.json 记着「当前正应用」的那份壁纸目录。
    #    机器上可能同时存在多份副本（旧 ID 目录 + 安装脚本新建的目录），只按"最新修改"
    #    猜会把 todo-data.js 写到没在显示的那份里。
    try {
        $lay = Join-Path $env:LOCALAPPDATA 'Lively Wallpaper\WallpaperLayout.json'
        if (Test-Path $lay) {
            $j = [System.IO.File]::ReadAllText($lay, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($it in @($j)) {
                $p = [string]$it.LivelyInfoPath
                if ($p -and (Test-Path (Join-Path $p 'dsh.js'))) { $wallDir = $p; break }
            }
        }
    } catch { }
}
if (-not $wallDir) {
    # ② 退路：Lively 库里带 dsh.js 的那份壁纸（取最新修改的一份）
    try {
        $base = Join-Path $env:LOCALAPPDATA 'Lively Wallpaper\Library\wallpapers'
        $hit = Get-ChildItem $base -Directory -ErrorAction Stop |
            Where-Object { Test-Path (Join-Path $_.FullName 'dsh.js') } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { $wallDir = $hit.FullName }
    } catch { }
}

$mtx = New-Object System.Threading.Mutex($false, 'Global\DesktopPage_dshagent')
if (-not $mtx.WaitOne(0)) { exit 0 }
try { [System.IO.File]::WriteAllText((Join-Path $appDir 'dsh-agent.pid'), "$PID") } catch { }

# ===== 日志 =====
# 之前这个脚本失败是"静默退出"（catch { exit 1 }），控制台只显示"本地代理没有响应"，
# 没有任何线索。现在所有关键节点都写 dsh-agent.log，超过 256KB 自动清空。
$agentLog = Join-Path $appDir 'dsh-agent.log'
function Agent-Log([string]$msg) {
    try {
        if ((Test-Path $agentLog) -and ((Get-Item $agentLog -ErrorAction SilentlyContinue).Length -gt 262144)) {
            [System.IO.File]::WriteAllText($agentLog, '')
        }
        [System.IO.File]::AppendAllText($agentLog, ('{0}  {1}{2}' -f (Get-Date -Format 'MM-dd HH:mm:ss'), $msg, [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}
trap { Agent-Log ('FATAL: ' + $_.Exception.Message + ' @line ' + $_.InvocationInfo.ScriptLineNumber); exit 1 }
Agent-Log "agent: start pid=$PID port=$Port root=$root"

# ===== 统一审计日志 =====
# 三端（AHK / 本代理 / 壁纸页）写同一份 %LOCALAPPDATA%\DesktopPage\audit.log，
# 靠行内标签 [API ] / [AHK ] / [WEB ] 区分。旁路：任何失败都不影响请求处理。
# 硬约束：
#   1) 单线程代理，单次调用目标 <1ms —— 只做一次 AppendAllText，不查目录、不算哈希；
#   2) 每个请求最多写一行，且在"请求结束时"写（含耗时）；
#   3) 高频只读接口（/state.js /scroll.js /dock.js /media.js /rect.gif）一律不写，
#      否则 80ms~1.5s 一条会把 2MB 的审计文件撑爆并拖慢单线程；
#   4) 轮转只保留一份历史：>2MB 用 Move-Item -Force 改名 audit.log.1（不用 Remove-Item）。
#      轮转是「改名 + 截空」两步，**改名成功才许截空**：改名失败（AHK 正在追加、.1 被人
#      打开着、杀软在扫）时截空等于把 2MB 历史和它唯一的备份一起抹掉，而日志上什么都没有。
$auditFile = Join-Path $appDir 'audit.log'
$script:auditEnc = New-Object System.Text.UTF8Encoding($false)
$script:auditBytes = 0
$script:auditWrites = 0                     # 写入计数：每 32 条与真实文件尺寸对齐一次（三端共写，本地累加值只会偏小）
$script:auditRotSkipAt = [long]0            # 轮转失败日志的限流时间戳（60 秒一条，别在动作型请求里刷屏）
try { if (Test-Path $auditFile) { $script:auditBytes = (Get-Item $auditFile -ErrorAction SilentlyContinue).Length } } catch { }
# 动作类路由白名单（哪些路由每请求写一行审计）现在挂在路由表里：
# 见下方 $script:ROUTES 的 audit 字段。以前这里有一份 $script:auditRoutes 数组，
# 和主循环的分支各写一遍同样的路由名，加接口时容易漏改一处 —— 已合并进表。

function Write-Audit([string]$action, [string]$detail = '', [string]$tag = 'API') {
    try {
        # [datetime]::Now 比 Get-Date 快一个量级（cmdlet 开销 ~0.3ms），单线程代理里这点很值钱
        $line = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff') + ' [' + $tag.PadRight(4) + '] ' + $action
        if ($detail) { $line += ' ' + $detail }
        $line += "`n"
        [System.IO.File]::AppendAllText($auditFile, $line, $script:auditEnc)
        $script:auditBytes += $script:auditEnc.GetByteCount($line)
        $script:auditWrites++
        # 三端（AHK / 本代理 / 壁纸页）共写同一个 audit.log，本地累加值永远只会**偏小**
        # （别人写进去的字节它看不见）。AHK 侧每 32 条 FileGetSize 对齐一次（DesktopPage.ahk 的 AuditLog），
        # 代理侧原来从启动起只累加自己的字节、从不复查 —— 判据于是与真实尺寸脱钩：
        #   · 偏小时：自己这辈子都到不了 2MB，轮转形同虚设；
        #   · 偏大时：别人刚轮转完（文件归 0）它还以为快满，于是「提前轮转」一个很小的文件，
        #     把上一份真正的 2MB 历史（audit.log.1）覆盖掉。
        # 这里补上与 AHK 同频的对齐（每 32 条一次真实尺寸，单次 FileInfo.Length ≈ 0.05ms，
        # 且只落在动作型请求上，不在 /state.js 那种高频轮询里）。
        if (($script:auditWrites % 32) -eq 0) {
            try { $script:auditBytes = (New-Object System.IO.FileInfo($auditFile)).Length } catch { }
        }
        if ($script:auditBytes -gt 2097152) {
            # 轮转是两步：①改名成 .1 ②建一个空文件。老写法是
            #   Move-Item … -ErrorAction SilentlyContinue   ← 失败不抛、不记、不管
            #   WriteAllText($auditFile, '')                ← 照样执行
            # 于是第一步失败（AHK 正持有句柄追加 / 有人把 audit.log.1 开着看 / 杀软扫描）
            # 时第二步把整份 2MB 历史当场抹成 0 字节，而 .1 里还是上一代的内容 ——
            # 恰好在"刚出过事、最需要这份日志"的时刻丢证据，且三处日志（dsh-agent.log /
            # audit.log / verify）都不会记录这次失败。改成「改名成功才许截空」：
            # 没轮转成就原样留着，把计数器拉回真实尺寸，下一次写入再试（失败日志 60 秒限流）。
            $rotBak = $auditFile + '.1'
            $moved = $false
            try {
                Move-Item -LiteralPath $auditFile -Destination $rotBak -Force -ErrorAction Stop
                $moved = -not (Test-Path -LiteralPath $auditFile)
            } catch { $moved = $false }
            if ($moved) {
                # 立刻建一个空文件：「存在但为空」比「不存在」好判断（verify.ps1 / 人肉排查都靠它）
                try { [System.IO.File]::WriteAllText($auditFile, '', $script:auditEnc) } catch { }
                $script:auditBytes = 0
            } else {
                try { $script:auditBytes = (New-Object System.IO.FileInfo($auditFile)).Length } catch { $script:auditBytes = 0 }
                try {
                    $n64 = [long]$script:clock.ElapsedMilliseconds
                    # 0 = 还没记过（第一轮必须留下证据，否则又变回"静默失败"）；之后 60 秒一条
                    if (($script:auditRotSkipAt -eq 0) -or (($n64 - $script:auditRotSkipAt) -gt 60000)) {
                        $script:auditRotSkipAt = $n64
                        Agent-Log ('audit: rotate skipped (rename failed), size=' + $script:auditBytes)
                    }
                } catch { }
            }
        }
    } catch { }
}

# 审计字段值：含空格 / 中文路径一律加双引号；内部双引号换单引号、换行压成空格
# （一行一条是 grep 的前提，URL 里塞换行就能伪造假日志行，必须在这里掐死）
function Quote-Audit([string]$v) {
    if ($null -eq $v) { return '""' }
    $s = ($v -replace '"', "'") -replace '[\r\n\t]', ' '
    return '"' + $s + '"'
}

# 路由分类（审计行里的 route= 字段）不再用 if 链判断，见 $script:ROUTES 的 kind 字段。

# 1x1 透明 GIF：作为跨域“信标”响应，壁纸页面用 <img> 触发即可，不受 CORS / 私有网络策略影响
$gif = [byte[]](0x47,0x49,0x46,0x38,0x39,0x61,0x01,0x00,0x01,0x00,0x80,0x00,0x00,0x00,0x00,0x00,
                0xFF,0xFF,0xFF,0x21,0xF9,0x04,0x01,0x00,0x00,0x00,0x00,0x2C,0x00,0x00,0x00,0x00,
                0x01,0x00,0x01,0x00,0x00,0x02,0x02,0x44,0x01,0x00,0x3B)

function Get-WebUrl {
    try {
        $u = ([System.IO.File]::ReadAllText($tokenFile)).Trim()
        if ($u) { return $u }
    } catch { }
    return 'http://127.0.0.1:3080/'
}

function Test-PortOpen([int]$p, [int]$ms = 120) {
    # 比 HTTP 探测可靠的"有没有人在监听"判断：连上就算开
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $r = $c.BeginConnect('127.0.0.1', $p, $null, $null)
        $ok = $r.AsyncWaitHandle.WaitOne($ms)
        $c.Close()
        return $ok
    } catch { return $false }
}

function Test-WebUp {
    # 端口探测代替 HTTP 探测：380ms 的 HTTP 超时会把"其实活着"判成"没起来"，
    # 那会误导 /launch.gif 去重启（dsh.cmd quiet 会先杀掉当前实例）。连上就算活。
    $ports = @()
    try {
        $u = ([System.IO.File]::ReadAllText($tokenFile)).Trim()
        if ($u -match ':(\d{2,5})') { $ports += [int]$matches[1] }
    } catch { }
    foreach ($p in (3080..3085)) { if ($ports -notcontains $p) { $ports += $p } }
    foreach ($p in $ports) { if (Test-PortOpen $p 120) { return $true } }
    return $false
}

function Get-RunBusy {
    if (-not (Test-Path $pidFile)) { return $false }
    $raw = ''
    try { $raw = ([System.IO.File]::ReadAllText($pidFile)).Trim() } catch { return $false }
    # 格式：<pid>|<yyyy-MM-dd HH:mm:ss>。只认 pid 会被系统复用（比如复用成 OpenConsole.exe），
    # 导致控制台永远显示"运行中"，所以必须校验启动时间。
    $parts = $raw.Split('|')
    $procId = 0
    [void][int]::TryParse($parts[0], [ref]$procId)
    if ($procId -le 0) { return $false }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    if ($parts.Length -lt 2 -or -not $parts[1]) {
        # 老格式（只有 pid）无法校验身份，直接当脏数据清掉，否则会被系统复用的 pid 永久误导
        try { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue } catch { }
        return $false
    }
    try { if ($proc.StartTime.ToString('yyyy-MM-dd HH:mm:ss') -ne $parts[1]) { return $false } } catch { return $false }
    return $true
}

# 读共享日志：写方是 cmd 的 >> 重定向，整条命令跑完前句柄不释放。
# 老实现用 [IO.File]::ReadAllLines，Windows 上会直接抛 IOException，被 catch 吞掉后
# 面板只剩「（还没有输出）」—— 这就是「日志不更新」的老坑。必须 FileShare.ReadWrite|Delete。
function Read-TextShared([string]$path) {
    if (-not (Test-Path $path)) { return '' }
    $fs = $null
    $sr = $null
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        return $sr.ReadToEnd()
    } catch { return '' }
    finally {
        if ($sr) { try { $sr.Dispose() } catch { } }
        if ($fs) { try { $fs.Dispose() } catch { } }
    }
}

function Get-LogTail([int]$n) {
    $txt = Read-TextShared $logFile
    if (-not $txt) { return @() }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($ln in ($txt -split "`r?`n")) { $out.Add($ln) }
    while ($out.Count -gt 0 -and $out[$out.Count - 1] -eq '') { $out.RemoveAt($out.Count - 1) }
    if ($out.Count -eq 0) { return @() }
    if ($out.Count -le $n) { return $out.ToArray() }
    return $out.GetRange($out.Count - $n, $n).ToArray()
}

# 会话视图用：整段日志（有上限，避免一条 /log.js 把单线程代理拖住）
function Get-LogText([int]$maxChars) {
    $txt = Read-TextShared $logFile
    if (-not $txt) { return '' }
    if ($txt.Length -le $maxChars) { return $txt }
    $cut = $txt.Length - $maxChars
    # 从半行处切开会把一行的中文截成乱码，往下找第一个换行，从下一行开始
    $nl = $txt.IndexOf("`n", $cut)
    if ($nl -ge 0) { return $txt.Substring($nl + 1) }
    return $txt.Substring($cut)
}

# 日志身份：长度 + mtime。页面拿它判断「要不要再拉一次 /log.js」，比传全文便宜得多。
function Get-LogSig {
    try {
        $fi = Get-Item -LiteralPath $logFile -ErrorAction SilentlyContinue
        if ($fi) { return ([string]$fi.Length + '-' + [string]$fi.LastWriteTimeUtc.Ticks) }
    } catch { }
    return ''
}

# 最近一次失败原因：只挑 dsh 的 "dsh: <code>: <msg>"（reasoning 段不算）+ 崩溃行
function Get-ErrText {
    $txt = Read-TextShared $errFile
    if (-not $txt) { return '' }
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($ln in ($txt -split "`r?`n")) {
        # 只收"有内容"的错误行：裸的 "dsh: reasoning:" 是流式推理的开头标记，不是错误（2026-11-05 面板上一直挂它）
        if ($ln -match '^(dsh:(?!\s*reasoning:)\s*\S|FATAL:|Unhandled)') { $hits.Add($ln.Trim()) }
    }
    if ($hits.Count -eq 0) { return '' }
    $take = [Math]::Min(2, $hits.Count)
    $out = ($hits.GetRange($hits.Count - $take, $take) -join ' · ')
    if ($out.Length -gt 220) { $out = $out.Substring($out.Length - 220) }
    return $out
}

# 热重载令牌（/reload.gif 写入）。0 = 无令牌。
function Get-ReloadToken {
    try {
        if (Test-Path $reloadFile) {
            $v = [long]0
            if ([long]::TryParse(([System.IO.File]::ReadAllText($reloadFile)).Trim(), [ref]$v)) { return $v }
        }
    } catch { }
    return [long]0
}

function Escape-Js([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '\\', '\\' -replace '"', '\"' -replace "`r", '' -replace "`n", '\n' -replace '</', '<\/')
}

# ===== 进程级分层缓存 =====
# 代理是单线程 HttpListener 循环：一个请求慢，后面所有请求排队。之前 /state.js 每次
# 都现算（读日志尾巴 + 打 3080 端口 + 查 pid + 查余额），实测 800-1375ms，页面 2.5s
# 看门狗不触发，但排队会把 /scroll.js 一起拖死 —— 用户看到的就是"连接失败 + 翻不动"。
# 这里按项缓存，每次请求只重算过期的那几项。TTL 表：
#   lines 500ms / web 3000ms / busy 1000ms / drawer 2000ms / bal 300000ms / media 1000ms
$script:stateCache = @{}
$script:stateCacheAt = @{}
$script:missKeys = @()                      # 本次请求重算了哪些项（空 = 全部命中）
# 单调时钟：Windows PowerShell 5.1 跑在 .NET Framework 4.8，[Environment]::TickCount64 是
# .NET Core 才有的属性，在这里取到 $null —— 于是 $age 恒为 0、缓存永不失效，/state.js 的
# lines/sig/log 全被冻在第一次算出来的值上（2026-11-05 实测：日志涨了 sig 还是 89 字节）。
# 用 Stopwatch 自己维护毫秒时钟，别再碰 Environment.TickCount64。
$script:clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:stateLogAt = [long]$script:clock.ElapsedMilliseconds - 20000

function Cache-Get([string]$key, [int]$ttlMs, [scriptblock]$producer, $fallback = $null) {
    $now = [long]$script:clock.ElapsedMilliseconds
    $had = $script:stateCache.ContainsKey($key)
    if ($had) {
        $age = $now - [long]$script:stateCacheAt[$key]
        if ($age -ge 0 -and $age -lt $ttlMs) { return $script:stateCache[$key] }
    }
    # 任何一项失败都不能让整条 /state.js 抛异常（抛了就只剩半个响应，页面直接判离线）
    $v = $fallback
    try { $v = & $producer }
    catch { if ($had) { $v = $script:stateCache[$key] } else { $v = $fallback } }
    $script:stateCache[$key] = $v
    $script:stateCacheAt[$key] = $now
    $script:missKeys += $key
    return $v
}

function Cache-Drop([string]$key) {
    try { [void]$script:stateCache.Remove($key); [void]$script:stateCacheAt.Remove($key) } catch { }
}

function Write-Raw($ctx, [byte[]]$bytes, [string]$type) {
    $res = $ctx.Response
    $res.StatusCode = 200
    if ($type -eq 'application/javascript') { $type = 'application/javascript; charset=utf-8' }
    $res.ContentType = $type
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Cache-Control', 'no-store')
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}

function Write-Js($ctx, $web, $busy, $lines, $bal, $drawer, $scroll, $sig, $err, $reload, $dbg) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('window.__DSH_STATE = {web:')
    [void]$sb.Append($(if ($web) { 'true' } else { 'false' }))
    [void]$sb.Append(',scroll:').Append([int]$scroll)
    [void]$sb.Append(',busy:')
    [void]$sb.Append($(if ($busy) { 'true' } else { 'false' }))
    [void]$sb.Append(',bal:"').Append((Escape-Js $bal)).Append('",drawer:')
    [void]$sb.Append($(if ($drawer) { 'true' } else { 'false' }))
    # 2026-11-05 会话视图新增三个薄字段（都是小标量，别在这里塞正文）：
    #   sig    日志身份（长度-mtime），页面据此决定是否拉 /log.js
    #   err    上一轮失败原因（stderr 的 dsh: 行），面板顶部挂一行警告
    #   reload 热重载令牌，/reload.gif 写入
    [void]$sb.Append(',sig:"').Append((Escape-Js $sig)).Append('"')
    [void]$sb.Append(',err:"').Append((Escape-Js $err)).Append('"')
    [void]$sb.Append(',reload:').Append([string][long]$reload)
    [void]$sb.Append(',dbg:')
    [void]$sb.Append($(if ($dbg) { 'true' } else { 'false' }))
    [void]$sb.Append(',lines:[')
    $first = $true
    foreach ($ln in $lines) {
        if (-not $first) { [void]$sb.Append(',') }
        [void]$sb.Append('"').Append((Escape-Js $ln)).Append('"')
        $first = $false
    }
    [void]$sb.Append(']};')
    Write-Raw $ctx ([System.Text.Encoding]::UTF8.GetBytes($sb.ToString())) 'application/javascript; charset=utf-8'
}

function Get-TextParam($req) {
    $q = $req.Url.Query
    if ($q -match '[?&]t=([^&]*)') {
        return ([System.Uri]::UnescapeDataString(($matches[1] -replace '\+', ' ')))
    }
    if ($req.HasEntityBody) {
        $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
        $body = $reader.ReadToEnd()
        $reader.Close()
        return $body.Trim()
    }
    return ''
}

# ---- DeepSeek 余额（5 分钟缓存） ----
$script:balText = ''
$script:balTs = [datetime]::MinValue
# 失败也要缓存：原实现只在成功时更新 balTs，一旦 key 失效 / 网络不通，
# 每次 /state.js 都会重发一次（Timeout=4000），单线程代理就被这条请求堵死了。
# 现在成功缓存 300s，失败冷却 30s（这是本次 800-1375ms 的主要来源之一）。
$script:balTrySec = 300
# DesktopPage-agent-proxy-cleared
foreach ($pv in @('HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy')) { try { [Environment]::SetEnvironmentVariable($pv, $null, 'Process') } catch { } }
$script:scrollAcc = 0

# 滚轮意图「读到但清不掉」时的日志限流（这条路由 40ms 一轮，不限流会一秒刷 25 行）
$script:scrollSkipAt = [long]0

function Take-Scroll {
    $scrollDat = Join-Path $appDir 'scroll.dat'
    $sum = 0
    try {
        if (Test-Path $scrollDat) {
            # 兜底：万一别的东西（外部脚本、旧版本、手工测试）把这个文件写到 1MB 以上，
            # 先丢掉再返回，不让一次 ReadAllText 卡住单线程主循环。正常路径永远走不到。
            $fi = Get-Item $scrollDat -ErrorAction SilentlyContinue
            if ($fi -and $fi.Length -gt 1MB) {
                try { [System.IO.File]::Delete($scrollDat) } catch { }
                if (Test-Path $scrollDat) {
                    try { [System.IO.File]::WriteAllText($scrollDat, '', (New-Object System.Text.UTF8Encoding($false))) } catch { }
                }
                return 0
            }
            $raw = [System.IO.File]::ReadAllText($scrollDat)
            foreach ($ln in ($raw -split "`n")) {
                $v = 0
                if ([int]::TryParse($ln.Trim(), [ref]$v)) { $sum += $v }
            }
            # 「读到」不等于「取走」：原来读完就 FileDelete、删没删掉一律不管（失败被 catch 吞掉），
            # 于是同一批意图 40ms 后又被读一遍 —— 滚一格跳两格，而且日志干干净净（2026-11-09）。
            # 现在先清后发（和热重载令牌同一套姿势）：删掉并复核 → 删不掉退化成截空再复核 →
            # 两者都不成就**这一轮不发**（返回 0，内容还在文件里，下一轮再取）。
            # 无论如何不能带着「没清掉的意图」下发，否则就是重复消费。
            $cleared = $false
            try { [System.IO.File]::Delete($scrollDat) } catch { }
            if (-not (Test-Path $scrollDat)) { $cleared = $true }
            else {
                try { [System.IO.File]::WriteAllText($scrollDat, '', (New-Object System.Text.UTF8Encoding($false))) } catch { }
                $fi2 = Get-Item $scrollDat -ErrorAction SilentlyContinue
                if (-not $fi2 -or $fi2.Length -eq 0) { $cleared = $true }
            }
            if (-not $cleared) {
                $n64 = [long]$script:clock.ElapsedMilliseconds
                if (($n64 - $script:scrollSkipAt) -gt 60000) {
                    $script:scrollSkipAt = $n64
                    Agent-Log 'scroll: intent queue not cleared, skipped this round'
                }
                return 0
            }
        }
    } catch { }
    return $sum
}

function Get-Balance {
    if (((Get-Date) - $script:balTs).TotalSeconds -lt $script:balTrySec) { return $script:balText }
    $script:balTs = Get-Date
    $script:balTrySec = 30          # 先按失败处理；成功再放宽到 300s
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $key = ''
        if (Test-Path $envFile) {
            foreach ($line in [System.IO.File]::ReadAllLines($envFile)) {
                if ($line -match '^\s*DEEPSEEK_API_KEY\s*=\s*(.+)$') { $key = $matches[1].Trim(); break }
            }
        }
        if (-not $key) { $key = $env:DEEPSEEK_API_KEY }
        if (-not $key) { return '' }
        $req = [System.Net.HttpWebRequest]::Create('https://api.deepseek.com/user/balance')
        $req.Proxy = $null
        $req.Timeout = 4000
        $req.ReadWriteTimeout = 4000
        $req.Method = 'GET'
        $req.Headers.Add('Authorization', "Bearer $key")
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $json = $sr.ReadToEnd()
        $sr.Close()
        $resp.Close()
        $r = $json | ConvertFrom-Json
        $info = $r.balance_infos | Select-Object -First 1
        if ($info) {
            $sym = [string][char]0xA5
            if ($info.currency -eq 'USD') { $sym = '$' }
            $script:balText = $sym + $info.total_balance
            $script:balTrySec = 300
            return $script:balText
        }
    } catch { }
    return $script:balText
}
# ---- 待办任务（todo.txt 是唯一真源，改完直接重写 todo-data.js） ----
$rectFile = Join-Path $appDir 'panel-rect.txt'
$todoTxt = Join-Path $appDir 'todo.txt'
$todoJs = if ($wallDir) { Join-Path $wallDir 'todo-data.js' } else { '' }

# scroll.dat 是「滚轮意图队列」：抽屉写一行，壁纸页每 80ms 取走并清空。
# 一旦消费方不在（Lively 没起、壁纸页面报错），它就会一直涨；而 Take-Scroll 是
# 整份 ReadAllText —— 在单线程代理里，这等于给自己埋一颗「越滚越慢、最后连坐
# 所有接口」的雷（铁律：单线程不许有 >200ms 的同步操作）。
# 超过 64KB（约 1.2 万条意图，正常 80ms 就取空，根本到不了）说明消费方早就没了，
# 旧意图没有重放价值 —— 直接丢弃，别为了几条过期滚动把整条链路拖死。
$script:SCROLL_MAX = 65536

function Get-TodoItems {
    $out = @()
    if (Test-Path $todoTxt) {
        foreach ($line in [System.IO.File]::ReadAllLines($todoTxt, [System.Text.Encoding]::UTF8)) {
            $s = $line.Trim()
            if (-not $s) { continue }
            $d = $false
            if ($s -match '^(?i)\[\s*x\s*\]\s*(.+)$') { $d = $true; $s = $matches[1] }
            elseif ($s -match '^(?i)x\s+(.+)$') { $d = $true; $s = $matches[1] }
            $out += , @{ t = $s.Trim(); d = $d }
        }
    }
    return $out
}

function Save-TodoItems($items) {
    $lines = @()
    foreach ($it in $items) {
        $prefix = ''
        if ($it.d) { $prefix = 'x ' }
        $lines += ($prefix + $it.t)
    }
    # 原子写（tmp + Move-Item 覆盖）：直接 WriteAllLines 会有一瞬文件被截断成空/半个，
    # 而抽屉读 todo.txt、壁纸页加载 todo-data.js 正好撞上，表现就是「待办空一片」。
    try {
        $tt = $todoTxt + '.tmp'
        [System.IO.File]::WriteAllLines($tt, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tt -Destination $todoTxt -Force
    } catch { }

    $ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("/* generated by dsh-agent */`n")
    [void]$sb.Append("window.__TODO_TS = $ms;`n")
    [void]$sb.Append('window.__TODO = [')
    $first = $true
    foreach ($it in $items) {
        if (-not $first) { [void]$sb.Append(', ') }
        $safe = $it.t -replace '\\', '\\' -replace "'", "\'"
        [void]$sb.Append("{ t: '").Append($safe).Append("', d: ")
        [void]$sb.Append($(if ($it.d) { 'true' } else { 'false' }))
        [void]$sb.Append(' }')
        $first = $false
    }
    [void]$sb.Append("];`n")
    # 同上：todo-data.js 是壁纸页用 <script src> 直接加载的，写到一半被读到就是整页脚本挂
    if ($todoJs) {
        try {
            $tj = $todoJs + '.tmp'
            [System.IO.File]::WriteAllText($tj, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tj -Destination $todoJs -Force
        } catch { }
    }
}

# ---- 抽屉程序（DesktopPage）是否在跑 ----
$ahkExe = Join-Path $appDir 'AutoHotkey64.exe'
$ahkScript = Join-Path $appDir 'DesktopPage.ahk'

function Get-DrawerRunning {
    return [bool](Get-Process -Name 'AutoHotkey64' -ErrorAction SilentlyContinue)
}

function Start-Drawer {
    # 走计划任务启动：从本进程 Start-Process 起的 AHK 会被沙箱限制（键盘钩子失效、不写日志）
    try { & schtasks.exe /run /tn "DesktopPage Autostart" | Out-Null } catch { }
}

function Start-NoConsole([string]$exe, [string[]]$argv, [string]$workDir) {
    # 一律用 CreateProcess + CREATE_NO_WINDOW 起子进程。
    # 本机默认终端是 Windows Terminal，-WindowStyle Hidden 对 WT 宿主无效，
    # 每次 Start-Process 控制台程序都会弹一个空的「管理员:」黑框（用户实测反复出现）。
    # CreateNoWindow=$true 时完全不创建控制台 → 实测可见窗口数 0 增长，也不会漏 OpenConsole.exe。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($argv -join ' ')
    if ($workDir) { $psi.WorkingDirectory = $workDir }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    return [System.Diagnostics.Process]::Start($psi)
}

function Start-Run([string]$text) {
    $stamp = (Get-Date).ToString('HH:mm:ss')
    # 两个日志都是 cmd 用 >> / 2>> 追加的，没法在写入处判断尺寸 —— 只能在每次启动前查一次。
    # 超过 256KB 就轮转成 .1（Move-Item -Force；本机安全策略会拦 Remove-Item）。
    # 轮转后必须补一个空文件，否则 Test-Path 短路，面板上看不到新输出。
    try {
        foreach ($f in @($logFile, $errFile)) {
            if ((Test-Path $f) -and ((Get-Item $f -ErrorAction SilentlyContinue).Length -gt 262144)) {
                # 同样「改名成功才许截空」：上一轮 dsh 还活着时它的 >> 句柄占着这个文件，
                # 改名会失败 —— 老写法接着截空，等于把上一整轮会话正文抹掉（面板上"历史突然没了"）。
                $rotOk = $false
                try {
                    Move-Item -LiteralPath $f -Destination ($f + '.1') -Force -ErrorAction Stop
                    $rotOk = -not (Test-Path -LiteralPath $f)
                } catch { $rotOk = $false }
                if ($rotOk) {
                    [System.IO.File]::WriteAllText($f, '', (New-Object System.Text.UTF8Encoding($false)))
                } else {
                    Agent-Log ('run: rotate skipped (rename failed) ' + [System.IO.Path]::GetFileName($f))
                }
            }
        }
        # 新一轮开始先清掉上一轮的错误：否则面板会一直挂着旧报错
        [System.IO.File]::WriteAllText($errFile, '', (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    try { [System.IO.File]::AppendAllText($logFile, "[$stamp] >>> $text`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch { }
    foreach ($k in @('lines', 'sig', 'log', 'err')) { Cache-Drop $k }
    $safe = $text -replace '"', '\"'
    # 2>> 把 reasoning / 报错分到 err 文件：面板只渲染「指令 + 回答」，思考过程不该混进取景框
    $cmdLine = '/c chcp 65001 >nul & "' + $dshCmd + '" headless "' + $safe + '" >> "' + $logFile + '" 2>> "' + $errFile + '"'
    $p = Start-NoConsole 'cmd.exe' @($cmdLine) $null
    $st = ''
    try { $st = (Get-Process -Id $p.Id).StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { }
    try { [System.IO.File]::WriteAllText($pidFile, "$($p.Id)|$st") } catch { }
    return $p.Id
}

function Get-Dock {
    $dockFile = Join-Path $appDir 'dock.txt'
    $out = @()
    if (Test-Path $dockFile) {
        foreach ($ln in [System.IO.File]::ReadAllLines($dockFile, [Text.Encoding]::UTF8)) {
            if (-not $ln) { continue }
            $parts = $ln.Split('|')
            if ($parts.Length -lt 2) { continue }
            $icon = ''
            if ($parts.Length -ge 3) { $icon = $parts[2] }
            $out += [pscustomobject]@{ p = $parts[0]; n = $parts[1]; i = $icon }
        }
    }
    return $out
}
function Save-Dock($items) {
    $dockFile = Join-Path $appDir 'dock.txt'
    try {
        $sb = New-Object System.Text.StringBuilder
        foreach ($it in $items) { [void]$sb.AppendLine($it.p + '|' + $it.n + '|' + $it.i) }
        # 原子写（与 hwmon/wxmon 同一范式）：dock.txt 由 AHK 与代理共读，
        # 截断到一半会被读成「快捷启动少了几项」。
        $dk = $dockFile + '.tmp'
        [System.IO.File]::WriteAllText($dk, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $dk -Destination $dockFile -Force
    } catch { }
}
function Write-DockJs($ctx) {
    $items = @(Get-Dock)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('window.__DOCK=[')
    $first = $true
    foreach ($it in $items) {
        if (-not $first) { [void]$sb.Append(',') }
        $first = $false
        $nm = Escape-Js $it.n
        $ic = Escape-Js $it.i
        [void]$sb.Append('{n:"' + $nm + '",i:"' + $ic + '",p:"' + (Escape-Js $it.p) + '"}')
    }
    [void]$sb.Append('];')
    $busyFlag = 0
    try {
        $stf = Join-Path $appDir 'dock-add.state'
        if ((Test-Path $stf) -and ((([System.IO.File]::ReadAllText($stf)).Trim()) -eq 'open')) { $busyFlag = 1 }
    } catch { }
    [void]$sb.Append('window.__DOCK_BUSY=' + $busyFlag + ';')
    Write-Raw $ctx ([Text.Encoding]::UTF8.GetBytes($sb.ToString())) 'application/javascript'
}
# ===== 当前播放（WinRT GSMTC）=====
try { Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop } catch { }
$script:asTask = $null
try {
    $script:asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
} catch { }
function Await-Op($op, $type) {
    if (-not $script:asTask) { return $null }
    $t = $script:asTask.MakeGenericMethod($type).Invoke($null, @($op))
    $t.Wait(3000) | Out-Null
    if ($t.IsCompleted) { return $t.Result } else { return $null }
}
$script:mediaMgr = $null
$script:mediaTs = 0
$script:mediaCache = $null
function Get-MediaMgr {
    if ($script:mediaMgr) { return $script:mediaMgr }
    try {
        [void][Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
    } catch { return $null }
    try {
        $script:mediaMgr = Await-Op ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
    } catch { $script:mediaMgr = $null }
    return $script:mediaMgr
}
# ===== 当前播放兜底：网易云音乐（3.1.x 不发布 GSMTC 会话）=====
# 依据：窗口标题「歌曲 - 歌手」+ WASAPI 会话状态（是否在播）+ 播放列表文件（时长）
$script:dshAudio = $null
try {
    $audioCs = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.IO;
using System.Diagnostics;

// ---- WASAPI（判断某个进程是否真的在出声）----
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorComObject { }

[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
public interface IMMDeviceEnumerator {
  int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
  int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
  int GetDevice(string id, out IMMDevice device);
  int RegisterEndpointNotificationCallback(IntPtr client);
  int UnregisterEndpointNotificationCallback(IntPtr client);
}
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")]
public interface IMMDevice {
  int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
  int OpenPropertyStore(int stgmAccess, out IntPtr props);
  int GetId(out IntPtr id);
  int GetState(out int state);
}
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F")]
public interface IAudioSessionManager2 {
  int GetAudioSessionControl(IntPtr audioSessionGuid, int flags, out IntPtr sessionControl);
  int GetSimpleAudioVolume(IntPtr audioSessionGuid, int flags, out IntPtr audioVolume);
  int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnum);
  int RegisterSessionNotification(IntPtr sessionNotification);
  int UnregisterSessionNotification(IntPtr sessionNotification);
  int RegisterDuckNotification(string sessionId, IntPtr duckNotification);
  int UnregisterDuckNotification(IntPtr duckNotification);
}
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8")]
public interface IAudioSessionEnumerator {
  int GetCount(out int sessionCount);
  int GetSession(int sessionCount, out IAudioSessionControl session);
}
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD")]
public interface IAudioSessionControl {
  int GetState(out int state);
  int GetDisplayName(out IntPtr name);
  int SetDisplayName(string name, IntPtr eventContext);
  int GetIconPath(out IntPtr path);
  int SetIconPath(string path, IntPtr eventContext);
  int GetGroupingParam(out Guid groupingId);
  int SetGroupingParam(ref Guid groupingId, IntPtr eventContext);
  int RegisterAudioSessionNotification(IntPtr client);
  int UnregisterAudioSessionNotification(IntPtr client);
}
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064")]
public interface IAudioMeterInformation {
  int GetPeakValue(out float peak);
}
[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D")]
public interface IAudioSessionControl2 {
  int GetState(out int state);
  int GetDisplayName(out IntPtr name);
  int SetDisplayName(string name, IntPtr eventContext);
  int GetIconPath(out IntPtr path);
  int SetIconPath(string path, IntPtr eventContext);
  int GetGroupingParam(out Guid groupingId);
  int SetGroupingParam(ref Guid groupingId, IntPtr eventContext);
  int RegisterAudioSessionNotification(IntPtr client);
  int UnregisterAudioSessionNotification(IntPtr client);
  int GetSessionIdentifier(out IntPtr id);
  int GetSessionInstanceIdentifier(out IntPtr id);
  int GetProcessId(out uint pid);
  int IsSystemSoundsSession();
  int SetDuckingPreference(bool optOut);
}

public class DshAudio {
  // ===== 通用 =====
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  public struct RECT { public int L; public int T; public int R; public int B; }
  public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);

  // ===== WASAPI：会话状态 / 峰值 =====
  // 0=非活跃 1=在播 2=过期 -1=找不到（注意：暂停后 state 可能仍是 1，判在播请用 PeakMax）
  public static int GetState(uint pid) {
    try {
      var en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
      IMMDevice dev;
      if (en.GetDefaultAudioEndpoint(0, 1, out dev) != 0) return -1;
      Guid iid = typeof(IAudioSessionManager2).GUID;
      object o;
      if (dev.Activate(ref iid, 1, IntPtr.Zero, out o) != 0) return -1;
      var mgr = (IAudioSessionManager2)o;
      IAudioSessionEnumerator se;
      mgr.GetSessionEnumerator(out se);
      int n; se.GetCount(out n);
      int best = -1;
      for (int i = 0; i < n; i++) {
        IAudioSessionControl ctl;
        se.GetSession(i, out ctl);
        var c2 = ctl as IAudioSessionControl2;
        if (c2 == null) continue;
        uint sp;
        if (c2.GetProcessId(out sp) != 0 || sp != pid) continue;
        int st;
        if (ctl.GetState(out st) != 0) continue;
        if (st > best) best = st;
      }
      return best;
    } catch { return -1; }
  }

  // 采样窗口内的峰值：暂停恒为 0，播放通常 > 0.01
  public static float PeakMax(uint pid, int ms) {
    float best = 0f;
    int iters = ms / 60;
    if (iters < 1) iters = 1;
    for (int k = 0; k < iters; k++) {
      try {
        var en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
        IMMDevice dev;
        if (en.GetDefaultAudioEndpoint(0, 1, out dev) == 0) {
          Guid iid = typeof(IAudioSessionManager2).GUID;
          object o;
          if (dev.Activate(ref iid, 1, IntPtr.Zero, out o) == 0) {
            var mgr = (IAudioSessionManager2)o;
            IAudioSessionEnumerator se;
            mgr.GetSessionEnumerator(out se);
            int n; se.GetCount(out n);
            for (int i = 0; i < n; i++) {
              IAudioSessionControl ctl;
              se.GetSession(i, out ctl);
              var c2 = ctl as IAudioSessionControl2;
              if (c2 == null) continue;
              uint sp;
              if (c2.GetProcessId(out sp) != 0 || sp != pid) continue;
              var mi = ctl as IAudioMeterInformation;
              if (mi == null) continue;
              float pk;
              if (mi.GetPeakValue(out pk) == 0 && pk > best) best = pk;
            }
          }
        }
      } catch { }
      if (k + 1 < iters) Thread.Sleep(60);
    }
    return best;
  }

  // ===== 网易云主窗口 =====
  // 类名 OrpheusBrowserHost；不能用 MainWindowHandle（有时指向迷你播放器/提示小窗）
  public static IntPtr NEMain(uint pid) {
    IntPtr best = IntPtr.Zero;
    long bestScore = -1;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid) return true;
      var cn = new System.Text.StringBuilder(256);
      GetClassName(h, cn, 256);
      if (cn.ToString().IndexOf("OrpheusBrowserHost") < 0) return true;
      RECT r; GetWindowRect(h, out r);
      long a = (long)(r.R - r.L) * (r.B - r.T);
      long score = (IsWindowVisible(h) ? 100000000L : 0L) + a;
      if (score > bestScore) { bestScore = score; best = h; }
      return true;
    }, IntPtr.Zero);
    return best;
  }

  public static string WinTitle(IntPtr h) {
    var sb = new System.Text.StringBuilder(1024);
    GetWindowText(h, sb, 1024);
    return sb.ToString();
  }

  public static bool Min(IntPtr hwnd) { return hwnd != IntPtr.Zero && IsIconic(hwnd); }
  public static bool Vis(IntPtr hwnd) { return hwnd != IntPtr.Zero && IsWindowVisible(hwnd); }

  // ===== npix.exe（DPI 感知）：读控制条真实位置，用于校准进度 =====
  public static string Npix(IntPtr hwnd) {
    try {
      string exe = "";
      try {
        string loc = System.Reflection.Assembly.GetExecutingAssembly().Location;
        if (!string.IsNullOrEmpty(loc)) exe = Path.Combine(Path.GetDirectoryName(loc), "npix.exe");
      } catch { }
      string alt = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DesktopPage", "npix.exe");
      if (string.IsNullOrEmpty(exe) || !File.Exists(exe)) exe = alt;
      if (!File.Exists(exe)) return null;
      var psi = new ProcessStartInfo(exe, "report " + hwnd.ToInt64());
      psi.UseShellExecute = false;
      psi.RedirectStandardOutput = true;
      psi.CreateNoWindow = true;
      using (var p = Process.Start(psi)) {
        if (p == null) return null;
        string outp = p.StandardOutput.ReadToEnd();
        p.WaitForExit(4000);
        return outp == null ? null : outp.Trim();
      }
    } catch { return null; }
  }

  // ===== 系统媒体键（不弹窗、不抢前台）=====
  // VK_MEDIA_PLAY_PAUSE=0xB3  VK_MEDIA_PREV_TRACK=0xB1  VK_MEDIA_NEXT_TRACK=0xB0
  public static string MediaKey(int vk) {
    keybd_event((byte)vk, 0, 0, UIntPtr.Zero);
    Thread.Sleep(25);
    keybd_event((byte)vk, 0, 2, UIntPtr.Zero);
    return "media=" + vk;
  }
}
'@
    Add-Type -TypeDefinition $audioCs -Language CSharp -ErrorAction Stop
    $script:dshAudio = $true
} catch { $script:dshAudio = $null; $script:dshErr = $_.Exception.Message }

$script:plFile = Join-Path $env:LOCALAPPDATA 'NetEase\CloudMusic\webdata\file\playingList'
$script:niCache = $null
$script:niTs = [DateTime]::MinValue
$script:plMtime = [DateTime]::MinValue
$script:plDur = @{}
function Get-PlayingListDuration([string]$name, [string]$artist) {
    try {
        if (-not $name) { return 0 }
        if (-not (Test-Path $script:plFile)) { return 0 }
        $mt = (Get-Item $script:plFile).LastWriteTimeUtc
        if ($mt -ne $script:plMtime) {
            $map = @{}
            $j = [System.IO.File]::ReadAllText($script:plFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($e in $j.list) {
                $t = $e.track
                if (-not $t -or -not $t.name -or -not $t.duration) { continue }
                $n = [string]$t.name
                $d = [int]$t.duration
                if ($d -le 0) { continue }
                if (-not $map.ContainsKey($n)) { $map[$n] = $d }
                $a = ''
                try { if ($t.artists.Count -gt 0) { $a = [string]$t.artists[0].name } } catch { }
                if ($a) {
                    $k = $n + '|' + $a
                    if (-not $map.ContainsKey($k)) { $map[$k] = $d }
                }
            }
            $script:plDur = $map
            $script:plMtime = $mt
        }
        $n2 = $name -replace '\s*[\(\uFF08\[\u3010].*$', ''
        if ($artist -and $script:plDur.ContainsKey($name + '|' + $artist)) { return [int]$script:plDur[$name + '|' + $artist] }
        if ($script:plDur.ContainsKey($name)) { return [int]$script:plDur[$name] }
        if ($n2 -and $artist -and $script:plDur.ContainsKey($n2 + '|' + $artist)) { return [int]$script:plDur[$n2 + '|' + $artist] }
        if ($n2 -and $script:plDur.ContainsKey($n2)) { return [int]$script:plDur[$n2] }
        return 0
    } catch { $script:plErr = $_.Exception.Message; return 0 }
}
# 进度估算：GSMTC 拿不到网易云时间轴，只能按「首次观测到该曲 + 是否在播」累加
$script:neTrack = ''
$script:neAcc = 0.0
$script:neRunning = $false
$script:neSince = [DateTime]::MinValue
$script:neSyncTs = [DateTime]::MinValue
$script:neSaveTs = [DateTime]::MinValue
# 进度估算落到磁盘：代理重启后还能接着上次的位置，而不是从 00:00 重新数
$script:neStateFile = Join-Path $appDir 'media-pos.json'
try {
    if (Test-Path $script:neStateFile) {
        $st = [System.IO.File]::ReadAllText($script:neStateFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($st -and $st.track) {
            $script:neTrack = [string]$st.track
            $script:neAcc = [double]$st.pos
            $script:neRunning = ([int]$st.playing -eq 1)
            $script:neSince = [DateTime]::Parse([string]$st.ts, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
    }
} catch { }
function Update-NePos([string]$key, [bool]$playing, [int]$dur) {
    $now = [DateTime]::UtcNow
    if ($script:neTrack -ne $key) {
        $script:neTrack = $key
        $script:neAcc = 0.0
        $script:neRunning = $false
        $script:neSince = $now
    }
    if ($script:neRunning) { $script:neAcc += ($now - $script:neSince).TotalSeconds }
    $script:neSince = $now
    $script:neRunning = $playing
    $pos = [int][math]::Floor($script:neAcc)
    if ($pos -lt 0) { $pos = 0 }
    if ($dur -gt 0 -and $pos -gt $dur) { $pos = $dur }
    return $pos
}

function Sync-NeteasePos([IntPtr]$hwnd, [int]$dur) {
    if ($dur -le 0 -or -not $script:dshAudio) { return $false }
    $now = [DateTime]::UtcNow
    if (($now - $script:neSyncTs).TotalSeconds -lt 6) { return $false }
    $script:neSyncTs = $now
    try {
        # 窗口最小化时抓不到画面，且不想为了读进度把窗口弹出来，直接跳过
        if ([DshAudio]::Min($hwnd)) { return $false }
        if (-not [DshAudio]::Vis($hwnd)) { return $false }
        $rep = [DshAudio]::Npix($hwnd)
        if (-not $rep) { return $false }
        if ($rep -notmatch 'pos=([0-9.]+)') { return $false }
        $f = [double]$matches[1]
        if ($f -lt 0 -or $f -gt 1) { return $false }
        # 窗口被别的窗口挡住时截到的是别人的画面，和估算值差得太远就不采信
        $est = $script:neAcc + (($now - $script:neSince).TotalSeconds)
        if ($est -gt 5 -and [math]::Abs(($f * $dur) - $est) -gt 90) { return $false }
        $script:neAcc = $f * [double]$dur
        $script:neSince = [DateTime]::UtcNow
        return $true
    } catch { return $false }
}

function Get-NeteaseInfo {
    try {
        if (-not $script:dshAudio) { return $null }
        # 点击时这条会走一遍进程/窗口枚举（几十到上百毫秒），缓存 4 秒让空格键更早落下
        $now = [DateTime]::UtcNow
        if ($script:niCache -and (($now - $script:niTs).TotalMilliseconds -lt 4000)) { return $script:niCache }
        $hits = @()
        foreach ($p in @(Get-Process cloudmusic -ErrorAction SilentlyContinue)) {
            try {
                $h = [DshAudio]::NEMain([uint32]$p.Id)
                if ($h -ne [IntPtr]::Zero) {
                    $tt = [string][DshAudio]::WinTitle($h)
                    if ($tt) { $hits += @{ Proc = $p; Hwnd = $h; Title = $tt } }
                }
            } catch { }
        }
        if ($hits.Count -eq 0) { $script:niCache = $null; $script:niTs = $now; return $null }
        $script:niCache = $hits[0]
        $script:niTs = $now
        return $hits[0]
    } catch { return $null }
}
function Get-NeteaseMedia {
    $o = @{ ok = 0; playing = 0; app = 'CloudMusic'; title = ''; artist = ''; pos = 0; dur = 0; est = 1 }
    try {
        $ni = Get-NeteaseInfo
        if (-not $ni) { return $o }
        $p = $ni.Proc
        $t = [string]$ni.Title
        if (-not $t) { return $o }
        $song = $t.Trim()
        $artist = ''
        $i = $t.LastIndexOf(' - ')
        if ($i -gt 0) {
            $song = $t.Substring(0, $i).Trim()
            $artist = $t.Substring($i + 3).Trim()
        }
        if (-not $song) { return $o }
        $dur = Get-PlayingListDuration $song $artist
        if ($dur -gt 0) { $dur = [int][math]::Round($dur / 1000) }   # 播放列表里是毫秒，壁纸用秒
        $playing = $false
        if ($script:dshAudio) {
            # 会话 state 在暂停后仍可能保持 1，改用峰值采样：暂停恒为 0
            try {
                $pk = [DshAudio]::PeakMax([uint32]$p.Id, 120)
                $playing = ($pk -gt 0.0015)
            } catch {
                try { $playing = ([DshAudio]::GetState([uint32]$p.Id) -eq 1) } catch { }
            }
        }
        if ($playing) { [void](Sync-NeteasePos $ni.Hwnd $dur) }
        $pos = Update-NePos ($song + '|' + $artist) $playing $dur
        if ((([DateTime]::UtcNow) - $script:neSaveTs).TotalSeconds -gt 5) {
            $script:neSaveTs = [DateTime]::UtcNow
            try {
                $obj = @{ track = ($song + '|' + $artist); pos = $pos; ts = ([DateTime]::UtcNow.ToString('o')); playing = [int]$playing } | ConvertTo-Json -Compress
                [System.IO.File]::WriteAllText($script:neStateFile, $obj, (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
        }
        $o.ok = 1
        $o.title = $song
        $o.artist = $artist
        $o.dur = $dur
        $o.pos = $pos
        if ($playing) { $o.playing = 1 }
    } catch { }
    return $o
}
function Invoke-NeteaseOp([string]$op, [object]$knownPlaying = $null) {
    try {
        if (-not $script:dshAudio) { return }
        $ni = Get-NeteaseInfo
        if (-not $ni) { return }
        $hwnd = $ni.Hwnd
        if ($op -eq 'toggle') {
            # 系统媒体键（VK_MEDIA_PLAY_PAUSE=0xB3）：和桌面播放器按键盘上的播放键等价，
            # 由 Windows 直接路由给媒体应用，不需要抢前台、更不需要把窗口弹出来点按钮。
            [void][DshAudio]::MediaKey(0xB3)
        } elseif ($op -eq 'back') {
            # 上一首（VK_MEDIA_PREV_TRACK=0xB1），零弹窗
            [void][DshAudio]::MediaKey(0xB1)
        } elseif ($op -eq 'fwd') {
            # 下一首（VK_MEDIA_NEXT_TRACK=0xB0），零弹窗
            [void][DshAudio]::MediaKey(0xB0)
        }
        # 曲目/状态变了，让下一次轮询重新取一遍
        $script:mediaCache = $null
        $script:mediaTs = [DateTime]::MinValue
    } catch { }
}
function Get-MediaInfo ([bool]$force) {
    $now = [DateTime]::UtcNow
    if (-not $force -and $script:mediaCache -and (($now - $script:mediaTs).TotalMilliseconds -lt 900)) { return $script:mediaCache }
    $o = @{ ok = 0; playing = 0; app = ''; title = ''; artist = ''; pos = 0; dur = 0; est = 0 }
    try {
        $sm = $null
        $mgr = Get-MediaMgr
        if ($mgr) {
            $s = $null
            try { $s = $mgr.GetCurrentSession() } catch { }
            if ($s) {
                $t = @{ ok = 1; playing = 0; app = [string]$s.SourceAppUserModelId; title = ''; artist = ''; pos = 0; dur = 0; est = 0 }
                try {
                    $pi = $s.GetPlaybackInfo()
                    if ([string]$pi.PlaybackStatus -eq 'Playing') { $t.playing = 1 }
                } catch { }
                try {
                    $p = Await-Op ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
                    if ($p) { $t.title = [string]$p.Title; $t.artist = [string]$p.Artist }
                } catch { }
                try {
                    $tl = $s.GetTimelineProperties()
                    $t.pos = [int][math]::Round($tl.Position.TotalSeconds)
                    $t.dur = [int][math]::Round($tl.EndTime.TotalSeconds)
                } catch { }
                if ($t.title) { $sm = $t }
            }
        }
        if ($sm -and $sm.playing) {
            # 真有别的东西在播（视频 / Edge）时优先它
            $o = $sm
        } else {
            # GSMTC 没有会话或在播会话：看网易云（它不发布 GSMTC，只能靠兜底）
            $ne = Get-NeteaseMedia
            if ($ne.ok) { $o = $ne }
            elseif ($sm) { $o = $sm }
        }
    } catch { }
    $script:mediaCache = $o
    $script:mediaTs = [DateTime]::UtcNow
    return $o
}
function Write-MediaJs($ctx) {
    # GSMTC 会话枚举 + 网易云窗口枚举很贵（100-300ms），进程级缓存 1000ms。
    # /media.gif?op= 动作后会 Cache-Drop 'media' 主动失效（页面本身还有 2.5s 乐观反馈）。
    $o = Cache-Get 'media' 1000 { Get-MediaInfo $false }
    if (-not $o) { $o = @{ ok = 0; playing = 0; app = ''; title = ''; artist = ''; pos = 0; dur = 0; est = 0 } }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('window.__MEDIA={ok:' + $o.ok + ',playing:' + $o.playing)
    [void]$sb.Append(',app:"' + (Escape-Js $o.app) + '"')
    [void]$sb.Append(',title:"' + (Escape-Js $o.title) + '"')
    [void]$sb.Append(',artist:"' + (Escape-Js $o.artist) + '"')
    [void]$sb.Append(',pos:' + $o.pos + ',dur:' + $o.dur + ',est:' + [int]$o.est + '};')
    Write-Raw $ctx ([Text.Encoding]::UTF8.GetBytes($sb.ToString())) 'application/javascript'
}
function Invoke-MediaOp([string]$op) {
    # 先记下最近的播放状态（用于判断这次是暂停还是恢复）和当前来源，再清缓存
    $cachedPlaying = $null
    $cachedApp = ''
    try {
        if ($script:mediaCache) {
            $cachedPlaying = ([int]$script:mediaCache.playing -eq 1)
            $cachedApp = [string]$script:mediaCache.app
        }
    } catch { }
    $script:mediaCache = $null
    try {
        # 面板上显示的就是网易云时直接走网易云链路，省掉 SMTC 枚举（每次要 100-300ms）
        if ($cachedApp -eq 'CloudMusic') {
            if (Get-NeteaseInfo) { Invoke-NeteaseOp $op $cachedPlaying; Cache-Drop 'media'; return }
        }
        $did = $false
        $mgr = Get-MediaMgr
        if ($mgr) {
            $s = $null
            try { $s = $mgr.GetCurrentSession() } catch { }
            if ($s) {
                $playing = $false
                try {
                    $pi = $s.GetPlaybackInfo()
                    $playing = ([string]$pi.PlaybackStatus -eq 'Playing')
                } catch { }
                # GSMTC 会话没在播、而网易云在跑时，按键要发给网易云
                $ne = $null
                if (-not $playing) { $ne = Get-NeteaseInfo }
                if (-not $ne) {
                    if ($op -eq 'toggle') {
                        if ($playing) { $t = $s.TryPauseAsync() } else { $t = $s.TryPlayAsync() }
                        Await-Op $t ([bool]) | Out-Null
                    } elseif ($op -eq 'back' -or $op -eq 'fwd') {
                        # 上一首 / 下一首：SMTC 原生方法，同样不弹窗
                        try {
                            if ($op -eq 'fwd') { $t = $s.TrySkipNextAsync() } else { $t = $s.TrySkipPreviousAsync() }
                            Await-Op $t ([bool]) | Out-Null
                        } catch { }
                    }
                    $did = $true
                }
            }
        }
        if (-not $did) { Invoke-NeteaseOp $op $cachedPlaying }
    } catch { }
    # 动作已落下，立刻让下一次 /media.js 重新取（否则 1 秒内页面还是旧数据）
    Cache-Drop 'media'
}
# =============================================================================
#  路由表 —— 加一个新接口 = 加一条表项 + 一个 handler 函数，主循环一行都不用改
# -----------------------------------------------------------------------------
#  $script:ROUTES   key = 规范化后的路径（$req.Url.AbsolutePath.ToLower()，O(1) 哈希查表）
#                   value = @{ handler / kind / poll / audit }
#                   · handler : 处理函数名（字符串），统一签名 param($ctx, $query)
#                   · kind    : 审计行里的 route= 分类。**值必须和改造前 Get-RouteKind
#                               的返回值一模一样**（例如 /launch.gif 当年落进 'other'，
#                               这里就还是 'other'）—— 审计是给人 grep 的，不许"顺手修正"。
#                   · poll    : $true = 80ms~1.5s 级轮询接口 → 不打 'req' 日志、不算慢请求
#                   · audit   : $true = 每个请求结束写一行 [API ] GET /xxx（含耗时）
#
#  $script:ROUTES_PREFIX  带变量尾巴的路径（/icon/<file>）。只做 Ordinal StartsWith，
#                         表项结构和上面一样，多一个 prefix 字段。
#
#  $query（handler 的第二参）是 New-QueryBag 造的等价结构 —— 不是裸的 NameValueCollection，
#  因为现有分支全靠正则怼原始查询串，换成 NameValueCollection 会改掉解析语义：
#      $query.raw   原始查询串，含前导 '?'，和 $req.Url.Query 完全相等（正则照旧用这个）
#      $query.req   HttpListenerRequest（Get-TextParam 的 POST 正文兜底要用）
#      $query.nvc   [System.Collections.Specialized.NameValueCollection]（已解码，新接口可直接用）
#      $query.path  规范化路径（前缀路由要取尾巴）
#
#  铁律（改表时别破坏）：
#    1) handler 里"先回包再干活"——Write-Raw 必须在动作之前，信标语义不变；
#    2) 返回格式 window.__XXX= / 1x1 GIF / 状态码 一律照旧；
#    3) handler 里不许加同步慢操作（单线程代理，一个慢请求堵住所有人）。
# =============================================================================
function New-QueryBag($req, [string]$path) {
    $raw = $req.Url.Query          # 含前导 '?'；空查询就是 ''
    $nvc = New-Object System.Collections.Specialized.NameValueCollection
    if ($raw) {
        foreach ($pair in $raw.TrimStart('?').Split('&')) {
            if (-not $pair) { continue }
            $kv = $pair.Split('=', 2)
            $k = [System.Uri]::UnescapeDataString(($kv[0] -replace '\+', ' '))
            $v = ''
            if ($kv.Length -gt 1) { $v = [System.Uri]::UnescapeDataString(($kv[1] -replace '\+', ' ')) }
            $nvc.Add($k, $v)
        }
    }
    return @{ raw = $raw; req = $req; nvc = $nvc; path = $path }
}

# ---- GET /state.js | /state ← window.__DSH_STATE {web,scroll,busy,bal,drawer,sig,err,reload,dbg,lines[]} ----
function Invoke-StateJs($ctx, $query) {
    # 分层 TTL：每次只重算过期项；每项各自 try/catch（见 Cache-Get），
    # 任何一项失败都不会把整条响应变成 500 或半个响应。
    $web = [bool](Cache-Get 'web' 3000 { Test-WebUp })
    $busy = [bool](Cache-Get 'busy' 1000 { Get-RunBusy })
    $lines = Cache-Get 'lines' 500 { Get-LogTail 40 }
    $bal = [string](Cache-Get 'bal' 300000 { Get-Balance })
    $drawer = [bool](Cache-Get 'drawer' 2000 { Get-DrawerRunning })
    # 会话视图的两个指针：sig 变了页面才去拉 /log.js（正文在那边，这里不塞）
    $sig = [string](Cache-Get 'sig' 500 { Get-LogSig })
    $err = [string](Cache-Get 'err' 500 { Get-ErrText })
    $reload = [long](Cache-Get 'reload' 500 { Get-ReloadToken })
    # 调试旗标每次看盘（没有缓存）：改完不用重启代理就能开/关信标
    $dbg = Test-Path $dbgFlag
    Write-Js $ctx $web $busy $lines $bal $drawer 0 $sig $err $reload $dbg
    # cache=1 → 全部命中；cache=0:lines → 只重算了日志尾巴
    # 用 $script: 是因为 handler 是函数：局部变量传不回主循环的日志行
    $script:stateTag = if ($script:missKeys.Count -eq 0) { ' (cache=1)' } else { ' (cache=0:' + ($script:missKeys -join ',') + ')' }
}

function Invoke-MediaJs($ctx, $query) {
    Write-MediaJs $ctx
}

function Invoke-MediaGif($ctx, $query) {
    $mop = ''
    if ($query.raw -match '[?&]op=([a-z]+)') { $mop = $matches[1] }
    # 先回包再执行动作：按钮点击的等车感来自这段（抢前台 + 等音频起流）
    Write-Raw $ctx $gif 'image/gif'
    if ($mop) { Invoke-MediaOp $mop }
}

function Invoke-DockJs($ctx, $query) {
    Write-DockJs $ctx
}

function Invoke-DockGif($ctx, $query) {
    $di = -1
    if ($query.raw -match '[?&]i=(-?\d+)') { $di = [int]$matches[1] }
    if ($query.raw -match 'op=del' -and $di -ge 0) {
        $items = @(Get-Dock)
        if ($di -lt $items.Count) {
            $keep = @(); for ($k = 0; $k -lt $items.Count; $k++) { if ($k -ne $di) { $keep += $items[$k] } }
            Save-Dock $keep
        }
    }
    Write-Raw $ctx $gif 'image/gif'
    if ($query.raw -match 'op=del' -and $di -ge 0) { Write-Audit 'dock' ('del i={0}' -f $di) }
}

function Invoke-AddDock($ctx, $query) {
    # 只写触发文件，由常驻的 dock-add-host.ps1 立刻弹框（毫秒级）
    try {
        $st = Join-Path $appDir 'dock-add.state'
        $busy = ((Test-Path $st) -and ((([System.IO.File]::ReadAllText($st)).Trim()) -eq 'open'))
        if (-not $busy) { [System.IO.File]::WriteAllText((Join-Path $appDir 'dock-add.trigger'), '1') }
    } catch { }
    Write-Raw $ctx $gif 'image/gif'
}

function Invoke-IconPath($ctx, $query) {
    # 前缀表命中：/icon/<文件名>，尾巴从规范化路径上切（'/icon/' = 6 个字符）
    $fn = $query.path.Substring(6)
    $fn = ($fn -replace '[^A-Za-z0-9._-]', '')
    $fp = Join-Path (Join-Path $appDir 'icons') $fn
    if ($fn -and (Test-Path $fp)) {
        try { Write-Raw $ctx ([System.IO.File]::ReadAllBytes($fp)) 'image/png' } catch { Write-Raw $ctx $gif 'image/gif' }
    } else { Write-Raw $ctx $gif 'image/gif' }
}

function Invoke-LaunchPath($ctx, $query) {
    $lp = Get-TextParam $query.req
    # 先回包再启动：ShellExecute 拉 .vbs/.lnk 偶尔要 6 秒（实测一个 .vbs 6.28 秒），
    # 期间这个单线程请求循环整段停摆，抽屉端 0.9 秒超时后会误判失败并改走启动队列。
    Write-Raw $ctx $gif 'image/gif'
    # 快捷方式（.lnk）单独处理：走 ShellExecute 会弹「打开文件 - 安全警告」（实测 E:\ 下的
    # .lnk 必弹；弹窗挂着时 Start-Process 一直不返回，用户看到的就是"弹了个框、文件没打开"）。
    # 能解析出 exe 就直接起目标 exe，绕过快捷方式本身的风险检查；其余类型仍走 explorer 中转。
    $lnkDone = $false
    if ($lp -and ($lp -like '*.lnk') -and (Test-Path -LiteralPath $lp)) {
        $sc = $null
        try { $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lp) } catch { }
        if ($sc -and $sc.TargetPath -and ($sc.TargetPath -like '*.exe') -and (Test-Path -LiteralPath $sc.TargetPath)) {
            try {
                $spArgs = @{ FilePath = $sc.TargetPath }
                if ($sc.Arguments) { $spArgs['ArgumentList'] = $sc.Arguments }
                if ($sc.WorkingDirectory) {
                    if (Test-Path -LiteralPath $sc.WorkingDirectory) { $spArgs['WorkingDirectory'] = $sc.WorkingDirectory }
                }
                $lt0 = [Diagnostics.Stopwatch]::StartNew()
                Start-Process @spArgs | Out-Null
                Agent-Log ('launchpath lnk->exe: ' + $lp + ' -> ' + $sc.TargetPath + ' (' + $lt0.ElapsedMilliseconds + 'ms)')
                Write-Audit 'launch' ('path={0} via=lnk-exe ok=1 ms={1}' -f (Quote-Audit $lp), $lt0.ElapsedMilliseconds)
                $lnkDone = $true
            } catch {
                Agent-Log ('launchpath lnk->exe failed: ' + $_.Exception.Message + ', fallback explorer')
            }
        }
    }
    if ($lnkDone) {
        # 已经起了快捷方式的目标，不再走下面的 explorer 中转
    } elseif ($lp -and (Test-Path -LiteralPath $lp -PathType Container)) {
        # 目录单独一条分支：日志前缀写成 'launchpath dir'，从日志一眼能看出走的是目录还是 lnk。
        # 仍然用 explorer 中转（CreateProcess 立刻返回、父进程不是本代理）。
        # 回退只在 explorer 调用本身抛异常时做：单线程代理里绝不做"枚举窗口验证"那种重活。
        $lt = [Diagnostics.Stopwatch]::StartNew()
        try {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $lp + '"') | Out-Null
            Agent-Log ('launchpath dir: ' + $lp + ' (' + $lt.ElapsedMilliseconds + 'ms)')
            Write-Audit 'launch' ('path={0} via=dir ok=1 ms={1}' -f (Quote-Audit $lp), $lt.ElapsedMilliseconds)
        } catch {
            Agent-Log ('launchpath dir explorer failed: ' + $_.Exception.Message + ', fallback Start-Process')
            try {
                Start-Process -FilePath $lp | Out-Null
                Agent-Log ('launchpath dir direct: ' + $lp + ' (' + $lt.ElapsedMilliseconds + 'ms)')
                Write-Audit 'launch' ('path={0} via=dir ok=1 ms={1}' -f (Quote-Audit $lp), $lt.ElapsedMilliseconds)
            } catch {
                Agent-Log ('launchpath dir failed: ' + $lp + ' err=' + $_.Exception.Message)
                Write-Audit 'launch' ('path={0} via=dir ok=0 ms={1}' -f (Quote-Audit $lp), $lt.ElapsedMilliseconds)
            }
        }
    } elseif ($lp -and (Test-Path -LiteralPath $lp)) {
        # 交给 explorer 去启动，两个好处：
        #   1) CreateProcess 立刻返回，代理不再被 ShellExecute 的关联查找拖住；
        #   2) 目标的父进程变成 explorer 而不是本代理 —— 鹰角启动器这类会清理"可疑父进程"的
        #      程序就杀不到代理（20:28 拉起启动器后 20:29 代理就没了）。
        $lt = [Diagnostics.Stopwatch]::StartNew()
        try {
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $lp + '"') | Out-Null
            Agent-Log ('launchpath via explorer: ' + $lp + ' (' + $lt.ElapsedMilliseconds + 'ms)')
            Write-Audit 'launch' ('path={0} via=explorer ok=1 ms={1}' -f (Quote-Audit $lp), $lt.ElapsedMilliseconds)
        } catch {
            # explorer 中转失败就退回直连（老行为），至少保证还能启动
            Agent-Log ('launchpath explorer failed: ' + $_.Exception.Message + ', fallback direct')
            try {
                Start-Process -FilePath $lp | Out-Null
                Agent-Log ('launchpath: ' + $lp)
                Write-Audit 'launch' ('path={0} via=direct ok=1 ms={1}' -f (Quote-Audit $lp), $lt.ElapsedMilliseconds)
            } catch {
                Agent-Log ('launchpath failed: ' + $lp + ' err=' + $_.Exception.Message)
                Write-Audit 'launch' ('path={0} via=explorer ok=0 ms={1}' -f (Quote-Audit $lp), $lt.ElapsedMilliseconds)
            }
        }
    } else {
        Agent-Log ('launchpath missing: ' + $lp)
        Write-Audit 'launch' ('path={0} via=none ok=0' -f (Quote-Audit $lp))
    }
}

# 令牌清不掉时的日志限流（这条路由 40ms 一轮，不限流会一秒刷 25 行）
$script:reloadSkipAt = [long]0

function Invoke-ScrollJs($ctx, $query) {
    $sd = Take-Scroll
    $js = 'window.__DSH_SCROLL=' + [int]$sd + ';'
    # 热重载搭这条 40ms 通道的便车：/reload.gif 写了令牌，就让页面重插一次 dsh.js（软重载）。
    # 不走 location.reload()：Lively 的 WebView2 上导航会白屏（2026-11-06 两次实测，panel-rect 直接不再更新）。
    # 新页面暴露 window.__DSH_RELOAD_OK（清旧定时器 + 删旧面板 + 重插脚本）；老页面没这个钩子才退回 reload。
    # 注意：/state.js 的 reload 字段是**同一份令牌的第二个入口**（见 dsh.js 的 softReload），两条必须一致。
    # 2026-11-07：判据从「文件在不在」改成「令牌是不是有效数字」（Get-ReloadToken -gt 0），和 /state.js 同源。
    # 只看 Test-Path 有个致命分支：Remove-Item 被安全策略拦掉时下面会退化成「写空文件」，
    # 文件名于是长期存在 → 每 40ms 又下发一次软重载，页面无限重插 dsh.js（面板一直重建、CPU 飙升），
    # 而 /state.js 那条读到空值当 0、完全不报错，日志上也看不出异常（实测：空文件同样触发了软重载）。
    # 另一个顺序要求：先清令牌再下发。清不掉就这一轮不发，下一轮再试 —— 绝不带着没清掉的令牌下发。
    try {
        if ((Get-ReloadToken) -gt 0) {
            $cleared = $false
            Remove-Item -LiteralPath $reloadFile -Force -ErrorAction SilentlyContinue
            if (-not (Test-Path $reloadFile)) { $cleared = $true }
            else {
                # 安全策略拦 Remove-Item：退化成写空文件（Get-ReloadToken 读到空 → 0，等于已失效）
                try { [System.IO.File]::WriteAllText($reloadFile, '', (New-Object System.Text.UTF8Encoding($false))) } catch { }
                if ((Get-ReloadToken) -eq 0) { $cleared = $true }
            }
            if ($cleared) {
                $js += 'if(window.__DSH_RELOAD_OK){window.__DSH_RELOAD_OK()}else{setTimeout(function(){location.reload()},60)}'
                # /state.js 的 reload 有 500ms 缓存：这里顺手清掉，免得它半秒内把同一个令牌再下发一次
                Cache-Drop 'reload'
                Agent-Log 'scroll: page-reload emitted'
            }
            else {
                $n64 = [long]$script:clock.ElapsedMilliseconds
                if (($n64 - $script:reloadSkipAt) -gt 60000) {
                    $script:reloadSkipAt = $n64
                    Agent-Log 'scroll: reload token not cleared, skipped this round'
                }
            }
        }
    } catch { }
    Write-Raw $ctx ([Text.Encoding]::UTF8.GetBytes($js)) 'application/javascript'
}

function Invoke-ScrollGif($ctx, $query) {
    # 壁纸页拿不到真实滚轮事件（桌面窗口在壁纸前面），由抽屉程序转发滚动意图
    $d = 1
    if ($query.raw -match '[?&]d=(-?\d+)') { $d = [int]$matches[1] }
    try {
        $sol = Join-Path $appDir 'scroll.dat'
        # 写入方设上限（见 $script:SCROLL_MAX 的注释）：消费方停了就别无限追加。
        # 判尺寸是元数据查询（~0.1ms），不影响这条高频路由。
        $fi = Get-Item $sol -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt $script:SCROLL_MAX) { [System.IO.File]::WriteAllText($sol, '') }
        [System.IO.File]::AppendAllText($sol, "$d`r`n")
    } catch { }
    Write-Raw $ctx $gif 'image/gif'
}

# ---- GET /log.js ← window.__DSH_LOG（整段 dsh-run.log，页面自己切气泡） ----
function Invoke-LogJs($ctx, $query) {
    # /state.js 只给 sig（长度-mtime），正文走这条：sig 没变页面就不来拿。
    # 上限 60000 字符 ≈ 最近几十轮对话；采样正常时一条 60KB 的 JSONP 只要几毫秒。
    $txt = [string](Cache-Get 'log' 400 { Get-LogText 60000 })
    $js = 'window.__DSH_LOG="' + (Escape-Js $txt) + '";'
    Write-Raw $ctx ([Text.Encoding]::UTF8.GetBytes($js)) 'application/javascript'
}

# ---- GET /dbg.gif?m= ← 壁纸页调试信标（仅 dsh-debug.flag 存在时落 dsh-debug.log） ----
function Invoke-DbgGif($ctx, $query) {
    $m = ''
    if ($query.raw -match '[?&]m=([^&]*)') {
        try { $m = [System.Uri]::UnescapeDataString($matches[1]) } catch { $m = $matches[1] }
    }
    if ($m.Length -gt 400) { $m = $m.Substring(0, 400) }
    $m = $m -replace '[\r\n\t]', ' '
    try {
        if (Test-Path $dbgFlag) {
            $fi = Get-Item $dbgFile -ErrorAction SilentlyContinue
            if ($fi -and $fi.Length -gt 2097152) { [System.IO.File]::WriteAllText($dbgFile, '', (New-Object System.Text.UTF8Encoding($false))) }
            $line = (Get-Date).ToString('HH:mm:ss.fff') + ' ' + $m + "`r`n"
            [System.IO.File]::AppendAllText($dbgFile, $line, (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch { }
    Write-Raw $ctx $gif 'image/gif'
}

# ---- GET /reload.gif ← 写 page-reload.txt，壁纸页下一次 /scroll.js 时软重载（重插 dsh.js?hot=） ----
function Invoke-ReloadGif($ctx, $query) {
    try {
        [System.IO.File]::WriteAllText($reloadFile, [string][long]$script:clock.ElapsedMilliseconds, (New-Object System.Text.UTF8Encoding($false)))
        Agent-Log 'reload: token written'
    } catch { Agent-Log ('reload: failed ' + $_.Exception.Message) }
    Write-Raw $ctx $gif 'image/gif'
}

function Invoke-RectGif($ctx, $query) {
    $rx = 0; $ry = 0; $rw = 0; $rh = 0
    if ($query.raw -match '[?&]x=(-?\d+)') { $rx = [int]$matches[1] }
    if ($query.raw -match '[?&]y=(-?\d+)') { $ry = [int]$matches[1] }
    if ($query.raw -match '[?&]w=(-?\d+)') { $rw = [int]$matches[1] }
    if ($query.raw -match '[?&]h=(-?\d+)') { $rh = [int]$matches[1] }
    if ($rw -gt 200) {
        # 原子写（tmp + Move-Item 覆盖）：抽屉每 400ms 就来读这个文件（AHK 的 PanelRect()），
        # 直接 WriteAllText 是「先截断成 0 字节、再补齐」——撞上读取方就是「读到空/只有两个字段」，
        # PanelRect 于是掉进兜底矩形，滚轮落点错一次（用户感觉是「面板里忽然滚不动」）。
        # 改名替换不会出现「存在但为空」的中间态：读到的要么是旧值，要么是新值。
        # 改不动就这一轮不写（页面 4 秒后会再报一次，内容通常没变），绝不退回直写。
        $rt = $rectFile + '.tmp'
        try {
            [System.IO.File]::WriteAllText($rt, "$rx $ry $rw $rh", (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $rt -Destination $rectFile -Force
        } catch {
            try { [System.IO.File]::Delete($rt) } catch { }
            Agent-Log ('rect: atomic write skipped ' + $_.Exception.Message)
        }
    }
    Write-Raw $ctx $gif 'image/gif'
}

function Invoke-TodoGif($ctx, $query) {
    $op = ''
    $title = ''
    if ($query.raw -match '[?&]op=([^&]*)') { $op = $matches[1].ToLower() }
    if ($query.raw -match '[?&]t=([^&]*)') { $title = [System.Uri]::UnescapeDataString(($matches[1] -replace '\+', ' ')) }
    # 待办标题必须清洗（SEC-008）：%0A/%0D 能伪造出多条待办，而行首的 "x " 前缀
    # 会把别的条目标成已完成 —— 一律压成单行、限长 200。正文本身仍存在 todo.txt 里。
    if ($title) {
        $title = (($title -replace '[\r\n\t]', ' ') -replace '\s{2,}', ' ').Trim()
        if ($title.Length -gt 200) { $title = $title.Substring(0, 200) }
    }
    $items = @(Get-TodoItems)
    if ($op -eq 'add' -and $title) {
        $items += , @{ t = $title; d = $false }
    } elseif ($op -eq 'del' -and $title) {
        $items = @($items | Where-Object { $_.t -ne $title })
    } elseif ($op -eq 'toggle' -and $title) {
        foreach ($it in $items) { if ($it.t -eq $title) { $it.d = (-not $it.d) } }
    }
    Save-TodoItems $items
    Write-Raw $ctx $gif 'image/gif'
    # 待办正文只截 40 字：审计是排查用的，不是内容备份（正文在 todo.txt 里）
    if ($op -eq 'add' -or $op -eq 'del' -or $op -eq 'toggle') {
        $tv = ''
        if ($title) { $tv = $title; if ($tv.Length -gt 40) { $tv = $tv.Substring(0, 40) + [char]0x2026 } }
        Write-Audit 'todo' ('op={0} text={1}' -f $op, (Quote-Audit $tv))
    }
}

function Invoke-SummonGif($ctx, $query) {
    # 文件召唤：写 summon.cmd，抽屉 400ms 内轮询到就开合（不依赖键鼠钩子）
    $sd = 'show'
    if ($query.raw -match '[?&]d=([^&]*)') { if ($matches[1] -eq '1' -or $matches[1] -eq 'hide') { $sd = 'hide' } }
    # 原子写：SummonTick 是「读一次 → 无论读成什么都会删文件」的消费方（AHK 侧无法改动，
    # 本机也没法自动校验）。所以「文件存在但内容为空」必须不存在 —— 只要出现一次，
    # 那条命令就被静默吞掉（用户看到的是「点了没反应」，日志里什么也没有）。
    # 改名替换保证读到的一定是完整的一行；万一被读方占着句柄，隔 15ms 再试一次。
    $sf = Join-Path $appDir 'summon.cmd'
    $st = $sf + '.tmp'
    try {
        [System.IO.File]::WriteAllText($st, $sd, (New-Object System.Text.UTF8Encoding($false)))
        try { Move-Item -LiteralPath $st -Destination $sf -Force }
        catch { Start-Sleep -Milliseconds 15; Move-Item -LiteralPath $st -Destination $sf -Force }
        Agent-Log ('summon: ' + $sd)
    } catch {
        try { [System.IO.File]::Delete($st) } catch { }
        Agent-Log ('summon failed: ' + $_.Exception.Message)
    }
    Write-Raw $ctx $gif 'image/gif'
    Write-Audit 'summon' ('d=' + $sd)
}

function Invoke-RunGif($ctx, $query) {
    $text = Get-TextParam $query.req
    if ($text -and -not (Get-RunBusy)) { [void](Start-Run $text) }
    Write-Raw $ctx $gif 'image/gif'
    # 只记长度，不记指令正文：dsh-run.log 已经有原文，审计只负责"什么时候发过指令"
    if ($text) { Write-Audit 'dsh.run' ('chars={0}' -f $text.Length) }
}

function Invoke-LaunchGif($ctx, $query) {
    # 只在 DSH 完全没监听时启动；绝不 restart（dsh.cmd quiet 会先杀掉当前实例）
    try {
        if (Test-WebUp) {
            Agent-Log 'launch: skipped, DSH already listening'
        } elseif (Test-Path $dshCmd) {
            # dsh.cmd 是批处理，CreateProcess 不能直接执行 .cmd，得经 cmd.exe /c；
            # 用 Start-NoConsole 避免弹空控制台窗（-WindowStyle Hidden 对 WT 宿主无效）
            $null = Start-NoConsole 'cmd.exe' @('/c', ('"' + $dshCmd + '"'), 'quiet') $appDir
            Agent-Log 'launch: started dsh.cmd quiet'
        } else {
            Agent-Log "launch: dsh.cmd not found at $dshCmd"
        }
    } catch { Agent-Log ('launch: failed ' + $_.Exception.Message) }
    Write-Raw $ctx $gif 'image/gif'
}

function Invoke-OpenGif($ctx, $query) {
    Start-Process (Get-WebUrl) | Out-Null
    Write-Raw $ctx $gif 'image/gif'
}

function Invoke-DrawerGif($ctx, $query) {
    Start-Drawer
    Write-Raw $ctx $gif 'image/gif'
}

function Invoke-ClearGif($ctx, $query) {
    # 「清空」必须连错误文件一起清：否则清完会话，顶部还挂着上一轮的 ⚠ 报错
    try { [System.IO.File]::WriteAllText($logFile, '', (New-Object System.Text.UTF8Encoding($false))) } catch { }
    try { [System.IO.File]::WriteAllText($errFile, '', (New-Object System.Text.UTF8Encoding($false))) } catch { }
    foreach ($k in @('lines', 'sig', 'log', 'err')) { Cache-Drop $k }
    Write-Raw $ctx $gif 'image/gif'
}

function Invoke-AuditGif($ctx, $query) {
    # 壁纸页统一审计信标（file:// 页面不能 fetch/XHR，只能打 1x1 GIF）
    # 信标铁律：先回 GIF，再落盘 —— 写日志永远不会拖慢按钮的反馈。
    $ae = ''
    $ak = ''
    try {
        if ($query.raw -match '[?&]e=([^&]*)') { $ae = [System.Uri]::UnescapeDataString(($matches[1] -replace '\+', ' ')) }
        if ($query.raw -match '[?&]k=([^&]*)') { $ak = [System.Uri]::UnescapeDataString(($matches[1] -replace '\+', ' ')) }
    } catch { }
    Write-Raw $ctx $gif 'image/gif'
    # 参数限制：e ≤ 32 / k ≤ 200，并剥掉换行制表符 —— 否则一个 %0A 就能往审计里
    # 塞一行伪造的 [AHK ] / [API ] 记录，事后排查会被彻底带偏。
    # 事件名里再剃掉方括号：值不可信的时候，连"看起来像标签"都不许出现。
    $ae = (($ae -replace '[\r\n\t]', ' ') -replace '\s{2,}', ' ').Trim()
    $ak = (($ak -replace '[\r\n\t]', ' ') -replace '\s{2,}', ' ').Trim()
    $ae = $ae -replace '[\[\]]', ''
    # k 也要剃方括号：否则 k=2099-01-01 00:00:00.000 [AHK ] fake 会在审计里造出
    # 一行看着像 [AHK ] 的记录（[WEB ] 标签在行首，但人眼/正则都会被带偏）。
    $ak = $ak -replace '[\[\]]', ''
    if ($ae.Length -gt 32) { $ae = $ae.Substring(0, 32) }
    if ($ak.Length -gt 200) { $ak = $ak.Substring(0, 200) }
    if ($ae) { Write-Audit $ae $ak 'WEB' }
}

$script:ROUTES = @{
    '/state.js'       = @{ handler = 'Invoke-StateJs';    kind = 'state';      poll = $true;  audit = $false }
    '/state'          = @{ handler = 'Invoke-StateJs';    kind = 'state';      poll = $true;  audit = $false }
    '/log.js'         = @{ handler = 'Invoke-LogJs';      kind = 'log';        poll = $true;  audit = $false }
    '/media.js'       = @{ handler = 'Invoke-MediaJs';    kind = 'media';      poll = $true;  audit = $false }
    '/media.gif'      = @{ handler = 'Invoke-MediaGif';   kind = 'media';      poll = $false; audit = $false }
    '/dock.js'        = @{ handler = 'Invoke-DockJs';     kind = 'dock';       poll = $true;  audit = $false }
    '/dock.gif'       = @{ handler = 'Invoke-DockGif';    kind = 'dock';       poll = $true;  audit = $true }
    '/adddock.gif'    = @{ handler = 'Invoke-AddDock';    kind = 'dock';       poll = $false; audit = $true }
    '/launchpath.gif' = @{ handler = 'Invoke-LaunchPath'; kind = 'launchpath'; poll = $false; audit = $true }
    '/scroll.js'      = @{ handler = 'Invoke-ScrollJs';   kind = 'scroll';     poll = $true;  audit = $false }
    '/scroll.gif'     = @{ handler = 'Invoke-ScrollGif';  kind = 'scroll';     poll = $true;  audit = $false }
    '/rect.gif'       = @{ handler = 'Invoke-RectGif';    kind = 'rect';       poll = $true;  audit = $false }
    '/todo.gif'       = @{ handler = 'Invoke-TodoGif';    kind = 'todo';       poll = $false; audit = $true }
    '/summon.gif'     = @{ handler = 'Invoke-SummonGif';  kind = 'summon';     poll = $false; audit = $true }
    '/run.gif'        = @{ handler = 'Invoke-RunGif';     kind = 'run';        poll = $false; audit = $true }
    '/launch.gif'     = @{ handler = 'Invoke-LaunchGif';  kind = 'other';      poll = $false; audit = $true }
    '/open.gif'       = @{ handler = 'Invoke-OpenGif';    kind = 'other';      poll = $false; audit = $true }
    '/drawer.gif'     = @{ handler = 'Invoke-DrawerGif';  kind = 'other';      poll = $false; audit = $true }
    '/clear.gif'      = @{ handler = 'Invoke-ClearGif';   kind = 'clear';      poll = $false; audit = $true }
    '/reload.gif'     = @{ handler = 'Invoke-ReloadGif';  kind = 'other';      poll = $false; audit = $false }
    '/dbg.gif'        = @{ handler = 'Invoke-DbgGif';     kind = 'other';      poll = $true;  audit = $false }
    '/audit.gif'      = @{ handler = 'Invoke-AuditGif';   kind = 'other';      poll = $true;  audit = $true }
}
$script:ROUTES_PREFIX = @(
    @{ prefix = '/icon/'; handler = 'Invoke-IconPath'; kind = 'icon'; poll = $false; audit = $false }
)

# ===== 主循环 =====
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
# 端口可能被"正在退出的上一个实例"占着：重试 30 次×2s，而不是静默 exit 1
$started = $false
$err = ''
for ($i = 0; $i -lt 30; $i++) {
    try { $listener.Start(); $started = $true; break }
    catch {
        $err = $_.Exception.Message
        try { $listener.Close() } catch { }
        Start-Sleep -Seconds 2
        $listener = New-Object System.Net.HttpListener
        $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    }
}
if (-not $started) {
    Agent-Log "agent: listen failed on $Port after retries: $err"
    exit 1
}
Agent-Log "agent: listening on http://127.0.0.1:$Port/"

$lastHb = 0
$lastAlive = 0
while ($listener.IsListening) {
    # 心跳：每轮循环刷新 <!-- hb -->
    try {
        if (([Environment]::TickCount - $lastHb) -gt 800) {
            [System.IO.File]::WriteAllText($hbFile, ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')))
            $lastHb = [Environment]::TickCount
        }
    } catch { }
    # 5 分钟一条存活日志：事后能确认"代理活着且在工作"，而不只是进程还在
    try {
        if (([Environment]::TickCount - $lastAlive) -gt 300000) {
            Agent-Log ('agent: alive pid=' + $PID + ' port=' + $Port)
            $lastAlive = [Environment]::TickCount
        }
    } catch { }
    try {
        # 这里必须是"带超时的等待"，不能直接 GetContext()：
        # GetContext() 没有请求时会一直阻塞，心跳只在有请求时才刷新 →
        # 代理一空闲就被看门狗按 hb 过期判定成假死、每 50 秒被杀一次，
        # 用户就表现为"点应用卡住、提示等待队列"（2026-11-03 实测：hb 只随请求前进）
        $tWait = $listener.GetContextAsync()
        while (-not $tWait.AsyncWaitHandle.WaitOne(250)) {
            if (-not $listener.IsListening) { break }
            try {
                [System.IO.File]::WriteAllText($hbFile, ([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')))
                $lastHb = [Environment]::TickCount
            } catch { }
        }
        if (-not $tWait.IsCompleted) {
            if (-not $listener.IsListening) { break }
            continue
        }
        $ctx = $tWait.GetAwaiter().GetResult()
    } catch {
        # 客户端中途断开 / 连接异常时不要让整个代理退出
        if (-not $listener.IsListening) { break }
        Start-Sleep -Milliseconds 80
        continue
    }
    $req = $ctx.Request
    $path = $req.Url.AbsolutePath.ToLower()
    # 慢请求/非轮询请求都记一行：代理"假活"卡死时，最后一条日志就是卡住的入口
    $t0 = [Environment]::TickCount
    $script:stateTag = ''
    $script:missKeys = @()      # 每个请求独立统计（单线程，不会被别的请求串味）
    # 路由查表：精确表 O(1) → 前缀表（/icon/<file>）→ 都没有就是未知路径
    $route = $null
    if ($script:ROUTES.ContainsKey($path)) {
        $route = $script:ROUTES[$path]
    } else {
        foreach ($pr in $script:ROUTES_PREFIX) {
            if ($path.StartsWith($pr.prefix, [StringComparison]::Ordinal)) { $route = $pr; break }
        }
    }
    $pollPath = $false
    if ($route) { $pollPath = [bool]$route.poll }
    if (-not $pollPath) { Agent-Log ('req ' + $path) }

    try {
        if ($req.HttpMethod -eq 'OPTIONS') {
            $ctx.Response.StatusCode = 204
            $ctx.Response.Headers.Add('Access-Control-Allow-Origin', '*')
            $ctx.Response.Headers.Add('Access-Control-Allow-Headers', '*')
            $ctx.Response.Headers.Add('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
            $ctx.Response.OutputStream.Close()
            continue
        }
        # 主循环只做三件事：查表 → 调 handler → 未命中回 {"ok":false}。
        # 加接口只动 1020 行附近的路由表 + 一个 handler 函数，这里不用改。
        if ($route) {
            $query = New-QueryBag $req $path
            & $route.handler $ctx $query
        } else {
            Write-Raw $ctx ([System.Text.Encoding]::UTF8.GetBytes('{"ok":false}')) 'application/json'
        }
    } catch {
        try { Write-Raw $ctx ([System.Text.Encoding]::UTF8.GetBytes('{"ok":false}')) 'application/json' } catch { }
    }
    $ms = [Environment]::TickCount - $t0
    $doLog = ($ms -gt 800 -or -not $pollPath)
    if ($script:stateTag) {
        # 命中缓存后 /state.js 一般 5-40ms，永远进不了 >800ms 的条件，日志里就看不到它了。
        # 每 10 秒采一条样本（不刷屏），事后 grep 'cache=1' 就能确认缓存是否生效。
        $n64 = [long]$script:clock.ElapsedMilliseconds
        if (($n64 - $script:stateLogAt) -gt 10000) { $script:stateLogAt = $n64; $doLog = $true }
    }
    if ($doLog) { Agent-Log ('req done ' + $path + ' ' + $ms + 'ms' + $script:stateTag) }
    # 审计：动作类路由每请求一行（请求结束时写，含耗时）。白名单挂在路由表的 audit 字段上。
    if ($route -and $route.audit) {
        Write-Audit ('GET ' + $path) ('{0}ms ok route={1}' -f $ms, $route.kind)
    }
}

try { $listener.Stop() } catch { }
