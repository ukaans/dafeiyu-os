# Builds an icon cache + item list for the desktop "second page" drawer.
# Output: icons\*.png (96px), items.tsv (Name<TAB>Path<TAB>IconPng)
# 用法：
#   powershell -File Build-IconCache.ps1                 # 全量重建（扫描两个桌面）
#   powershell -File Build-IconCache.ps1 -AddPath "C:\x" # 追加单个文件/文件夹到抽屉

param(
    [string[]]$AddPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$iconDir = Join-Path $root 'icons'
$addMode = ($null -ne $AddPath -and $AddPath.Count -gt 0)
if (-not $addMode) {
    if (Test-Path $iconDir) { Remove-Item $iconDir -Recurse -Force }
}
New-Item -ItemType Directory -Force -Path $iconDir | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public static class ShellIcons
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [ComImport, Guid("46EB5926-582E-4017-9FDF-E8998DAA0950"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IImageList
    {
        int Add(IntPtr hbmImage, IntPtr hbmMask, out int pi);
        int ReplaceIcon(int i, IntPtr hicon, out int pi);
        int SetOverlayImage(int iImage, int iOverlay);
        int Replace(int i, IntPtr hbmImage, IntPtr hbmMask);
        int AddMasked(IntPtr hbmImage, uint crMask, out int pi);
        int Draw(IntPtr pimldp);
        int Remove(int i);
        int GetIcon(int i, uint flags, out IntPtr picon);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SHGetFileInfo(string pszPath, uint dwFileAttributes, ref SHFILEINFO psfi, uint cbFileInfo, uint uFlags);

    [DllImport("shell32.dll")]
    static extern int SHGetImageList(int iImageList, ref Guid riid, out IImageList ppv);

    [DllImport("user32.dll")]
    static extern bool DestroyIcon(IntPtr hIcon);

    const uint SHGFI_SYSICONINDEX = 0x000004000;
    const uint SHGFI_LARGEICON = 0x000000000;
    static Guid IID_IImageList = new Guid("46EB5926-582E-4017-9FDF-E8998DAA0950");

    public static Icon GetJumboIcon(string path)
    {
        SHFILEINFO sfi = new SHFILEINFO();
        IntPtr himl = SHGetFileInfo(path, 0, ref sfi, (uint)Marshal.SizeOf(typeof(SHFILEINFO)), SHGFI_SYSICONINDEX | SHGFI_LARGEICON);
        if (himl == IntPtr.Zero) return null;

        IImageList jumbo = null;
        Guid iid = IID_IImageList;
        // 0 = SHIL_LARGE, 1 = SHIL_SMALL, 2 = SHIL_EXTRALARGE, 4 = SHIL_JUMBO
        int hr = SHGetImageList(4, ref iid, out jumbo);
        if (hr != 0 || jumbo == null)
        {
            hr = SHGetImageList(2, ref iid, out jumbo);
            if (hr != 0 || jumbo == null) return null;
        }
        IntPtr hIcon;
        hr = jumbo.GetIcon(sfi.iIcon, 0x1 /*ILD_TRANSPARENT*/, out hIcon);
        if (hr != 0 || hIcon == IntPtr.Zero) return null;
        Icon ic = (Icon)Icon.FromHandle(hIcon).Clone();
        DestroyIcon(hIcon);
        Marshal.ReleaseComObject(jumbo);
        return ic;
    }

    public static Bitmap Render(Icon icon, int size)
    {
        Bitmap bmp = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.Clear(Color.Transparent);
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.HighQuality;
            g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
            using (Bitmap src = icon.ToBitmap())
            {
                g.DrawImage(src, new Rectangle(0, 0, size, size));
            }
        }
        return Normalize(bmp);
    }

    // 统一图标视觉尺寸：把 96px 画布里只占一小块的图标（Clash/CheatEngine/FinalShell 这类）
    // 按 alpha 外接框裁出来再等比放大到画布 78% 左右，避免"有的正常有的特别小"。
    public static Bitmap Normalize(Bitmap bmp)
    {
        int size = bmp.Width;
        int minX = size, minY = size, maxX = -1, maxY = -1;
        for (int y = 0; y < size; y++)
        {
            for (int x = 0; x < size; x++)
            {
                if (bmp.GetPixel(x, y).A >= 20)
                {
                    if (x < minX) minX = x;
                    if (x > maxX) maxX = x;
                    if (y < minY) minY = y;
                    if (y > maxY) maxY = y;
                }
            }
        }
        if (maxX < 0) return bmp;
        int w = maxX - minX + 1, h = maxY - minY + 1;
        int target = (int)(size * 0.78);
        if (w >= target && h >= target) return bmp;
        double k = Math.Min((double)target / w, (double)target / h);
        int nw = Math.Max(1, (int)Math.Round(w * k)), nh = Math.Max(1, (int)Math.Round(h * k));
        Bitmap outp = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (Graphics g = Graphics.FromImage(outp))
        {
            g.Clear(Color.Transparent);
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;
            g.DrawImage(bmp, new Rectangle((size - nw) / 2, (size - nh) / 2, nw, nh), new Rectangle(minX, minY, w, h), GraphicsUnit.Pixel);
        }
        bmp.Dispose();
        return outp;
    }
}
'@

# ---------------- 追加模式：把指定文件/文件夹加进抽屉 ----------------
if ($addMode) {
    $tsv = Join-Path $root 'items.tsv'
    $existing = @{}
    if (Test-Path $tsv) {
        foreach ($l in [System.IO.File]::ReadAllLines($tsv, [System.Text.Encoding]::UTF8)) {
            if ($l.Trim() -eq '') { continue }
            $p = $l.Split("`t")
            if ($p.Length -ge 2) { $existing[$p[1].ToLowerInvariant()] = $true }
        }
    }
    $added = 0
    foreach ($raw in $AddPath) {
        if (-not $raw) { continue }
        $full = $raw
        if (-not (Test-Path -LiteralPath $full)) { continue }
        try { $full = (Get-Item -LiteralPath $raw).FullName } catch { }
        if ($existing.ContainsKey($full.ToLowerInvariant())) { continue }
        $it = Get-Item -LiteralPath $full
        $isDir = $it.PSIsContainer
        $icon = $null
        try { $icon = [ShellIcons]::GetJumboIcon($full) } catch { }
        if (-not $icon) { try { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($full) } catch { } }
        if (-not $icon -and $isDir) { try { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\explorer.exe") } catch { } }
        if (-not $icon) { continue }
        $hash = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA1]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($full))
        ).Replace('-', '').Substring(0, 12).ToLowerInvariant()
        $png = Join-Path $iconDir "$hash.png"
        $bmp = [ShellIcons]::Render($icon, 96)
        $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose(); $icon.Dispose()
        $name = if ($isDir) { $it.Name } else { [System.IO.Path]::GetFileNameWithoutExtension($it.Name) }
        $kind = if ($isDir) { 'folder' } else { 'file' }
        $line = "{0}`t{1}`t{2}`t{3}" -f $name, $full, $png, $kind
        [System.IO.File]::AppendAllText($tsv, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        $existing[$full.ToLowerInvariant()] = $true
        $added++
    }
    "added: $added"
    exit 0
}

$sources = @(
  [Environment]::GetFolderPath('Desktop'),
  [Environment]::GetFolderPath('CommonDesktopDirectory')
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

$items = New-Object System.Collections.ArrayList
$seen = @{}
foreach ($dir in $sources) {
  foreach ($f in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
    if ($f.Name -like 'desktop.ini' -or $f.Name -in @('desktop.ini', '.DS_Store')) { continue }
    if ($f.Name -like '*.tmp') { continue }
    $key = $f.Name.ToLowerInvariant()
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true

    $isDir = $f.PSIsContainer
    $ext = $f.Extension.ToLowerInvariant()
    $path = $f.FullName

    $icon = $null
    try { $icon = [ShellIcons]::GetJumboIcon($path) } catch { }
    if (-not $icon) {
      try { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($path) } catch { }
    }
    if (-not $icon -and $isDir) {
      try { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon("$env:SystemRoot\explorer.exe") } catch { }
    }
    if (-not $icon) { continue }

    $hash = [System.BitConverter]::ToString(
      [System.Security.Cryptography.SHA1]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($path))
    ).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    $png = Join-Path $iconDir "$hash.png"
    $bmp = [ShellIcons]::Render($icon, 96)
    $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose(); $icon.Dispose()

    $name = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    if ($isDir) { $name = $f.Name }
    $kind = if ($isDir) { 'folder' } else { 'file' }
    [void]$items.Add([pscustomobject]@{ Name = $name; Path = $path; Icon = $png; Kind = $kind; Sort = ($(if ($isDir) { '0' } else { '1' }) + $name) })
  }
}

$items = $items | Sort-Object Sort
$lines = $items | ForEach-Object { "{0}`t{1}`t{2}`t{3}" -f $_.Name, $_.Path, $_.Icon, $_.Kind }
$tsv = Join-Path $root 'items.tsv'
[System.IO.File]::WriteAllLines($tsv, $lines, (New-Object System.Text.UTF8Encoding($false)))
"items: $($items.Count)"
