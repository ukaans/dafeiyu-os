param(
    [int]$Interval = 300
)
$mtx = New-Object System.Threading.Mutex($false, 'Global\DesktopPage_wxmon')
if (-not $mtx.WaitOne(0)) { exit 0 }
$pidFile = Join-Path $env:LOCALAPPDATA 'DesktopPage\wxmon.pid'
[System.IO.File]::WriteAllText($pidFile, "$PID")
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

# 壁纸目录解析顺序（与 dsh-agent.ps1、DesktopPage.ahk 的 FindWallpaperDir() 保持一致）：
#   1) 环境变量 DSH_WALLPAPER（手动覆盖）
#   2) Lively 的 WallpaperLayout.json 里「当前正应用」的那份 —— 唯一权威来源
#   3) Lively 库里含 dsh.js 的最新一份
#   4) 兜底 dsqq0001.ab1
# 不要写死目录名：install.ps1 允许装成任意名字，机器上也可能同时有多份副本。
function Resolve-WallpaperDir {
    $e = $env:DSH_WALLPAPER
    if ($e -and (Test-Path (Join-Path $e 'index.html'))) { return $e }
    $libBase = Join-Path $env:LOCALAPPDATA 'Lively Wallpaper'
    try {
        $lay = Join-Path $libBase 'WallpaperLayout.json'
        if (Test-Path $lay) {
            $j = [System.IO.File]::ReadAllText($lay, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($it in @($j)) {
                $p = [string]$it.LivelyInfoPath
                if ($p -and (Test-Path (Join-Path $p 'dsh.js'))) { return $p }
            }
        }
    } catch { }
    $best = ''
    $bestTs = [datetime]::MinValue
    try {
        $base = Join-Path $libBase 'Library\wallpapers'
        foreach ($d in (Get-ChildItem $base -Directory -ErrorAction Stop)) {
            if (-not (Test-Path (Join-Path $d.FullName 'dsh.js'))) { continue }
            if ($d.LastWriteTime -gt $bestTs) { $best = $d.FullName; $bestTs = $d.LastWriteTime }
        }
    } catch { }
    if (-not $best) { $best = Join-Path $libBase 'Library\wallpapers\dsqq0001.ab1' }
    return $best
}
$dir = Resolve-WallpaperDir
$outFile = Join-Path $dir 'wx-data.js'
$tmpFile = Join-Path $dir 'wx-data.tmp'

function Get-WmoText([int]$code) {
    switch ($code) {
        0  { '晴' }
        1  { '晴间多云' }
        2  { '多云' }
        3  { '阴' }
        45 { '有雾' }
        48 { '雾凇' }
        51 { '毛毛雨' }
        53 { '小雨夹雾' }
        55 { '细雨' }
        56 { '冻雨' }
        57 { '强冻雨' }
        61 { '小雨' }
        63 { '中雨' }
        65 { '大雨' }
        66 { '冻雨' }
        67 { '强冻雨' }
        71 { '小雪' }
        73 { '中雪' }
        75 { '大雪' }
        77 { '米雪' }
        80 { '阵雨' }
        81 { '强阵雨' }
        82 { '暴雨' }
        85 { '阵雪' }
        86 { '强阵雪' }
        95 { '雷阵雨' }
        96 { '雷阵雨伴冰雹' }
        99 { '强雷暴冰雹' }
        default { '未知' }
    }
}

function Get-Dress([double]$t) {
    if ($t -ge 30) { return '短袖 · 注意防晒' }
    if ($t -ge 26) { return '短袖 / 薄衫' }
    if ($t -ge 22) { return '长袖衬衫' }
    if ($t -ge 18) { return '薄外套' }
    if ($t -ge 14) { return '外套 + 长袖' }
    if ($t -ge 9)  { return '厚外套 / 毛衣' }
    if ($t -ge 3)  { return '大衣 / 加绒' }
    return '羽绒服'
}

function ConvertTo-JsString([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '\\', '\\\\' -replace "'", "\'" -replace "`r", ' ' -replace "`n", ' ')
}

# ---------------------------------------------------------------
# 位置解析（2026-11-14 修复）
# 原来只在进程启动时解析一次：换城市 / 挂代理 / 开机那一刻定位失败之后，
# 城市会一直停在启动时那个（失败时甚至是写死的「北京」），天气也跟着查错地方。
# 现在：多家 HTTPS 服务按顺序兜底 → 结果缓存到 wx-loc.json（带时间戳）
#      → 每 $LOC_TTL 秒重解析一次；全部失败就保留上次结果，绝不覆盖成北京。
# ---------------------------------------------------------------
$locFile = Join-Path $env:LOCALAPPDATA 'DesktopPage\wx-loc.json'
$wxLogFile = Join-Path $env:LOCALAPPDATA 'DesktopPage\wxmon.log'
$LOC_TTL = 900           # 位置多久重解析一次（秒）
$LOC_RETRY = 300         # 重解析失败后多久再试（秒）
$WIN_TIMEOUT = 8         # 等 Windows 定位结果的秒数
$DEFAULT_LOC = @{ city = '北京'; lat = 39.911; lon = 116.395; src = 'default' }

function Write-WxLog([string]$msg) {
    try {
        if ((Test-Path -LiteralPath $wxLogFile) -and ((Get-Item -LiteralPath $wxLogFile).Length -gt 256KB)) {
            Move-Item -LiteralPath $wxLogFile -Destination ($wxLogFile + '.1') -Force
        }
        $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + ' ' + $msg + "`r`n"
        [System.IO.File]::AppendAllText($wxLogFile, $line, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Get-IpLocJson([string]$url) {
    Invoke-RestMethod -TimeoutSec 12 -Uri $url -Headers @{ 'User-Agent' = 'DesktopPage/1.0' }
}

function Resolve-IpLoc {
    # 1) ipwho.is：HTTPS 免费、支持中文城市名、一次给全经纬度
    try {
        $r = Get-IpLocJson 'https://ipwho.is/?lang=zh-CN'
        if ($r.success -and $r.city -and $r.latitude -and $r.longitude) {
            return @{ city = [string]$r.city; lat = [double]$r.latitude; lon = [double]$r.longitude; src = 'ipwho.is' }
        }
    } catch { }
    # 2) ipinfo.io：英文城市名 + "lat,lon"
    try {
        $r = Get-IpLocJson 'https://ipinfo.io/json'
        if ($r.city -and $r.loc) {
            $xy = ([string]$r.loc) -split ','
            if ($xy.Count -eq 2) {
                return @{ city = [string]$r.city; lat = [double]$xy[0]; lon = [double]$xy[1]; src = 'ipinfo.io' }
            }
        }
    } catch { }
    # 3) ip-api.com 免费版只给 HTTP（HTTPS 会 403），最后兜底
    try {
        $r = Get-IpLocJson 'http://ip-api.com/json/?fields=status,city,regionName,lat,lon&lang=zh-CN'
        if ($r.status -eq 'success' -and $r.lat) {
            $c = ''
            if ($r.city) { $c = [string]$r.city }
            elseif ($r.regionName) { $c = [string]$r.regionName }
            if ($c) { return @{ city = $c; lat = [double]$r.lat; lon = [double]$r.lon; src = 'ip-api.com' } }
        }
    } catch { }
    return $null
}

function Get-WinLoc {
    # Windows 定位服务（GeoCoordinateWatcher）。比 IP 准得多（本机实测 2 秒出坐标、精度 76m），
    # 但它依赖两件事：①「设置 → 隐私 → 定位」开着；②「让桌面应用访问你的位置」= Allow
    #（本机 HKCU/HKLM 的 CapabilityAccessManager\ConsentStore\location 都是 Allow）。
    # 拿不到就返回 $null，由 IP 兜底 —— 绝不让一次失败把城市钉死在旧值上。
    try {
        if (-not ('System.Device.Location.GeoCoordinateWatcher' -as [type])) { Add-Type -AssemblyName System.Device }
        $w = New-Object System.Device.Location.GeoCoordinateWatcher
        $w.Start()
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $fix = $null
        while ($sw.Elapsed.TotalSeconds -lt $WIN_TIMEOUT) {
            $pos = $w.Position
            if ($pos -and $pos.Location -and -not $pos.Location.IsUnknown) { $fix = $pos.Location; break }
            Start-Sleep -Milliseconds 300
        }
        $perm = [string]$w.Permission
        $st = [string]$w.Status
        $w.Stop()
        if ($fix) {
            return @{ lat = [double]$fix.Latitude; lon = [double]$fix.Longitude; src = 'windows'; perm = $perm; status = $st }
        }
        Write-WxLog ('winloc: no fix (permission=' + $perm + ' status=' + $st + ')')
        return $null
    } catch {
        Write-WxLog ('winloc: failed ' + $_.Exception.Message)
        return $null
    }
}

function Get-CityFromLatLon([double]$la, [double]$lo) {
    # Windows 只给坐标；城市名要反向地理编码。用 OpenStreetMap Nominatim：免费、无 key，
    # 要求带 UA、≤1 次/秒 —— 我们最多 15 分钟一次，远低于限制。
    try {
        $u = "https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$la&lon=$lo&accept-language=zh-CN&zoom=10"
        $r = Invoke-RestMethod -TimeoutSec 12 -Uri $u -Headers @{ 'User-Agent' = 'DesktopPage/1.0 (desktop drawer weather)' }
        $city = ''
        # 中文结果里 address.city 常是「区」（天河区），真正的市藏在 display_name（…, 广州市, 广东省, …）
        if ($r.display_name) {
            foreach ($part in ([string]$r.display_name -split ',\s*')) {
                if ($part -match '市$') { $city = $part; break }
            }
        }
        if (-not $city -and $r.address) {
            foreach ($k in @('city', 'town', 'county', 'state')) {
                $v = $r.address.$k
                if ($v) { $city = [string]$v; break }
            }
        }
        if (-not $city -and $r.name) { $city = [string]$r.name }
        if ($city) { $city = $city -replace '市$', '' }
        return $city
    } catch {
        Write-WxLog ('reverse-geo failed: ' + $_.Exception.Message)
        return ''
    }
}

function Resolve-Loc {
    # 顺序：Windows 系统定位（准）→ IP 定位（兜底）。两边都失败返回 $null，调用方保留旧值。
    $w = Get-WinLoc
    if ($w) {
        $c = Get-CityFromLatLon $w.lat $w.lon
        if ($c) { return @{ city = $c; lat = $w.lat; lon = $w.lon; src = 'windows+nominatim' } }
        Write-WxLog 'winloc: got fix but reverse-geo gave no city, fallback to IP'
    }
    return Resolve-IpLoc
}
function Save-Loc($l) {
    try {
        $o = [ordered]@{
            ts   = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            city = $l.city; lat = $l.lat; lon = $l.lon; src = $l.src
        }
        [System.IO.File]::WriteAllText($locFile, (ConvertTo-Json $o -Compress), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Load-Loc {
    try {
        if (-not (Test-Path -LiteralPath $locFile)) { return $null }
        $o = [System.IO.File]::ReadAllText($locFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if (-not $o.city -or -not $o.lat -or -not $o.lon) { return $null }
        $age = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$o.ts
        # 太旧（超过 2 个周期）就当没有：宁可重解析，也不拿半年前的缓存当年底
        if ($age -lt 0 -or $age -gt ($LOC_TTL * 2)) { return $null }
        return @{ city = [string]$o.city; lat = [double]$o.lat; lon = [double]$o.lon; src = [string]$o.src }
    } catch { return $null }
}

function Get-WeatherUrl($l) {
    "https://api.open-meteo.com/v1/forecast?latitude=$($l.lat)&longitude=$($l.lon)" +
        "&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code" +
        "&daily=precipitation_probability_max,temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=Asia%2FShanghai"
}

$loc = Resolve-Loc
$locAt = [DateTime]::UtcNow
if (-not $loc) {
    $loc = Load-Loc
    if ($loc) { Write-WxLog ('loc: resolve failed at startup, using cache ' + $loc.city) }
}
if (-not $loc) {
    $loc = $DEFAULT_LOC
    $locAt = [DateTime]::MinValue      # 立刻在下一轮重试
    Write-WxLog 'loc: resolve failed at startup, using default; will retry'
} else {
    Save-Loc $loc
    Write-WxLog ('loc: ' + $loc.city + ' (' + $loc.lat + ',' + $loc.lon + ') via ' + $loc.src)
}
$city = $loc.city
$weatherUrl = Get-WeatherUrl $loc

$lastOk = $null
# 启动时从上一份 wx-data.js 播种 lastOk（2026-11-13 实测教训）：
#   天气源不可达 + 进程刚重启时，lastOk 是空 → 失败分支没东西可写，
#   每一轮都静默跳过，wx-data.js 冻结在重启前的旧值上（那次冻了 35 小时）。
#   播种后失败分支照旧工作：每轮只刷新 ts、正文原样重写，upd 保持诚实（显示最后取到数据的时刻）。
#   只认自己生成的格式（头注释 + window.__WX = {），防止把别人写坏的内容当数据循环放大。
try {
    if ((Test-Path -LiteralPath $outFile) -and ((Get-Item -LiteralPath $outFile).Length -gt 0)) {
        $seed = [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8)
        if ($seed -match '(?s)/\* generated by wxmon\.ps1 \*/\s*window\.__WX = \{') { $lastOk = $seed }
    }
} catch { }

while ($true) {
    # 到点重解析位置：换城市 / 挂代理 之后不用重启进程也能跟上；失败保留上次结果
    if (([DateTime]::UtcNow - $locAt).TotalSeconds -gt $LOC_TTL) {
        $nl = Resolve-Loc
        if ($nl) {
            if ($nl.city -ne $loc.city) { Write-WxLog ('loc: ' + $loc.city + ' -> ' + $nl.city + ' via ' + $nl.src) }
            $loc = $nl
            Save-Loc $loc
            $locAt = [DateTime]::UtcNow
        } else {
            $locAt = [DateTime]::UtcNow.AddSeconds($LOC_TTL - $LOC_RETRY)
            Write-WxLog ('loc: resolve failed, keep ' + $loc.city)
        }
        $city = $loc.city
        $weatherUrl = Get-WeatherUrl $loc
    }

    $js = $null
    try {
        $w = Invoke-RestMethod -TimeoutSec 20 -Uri $weatherUrl
        $cur = $w.current
        $day = $w.daily
        $temp = [math]::Round([double]$cur.temperature_2m, 1)
        $feels = [math]::Round([double]$cur.apparent_temperature, 1)
        $hum = [int]$cur.relative_humidity_2m
        $code = [int]$cur.weather_code
        $cond = Get-WmoText $code
        $rain = 0
        if ($day -and $day.precipitation_probability_max) { $rain = [int]$day.precipitation_probability_max[0] }
        $tmin = $temp
        $tmax = $temp
        if ($day -and $day.temperature_2m_min) { $tmin = [math]::Round([double]$day.temperature_2m_min[0], 1) }
        if ($day -and $day.temperature_2m_max) { $tmax = [math]::Round([double]$day.temperature_2m_max[0], 1) }
        $dress = Get-Dress $feels
        $upd = (Get-Date).ToString('HH:mm')
        $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

        $js = "/* generated by wxmon.ps1 */`n" +
            "window.__WX = { ts: $ts, city: '$(ConvertTo-JsString $city)', temp: $temp, feels: $feels, hum: $hum, rain: $rain, cond: '$(ConvertTo-JsString $cond)', dress: '$(ConvertTo-JsString $dress)', tmin: $tmin, tmax: $tmax, upd: '$upd' };`n"
        $lastOk = $js
    } catch {
        # 取不到就用上次的数据重写一遍（保证 ts 变化，壁纸不会卡在旧值上）
        if ($lastOk) {
            $js = $lastOk -replace 'ts: \d+', ('ts: ' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
        }
    }

    if ($js) {
        try {
            [System.IO.File]::WriteAllText($tmpFile, $js, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tmpFile -Destination $outFile -Force
        } catch { }
    }

    Start-Sleep -Seconds $Interval
}
