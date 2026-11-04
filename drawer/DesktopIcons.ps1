param(
    [ValidateSet('hide', 'show', 'toggle', 'query')]
    [string]$Mode = 'hide'
)

$ErrorActionPreference = 'Stop'

Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class DeskIcons {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowEx(IntPtr p, IntPtr c, string cls, string name);

    public static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }

    public static IntPtr Progman() {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            if (Cls(h) == "Progman") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // returns the SHELLDLL_DefView window (parent of the desktop icon list)
    public static IntPtr DefView(IntPtr progman) {
        IntPtr dv = FindWindowEx(progman, IntPtr.Zero, "SHELLDLL_DefView", null);
        if (dv != IntPtr.Zero) return dv;
        IntPtr worker = IntPtr.Zero;
        while ((worker = FindWindowEx(IntPtr.Zero, worker, "WorkerW", null)) != IntPtr.Zero) {
            dv = FindWindowEx(worker, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (dv != IntPtr.Zero) return dv;
        }
        return IntPtr.Zero;
    }

    public static IntPtr IconList(IntPtr defView) {
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(defView, (h, l) => {
            if (Cls(h) == "SysListView32") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static bool IconsVisible(IntPtr defView) {
        IntPtr lv = IconList(defView);
        if (lv == IntPtr.Zero) return true;
        return IsWindowVisible(lv);
    }

    public static bool Toggle(IntPtr defView) {
        return PostMessage(defView, 0x111, (IntPtr)0x7402, IntPtr.Zero);
    }
}
'@

$progman = [DeskIcons]::Progman()
if ($progman -eq [IntPtr]::Zero) { Write-Output 'error: progman not found'; exit 2 }
$defView = [DeskIcons]::DefView($progman)
if ($defView -eq [IntPtr]::Zero) { Write-Output 'error: defview not found'; exit 3 }

$visible = [DeskIcons]::IconsVisible($defView)

switch ($Mode) {
    'query' { if ($visible) { Write-Output 'shown' } else { Write-Output 'hidden' }; exit 0 }
    'hide'  { if ($visible) { [void][DeskIcons]::Toggle($defView); Start-Sleep -Milliseconds 250 } }
    'show'  { if (-not $visible) { [void][DeskIcons]::Toggle($defView); Start-Sleep -Milliseconds 250 } }
    'toggle' { [void][DeskIcons]::Toggle($defView); Start-Sleep -Milliseconds 250 }
}

$now = [DeskIcons]::IconsVisible($defView)
if ($now) { Write-Output 'shown' } else { Write-Output 'hidden' }
