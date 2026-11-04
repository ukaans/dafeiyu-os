# 大肥鱼桌面系统 · 滚轮桥（wheel-bridge.ps1）
# ---------------------------------------------------------------------------
# 它解决的问题（2026-11-04 深夜实测）：
#   本机的 AutoHotkey 进程会周期性地收不到鼠标输入 —— `$WheelDown` 一次都不触发、
#   `OnMessage(0x00FF)` 的 WM_INPUT 也一条都没有，而同机的普通 .NET 进程能稳定收到
#   （Raw Input usButtonFlags=0x400 delta=-120 + WH_MOUSE_LL 回调都在）。
#   一旦 AHK 的鼠标通道哑掉，滚轮唤起抽屉就整条链路失效，只能靠 Ctrl+Alt+Space。
#
# 为什么用 PowerShell 而不是编译成 exe：
#   同一份 C# 代码，在被 PowerShell 托管的进程里能收到滚轮/按键事件；
#   编译成独立 exe 后（无论用 explorer / cmd start /b / Start-Process 启动）
#   一条都收不到（2026-11-04 23:44–23:50 三组对照，见 docs 的项目日志）。
#   所以这里用 powershell.exe 承载，而不是 csc 出来的 exe。
#
# 行为：
#   1) 建隐藏窗口 + 装 WH_MOUSE_LL（必须"有窗口 + 窗口消息循环"，实测可行）
#   2) 只认 WM_MOUSEWHEEL；带 LLMHF_INJECTED 标志的合成事件一律丢弃
#      （否则抽屉自己 WheelPassThrough 的 Send("{WheelDown}") 会被当成召唤信号，死循环）
#   3) delta<0（滚轮向下）→ PostMessage(抽屉窗口, 0x8001, 1, 0)
#      delta>0（滚轮向上）→ PostMessage(抽屉窗口, 0x8001, 2, 0)
#   4) 抽屉窗口句柄从 wheel-bridge.hwnd 读（每 2 秒重读，IsWindow 校验）
#   5) 每 55 秒写心跳；180 秒没有回调而系统最近有输入 → 摘钩重装（抗钩子被摘）
#   6) 日志 wheel-bridge.log，256KB 两代轮转；单实例（互斥体）
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSCommandPath
if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = (Get-Location).Path }

