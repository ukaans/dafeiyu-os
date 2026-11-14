param([string]$Out = "$env:LOCALAPPDATA\DesktopPage\desktop_positions.tsv")

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class DesktopLayout
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct LVITEMW
    {
        public uint mask;
        public int iItem;
        public int iSubItem;
        public uint state;
        public uint stateMask;
        public IntPtr pszText;
        public int cchTextMax;
        public int iImage;
        public IntPtr lParam;
        public int iIndent;
        public int iGroupId;
        public uint cColumns;
        public IntPtr puColumns;
        public IntPtr piColFmt;
        public int iGroup;
    }

    const int LVM_FIRST = 0x1000;
    const int LVM_GETITEMCOUNT = LVM_FIRST + 4;
    const int LVM_GETITEMPOSITION = LVM_FIRST + 16;
    const int LVM_GETITEMTEXTW = LVM_FIRST + 115;

    delegate bool EnumProc(IntPtr h, IntPtr l);

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, IntPtr l);

    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern IntPtr VirtualAllocEx(IntPtr p, IntPtr addr, IntPtr size, int type, int prot);
    [DllImport("kernel32.dll")] static extern bool VirtualFreeEx(IntPtr p, IntPtr addr, IntPtr size, int type);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr p, IntPtr addr, byte[] buf, IntPtr size, out IntPtr read);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr p, IntPtr addr, byte[] buf, IntPtr size, out IntPtr written);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out int pid);

    static IntPtr FindList()
    {
        IntPtr prog = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            var sb = new StringBuilder(64);
            GetClassName(h, sb, 64);
            if (sb.ToString() == "Progman") { prog = h; return false; }
            return true;
        }, IntPtr.Zero);

        if (prog != IntPtr.Zero)
        {
            IntPtr defView = FindWindowEx(prog, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (defView != IntPtr.Zero)
            {
                IntPtr lv = FindWindowEx(defView, IntPtr.Zero, "SysListView32", null);
                if (lv != IntPtr.Zero) return lv;
            }
        }

        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            IntPtr defView = FindWindowEx(h, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (defView != IntPtr.Zero)
            {
                IntPtr lv = FindWindowEx(defView, IntPtr.Zero, "SysListView32", null);
                if (lv != IntPtr.Zero) { found = lv; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static string Dump()
    {
        IntPtr lv = FindList();
        if (lv == IntPtr.Zero) return "error: listview not found";

        int pid;
        GetWindowThreadProcessId(lv, out pid);
        IntPtr proc = OpenProcess(0x8 | 0x10 | 0x20, false, pid);
        if (proc == IntPtr.Zero) return "error: openprocess failed";

        IntPtr buf = VirtualAllocEx(proc, IntPtr.Zero, new IntPtr(8192), 0x1000 | 0x2000, 0x04);
        if (buf == IntPtr.Zero) { CloseHandle(proc); return "error: virtualallocex failed"; }

        var sb = new StringBuilder();
        try
        {
            int count = (int)SendMessage(lv, LVM_GETITEMCOUNT, IntPtr.Zero, IntPtr.Zero);
            IntPtr itemAddr = new IntPtr(buf.ToInt64() + 0x800);
            IntPtr textAddr = new IntPtr(buf.ToInt64() + 0x100);
            IntPtr ptAddr = new IntPtr(buf.ToInt64() + 0x400);

            for (int i = 0; i < count; i++)
            {
                var item = new LVITEMW();
                item.mask = 0x1;
                item.iItem = i;
                item.iSubItem = 0;
                item.pszText = textAddr;
                item.cchTextMax = 260;

                byte[] raw = new byte[Marshal.SizeOf(typeof(LVITEMW))];
                IntPtr ptr = Marshal.AllocHGlobal(raw.Length);
                Marshal.StructureToPtr(item, ptr, false);
                Marshal.Copy(ptr, raw, 0, raw.Length);
                Marshal.FreeHGlobal(ptr);

                IntPtr wr;
                byte[] zero = new byte[520];
                WriteProcessMemory(proc, textAddr, zero, new IntPtr(520), out wr);
                WriteProcessMemory(proc, itemAddr, raw, new IntPtr(raw.Length), out wr);
                SendMessage(lv, LVM_GETITEMTEXTW, new IntPtr(i), itemAddr);

                byte[] tb = new byte[520];
                IntPtr rd;
                ReadProcessMemory(proc, textAddr, tb, new IntPtr(520), out rd);
                string text = Encoding.Unicode.GetString(tb);
                int z = text.IndexOf('\0');
                if (z >= 0) text = text.Substring(0, z);

                SendMessage(lv, LVM_GETITEMPOSITION, new IntPtr(i), ptAddr);
                byte[] pb = new byte[8];
                ReadProcessMemory(proc, ptAddr, pb, new IntPtr(8), out rd);
                int x = BitConverter.ToInt32(pb, 0);
                int y = BitConverter.ToInt32(pb, 4);

                sb.Append(text).Append('\t').Append(x).Append('\t').Append(y).Append("\r\n");
            }
        }
        finally
        {
            VirtualFreeEx(proc, buf, IntPtr.Zero, 0x8000);
            CloseHandle(proc);
        }
        return sb.ToString();
    }
}
'@

$text = [DesktopLayout]::Dump()
if ($text -like 'error:*') {
    Write-Output $text
    exit 1
}

# 把「桌面显示名」解析成真实路径，供 AHK 按路径匹配（避免显示名与 items.tsv 名称不一致）
$map = @{}
foreach ($base in @([Environment]::GetFolderPath('Desktop'), 'C:\Users\Public\Desktop')) {
    if (-not $base -or -not (Test-Path $base)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $base -Force -ErrorAction SilentlyContinue)) {
        $full = $f.FullName
        $map[$f.Name] = $full
        $map[$f.BaseName] = $full
        $short = ($f.BaseName -replace '\s*-\s*快捷方式$', '')
        $map[$short] = $full
        $map[$short + $f.Extension] = $full
    }
}

$sb = New-Object System.Text.StringBuilder
foreach ($line in ($text -split "`n")) {
    $l = $line.TrimEnd("`r")
    if ($l.Trim() -eq '') { continue }
    $parts = $l -split "`t"
    if ($parts.Count -lt 3) { continue }
    $name = $parts[0]
    $p = $null
    if ($map.ContainsKey($name)) { $p = $map[$name] }
    elseif ($map.ContainsKey($name + '.lnk')) { $p = $map[$name + '.lnk'] }
    elseif ($map.ContainsKey($name + '.url')) { $p = $map[$name + '.url'] }
    if (-not $p) { continue }
    [void]$sb.Append($p).Append("`t").Append($parts[1]).Append("`t").Append($parts[2]).Append("`r`n")
}
$text = $sb.ToString()
$n = ($text -split "`n" | Where-Object { $_.Trim() -ne "" }).Count
$dir = Split-Path -Parent $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
# 2026-11-14 13:04 事故：图标当时是隐藏的，枚举回来 0 行，这里照样整文件覆盖 →
# desktop_positions.tsv 变成 0 字节，抽屉失去"原始桌面"落位，113 条集体回网格重排。
# 现在先写临时文件，只有真抓到坐标才替换；0 行就保留旧文件，让调用方继续用旧 dpos。
$tmp = "$Out.tmp-$PID"
[System.IO.File]::WriteAllText($tmp, $text, (New-Object System.Text.UTF8Encoding($false)))
if ($n -lt 1) {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Write-Output "positions: 0 (kept existing $Out)"
    exit 4
}
Move-Item -LiteralPath $tmp -Destination $Out -Force
Write-Output "positions: $n -> $Out"
