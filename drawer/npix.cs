using System;
using System.Drawing;
using System.Runtime.InteropServices;

// 网易云控制条像素定位：DPI 感知进程，输出相对窗口的比例坐标，供 dsh-agent 使用
public class Npix {
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }

    static bool IsRed(Color c) { return c.R > 200 && c.G < 120 && c.B < 140; }
    static bool IsWhite(Color c) { return c.R > 205 && c.G > 205 && c.B > 205; }

    // report: 取窗口区域截图 -> "rect=WxH bar=<yFraction> btn=<xFraction>,<yFraction>"
    static string Report(IntPtr hwnd) {
        RECT r;
        if (!GetWindowRect(hwnd, out r)) return "no-rect";
        int w = r.R - r.L, hh = r.B - r.T;
        if (w < 200 || hh < 200) return "tiny-window";
        using (var bmp = new Bitmap(w, hh))
        using (var g = Graphics.FromImage(bmp)) {
            g.CopyFromScreen(r.L, r.T, 0, 0, bmp.Size);
            int barY = -1, barRun = 0;
            for (int y = (int)(hh * 0.84); y < (int)(hh * 0.97); y++) {
                int best = 0, cur = 0, gap = 0, curStart = 0, bestStart = -1;
                for (int x = 0; x < w; x++) {
                    if (IsRed(bmp.GetPixel(x, y))) { if (cur == 0) curStart = x; cur++; gap = 0; }
                    else { gap++; if (gap > 6) { if (cur > best) { best = cur; bestStart = curStart; } cur = 0; } }
                }
                if (cur > best) { best = cur; bestStart = curStart; }
                // 进度条从窗口最左侧开始；中途的爱心等红色块 start 偏右，用它排除
                if (bestStart >= 0 && bestStart < w * 0.06 && best > barRun) { barRun = best; barY = y; }
            }
            // 播放键：底部中间区域的红色圆块
            int bx0 = -1, bx1 = -1, by0 = -1, by1 = -1, cnt = 0;
            for (int y = (int)(hh * 0.93); y < hh; y++) {
                for (int x = (int)(w * 0.40); x < (int)(w * 0.60); x++) {
                    if (!IsRed(bmp.GetPixel(x, y))) continue;
                    cnt++;
                    if (bx0 < 0 || x < bx0) bx0 = x;
                    if (x > bx1) bx1 = x;
                    if (by0 < 0 || y < by0) by0 = y;
                    if (y > by1) by1 = y;
                }
            }
            string bs = "none";
            if (cnt > 150) {
                double fx = (double)(bx0 + bx1) / 2 / w;
                double fy = (double)(by0 + by1) / 2 / hh;
                bs = Math.Round(fx, 4) + "," + Math.Round(fy, 4);
            }
            // 播放页：播放键是深色圆 + 白色图标，没有红色块；用底部中间的白色图标定位
            int wx0 = -1, wx1 = -1, wy0 = -1, wy1 = -1, wcnt = 0;
            for (int y = (int)(hh * 0.94); y < (int)(hh * 0.995); y++) {
                for (int x = (int)(w * 0.49); x < (int)(w * 0.545); x++) {
                    if (!IsWhite(bmp.GetPixel(x, y))) continue;
                    wcnt++;
                    if (wx0 < 0 || x < wx0) wx0 = x;
                    if (x > wx1) wx1 = x;
                    if (wy0 < 0 || y < wy0) wy0 = y;
                    if (y > wy1) wy1 = y;
                }
            }
            string ws = "none";
            if (wcnt > 60) {
                double wx = (double)(wx0 + wx1) / 2 / w;
                double wy = (double)(wy0 + wy1) / 2 / hh;
                ws = Math.Round(wx, 4) + "," + Math.Round(wy, 4);
            }
            string bars = "none";
            if (barY >= 0 && barRun > w / 40) bars = Math.Round((double)barY / hh, 4).ToString();
            // 已播比例（进度条红色段占窗口宽度的比例），供快进/快退按真实进度跳
            string poss = "none";
            if (barY >= 0 && barRun > w / 80) poss = Math.Round((double)barRun / w, 4).ToString();
            return "rect=" + w + "x" + hh + " bar=" + bars + " pos=" + poss + " btn=" + bs + " btnw=" + ws + " bn=" + barRun + " cn=" + cnt + " wn=" + wcnt;
        }
    }

    // click: 按比例点击（坐标换算在本进程内做，DPI 感知）
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    public struct POINT { public int X, Y; }

    static string Click(IntPtr hwnd, double fx, double fy) {
        RECT r;
        if (!GetWindowRect(hwnd, out r)) return "no-rect";
        int x = r.L + (int)Math.Round((r.R - r.L) * fx);
        int y = r.T + (int)Math.Round((r.B - r.T) * fy);
        POINT old;
        GetCursorPos(out old);
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(120);
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(70);
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(80);
        SetCursorPos(old.X, old.Y);
        return "click=" + x + "," + y;
    }

    static int Main(string[] args) {
        if (args.Length < 2) { Console.WriteLine("usage: npix report|click <hwnd> [fx fy]"); return 2; }
        IntPtr h = new IntPtr(long.Parse(args[1]));
        if (args[0] == "report") { Console.WriteLine(Report(h)); return 0; }
        if (args[0] == "dump" && args.Length >= 3) {
            RECT r;
            GetWindowRect(h, out r);
            int w = r.R - r.L, hh = r.B - r.T;
            using (var bmp = new Bitmap(w, hh))
            using (var g = Graphics.FromImage(bmp)) {
                g.CopyFromScreen(r.L, r.T, 0, 0, bmp.Size);
                bmp.Save(args[2]);
            }
            Console.WriteLine("dumped " + w + "x" + hh + "@" + r.L + "," + r.T);
            return 0;
        }
        if (args[0] == "click" && args.Length >= 4) {
            Console.WriteLine(Click(h, double.Parse(args[2]), double.Parse(args[3])));
            return 0;
        }
        Console.WriteLine("bad-args");
        return 2;
    }
}