$cs = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class DshWheelBridge
{
    const int WH_MOUSE_LL = 14;
    const int WM_MOUSEWHEEL = 0x020A;
    const int WM_TIMER = 0x0113;
    const uint LLMHF_INJECTED = 0x00000001;
    const uint WM_BRIDGE_WHEEL = 0x8001;
    const int LOG_MAX = 262144;

    [StructLayout(LayoutKind.Sequential)]
    public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int pt_x; public int pt_y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct WNDCLASSEX { public uint cbSize, style; public IntPtr lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground, lpszMenuName, lpszClassName, hIconSm; }

    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO { public uint cbSize, dwTime; }

    public delegate IntPtr WndProcDelegate(IntPtr h, uint m, IntPtr w, IntPtr l);
    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern ushort RegisterClassExW(ref WNDCLASSEX wc);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
    [DllImport("user32.dll")] static extern IntPtr DefWindowProcW(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessageW(out MSG m, IntPtr h, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessageW(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr SetTimer(IntPtr h, IntPtr id, uint ms, IntPtr fn);
    [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO li);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookExW(int id, HookProc proc, IntPtr hmod, uint tid);
    [DllImport("user32.dll", SetLastError = true)] static extern bool UnhookWindowsHookEx(IntPtr hk);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandleW(string name);
    [DllImport("kernel32.dll")] static extern uint GetTickCount();

    static WndProcDelegate _wndProc;
    static HookProc _hookProc;
    static IntPtr _hook = IntPtr.Zero;
    static IntPtr _target = IntPtr.Zero;
    static IntPtr _win = IntPtr.Zero;
    static string _logPath, _hwndPath, _id = "", _dir;
    static long _hits, _posts, _failPost, _rearms;
    static DateTime _lastEvent = DateTime.MinValue, _lastBeat = DateTime.MinValue, _lastRead = DateTime.MinValue;

    public static void Log(string s)
    {
        try
        {
            if (File.Exists(_logPath) && new FileInfo(_logPath).Length > LOG_MAX)
            {
                File.Copy(_logPath, _logPath + ".1", true);   // .NET 4.0 没有 File.Move(overwrite)
                File.WriteAllText(_logPath, string.Empty);
            }
            File.AppendAllText(_logPath, DateTime.Now.ToString("MM-dd HH:mm:ss.fff") + " " + s + Environment.NewLine, new UTF8Encoding(false));
        }
        catch { }
    }

    static void ReadTarget()
    {
        _lastRead = DateTime.Now;
        try
        {
            if (!File.Exists(_hwndPath)) return;
            string s = File.ReadAllText(_hwndPath).Trim();
            if (s.Length == 0) return;
            IntPtr h = new IntPtr(long.Parse(s));
            if (h != _target && IsWindow(h)) { _target = h; Log("target: drawer hwnd=" + h); }
        }
        catch { }
    }

    static void PostWheel(int dir, string via)
    {
        if (DateTime.Now - _lastRead > TimeSpan.FromSeconds(2)) ReadTarget();
        if (_target != IntPtr.Zero && IsWindow(_target) &&
            PostMessageW(_target, WM_BRIDGE_WHEEL, new IntPtr(dir), IntPtr.Zero))
        {
            _posts++;
        }
        else
        {
            _failPost++;
            Log("post FAILED dir=" + dir + " via=" + via + " target=" + _target);
        }
    }

    static IntPtr HookCB(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode == 0)
        {
            _hits++;
            _lastEvent = DateTime.Now;
            if ((int)wParam == WM_MOUSEWHEEL)
            {
                int mouseData = Marshal.ReadInt32(lParam, 8);   // MSLLHOOKSTRUCT.mouseData
                int flags = Marshal.ReadInt32(lParam, 12);      // .flags
                int delta = (short)((mouseData >> 16) & 0xFFFF);
                if ((flags & LLMHF_INJECTED) == 0 && delta != 0)
                    PostWheel(delta < 0 ? 1 : 2, "hook");
            }
        }
        return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }

    static IntPtr Proc(IntPtr h, uint msg, IntPtr w, IntPtr l)
    {
        if (msg == WM_TIMER) { Housekeeping(); return IntPtr.Zero; }
        return DefWindowProcW(h, msg, w, l);
    }

    static void InstallHook()
    {
        _hookProc = new HookProc(HookCB);
        _hook = SetWindowsHookExW(WH_MOUSE_LL, _hookProc, GetModuleHandleW(null), 0);
        if (_hook == IntPtr.Zero) Log("hook: install FAILED err=" + Marshal.GetLastWin32Error());
    }

    static void RearmHook()
    {
        _rearms++;
        if (_hook != IntPtr.Zero) { try { UnhookWindowsHookEx(_hook); } catch { } _hook = IntPtr.Zero; }
        InstallHook();
        Log("hook: rearmed x" + _rearms + " ok=" + (_hook != IntPtr.Zero));
    }

    static bool RecentInput(int ms)
    {
        LASTINPUTINFO li = new LASTINPUTINFO();
        li.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref li)) return false;
        return (GetTickCount() - li.dwTime) < (uint)ms;
    }

    static void Housekeeping()
    {
        if (DateTime.Now - _lastBeat < TimeSpan.FromSeconds(55)) return;
        _lastBeat = DateTime.Now;
        double quiet = (_lastEvent == DateTime.MinValue)
            ? (_lastBeat - _started).TotalSeconds
            : (DateTime.Now - _lastEvent).TotalSeconds;
        Log("beat hits=" + _hits + " posts=" + _posts + " failpost=" + _failPost + " quiet=" + (int)quiet + "s target=" + _target);
        if (quiet > 180 && RecentInput(2000)) RearmHook();
    }

    static DateTime _started;

    public static int Run(string dir, string idSuffix)
    {
        _dir = dir; _id = idSuffix ?? "";
        _logPath = Path.Combine(_dir, "wheel-bridge" + _id + ".log");
        _hwndPath = Path.Combine(_dir, "wheel-bridge.hwnd");
        bool created;
        using (var mutex = new Mutex(true, @"Local\DshWheelBridge" + _id, out created))
        {
            if (!created) { Log("start: another instance running, exit"); return 0; }
            _started = DateTime.Now;
            _lastBeat = _started;

            string cls = "DshWheelBridgeWnd" + _id;
            _wndProc = new WndProcDelegate(Proc);
            WNDCLASSEX wc = new WNDCLASSEX();
            wc.cbSize = (uint)Marshal.SizeOf(typeof(WNDCLASSEX));
            wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProc);
            wc.hInstance = GetModuleHandleW(null);
            wc.lpszClassName = Marshal.StringToHGlobalUni(cls);
            ushort atom = RegisterClassExW(ref wc);
            _win = CreateWindowExW(0, cls, "DshWheelBridge", 0x80000000, 0, 0, 0, 0,
                                   IntPtr.Zero, IntPtr.Zero, wc.hInstance, IntPtr.Zero);
            ReadTarget();
            InstallHook();
            Log("start: pid=" + System.Diagnostics.Process.GetCurrentProcess().Id +
                " host=" + System.Diagnostics.Process.GetCurrentProcess().ProcessName +
                " atom=" + atom + " win=" + _win + " hook=" + (_hook != IntPtr.Zero) + " target=" + _target);
            SetTimer(_win, new IntPtr(1), 5000, IntPtr.Zero);
            MSG m;
            int r;
            while ((r = GetMessageW(out m, IntPtr.Zero, 0, 0)) > 0)
            {
                TranslateMessage(ref m);
                DispatchMessageW(ref m);
            }
            Log("exit: loop ended r=" + r);
            return 0;
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $cs -Language CSharp | Out-Null
} catch {
    # 已加载过同名类型时忽略
    if ($_.Exception.Message -notmatch 'already exists') { throw }
}

[void][DshWheelBridge]::Run($scriptDir, '')
