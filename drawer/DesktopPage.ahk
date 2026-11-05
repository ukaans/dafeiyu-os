#Warn LocalSameAsGlobal, OutputDebug
#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
;  Desktop Page - 桌面两页
;  Page 1: 干净桌面（系统图标自动隐藏，壁纸直接可见）
;  Wheel down -> 下滑滑出图标页（壁纸主题色毛玻璃）
;  Wheel up   -> 回到桌面上沿 / 收起
; ============================================================

; ===== 组件与扩展点 =====
;  本文件 = 「抽屉」这一个组件的全部实现，内部按四层切开。加功能先认层、再认函数，
;  不要跨层互调（数据层不碰 Gui，渲染层不解析输入）。
;
;  ── 数据层：磁盘 ↔ 内存 ─────────────────────────────────
;    LoadItems()           items.tsv → ITEMS[]
;    LoadLayout()/SaveLayout()   layout.dat → POS / FOLDERS（原子写，见 WriteFileAtomic）
;    LoadHidden()/SaveHidden()   hidden.dat（已回收/已隐藏的黑名单）
;    LoadPositions()       记忆的桌面图标位置
;    加「一种新的持久化数据」：照 LoadLayout/SaveLayout 的形状写一对函数，
;    文件名放进顶部 global 段，写文件一律走 WriteFileAtomic。
;
;  ── 窗口层：Gui 生命周期 / 显隐 / 层级 ───────────────────
;    EnsureWindow()       建主窗（只建一次）
;    ShowDrawer()/HideDrawer()/FadeIn()/FadeOut()   开合与动画
;    EnsureOverlay()/HideOverlay()/RestoreOverlayForDrawer()   覆盖层（点空白收起）
;    加「新窗口/新浮层」：自己建 Gui，显隐必须成对；层级顺序照抄 ShowDrawer 里的
;    EnsureOverlay → SetWindowPos(TOPMOST) 两步，否则新窗会被压在图标层下面点不到。
;
;  ── 渲染层：内存 ↔ 屏幕 ─────────────────────────────────
;    ComputeLayout()      算 cols/rows/格子尺寸
;    SyncItems()          把 ITEMS 灌进控件池（增删控件只在这里）
;    UpdatePage()         翻页；RenderFolders() 画文件夹格子
;    加「新的显示元素」：BuildGui 里建一次控件 → SyncItems/UpdatePage 里只改属性和可见性。
;    绝不在定时器里重建控件：会丢 hover、反复请求图标。
;
;  ── 交互层：输入 → 动作 ─────────────────────────────────
;    OnOverMove/OnOverUp/OnOverDown/OnOverRUp   鼠标消息（OnMessage 接线见下方自动执行段）
;    WheelHandle()        滚轮决策（热键通道 / Raw Input 通道都汇到这里）
;    BarAction()          顶栏按钮
;    SummonTick()         文件召唤（summon.cmd），命令表见 SUMMON_CMDS
;    加「一个入口」：只负责解析输入，动作调窗口层/数据层函数，不直接改全局状态。
;
;  跨组件契约（抽屉 / 代理 / 壁纸三方）：见 drawer\components.md。
; ============================================================

try DllCall("SetProcessDpiAwarenessContext", "Ptr", -4, "Int")
catch
    try DllCall("SetProcessDpiAwarenessContext", "Ptr", -3, "Int")

global APP_DIR := A_ScriptDir
global SCROLL_FILE := A_ScriptDir "\scroll.dat"
global ITEMS := []
global GUI_W := A_ScreenWidth, GUI_H := A_ScreenHeight
global RECT_CACHE := 0, RECT_STAMP := ''
global COLS := 0, ROWS := 0, PER_PAGE := 0
global CELL_W := 112, CELL_H := 118
global GRID_X := 24, GRID_Y := 118
global ICON_PX := 72, SCALE := 1.0
global curPage := 0, LAST_HOVER := 0
global gDrawer := 0, pageText := 0, CTRL_POOL := [], gConfirm := 0
global gTip := 0, TIP_IDX := 0, TIP_LAST := ""
global FORCE_DIRTY := true, SIG_KEY := ""
global POS := Map()
global FOLDERS := []
global GROUP_OF := Map()
global DRAG := 0, gGhost := 0, gFolderGui := 0, gOverlay := 0
; 文件夹弹窗当前那个 Gui 对象：BindOpen/BindRemove 会直接 Destroy，靠它做存活判定
global FOLDER_POPUP := 0
global FOLDER_CTRLS := []
; 文件夹弹窗里每个成员"真正绑上去的那个闭包"，onclick 用的就是它。
; 自检 summon.cmd=foldertest=<路径> 直接调用它，等价于用户点了一下。
global FOLDER_BINDS := []
global POOL_BG := []
global POOL_MINI := []
global POOL_TXT := []
global HIDDEN := Map()
global DESK_LAYOUT := false
global LAYOUT_FILE := APP_DIR "\layout.dat"
global HIDDEN_FILE := APP_DIR "\hidden.dat"
global NO_ACRYLIC := false
global THEME_ABGR := 0xD813161B
global BAR_H := Round(34 * (A_ScreenDPI / 96))
global BAR_BTNS := []
global ICONS_SHOWN := false
global ONESHOT := false
global WP_TODO_DIR := FindWallpaperDir()
global TODO_TXT := ''
global TODO_JS := ''
; 滚轮双通道去重用的时间戳（热键通道 / Raw Input 通道 / 自己转发出去的窗口）
global WHEEL_HK_TICK := 0, WHEEL_RAW_TICK := 0, WHEEL_SELF_UNTIL := 0
global HK_ALIVE := false, RAW_ALIVE := false
global WHEEL_PT_LOG := 0
global RAW_BUF := 0, RAW_OK := 0, RAW_WARNED := false, RAW_HWARNED := false
; Raw Input 存活心跳：真实鼠标一动就会累加，每 5 分钟落一行（证明"硬件事件确实到得了抽屉"）
global RAW_TICKS := 0, RAW_LASTLOG := 0
; WM_INPUT 消息计数：连假消息（PostMessage 测试）也计数，用来证明 OnMessage 接线是通的
global RAW_MSGS := 0
; 滚轮命中计数：给 summon.cmd=diag 用，一眼看出"最近有没有滚轮事件到过决策层"
global WHEEL_HITS := 0, WHEEL_LASTDIR := 0, WHEEL_LASTSRC := ""
; ---- 滚轮「到没到」的可观测计数 ----
; 以前只在 HK_ALIVE 首次置位时记一行，导致「根本没收到事件」和「收到了但被吞掉」在日志里长得一样。
; 这两个计数在热键体第一行无条件自增（任何 return 之前），配 60 秒限流日志：
; 一次真实滚动必然在 wheel.log 里留下 "wheel: hk down n=..."。
global WHEEL_HK_DOWN := 0, WHEEL_HK_UP := 0
global WHEEL_HK_LOG := 0                 ; 上一条 "wheel: hk ..." 的时间戳（限流用）
; RAW_TICKS 的历史含义是「收到的所有鼠标报文」；下面两个把含义写清楚：
;   RAW_MOVE_TICKS  = 所有鼠标报文（移动 / 按键 / 滚轮都算）
;   RAW_WHEEL_TICKS = 其中真正的 RI_MOUSE_WHEEL 且 delta<>0 的条数
; RAW_TICKS 与 RAW_MOVE_TICKS 同步累加，保留旧字段只为不打断已有的日志读法。
global RAW_MOVE_TICKS := 0, RAW_WHEEL_TICKS := 0
; ---- 滚轮桥（wheel-bridge.exe）：完全不依赖 AHK 自身鼠标钩子的唤起入口 ----
; 2026-11-04 深夜实测定案：本机的 AHK 进程会整条鼠标通道哑掉（`$WheelDown`/`~LButton`
; 不触发、WM_INPUT 一条都收不到、A_TimeIdleMouse 一直涨），而同一时刻一个普通 .NET 进程
; 装 WH_MOUSE_LL 能稳定收到 WM_MOUSEWHEEL(delta=±120)。所以把"看滚轮"这件事挪到
; 独立的 C# 小进程里，它看懂之后 PostMessage(0x8001) 回来，这里只管决策。
global BRIDGE_FILE := A_ScriptDir "\wheel-bridge.hwnd"
global BRIDGE_ANNOUNCE_LOG := 0          ; 上一条 announce 日志的时间戳（限流用）
global WHEEL_BRIDGE_TICK := 0            ; 桥最后一次把消息投进来的时刻
global WHEEL_BRIDGE_HITS := 0            ; 桥投进来的滚轮消息条数（diag 用）
global WHEEL_BRIDGE_LOG := 0             ; 上一条 "bridge: wheel ..." 日志的时间戳（限流用）
; ---- 屏幕边缘热区：完全不依赖任何键鼠钩子的等价唤起入口 ----
global EDGE_SUMMON := true               ; 运行时开关：summon.cmd 写 edge=0 / edge=1
global EDGE_PX := 6                      ; 触发厚度（96 DPI 下的像素，实际按 A_ScreenDPI 缩放）
global EDGE_HOLD_MS := 250               ; 要在边缘停留多久才触发
global EDGE_LAST_TICK := 0               ; 光标开始停在边缘的时刻（0 = 当前不在边缘）
global EDGE_ARMED := true                ; 触发一次后置 false，光标离开边缘 40px 以上才重新武装
global EDGE_INIT_LOGGED := false         ; 首次运行时写一行 `edge: probe init ...`，用于自证定时器在跑
; 本地代理（dsh-agent.ps1，端口写死在这张桌面系统的启动链里）
global AGENT_BASE := "http://127.0.0.1:17433"
; 文件召唤通道：任何进程往 <脚本目录>\summon.cmd 写一行 show/hide，抽屉 400ms 内开合。
; 键鼠钩子被系统摘掉、全局热键失效时，代理 /summon.gif 就靠它把抽屉叫出来。
global SUMMON_FILE := A_ScriptDir "\summon.cmd"
; ---- summon.cmd 命令表：命令名 → 处理函数。加一条命令 = 加一行 + 一个 handler 函数 ----
;   key     精确匹配的命令行（已 Trim；比较按原样，命令都写成小写）
;   fn      处理函数，签名 Summon_CmdXxx(arg)
;   prefix  true = 前缀匹配，arg = 去掉前缀后的剩余部分（log=N / foldertest=.. / dirtest=..）
;   匹配顺序固定为「先精确、再前缀」，与原来的 if/elseif 顺序等价；
;   所以 log= / foldertest= / dirtest= / classify= 这几条必须带 prefix: true。
global SUMMON_CMDS := Map(
    "show",        {fn: Summon_CmdShow,       prefix: false},
    "hide",        {fn: Summon_CmdHide,       prefix: false},
    "diag",        {fn: Summon_CmdDiag,       prefix: false},
    "classify=",   {fn: Summon_CmdClassify,   prefix: true},
    "edge=0",      {fn: Summon_CmdEdgeOff,    prefix: false},
    "edge=1",      {fn: Summon_CmdEdgeOn,     prefix: false},
    "log=",        {fn: Summon_CmdLog,        prefix: true},
    "foldertest=", {fn: Summon_CmdFolderTest, prefix: true},
    "dirtest=",    {fn: Summon_CmdDirTest,    prefix: true}
)
; 代理不可用时的启动队列文件（看门狗 / 巡检进程读它并拉起程序）。
; 行格式：<epoch 秒>|<完整路径>
global QUEUE_FILE := A_ScriptDir "\launch-queue.txt"
; ---- 统一审计日志：三端（AHK / 代理 / 壁纸）写同一份 audit.log，靠行内标签区分 ----
; 只记录"用户动作 / 请求 / 状态变化"，绝不放进任何 120ms~1s 级定时器。
global AUDIT_FILE := A_ScriptDir "\audit.log"
global AUDIT_MAX := 2097152                 ; 2MB 轮转阈值
global AUDIT_BYTES := -1                    ; <0 = 还没从磁盘取过尺寸（首次写时懒初始化）
global AUDIT_WRITES := 0                    ; 写入计数，用于定期与真实文件尺寸对齐
; ---- 抽屉运行日志 wheel.log：256KB 轮转 ----
; 这个文件只增不减（实测一周 77KB，长期跑会拖慢读取也占盘）。轮转范式照抄 AuditLog：
; 本地累加字节数，每 32 条与真实尺寸对齐一次，超限用 FileMove(..., 1) 改成 wheel.log.1。
; 本机安全策略会拦 Remove-Item，所以只能"改名覆盖"，不能"删旧建新"。
global WPLOG_MAX := 262144                  ; 256KB 轮转阈值
global WPLOG_BYTES := -1                    ; <0 = 还没从磁盘取过尺寸
global WPLOG_WRITES := 0                    ; 写入计数



OnError(LogError)

; ------------------------------------------------------------
;  字体
; ------------------------------------------------------------
LoadFonts() {
    global APP_DIR
    fonts := ["BarlowCondensed-Regular.ttf", "BarlowCondensed-Medium.ttf", "Oxanium-Variable.ttf"]
    for f in fonts {
        p := APP_DIR "\fonts\" f
        if FileExist(p)
            try DllCall("AddFontResourceExW", "Str", p, "UInt", 0x10, "Ptr", 0)
    }
}

; ------------------------------------------------------------
;  图标清单
; ------------------------------------------------------------
LoadItems() {
    global ITEMS, HIDDEN, POS_DESK
    ITEMS := []
    LoadHidden()
    p := APP_DIR "\items.tsv"
    if !FileExist(p)
        return
    for line in StrSplit(FileRead(p, "UTF-8"), "`n", "`r") {
        if (Trim(line) = "")
            continue
        f := StrSplit(line, "`t")
        if (f.Length < 4)
            continue
        path := f[2]
        if HIDDEN.Has(path)
            continue
        it := Map("name", f[1], "path", path, "icon", f[3], "kind", f[4])
        ; 桌面真实坐标（由 DesktopPositions.ps1 抓取，按路径匹配），用于还原「原桌面布局」
        if (IsObject(POS_DESK)) {
            if POS_DESK.Has(path)
                it["dpos"] := POS_DESK[path]
        }
        ITEMS.Push(it)
    }
}

; 读取桌面真实图标坐标：desktop_positions.tsv -> POS_DESK[name] := [x, y]
LoadPositions() {
    ; 读取桌面真实图标坐标：desktop_positions.tsv（路径<TAB>x<TAB>y）
    global POS_DESK
    POS_DESK := Map()
    p := APP_DIR "\desktop_positions.tsv"
    if !FileExist(p)
        return
    try {
        for line in StrSplit(FileRead(p, "UTF-8"), "`n", "`r") {
            f := StrSplit(line, "`t")
            if (f.Length < 3)
                continue
            POS_DESK[f[1]] := [Integer(f[2]), Integer(f[3]) + BAR_H]
        }
    } catch as e {
        LogWrite("load positions failed: " e.Message)
    }
}

LoadHidden() {
    global HIDDEN, HIDDEN_FILE
    HIDDEN := Map()
    if !FileExist(HIDDEN_FILE)
        return
    for line in StrSplit(FileRead(HIDDEN_FILE, "UTF-8"), "`n", "`r") {
        if (Trim(line) = "")
            continue
        HIDDEN[line] := true
    }
}

SaveHidden() {
    global HIDDEN, HIDDEN_FILE
    out := ""
    for p, _ in HIDDEN
        out .= p "`r`n"
    try {
        WriteFileAtomic(HIDDEN_FILE, out)
    } catch as e {
        LogWrite("save hidden failed: " e.Message)
    }
}

FindItem(path) {
    global ITEMS
    for it in ITEMS {
        if (it["path"] = path)
            return it
    }
    return 0
}

ItemIndex(path) {
    global ITEMS
    for i, it in ITEMS {
        if (it["path"] = path)
            return i
    }
    return 0
}

; ------------------------------------------------------------
;  启动图标
;  1) .lnk 先解析 TargetPath / Arguments / WorkingDirectory 再启动：
;     直接 Run 快捷方式是交给 ShellExecute，程序拿到的当前目录不可控，
;     鹰角启动器这类自检自身目录的程序会报 module init error
;  2) 同名进程已经有窗口 → 激活它，不再起第二个（单实例程序重复启动易踩关闭竞态）
;  3) 同名进程存在但还没窗口 → 等它要么出窗口、要么退干净，最多 5 秒
;  4) 全过程写日志，失败弹气泡，不再静默吞异常
;  5) 参数为空时优先交给本地代理拉起：AHK 当祖先后，目标程序的保护模块会拒绝初始化
; ------------------------------------------------------------
LaunchItem(path) {
    ; 目录走两级回退：
    ;   1) 本地代理 /launchpath.gif —— 交给 explorer.exe 中转（实测 45~63ms 返回，
    ;      而且目标进程的父进程是 explorer，不是 AHK，绕开"AHK 祖先"类保护）
    ;   2) 直连 Run（代理没起来时的兜底）
    ; 为什么用代理而不是 AHK 自己 Run explorer：
    ;   `explorer.exe <目录>` 是单实例转发，会复用已存在/最小化的旧窗口，用户看到的是
    ;   "点了没反应"；而走代理时目标由外壳新开窗口，行为可预期、可日志、可回退。
    ; 为什么不用 COM Shell.Application.Explore：本机实测该调用在 AHK 定时器线程里
    ;   既不返回也不抛异常（日志停在进入分支那一行），会把整个脚本线程拖死 —— 已弃用。
    if (InStr(FileExist(path), "D")) {
        t0 := A_TickCount
        LogWrite("launch dir: begin " path)
        if (AgentLaunch(path)) {
            LogWrite("launch dir ok via agent: " path " (" (A_TickCount - t0) "ms)")
            AuditLog("launch.new", "ok=1 via=agent path=" Aq(path) " ms=" (A_TickCount - t0))
            return
        }
        try {
            Run('explorer.exe "' path '"')
            LogWrite("launch dir ok via run: " path " (" (A_TickCount - t0) "ms)")
            AuditLog("launch.new", "ok=1 via=run path=" Aq(path) " ms=" (A_TickCount - t0))
            return
        } catch as e {
            LogWrite("launch dir run failed: " path " err=" e.Message)
        }
        LogWrite("launch dir FAILED: " path " (" (A_TickCount - t0) "ms)")
        AuditLog("launch.new", "ok=0 via=run path=" Aq(path) " ms=" (A_TickCount - t0))
        LaunchToast(path, "无法打开文件夹")
        return
    }
    target := path, args := "", wd := ""
    ; 注意 SubStr 负索引：-4 才是含点的最后 4 个字符（写 -3 只取到 "lnk"，永远进不来这个分支）
    isLink := (StrLower(SubStr(path, -4)) = ".lnk")
    if (isLink) {
        sc := ResolveShortcut(path)
        if (sc.Target != "") {
            target := sc.Target
            args := sc.Args
            wd := sc.Dir
        } else {
            LogWrite("launch: shortcut resolve failed, shell fallback: " path)
        }
    }
    if (wd = "")
        SplitPath(target, , &wd)
    name := ExeNameOf(target)
    if (name != "" && ProcessExist(name)) {
        loop 25 {
            if WinExist("ahk_exe " name) {
                WinActivate("ahk_exe " name)
                LogWrite("launch activate: " path " -> " name)
                AuditLog("launch.new", "ok=1 via=activate path=" Aq(path))
                return
            }
            if !ProcessExist(name)
                break
            Sleep 200       ; 旧实例正在退出，等它走干净再起新的
        }
    } else if (isLink && ActivateByTitleContains(ShortcutBaseName(path))) {
        ; 引导器型程序（鹰角启动器的 Launcher.exe 起完就退，真界面是 1.6.0\Games.exe）：
        ; 目标进程不在，但软件其实开着。再拉一次 lnk 会得到
        ; 「Load launcher failed, module init error」，所以先按窗口名认领已有窗口。
        ; 只对快捷方式这么做：普通文档（.txt/.docx/图片…）按文件名去匹配窗口标题，
        ; 会被随便一个标题里含这几个字的窗口骗走，表现就是"点了文件什么都没打开"。
        LogWrite("launch activate by title: " path)
        AuditLog("launch.new", "ok=1 via=activate path=" Aq(path) " by=title")
        return
    } else {
        LogWrite("launch: no running instance (exe=[" name "] title=[" ShortcutBaseName(path) "])")
    }
    ; 交给本地代理（powershell 子进程）去拉起，而不是 AHK 自己 Run：
    ; 实测从 AutoHotkey 进程起的鹰角启动器（连带 cmd/wscript 中转也一样）
    ; 必定弹「Load launcher failed, module init error」，而同一路径从
    ; powershell / 代理进程（无 AHK 祖先）起就正常 —— 是它的保护/反注入模块
    ; 按进程祖先识别并拒绝初始化。代理没起时才退回直连启动。
    if (args = "") {
        if (AgentLaunch(path)) {
            LogWrite("launch via agent: " path " -> " target)
            AuditLog("launch.new", "ok=1 via=agent path=" Aq(path))
            return
        }
        ; 代理没响应时不能退回 AHK 自己 Run：鹰角启动器的保护模块会按进程祖先
        ; 拒绝初始化，弹出「Load launcher failed, module init error」。
        ; 改写进启动队列，由 agent-watch.ps1 / ensure-all.ps1（都没有 AHK 祖先）拉起。
        if (QueueLaunch(path)) {
            LogWrite("launch queued (agent down): " path)
            AuditLog("launch.new", "ok=1 via=queue path=" Aq(path))
            LaunchToast(path, "本地代理未响应，已排入启动队列")
            return
        }
    }
    try {
        if (args != "")
            Run('"' target '" ' args, wd, , &pid)
        else
            Run('"' target '"', wd, , &pid)
        LogWrite("launch: " path " -> " target " args=[" args "] wd=[" wd "] pid=" pid)
        AuditLog("launch.new", "ok=1 via=run path=" Aq(path) " pid=" pid)
    } catch as e {
        LogWrite("launch failed: " path " -> " target " err=" e.Message)
        AuditLog("launch.new", "ok=0 via=run path=" Aq(path))
        LaunchToast(path, e.Message)
    }
}

; 代理不在时把待启动项写进队列文件；看门狗与巡检进程都没有 AHK 祖先，
; 能正常拉起鹰角启动器这类"拒绝 AHK 祖先进程"的程序。
QueueLaunch(path) {
    global QUEUE_FILE
    try {
        ts := DateDiff(A_NowUTC, "19700101000000", "Seconds")
        FileAppend(ts "|" path "`n", QUEUE_FILE, "UTF-8-RAW")
        return true
    } catch as e {
        LogWrite("queue launch failed: " path " err=" e.Message)
        return false
    }
}

ResolveShortcut(lnk) {
    out := {Target: "", Args: "", Dir: ""}
    try {
        sc := ComObject("WScript.Shell").CreateShortcut(lnk)
        out.Target := sc.TargetPath, out.Args := sc.Arguments, out.Dir := sc.WorkingDirectory
    } catch as e {
        LogWrite("launch: CreateShortcut failed " lnk " err=" e.Message)
    }
    return out
}

; 「鹰角启动器.lnk」-> 「鹰角启动器」；去掉扩展名和 Windows 自动加的「 - 快捷方式」
ShortcutBaseName(path) {
    SplitPath(path, , , , &nm)
    nm := RegExReplace(nm, "\s*-\s*快捷方式\s*$", "")
    return Trim(nm)
}

; 按标题包含关系找可见窗口并激活（不依赖进程名：引导器型程序的实际界面在别的 exe 里）
ActivateByTitleContains(needle) {
    global WIN_FIND_HWND, WIN_FIND_NEEDLE
    needle := Trim(needle)
    if (StrLen(needle) < 2)
        return false
    WIN_FIND_NEEDLE := StrLower(needle)
    WIN_FIND_HWND := 0
    cb := CallbackCreate(WinFindProc, "Fast")
    DllCall("EnumWindows", "Ptr", cb, "Ptr", 0)
    CallbackFree(cb)
    if (!WIN_FIND_HWND)
        return false
    try WinActivate("ahk_id " WIN_FIND_HWND)
    catch
        return false
    return true
}

WinFindProc(hwnd, lparam) {
    global WIN_FIND_HWND, WIN_FIND_NEEDLE
    if (WIN_FIND_HWND)
        return 0
    if !DllCall("IsWindowVisible", "Ptr", hwnd)
        return 1
    ; 取标题统一走 WinTitleOf（见文件末尾）：cap=0 表示不截断，和原来取全量一致
    t := StrLower(WinTitleOf(hwnd, 0))
    if (StrLen(t) < 2)
        return 1
    if (InStr(t, WIN_FIND_NEEDLE)) {
        WIN_FIND_HWND := hwnd
        return 0
    }
    return 1
}

ExeNameOf(target) {
    SplitPath(target, &nm, , &ext)
    if (ext = "exe" || ext = "com" || ext = "bat")
        return nm
    return ""
}

LaunchToast(path, msg) {
    SplitPath(path, &nm)
    ToolTip("启动失败：" nm "`n" msg, A_ScreenWidth // 2 - 160, A_ScreenHeight // 3)
    SetTimer(() => ToolTip(), -6000)
}

; ---- 经本地代理启动（避开"AHK 祖先"导致的启动器初始化失败）----
; 代理的 /launchpath.gif 走 Start-Process（ShellExecute），对 .lnk 由外壳
; 自己带上 lnk 里的参数和工作目录，所以这里只需要传 lnk / exe 路径本身。
AgentLaunch(path) {
    global AGENT_BASE
    try {
        t0 := A_TickCount
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        ; 代理是"先回 200 再启动"，正常 100ms 内就回来了；这里只等 900ms 封顶。
        ; 原来是 3 秒 —— 那是「滚轮/热键突然没反应」的直接成因：代理假死时每次点击都把
        ; 脚本线程（连带鼠标底层钩子）按住 3 秒，连续两下就超过系统的 LowLevelHooksTimeout，
        ; Windows 会把钩子静默摘掉，AHK 自己不知道，于是滚轮和 ^!Space 一起失灵。
        req.SetTimeouts(300, 300, 900, 900)
        req.Open("GET", AGENT_BASE "/launchpath.gif?t=" UrlEncodePath(path), false)
        req.Send()
        elapsed := A_TickCount - t0
        LogWrite("launch agent: status=" req.Status " " elapsed "ms " path)
        return (req.Status = 200)
    } catch as e {
        LogWrite("launch agent unavailable: " e.Message)
        return false
    }
}

; UTF-8 百分号编码（代理侧用 Uri::UnescapeDataString 解码，中文路径必须这样传）
UrlEncodePath(s) {
    buf := Buffer(StrPut(s, "UTF-8"))
    n := StrPut(s, buf, "UTF-8") - 1
    out := ""
    loop n {
        b := NumGet(buf, A_Index - 1, "UChar")
        if ((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
            || b = 0x2D || b = 0x5F || b = 0x2E || b = 0x7E || b = 0x3A || b = 0x5C)
            out .= Chr(b)
        else
            out .= "%" Format("{:02X}", b)
    }
    return out
}

; ------------------------------------------------------------
;  布局：优先还原「桌面真实坐标」；没有坐标时退回原生网格
; ------------------------------------------------------------
ComputeLayout() {
    global SCALE, CELL_W, CELL_H, ICON_PX, GRID_X, GRID_Y, COLS, ROWS, PER_PAGE, GUI_W, GUI_H, ITEMS, DESK_LAYOUT, BAR_H
    SCALE := A_ScreenDPI / 96

    ; 从真实坐标推断格宽/格高（x、y 的最小正差值）
    dx := 0, dy := 0, minX := 0, minY := 0
    xs := Map(), ys := Map()
    have := false
    for it in ITEMS {
        if !it.Has("dpos")
            continue
        have := true
        p := it["dpos"]
        xs[p[1]] := true, ys[p[2]] := true
    }
    if have {
        sx := [], sy := []
        for v, _ in xs
            sx.Push(v)
        for v, _ in ys
            sy.Push(v)
        SortInts(sx), SortInts(sy)
        dx := MinGap(sx), dy := MinGap(sy)
        minX := (sx.Length ? sx[1] : 0), minY := (sy.Length ? sy[1] : 0)
    }

    DESK_LAYOUT := have && dx > 40 && dy > 40
    if (DESK_LAYOUT) {
        CELL_W := dx
        CELL_H := dy
        ICON_PX := Round(Min(dx, dy) * 0.62)
        GRID_X := minX
        GRID_Y := BAR_H
    } else {
        CELL_W := Round(75 * SCALE)
        CELL_H := Round(78 * SCALE)
        ICON_PX := Round(48 * SCALE)
        GRID_X := Round(16 * SCALE)
        GRID_Y := Round(74 * SCALE)
    }
    COLS := Max(1, (GUI_W - GRID_X) // CELL_W)
    ROWS := Max(1, (GUI_H - GRID_Y) // CELL_H)
    PER_PAGE := Max(1, COLS * ROWS)
}

SortInts(arr) {
    n := arr.Length
    loop n - 1 {
        i := A_Index
        loop n - i {
            j := A_Index
            if (arr[j] > arr[j + 1]) {
                t := arr[j], arr[j] := arr[j + 1], arr[j + 1] := t
            }
        }
    }
}

MinGap(arr) {
    if (arr.Length < 2)
        return 0
    best := 99999
    loop arr.Length - 1 {
        d := arr[A_Index + 1] - arr[A_Index]
        if (d > 0 && d < best)
            best := d
    }
    return (best = 99999) ? 0 : best
}

DefaultSlot(idx) {
    global COLS, ROWS, CELL_W, CELL_H, GRID_X, GRID_Y, ITEMS
    if (IsObject(ITEMS) && ITEMS.Has(idx) && ITEMS[idx].Has("dpos")) {
        p := ITEMS[idx]["dpos"]
        return [p[1], p[2]]
    }
    i := idx - 1
    col := i // ROWS
    row := Mod(i, ROWS)
    return [GRID_X + col * CELL_W, GRID_Y + row * CELL_H]
}

FitLabel(s, maxPx, pt) {
    ; 粗估像素宽：CJK 约 1.02*pt，ASCII 约 0.55*pt，超宽就截断加省略号
    pxPerCjk := pt * 1.12 * (A_ScreenDPI / 72)
    pxPerAscii := pt * 0.55 * (A_ScreenDPI / 72)
    w := 0.0
    i := 1
    n := StrLen(s)
    while (i <= n) {
        ch := Ord(SubStr(s, i, 1))
        w += (ch > 0x2E80) ? pxPerCjk : pxPerAscii
        if (w > maxPx - pxPerCjk) {
            if (i >= n)
                return s
            return SubStr(s, 1, i - 1) "…"
        }
        i += 1
    }
    return s
}

; ------------------------------------------------------------
;  抽屉窗口
; ------------------------------------------------------------
; ------------------------------------------------------------
;  抽屉窗口（只建一次，之后只复用控件）
; ------------------------------------------------------------
EnsureWindow() {
    global gDrawer, gGhost, ITEMS, GUI_W, GUI_H, CELL_W, CELL_H, ICON_PX, SCALE, APP_DIR, GRID_X, GRID_Y, DESK_LAYOUT, BAR_H, BAR_BTNS
    global pageText, NO_ACRYLIC, THEME_ABGR
    if IsObject(gDrawer)
        return
    ; +E0x00080000 = WS_EX_LAYERED：用于开合时做淡入淡出（比移动窗口便宜得多）
    gDrawer := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08080000", "DesktopPage")
    gDrawer.BackColor := "1B1613"
    gDrawer.MarginX := 0
    gDrawer.MarginY := 0
    gDrawer.SetFont("s" Round(11 * SCALE) " cF5F0E6", "Barlow Condensed Medium")
    gDrawer.Add("Text", "Hidden x" GRID_X " y" Round(4 * SCALE) " h" Round(34 * SCALE) " BackgroundTrans", "DESKTOP / 桌面")
    gDrawer.SetFont("s" Round(7.5 * SCALE) " c9C8B79", "Microsoft YaHei UI")
    gDrawer.Add("Text", "Hidden x" GRID_X " y" Round(44 * SCALE) " h" Round(20 * SCALE) " w1400 BackgroundTrans",
        "滚轮↓下滑查看图标   ·   拖拽可自由摆放，拖到图标上合成文件夹   ·   右键图标有菜单   ·   Esc 关闭")
    pageText := gDrawer.Add("Text", "x" (GUI_W - GRID_X - 200) " y" (GUI_H - Round(30 * SCALE)) " w200 h" Round(22 * SCALE) " Right BackgroundTrans c8A8272", "01 / 01")
    gDrawer.SetFont("s" Round(9 * SCALE) " cE8E2D6", "Barlow Condensed")
    gGhost := gDrawer.Add("Picture", "x0 y0 w" ICON_PX " h" ICON_PX " BackgroundTrans Hidden", APP_DIR "\folder.png")
    ft := gDrawer.Add("Text", "Hidden x" GRID_X " y" (GUI_H - Round(22 * SCALE)) " w900 BackgroundTrans c7A7568", "DESKTOP PAGE · DEEPSEEK COMPANION WALLPAPER")
    ft.SetFont("s" Round(7 * SCALE), "Barlow Condensed")
    ; ── 顶部快捷操作栏（替代原来的说明文字） ──
    gDrawer.Add("Picture", "x0 y0 w" GUI_W " h" BAR_H, APP_DIR "\bar.png")
    gDrawer.SetFont("s" Round(11 * SCALE) " cF5F0E6", "Barlow Condensed Medium")
    gDrawer.Add("Text", "x" GRID_X " y" Round(2 * SCALE) " h" Round(30 * SCALE) " BackgroundTrans", "DESKTOP / 桌面")
    gDrawer.SetFont("s" Round(7.5 * SCALE) " c9C8B79", "Microsoft YaHei UI")
    gDrawer.Add("Text", "x" (GRID_X + Round(198 * SCALE)) " y" Round(13 * SCALE) " h" Round(24 * SCALE) " BackgroundTrans",
        "Ctrl+Alt+Space 唤出/收起   滚轮下滑唤出（桌面）   Ctrl+Alt+滚轮↓ 任意窗口唤出   Ctrl+Alt+D 桌面图标")
    gDrawer.SetFont("s" Round(8.5 * SCALE) " cE8E2D6", "Microsoft YaHei UI")
    BAR_BTNS := []
    bws := [Round(132 * SCALE), Round(116 * SCALE), Round(116 * SCALE), Round(86 * SCALE)]
    bls := ["原始桌面", "添加应用", "重新扫描", "退出程序"]
    bacs := ["desktop", "add", "rescan", "quit"]
    bgap := Round(9 * SCALE)
    btotal := bgap * (bws.Length - 1)
    for wv in bws
        btotal += wv
    bx := GUI_W - Round(28 * SCALE) - btotal
    by := Round(8 * SCALE)
    bh := Round(24 * SCALE)
    for i, lb in bls {
        tc := gDrawer.Add("Text", "x" bx " y" by " w" bws[i] " h" bh " Center BackgroundTrans cE8E2D6", lb)
        tc.SetFont("s" Round(8.5 * SCALE), "Microsoft YaHei UI")
        BAR_BTNS.Push(Map("x1", bx, "x2", bx + bws[i], "act", bacs[i], "ctrl", tc))
        bx += bws[i] + bgap
    }
    gDrawer.Show("x0 y" GUI_H " w" GUI_W " h" GUI_H " NoActivate")
    if !NO_ACRYLIC
        EnableAcrylic(gDrawer.Hwnd, THEME_ABGR)
}

; 复用控件池：条目数只增不减时新建，减少时隐藏多余的
SyncItems() {
    global gDrawer, ITEMS, CELL_W, CELL_H, ICON_PX, SCALE, APP_DIR, CTRL_POOL
    if !IsObject(CTRL_POOL)
        CTRL_POOL := []
    for i, it in ITEMS {
        try {
            s := DefaultSlot(i)
            c := (i <= CTRL_POOL.Length) ? CTRL_POOL[i] : 0
            if !c {
                hl := gDrawer.Add("Picture", "Hidden x0 y0 w" (CELL_W - 6) " h" (CELL_H - 4) " BackgroundTrans", APP_DIR "\hl.png")
                pic := gDrawer.Add("Picture", "x0 y0 w" ICON_PX " h" ICON_PX " BackgroundTrans", it["icon"])
                txt := gDrawer.Add("Text", "x0 y0 w" CELL_W " h" Round(18 * SCALE) " Center -Wrap BackgroundTrans cD6CBBB", "")
                txt.SetFont("s" Round(6.2 * SCALE), "Microsoft YaHei UI")
                c := Map("hl", hl, "pic", pic, "txt", txt)
                CTRL_POOL.Push(c)
            }
            c["hl"].Move(s[1] + 3, s[2], CELL_W - 6, CELL_H - 4)
            c["hl"].Visible := false
            c["pic"].Move(s[1] + (CELL_W - ICON_PX) // 2, s[2] + Round(6 * SCALE), ICON_PX, ICON_PX)
            if (c["pic"].Value != it["icon"])
                c["pic"].Value := it["icon"]
            ty := s[2] + Round(6 * SCALE) + ICON_PX + Round(2 * SCALE)
            c["txt"].Move(s[1], ty, CELL_W, Max(Round(18 * SCALE), CELL_H - (ty - s[2]) - 2))
            lbl := FitLabel(it["name"], CELL_W - Round(20 * SCALE), Round(6.2 * SCALE))
            if (c["txt"].Value != lbl)
                c["txt"].Value := lbl
            it["x"] := s[1], it["y"] := s[2]
            it["hl"] := c["hl"], it["pic"] := c["pic"], it["txt"] := c["txt"]
        } catch as e {
            try LogWrite("sync item " i " failed: " e.Message)
        }
    }
    for j, c in CTRL_POOL {
        if (j > ITEMS.Length) {
            try c["hl"].Visible := false
            try c["pic"].Visible := false
            try c["txt"].Visible := false
        }
    }
}

BuildGui() {
    global FOLDER_CTRLS, POOL_BG, POOL_MINI, POOL_TXT
    FOLDER_CTRLS := [], POOL_BG := [], POOL_MINI := [], POOL_TXT := []
    EnsureWindow()
    SyncItems()
    UpdatePage()
}

EnableAcrylic(hwnd, abgr) {
    ; SetWindowCompositionAttribute -> ACCENT_ENABLE_ACRYLICBLURBEHIND
    size := 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4
    acc := Buffer(size, 0)
    NumPut("Int", 4, acc, 0)          ; AccentState = ACCENT_ENABLE_ACRYLICBLURBEHIND
    NumPut("Int", 2, acc, 4)          ; AccentFlags
    NumPut("UInt", abgr, acc, 8)      ; GradientColor (AABBGGRR)
    NumPut("Int", 0, acc, 12)         ; AnimationId
    data := Buffer(16 + A_PtrSize, 0)
    NumPut("Int", 19, data, 0)        ; WCA_ACCENT_POLICY
    NumPut("Ptr", acc.Ptr, data, 8)
    NumPut("UInt", size, data, 8 + A_PtrSize)
    try DllCall("user32\SetWindowCompositionAttribute", "Ptr", hwnd, "Ptr", data)
}

DrawerVisible() {
    global gDrawer
    if !IsObject(gDrawer)
        return false
    return DllCall("IsWindowVisible", "Ptr", gDrawer.Hwnd)
}

EnsureOverlay() {
    global gOverlay, GUI_W, GUI_H
    if IsObject(gOverlay) {
        gOverlay.Show("x0 y0 w" GUI_W " h" GUI_H " NoActivate")
        try DllCall("user32\SetLayeredWindowAttributes", "Ptr", gOverlay.Hwnd, "UInt", 0, "UChar", 1, "UInt", 0x2)
        try DllCall("user32\SetWindowPos", "Ptr", gOverlay.Hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x53)
        return
    }
    gOverlay := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08080000", "DPOverlay")
    gOverlay.BackColor := "000000"
    gOverlay.Show("x0 y0 w" GUI_W " h" GUI_H " NoActivate")
    try DllCall("user32\SetLayeredWindowAttributes", "Ptr", gOverlay.Hwnd, "UInt", 0, "UChar", 1, "UInt", 0x2)
    try DllCall("user32\SetWindowPos", "Ptr", gOverlay.Hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x53)
}

HideOverlay() {
    global gOverlay
    if IsObject(gOverlay)
        try gOverlay.Hide()
}

ShowDrawer(instant := false) {
    try SyncIconState()
    global LAST_HOVER
    LAST_HOVER := 0
    global gDrawer, GUI_W, GUI_H, curPage
    if !IsObject(gDrawer)
        return
    if (curPage = 0)
        curPage := 1
    t0 := A_TickCount
    UpdatePage()
    t1 := A_TickCount
    EnsureOverlay()
    t2 := A_TickCount
    win := "ahk_id " gDrawer.Hwnd
    ; 带亚克力的全屏窗口每次 WinMove 都要重合成（实测约 150ms/次），
    ; 所以默认直接到位，不再做逐帧滑入，避免「按了要等一会才出来」。
    hwnd := gDrawer.Hwnd
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", GUI_W, "Int", GUI_H, "UInt", 0x0040)
    DllCall("ShowWindow", "Ptr", hwnd, "Int", 8)   ; SW_SHOWNA（不激活，键盘仍由本脚本接管）
    EnsureOverlay()
    FadeIn(hwnd)
    ; 实测出现过 "ShowDrawer vis=0"：ShowWindow(8) 之后窗口仍不可见（有一次是 alpha/合成卡住），
    ; 这种时候用户只会看到"唤不出抽屉"。补一次强制显示（SW_SHOWNOACTIVATE），并把结果记下来。
    if (!DllCall("IsWindowVisible", "Ptr", hwnd)) {
        DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", GUI_W, "Int", GUI_H, "UInt", 0x0040)
        DllCall("ShowWindow", "Ptr", hwnd, "Int", 4)   ; SW_SHOWNOACTIVATE
        try DllCall("SetLayeredWindowAttributes", "Ptr", hwnd, "UInt", 0, "UChar", 255, "UInt", 2)
        LogWrite("ShowDrawer: not visible after FadeIn, forced SW_SHOWNOACTIVATE -> vis=" DllCall("IsWindowVisible", "Ptr", hwnd))
    }
    LogWrite("ShowDrawer vis=" DllCall("IsWindowVisible", "Ptr", hwnd) " [page=" (t1 - t0) " ov=" (t2 - t1) " total=" (A_TickCount - t0) "]")
    LogWrite("overlay shown")
    AuditLog("open", "page=" curPage " src=ui")
}
; ── 淡入淡出：窗口用 WS_EX_LAYERED，改 alpha 只重合成颜色不需要重新布局，
;    实测每步 <2ms，整段 ~60ms，比逐帧 WinMove（每帧 ~150ms）快一个数量级又不突兀。
FadeIn(hwnd) {
    try {
        ; ease-out cubic，约 240ms：起步快、收尾慢，看起来更软
        steps := 18
        Loop steps {
            t := A_Index / steps
            ev := 1 - (1 - t) * (1 - t) * (1 - t)
            a := Round(255 * ev)
            if (a < 1)
                a := 1
            DllCall("SetLayeredWindowAttributes", "Ptr", hwnd, "UInt", 0, "UChar", a, "UInt", 2)
            Sleep 11
        }
        DllCall("SetLayeredWindowAttributes", "Ptr", hwnd, "UInt", 0, "UChar", 255, "UInt", 2)
    }
}

FadeOut(hwnd) {
    try {
        ; ease-in quad，约 130ms
        steps := 13
        Loop steps {
            t := A_Index / steps
            a := Round(255 * (1 - t * t))
            DllCall("SetLayeredWindowAttributes", "Ptr", hwnd, "UInt", 0, "UChar", a, "UInt", 2)
            Sleep 10
        }
    }
}
HideDrawer() {
    global gDrawer, GUI_W, GUI_H, curPage, LAST_HOVER
    HideTip()
    if !IsObject(gDrawer)
        return
    pageBefore := curPage
    HideOverlay()
    hwnd := gDrawer.Hwnd
    LogWrite("HideDrawer vis=" DllCall("IsWindowVisible", "Ptr", hwnd))
    ; 同样不做逐帧滑出：直接泊到屏幕外并隐藏，避免收起时也卡一下
    FadeOut(hwnd)
    DllCall("ShowWindow", "Ptr", hwnd, "Int", 0)   ; SW_HIDE
    DllCall("SetWindowPos", "Ptr", hwnd, "Ptr", -1, "Int", 0, "Int", GUI_H, "Int", GUI_W, "Int", GUI_H, "UInt", 0x0014)
    curPage := 0
    LAST_HOVER := 0
    AuditLog("close", "page_before=" pageBefore)
}

UpdatePage() {
    global ITEMS, curPage, pageText, FOLDERS, GROUP_OF, HIDDEN, FORCE_DIRTY, SIG_KEY
    if (!FORCE_DIRTY) {
        sig := curPage '|' ITEMS.Length '|' FOLDERS.Length '|' HIDDEN.Count
        if (sig = SIG_KEY)
            return
    }
    t0 := A_TickCount
    n := PageCount()
    if (curPage < 1 || curPage > n)
        curPage := 1
    vcount := 0
    for i, it in ITEMS {
        vis := (i > (curPage - 1) * PER_PAGE && i <= curPage * PER_PAGE)
        ; 已被移除/隐藏的条目，重开抽屉时也不能再显示出来
        if (vis && HIDDEN.Has(it["path"]))
            vis := false
        if (vis && IsObject(GROUP_OF) && GROUP_OF.Has(it["path"]))
            vis := false
        if (vis && POS.Has(it["path"])) {
            p := POS[it["path"]]
            PlaceItem(i, p[1], p[2])
        } else if vis {
            PlaceItem(i, it["x"], it["y"])
        } else {
            HideItem(i)
        }
        if (vis)
            vcount += 1
    }
    ResolveOverlaps()
    try pageText.Value := Format("{:02}/{:02}", curPage, n)
    RenderFolders()
    Repaint()
    SIG_KEY := curPage "|" ITEMS.Length "|" FOLDERS.Length "|" HIDDEN.Count
    FORCE_DIRTY := false
    LogWrite("updatepage: page=" curPage "/" n " vis=" vcount " ms=" (A_TickCount - t0))
}

PageCount() {
    global ITEMS, PER_PAGE
    if (PER_PAGE <= 0)
        return 1
    return Max(1, Ceil(ITEMS.Length / PER_PAGE))
}

BarAction(a) {
    global ICONS_SHOWN
    switch a {
        case "desktop":
            ; 按真实桌面状态决定：现在隐藏就显示、现在显示就隐藏
            was := QueryIcons()
            if (was = "hidden") {
                IconsScript("show")
                ICONS_SHOWN := true
                LogWrite("bar: 显示原始桌面图标")
            } else {
                IconsScript("hide")
                ICONS_SHOWN := false
                LogWrite("bar: 隐藏原始桌面图标")
            }
            SyncIconState()
            HideDrawer()
            AuditLog("bar.desktop", "shown=" (ICONS_SHOWN ? 1 : 0))
        case "add":
            LogWrite("bar: 添加应用")
            AuditLog("bar.add", "")
            HideDrawer()
            AddFilesToDrawer()
        case "rescan":
            LogWrite("bar: 重新扫描桌面")
            AuditLog("bar.rescan", "")
            RescanDesktop()
        case "quit":
            LogWrite("bar: 退出")
            AuditLog("bar.quit", "")
            ExitApp()
    }
}
HoverAt(x, y) {
    global ITEMS, LAST_HOVER, TIP_IDX, FOLDERS, CELL_W, CELL_H, BAR_H, BAR_BTNS
    ; 顶部快捷栏：命中就高亮，不参与图标悬停
    if (y < BAR_H) {
        if (LAST_HOVER > 0)
            try ITEMS[LAST_HOVER]["hl"].Visible := false
        LAST_HOVER := 0
        if (TIP_IDX != 0) {
            TIP_IDX := 0
            HideTip()
        }
        for b in BAR_BTNS {
            hit := (x >= b["x1"] && x <= b["x2"])
            try b["ctrl"].SetFont("c" (hit ? "FFF1DC" : "E8E2D6"))
        }
        return
    }
    ; 文件夹优先：命中文件夹就显示「名字（N 项）」
    fi := HitFolder(x, y)
    if fi {
        if (LAST_HOVER > 0)
            try ITEMS[LAST_HOVER]["hl"].Visible := false
        LAST_HOVER := -1000 - fi
        if (TIP_IDX != LAST_HOVER) {
            TIP_IDX := LAST_HOVER
            f := FOLDERS[fi]
            ShowTip(f["name"] " （" CountMembers(f) " 项）", f["x"], f["y"], CELL_H)
        }
        return
    }
    idx := HitItem(x, y)
    if (idx != LAST_HOVER) {
        if (LAST_HOVER > 0)
            try ITEMS[LAST_HOVER]["hl"].Visible := false
        LAST_HOVER := idx
        if idx
            try ITEMS[idx]["hl"].Visible := true
    }
    if (idx = 0) {
        if (TIP_IDX != 0) {
            TIP_IDX := 0
            HideTip()
        }
        return
    }
    if (TIP_IDX != idx) {
        TIP_IDX := idx
        it := ITEMS[idx]
        ShowTip(it["name"], it["x"], it["y"], CELL_H)   ; 标签会被截断，气泡显示全称
    }
}
CountMembers(f) {
    global GROUP_OF
    n := 0
    for p, id in GROUP_OF
        if (id = f["id"])
            n += 1
    return n
}

; ── 悬停气泡：网格标签统一被 FitLabel 截断，这里显示完整名称 ──
ShowTip(txt, ix, iy, ih) {
    global gTip, TIP_LAST, SCALE, CELL_W, GUI_W, GUI_H
    if (txt = "") {
        HideTip()
        return
    }
    ; 文字变了就整块重建：不写死宽高，让 Static 按文字自适应，彻底避免截断
    if (!IsObject(gTip) || TIP_LAST != txt) {
        if IsObject(gTip)
            try gTip.Destroy()
        gTip := Gui("+AlwaysOnTop -Caption +ToolWindow -DPIScale +E0x08000020", "DPTip")
        gTip.BackColor := "241E19"
        gTip.MarginX := 10
        gTip.MarginY := 6
        gTip.SetFont("s9 cF5F0E6", "Microsoft YaHei UI")
        gTip.Add("Text", "BackgroundTrans -Wrap", txt)
        gTip.Show("AutoSize NoActivate Hide")
        TIP_LAST := txt
    }
    gTip.GetPos(&ox, &oy, &ww, &hh)
    tx := ix + (CELL_W - ww) // 2
    tx := Max(6, Min(GUI_W - ww - 6, tx))
    ty := iy - hh - 8
    if (ty < 6)
        ty := iy + ih + 4
    if (ty + hh > GUI_H)
        ty := Max(6, GUI_H - hh - 6)
    gTip.Show("NoActivate x" tx " y" ty)
}
HideTip() {
    global gTip, TIP_IDX
    TIP_IDX := 0
    if IsObject(gTip)
        try gTip.Hide()
}

HitItem(x, y, skip := 0) {
    global ITEMS, CELL_W, CELL_H
    for i, it in ITEMS {
        if (i = skip)
            continue
        if !it.Has("pic") || !it["pic"].Visible
            continue
        if (x >= it["x"] - 4 && x <= it["x"] + CELL_W + 4 && y >= it["y"] - 6 && y <= it["y"] + CELL_H - 2)
            return i
    }
    return 0
}

HitFolder(x, y) {
    global FOLDERS, CELL_W, CELL_H
    for i, f in FOLDERS {
        if (x >= f["x"] - 4 && x <= f["x"] + CELL_W + 4 && y >= f["y"] - 6 && y <= f["y"] + CELL_H - 2)
            return i
    }
    return 0
}

; ------------------------------------------------------------
;  布局持久化
; ------------------------------------------------------------
LoadLayout() {
    global POS, FOLDERS, GROUP_OF, LAYOUT_FILE, BAR_H
    POS := Map(), FOLDERS := [], GROUP_OF := Map()
    if !FileExist(LAYOUT_FILE)
        return
    for line in StrSplit(FileRead(LAYOUT_FILE, "UTF-8"), "`n", "`r") {
        if (Trim(line) = "" || SubStr(line, 1, 2) = "V2")
            continue
        f := StrSplit(line, "`t")
        if (f.Length >= 4 && f[1] = "P") {
            POS[f[2]] := [Integer(f[3]), Integer(f[4]) + BAR_H]
        } else if (f.Length >= 6 && f[1] = "F") {
            mem := StrSplit(f[6], "|")
            FOLDERS.Push(Map("id", f[2], "name", f[3], "x", Integer(f[4]), "y", Integer(f[5]) + BAR_H, "members", mem))
            for m in mem
                GROUP_OF[m] := f[2]
        }
    }
}

SaveLayout() {
    global POS, FOLDERS, LAYOUT_FILE, BAR_H
    out := "V2`r`n"
    for p, v in POS
        out .= "P`t" p "`t" v[1] "`t" (v[2] - BAR_H) "`r`n"
    for f in FOLDERS {
        mem := ""
        for i, m in f["members"]
            mem .= (i = 1 ? "" : "|") m
        nm := StrReplace(StrReplace(StrReplace(f["name"], "`t", " "), "`r", " "), "`n", " ")
        out .= "F`t" f["id"] "`t" nm "`t" f["x"] "`t" (f["y"] - BAR_H) "`t" mem "`r`n"
    }
    ; 写入失败（文件被占用/权限）不应中断整个程序
    try {
        WriteFileAtomic(LAYOUT_FILE, out)
    } catch as err {
        LogWrite("save layout failed: " err.Message)
    }
}

NormalizeLayout() {
    global FOLDERS, GROUP_OF
    seen := Map()
    keep := []
    for f in FOLDERS {
        mem := []
        for m in f["members"] {
            if seen.Has(m)
                continue
            seen[m] := true
            mem.Push(m)
        }
        if (mem.Length >= 2) {
            f["members"] := mem
            keep.Push(f)
        } else {
            for m in mem
                GROUP_OF.Delete(m)
        }
    }
    FOLDERS := keep
    GROUP_OF := Map()
    k := 0
    for f in FOLDERS {
        k += 1
        if (f["name"] ~= "^文件夹 \d+$")
            f["name"] := "文件夹 " k
        for m in f["members"]
            GROUP_OF[m] := f["id"]
    }
}

; ------------------------------------------------------------
;  鼠标事件（全部由输入浮层接收）
; ------------------------------------------------------------
OnMessage(0x0200, OnOverMove)
OnMessage(0x0201, OnOverDown)
OnMessage(0x0202, OnOverUp)
OnMessage(0x0205, OnOverRUp)

OnOverMove(wParam, lParam, msg, hwnd) {
    global gOverlay, DRAG, curPage
    if (!IsObject(gOverlay) || hwnd != gOverlay.Hwnd || curPage = 0)
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    if IsObject(DRAG) {
        DragMove(x, y)
        return
    }
    HoverAt(x, y)
}

OnOverDown(wParam, lParam, msg, hwnd) {
    HideTip()
    global gOverlay, DRAG, curPage, BAR_H
    if (!IsObject(gOverlay) || hwnd != gOverlay.Hwnd || curPage = 0)
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    if (y < BAR_H)
        return
    fi := HitFolder(x, y)
    idx := fi ? 0 : HitItem(x, y)
    if (!idx && !fi)
        return
    DRAG := Map("idx", idx, "folder", fi, "sx", x, "sy", y, "active", false)
}

OnOverUp(wParam, lParam, msg, hwnd) {
    global gOverlay, DRAG, ITEMS, FOLDERS, curPage, BAR_H, BAR_BTNS
    if (!IsObject(gOverlay) || hwnd != gOverlay.Hwnd || curPage = 0)
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    if (y < BAR_H) {
        DRAG := 0
        for b in BAR_BTNS
            if (x >= b["x1"] && x <= b["x2"])
                BarAction(b["act"])
        return
    }
    if !IsObject(DRAG) {
        HideDrawer()
        return
    }
    d := DRAG
    DRAG := 0
    if (!d["active"] && (Abs(x - d["sx"]) + Abs(y - d["sy"]) > 6)) {
        d["active"] := true
        try gGhost.Visible := false
    }
    if !d["active"] {
        if d["folder"] {
            OpenFolder(FOLDERS[d["folder"]])
        } else if d["idx"] {
            HideDrawer()
            LaunchItem(ITEMS[d["idx"]]["path"])
        }
        return
    }
    FinishDrag(d, x, y)
}

; ------------------------------------------------------------
;  右键菜单
; ------------------------------------------------------------
OnOverRUp(wParam, lParam, msg, hwnd) {
    global gOverlay, curPage, ITEMS, FOLDERS
    if (!IsObject(gOverlay) || hwnd != gOverlay.Hwnd || curPage = 0)
        return
    x := lParam & 0xFFFF
    y := (lParam >> 16) & 0xFFFF
    if (y < BAR_H)
        return
    fi := HitFolder(x, y)
    if fi {
        FolderMenu(fi)
        return
    }
    idx := HitItem(x, y)
    if idx
        ItemMenu(idx)
    else
        DrawerMenu()
}

ItemMenu(idx) {
    global ITEMS
    it := ITEMS[idx]
    LogWrite("item menu: " it["name"])
    m := Menu()
    m.Add("打开", (*) => (HideDrawer(), LaunchItem(it["path"])))
    m.Add("打开所在位置", (*) => (HideDrawer(), RevealItem(it["path"])))
    m.Add()
    m.Add("加入快捷启动栏（壁纸 6 格）", (*) => DockAdd(it))
    m.Add()
    m.Add("从抽屉中移除（保留文件）", (*) => RemoveItemFromDrawer(it["path"]))
    m.Add("删除文件到回收站…", DeleteItemHandler.Bind(it["path"]))
    m.Show()
}

; 空白处右键：不依赖托盘的主菜单入口
; 托盘与抽屉右键共用的菜单项，避免两处各写一遍
AddCommonMenuItems(m) {
    m.Add("添加文件到抽屉…", AddFilesToDrawer)
    m.Add("添加文件夹到抽屉…", AddFolderToDrawer)
    m.Add()
    m.Add("恢复被移除的图标", RestoreHiddenItems)
    m.Add()
    m.Add("重新扫描桌面", RescanDesktop)
    m.Add("重置图标布局", ResetLayout)
    m.Add()
    m.Add("待办任务…（编辑壁纸待办）", EditTodo)
}

TodoPaths() {
    global APP_DIR, WP_TODO_DIR, TODO_TXT, TODO_JS
    TODO_TXT := APP_DIR "\todo.txt"
    TODO_JS := WP_TODO_DIR "\todo-data.js"
}

; 读 todo.txt（一行一条，x 开头=已完成）写回壁纸的 todo-data.js
SyncTodoFile() {
    TodoPaths()
    global TODO_TXT, TODO_JS
    if !FileExist(TODO_TXT) {
        LogWrite("todo: no todo.txt")
        return 0
    }
    if !DirExist(WP_TODO_DIR) {
        LogWrite("todo: wallpaper dir missing")
        return 0
    }
    out := "", n := 0, done := 0
    txt := ""
    try txt := FileRead(TODO_TXT, "UTF-8")
    catch as e {
        LogWrite("todo: read failed " e.Message)
        return 0
    }
    for line in StrSplit(txt, "`n", "`r") {
        line := Trim(line)
        if (line = "")
            continue
        d := 0
        if (SubStr(line, 1, 2) = "x " || SubStr(line, 1, 2) = "X ") {
            d := 1
            line := Trim(SubStr(line, 3))
        } else if (SubStr(line, 1, 3) = "[x]" || SubStr(line, 1, 3) = "[X]") {
            d := 1
            line := Trim(SubStr(line, 4))
        }
        if (line = "")
            continue
        line := StrReplace(line, "\", "\\")
        line := StrReplace(line, "'", "\'")
        if (out != "")
            out .= ", "
        out .= "{ t: '" line "', d: " (d ? "true" : "false") " }"
        n += 1
        if (d)
            done += 1
    }
    js := "/* generated by DesktopPage: 一行一条，x 开头为已完成 */`n"
    js .= "window.__TODO_TS = " DateNowMs() ";`n"
    js .= "window.__TODO = [" out "];`n"
    try {
        FileDelete(TODO_JS)
    } catch as e {
        ; 首次可能不存在
    }
    try FileAppend(js, TODO_JS, "UTF-8")
    catch as e {
        LogWrite("todo: write failed " e.Message)
        return 0
    }
    LogWrite("todo: synced n=" n " done=" done)
    AuditLog("todo.sync", "n=" n " done=" done)
    return n
}

DateNowMs() {
    ; AHK v2 没有直接的毫秒时间戳，用 FILETIME 换算
    ft := 0
    DllCall("GetSystemTimeAsFileTime", "Int64*", &ft)
    return (ft // 10000) - 11644473600000
}

EditTodo(*) {
    TodoPaths()
    global TODO_TXT
    if !FileExist(TODO_TXT) {
        try FileAppend("整理这周的桌面文件`n", TODO_TXT, "UTF-8")
    }
    try RunWait('notepad.exe "' TODO_TXT '"')
    SyncTodoFile()
}

DrawerMenu(*) {
    m := Menu()
    AddCommonMenuItems(m)
    m.Add()
    m.Add("显示/隐藏系统桌面图标", ToggleIcons)
    m.Add("退出 DesktopPage", (*) => ExitApp())
    LogWrite("drawer menu opened")
    m.Show()
}

RevealItem(path) {
    try Run('explorer.exe /select,"' path '"')
}

; 删除到回收站（用户明确点击才会执行）
DeleteItemHandler(path, *) {
    ; 用自有确认小窗替代 MsgBox：MsgBox 会阻塞消息循环，抽屉看起来像卡死
    global gConfirm
    if IsObject(gConfirm)
        try gConfirm.Destroy()
    gConfirm := Gui("+AlwaysOnTop -DPIScale -MinimizeBox -MaximizeBox", "删除到回收站")
    gConfirm.SetFont("s10", "Microsoft YaHei UI")
    gConfirm.Add("Text", "x18 y16 w384 h64", "把这个项目移到回收站？`n" path)
    gConfirm.Add("Button", "x18 y96 w150 h34 Default", "移到回收站").OnEvent("Click", DoRecycle.Bind(path, gConfirm))
    gConfirm.Add("Button", "x190 y96 w120 h34", "取消").OnEvent("Click", CloseConfirm.Bind(gConfirm))
    gConfirm.OnEvent("Escape", CloseConfirm.Bind(gConfirm))
    gConfirm.OnEvent("Close", CloseConfirm.Bind(gConfirm))
    gConfirm.Show("w420 h150 Center")
    LogWrite("confirm shown: " path)
}

CloseConfirm(g, *) {
    global gConfirm
    try g.Destroy()
    gConfirm := 0
}

DoRecycle(path, g, *) {
    global gConfirm
    CloseConfirm(g)
    try {
        ; 通过临时 .ps1 执行，避免 -Command 里嵌套引号被吃掉
        tmp := APP_DIR "\recycle_tmp.ps1"
        q := StrReplace(path, "'", "''")
        body := "Add-Type -AssemblyName Microsoft.VisualBasic`r`n"
              . "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile('" q "','OnlyErrorDialogs','SendToRecycleBin')`r`n"
              . "exit 0`r`n"
        try FileDelete(tmp)
        FileAppend(body, tmp, "UTF-8")
        rc := RunWait('powershell -NoProfile -ExecutionPolicy Bypass -File "' tmp '"', , "Hide")
        Sleep(250)
        gone := !FileExist(path)
        LogWrite("recycle path=" path " exit=" rc " gone=" gone)
        AuditLog("item.recycle", "path=" Aq(path) " ok=" (gone ? 1 : 0) " exit=" rc)
        if (gone) {
            HIDDEN[path] := true
            SaveHidden()
            idx := ItemIndex(path)
            if idx
                HideItem(idx)
            RenderFolders()
            Repaint()
        }
    } catch as e {
        LogWrite("delete failed: " e.Message)
    }
}

FolderMenu(fi) {
    global FOLDERS
    f := FOLDERS[fi]
    m := Menu()
    m.Add("打开文件夹", (*) => OpenFolder(f))
    m.Add("重命名…", (*) => RenameFolder(f))
    m.Add()
    m.Add("解散文件夹（图标回到网格）", (*) => DissolveFolder(f))
    m.Show()
}

RenameFolder(f) {
    global gFolderGui
    if IsObject(gFolderGui)
        try gFolderGui.Destroy()
    gFolderGui := Gui("+AlwaysOnTop -DPIScale", "重命名文件夹")
    gFolderGui.SetFont("s10", "Microsoft YaHei UI")
    gFolderGui.Add("Text", "x18 y16 w320", "给这个文件夹起个名字：")
    ed := gFolderGui.Add("Edit", "x18 y48 w320", f["name"])
    ok := gFolderGui.Add("Button", "x18 y88 w90 Default", "确定")
    cc := gFolderGui.Add("Button", "x120 y88 w90", "取消")
    gFolderGui.OnEvent("Close", CloseRename.Bind(gFolderGui))
    cc.OnEvent("Click", CloseRename.Bind(gFolderGui))
    ok.OnEvent("Click", ApplyRename.Bind(f, ed, gFolderGui))
    ed.Focus()
    gFolderGui.Show("w356 h140")
    try WinActivate("ahk_id " gFolderGui.Hwnd)
}

; ------------------------------------------------------------
;  桌面判定 / 热键 / 启动
; ------------------------------------------------------------
DesktopUnderCursor() {
    MouseGetPos(&mx, &my)
    ; 坐标越界时不能把"取不到窗口"当成桌面：WindowFromPoint 失败会走到下面的 !h 分支，
    ; 那样在浏览器上滚轮也会误召唤抽屉（实测 MouseGetPos 偶尔返回 at=2420,-421 这种值）。
    if !PointOnVirtualDesktop(mx, my)
        return false
    h := DllCall("WindowFromPoint", "Int64", mx | (my << 32), "Ptr")
    if !h
        return true          ; 一个窗口都没有 = 光标在桌面上
    return ClassifyDeskWindow(h)
}

; 光标是否落在虚拟桌面坐标范围内（SM_XVIRTUALSCREEN..）
PointOnVirtualDesktop(x, y) {
    vx := DllCall("GetSystemMetrics", "Int", 76, "Int")   ; SM_XVIRTUALSCREEN
    vy := DllCall("GetSystemMetrics", "Int", 77, "Int")   ; SM_YVIRTUALSCREEN
    vw := DllCall("GetSystemMetrics", "Int", 78, "Int")   ; SM_CXVIRTUALSCREEN
    vh := DllCall("GetSystemMetrics", "Int", 79, "Int")   ; SM_CYVIRTUALSCREEN
    if (vw <= 0 || vh <= 0)
        return true
    return (x >= vx && y >= vy && x < vx + vw && y < vy + vh)
}

; 取类名/进程名一律走 DllCall，不用 WinGetClass / WinGetProcessName：
; 那两个函数受 DetectHiddenWindows 影响，撞上 WorkerW（壁纸表面，属于"隐藏的"顶层窗口）
; 或本脚本自己的 Gui 时会抛「Target window not found」，把整个滚轮判定打断，
; 表现就是「在桌面滚轮下滑没反应」——实测 Progman 能过、WorkerW/DrawerGui 直接抛异常。
WinClassOf(h) {
    static buf := Buffer(512, 0)
    if !h
        return ""
    if !DllCall("GetClassNameW", "Ptr", h, "Ptr", buf, "Int", 256)
        return ""
    return StrGet(buf, "UTF-16")
}

WinProcNameOf(h) {
    if !h
        return ""
    pid := 0
    try DllCall("GetWindowThreadProcessId", "Ptr", h, "UInt*", &pid)
    if !pid
        return ""
    try return ProcessGetName(pid)
    return ""
}

; 判定某个窗口算不算「桌面/壁纸」。单独拆出来是为了能手测（summon.cmd 的 `classify=<hwnd>`）。
;
; 2026-11-05 定案：**只顶到顶层窗口（GA_ROOT）再判**，绝不看光标命中的内层子窗口类名。
;   踩过的坑：Windows 11 的文件资源管理器（CabinetWClass）内部也挂着整套"桌面类名"的子窗口，实测树是
;     CabinetWClass → ShellTabWindowClass → DUIViewWndClassName → DirectUIHWND → CtrlNotifySink
;       → SHELLDLL_DefView → FileExplorer_FolderViewIsland   （文件列表区）
;       → NamespaceTreeControl → SysTreeView32               （左侧导航栏）
;   旧版这里是「从命中窗口往上 8 层，见到 Progman/WorkerW/SysListView32/SHELLDLL_DefView/SysHeader32
;   就算桌面」，于是光标落在资源管理器文件列表上就 desk=1，滚轮下滑直接召唤抽屉：
;     wheel.log: hover: desk=1 cls=SHELLDLL_DefView proc=explorer.exe at=149,235
;   而桌面图标层确实长这样（Progman → SHELLDLL_DefView → SysListView32 → SysHeader32），
;   所以这几个类名只能当"证据"，不能当"判据" —— 判据是：这条窗口链顶到哪个顶层窗口。
;   以后再遇到"某个应用里滚轮召唤了抽屉"，先用 `classify=<hwnd>` 看 root_cls，
;   别又把内层类名加回白名单。
ClassifyDeskWindow(h) {
    global curPage, gDrawer, gOverlay
    ; 抽屉自己也算法外：抽屉开着时光标就在它上面。
    ; 注意抽屉是三个窗口（gDrawer 图标层 / gOverlay 透明事件层 / gTip 提示），
    ; 只认 gDrawer 会把覆盖全屏的 DPOverlay 判成"非桌面"（实测 hover 出现 desk=0 cls=AutoHotkeyGUI）。
    if (curPage > 0) {
        if (IsObject(gDrawer) && (h = gDrawer.Hwnd || IsDescendantOf(h, gDrawer.Hwnd)))
            return true
        if (IsObject(gOverlay) && h = gOverlay.Hwnd)
            return true
    }
    if !h
        return false
    ; 一律先顶到顶层窗口：命中的是哪个内层子窗口（DirectUIHWND / Chrome_RenderWidgetHostHWND …）不重要
    root := DllCall("GetAncestor", "Ptr", h, "UInt", 2, "Ptr")    ; GA_ROOT
    if !root
        root := h
    rc := WinClassOf(root)
    ; 任务栏/托盘不算桌面（它们同样是 explorer.exe 的顶层窗口，得先排掉）
    if (rc = "Shell_TrayWnd" || rc = "Shell_SecondaryTrayWnd" || rc = "NotifyIconOverflowWindow")
        return false
    ; 桌面壳本体：Progman（壁纸 + 图标层）、WorkerW（Win10 的图标层/壁纸层挂在它下面）
    if (rc = "Progman" || rc = "WorkerW")
        return true
    ; Lively 壁纸：顶层窗口类名带 Lively 就放行
    if (InStr(rc, "Lively"))
        return true
    ; 兜底：根窗口进程是 Lively / CefSharp 系。壁纸真正渲染在 Lively.Player.WebView2.exe /
    ; CefSharp 子进程里（类名是 WindowsForms10 / Chrome_WidgetWin 之类），只能靠进程名认。
    ; 不能按 explorer.exe 判 —— 那是文件资源管理器，不是桌面。
    rp := WinProcNameOf(root)
    if (InStr(rp, "Lively") = 1 || InStr(rp, "CefSharp") = 1)
        return true
    ; 其余一律不是桌面：文件资源管理器（CabinetWClass / ShellTabWindowClass）、浏览器、任何应用。
    return false
}

; w 是否是 parent 的后代（含 parent 本身不做判定，调用方自己比）
IsDescendantOf(w, parent) {
    loop 8 {
        w := DllCall("GetAncestor", "Ptr", w, "UInt", 1, "Ptr")   ; GA_PARENT
        if !w
            return false
        if (w = parent)
            return true
    }
    return false
}

TipTest(*) {
    global gTip, CELL_H
    ShowTip("谭熊煊3123003386《数字营销》期末报告.docx", 400, 1200, CELL_H)
    Sleep(250)
    gTip.GetPos(&x, &y, &w, &h)
    LogWrite("tiptest w=" w " h=" h " text=" StrLen("谭熊煊3123003386《数字营销》期末报告.docx"))
    ShowTip("Kingdom Come Deliverance II v1.1.1 Plus 24 Trainer.exe", 400, 1200, CELL_H)
    Sleep(250)
    gTip.GetPos(&x2, &y2, &w2, &h2)
    LogWrite("tiptest2 w=" w2 " h=" h2)
    ExitApp()

}
StartupArgs() {
    ; 这些开关都是调试/自检用；ONESHOT = 跑完自己退出（退出时不还原桌面图标，见 ExitCleanup）
    global ONESHOT, NO_ACRYLIC
    for arg in A_Args {
        if (arg = "--show") {
            SetTimer(() => ShowDrawer(), -900)
            LogWrite("startup: --show")
        } else if (arg = "--plain") {
            NO_ACRYLIC := true
            LogWrite("startup: --plain")
        } else if (SubStr(arg, 1, 7) = "--page=") {
            n := Integer(SubStr(arg, 8))
            SetTimer(ShowPageAt.Bind(n), -900)
            LogWrite("startup: --page=" n)
        } else if (SubStr(arg, 1, 9) = "--rename=") {
            nm := SubStr(arg, 10)
            SetTimer(DebugRename.Bind(nm), -1200)
            LogWrite("startup: --rename=" nm)
        } else if (arg = "--todo-sync") {
            ONESHOT := true
            SetTimer(() => (SyncTodoFile(), ExitApp()), -900)
            LogWrite("startup: --todo-sync")
        } else if (arg = "--restore") {
            SetTimer(() => RestoreHiddenItems(), -900)
            LogWrite("startup: --restore")
        } else if (arg = "--diag") {
            ONESHOT := true
            SetTimer(Diag, -900)
        } else if (arg = "--scrolltest") {
            ONESHOT := true
            SetTimer(ScrollTest, -900)
            LogWrite("startup: --scrolltest")
        } else if (arg = "--tiptest") {
            ONESHOT := true
            SetTimer(() => TipTest(), -900)
            LogWrite("startup: --tiptest")
        } else if (arg = "--selftest") {
            ONESHOT := true
            SetTimer(() => SelfTest(), -1500)
            LogWrite("startup: --selftest")
        } else if (arg = "--rescan") {
            SetTimer(() => RescanDesktop(), -900)
            LogWrite("startup: --rescan")
        } else if (SubStr(arg, 1, 9) = "--launch=") {
            ; 自检用：走的是和"点文件夹里的文件"完全相同的 LaunchItem 路径
            ; 注意：闭包不能直接引用 for 循环变量（循环结束后它就没值了，实测报
            ; "This local variable has not been assigned a value"），必须先存到局部变量再捕获
            lp := SubStr(arg, 10)
            SetTimer(LaunchItem.Bind(lp), -1200)
            LogWrite("startup: --launch=" lp)
        } else if (SubStr(arg, 1, 8) = "--wheel=") {
            ; 自检用：绕开输入通道（本机没法注入滚轮），直接调滚轮决策层。
            ; 走的是和真实滚轮完全相同的 WheelHandle，所以能验证"桌面下滑→召唤""抽屉里上滑→收起"
            ; 以及 ClassifyDeskWindow 的真实判定（光标在哪就看哪）。seq = 先下滑再上滑。
            wd := SubStr(arg, 9)
            if (wd = "seq") {
                SetTimer(WheelHandle.Bind(1, "selftest", false), -1500)
                SetTimer(WheelHandle.Bind(-1, "selftest", false), -4000)
            } else {
                SetTimer(WheelHandle.Bind(Integer(wd), "selftest", false), -1500)
            }
            LogWrite("startup: --wheel=" wd)
        } else if (SubStr(arg, 1, 9) = "--bridge=") {
            ; 自检用：假装滚轮桥投来一条消息，走和真实桥完全相同的 OnMessage 处理函数。
            ; 因为本机 AHK 的鼠标通道会哑、注入也不可见，这是唯一能脚本化验证桥接链路的办法。
            bd := SubStr(arg, 10)
            SetTimer(WheelBridgeMsg.Bind(Integer(bd), 0, 0x8001, 0), -1500)
            LogWrite("startup: --bridge=" bd)
        }
    }
}

ShowPageAt(n) {
    FORCE_DIRTY := true
    HideTip()
    global curPage, gDrawer, GUI_W, GUI_H, FORCE_DIRTY
    ShowDrawer()
    if (n >= 1 && n <= PageCount()) {
        curPage := n
        UpdatePage()
    }
    WinMove(0, 0, GUI_W, GUI_H, "ahk_id " gDrawer.Hwnd)
}

; ---- 控制台区域：滚轮转成滚动意图发给壁纸代理（壁纸在桌面窗口后面，收不到真实滚轮） ----
PanelRect() {
    ; 壁纸页会把 #dshPanel 的屏幕矩形上报到这里；没有就用右侧 430px 兜底
    global APP_DIR, GUI_W, GUI_H
    global RECT_CACHE, RECT_STAMP
    f := APP_DIR . "\panel-rect.txt"
    try {
        if !FileExist(f)
            return [GUI_W - 430, 0, 430, 640]
        ts := FileGetTime(f, "M")
        if (IsObject(RECT_CACHE) && RECT_STAMP = ts)
            return RECT_CACHE
        line := Trim(FileRead(f, "UTF-8"))
        parts := StrSplit(line, " ")
        if (parts.Length < 4)
            return [GUI_W - 430, 0, 430, 640]
        ; 页面用万分比上报（兼容 WebView2 的 CSS 视口缩放）
        RECT_CACHE := [Round(Integer(parts[1]) * GUI_W / 10000)
            , Round(Integer(parts[2]) * GUI_H / 10000)
            , Round(Integer(parts[3]) * GUI_W / 10000)
            , Round(Integer(parts[4]) * GUI_H / 10000)]
        RECT_STAMP := ts
        return RECT_CACHE
    } catch
        return [GUI_W - 430, 0, 430, 640]
}

ConsoleUnderCursor() {
    CoordMode "Mouse", "Screen"
    MouseGetPos(&mx, &my)
    r := PanelRect()
    ; 上下各放宽 12px，方便贴着边滚
    return (mx >= r[1] - 12 && mx <= r[1] + r[3] + 12 && my >= r[2] - 12 && my <= r[2] + r[4] + 12)
}

Diag(*) {
    global GUI_W, GUI_H, BAR_H
    CoordMode "Mouse", "Screen"
    MouseGetPos(&mx, &my)
    LogWrite("diag: GUI_W=" GUI_W " GUI_H=" GUI_H " BAR_H=" BAR_H " screen=" A_ScreenWidth "x" A_ScreenHeight)
    LogWrite("diag: cursor=" mx "," my " console=" ConsoleUnderCursor() " desktop=" DesktopUnderCursor())
    ExitApp()
}
ScrollTest(*) {
    LogWrite("scrolltest: 3 x AgentScroll(1)")
    Loop 3 {
        AgentScroll(1)
        Sleep 120
    }
    LogWrite("scrolltest: sent")
    ExitApp()
}

AgentScroll(delta) {
    ; 走文件通道：AHK 只往 scroll.dat 追加 +1/-1，代理轮询时读走并累加
    global SCROLL_FILE
    try
        FileAppend(delta "`n", SCROLL_FILE, "UTF-8-RAW")
    catch as e
        LogWrite("agent scroll failed: " e.Message)
}

; ---- 代理健康：不在这里探 ----
; 曾经在脚本线程里每 20 秒发一次同步 HTTP 探测，结果是：代理假死时每次探测把脚本线程
; 阻塞最多 2.4 秒，AHK 的底层钩子跟着一起卡 —— 而这正是「滚轮/热键突然没反应」的成因之一。
; 现在健康检查全部交给 agent-watch.ps1（独立进程，没有 AHK 祖先、也不在 UI 线程上）：
;   日志 %LOCALAPPDATA%\DesktopPage\agent-watch.log
;   判据 pid 活着 + 心跳 dsh-agent.hb ≤45s + 17433 能连上，坏了两轮就 taskkill 后重拉。

; ---- 滚轮 ----
; 两条通道同时用：
;   1) AHK 热键（底层鼠标钩子）—— 正常情况下最先收到
;   2) Raw Input（RIDEV_INPUTSINK）—— 钩子被系统摘掉 / 被别的程序抢走时兜底
; 两条通道都进 WheelHandle，用时间戳互斥，保证同一次滚动只处理一遍。
$WheelDown:: {
    global WHEEL_HK_TICK, WHEEL_RAW_TICK, HK_ALIVE, WHEEL_HK_DOWN, WHEEL_HK_LOG
    ; 第一行无条件计数：只要这一行执行过，就证明「滚轮事件真的进到本进程了」。
    ; 必须放在任何 return 之前 —— 被下面 120ms 双通道去重挡掉的那一次也要留痕。
    WHEEL_HK_DOWN += 1
    if (A_TickCount - WHEEL_HK_LOG > 60000) {
        WHEEL_HK_LOG := A_TickCount
        mx := 0, my := 0
        try {
            CoordMode "Mouse", "Screen"
            MouseGetPos(&mx, &my)
        }
        LogWrite("wheel: hk down n=" WHEEL_HK_DOWN " at=" mx "," my)
    }
    if (!HK_ALIVE) {
        HK_ALIVE := true
        LogWrite("wheel channel alive: hk")
    }
    if (A_TickCount - WHEEL_RAW_TICK < 120)
        return
    WHEEL_HK_TICK := A_TickCount
    WheelHandle(1)
}

$WheelUp:: {
    global WHEEL_HK_TICK, WHEEL_RAW_TICK, HK_ALIVE, WHEEL_HK_UP, WHEEL_HK_LOG
    ; 同上：先计数再判定。以前「wheel-down 一行日志都没有」正是因为日志藏在 return 之后。
    WHEEL_HK_UP += 1
    if (A_TickCount - WHEEL_HK_LOG > 60000) {
        WHEEL_HK_LOG := A_TickCount
        mx := 0, my := 0
        try {
            CoordMode "Mouse", "Screen"
            MouseGetPos(&mx, &my)
        }
        LogWrite("wheel: hk up n=" WHEEL_HK_UP " at=" mx "," my)
    }
    if (!HK_ALIVE) {
        HK_ALIVE := true
        LogWrite("wheel channel alive: hk")
    }
    if (A_TickCount - WHEEL_RAW_TICK < 120)
        return
    WHEEL_HK_TICK := A_TickCount
    WheelHandle(-1)
}

; Ctrl+Alt+滚轮：在任意窗口上都能召唤/收起抽屉。
; 普通滚轮只在光标下面是桌面/壁纸时生效（否则会把浏览器、IDE 的滚动抢走），
; 加这个组合键是为了解决「全屏浏览器把桌面挡住时唤不出抽屉」。
^!WheelDown:: {
    WheelHandle(1, "hk", true)
}

^!WheelUp:: {
    WheelHandle(-1, "hk")
}


WheelHandle(dir, src := "hk", force := false) {
    global curPage, WHEEL_HITS, WHEEL_LASTDIR, WHEEL_LASTSRC
    WHEEL_HITS += 1
    WHEEL_LASTDIR := dir
    WHEEL_LASTSRC := src
    if (dir < 0) {
        if (curPage > 1) {
            curPage -= 1
            UpdatePage()
            LogWrite("wheel-up page=" curPage)
            AuditLog("wheel", "dir=-1 src=" src " act=page page=" curPage)
            return
        }
        if (curPage = 1) {
            HideDrawer()
            LogWrite("wheel-up drawer=0 page=0 via " src)
            AuditLog("wheel", "dir=-1 src=" src " act=page page=0")
            return
        }
        if ConsoleUnderCursor() {
            AgentScroll(-1)
            LogWrite("wheel-up console-scroll")
            AuditLog("wheel", "dir=-1 src=" src " act=console")
            return
        }
        WheelPassThrough(-1)
        return
    }
    if (curPage > 0) {
        if (curPage < PageCount()) {
            curPage += 1
            UpdatePage()
            LogWrite("wheel-down page=" curPage)
            AuditLog("wheel", "dir=1 src=" src " act=page page=" curPage)
        }
        return
    }
    if ConsoleUnderCursor() {
        AgentScroll(1)
        LogWrite("wheel-down console-scroll")
        AuditLog("wheel", "dir=1 src=" src " act=console")
        return
    }
    if (!force && !DesktopUnderCursor()) {
        WheelPassThrough(1)
        return
    }
    ShowDrawer()
    LogWrite("wheel-down drawer=1 via " src (force ? " forced" : ""))
    AuditLog("wheel", "dir=1 src=" src " act=summon" (force ? " force=1" : ""))
}

WheelPassThrough(dir) {
    global WHEEL_SELF_UNTIL, WHEEL_PT_LOG, WHEEL_HK_DOWN, WHEEL_HK_UP, RAW_WHEEL_TICKS
    ; 记下自己刚发出去的这次滚动：Raw Input 会把它再收一遍，必须当自己人跳过
    WHEEL_SELF_UNTIL := A_TickCount + 500
    ; 透传很频繁（在任何非桌面窗口上滚动都会走到），最多 30 秒记一条，
    ; 用来回答「我在桌面上滚动为什么没召唤抽屉」这类问题。
    ; 取类名/进程名/标题一律走 DllCall 版：WinGetClass / WinGetProcessName / WinGetTitle
    ; 受 DetectHiddenWindows 影响，撞上 WorkerW 或隐藏窗口会抛「Target window not found」，
    ; 而这里就在滚轮热键体里 —— 抛一次整条热键就断，连一行日志都留不下。
    ; 整个 info 构造也包在 try 里：取证失败不能影响后面的 Send。
    if (A_TickCount - WHEEL_PT_LOG > 30000) {
        WHEEL_PT_LOG := A_TickCount
        info := ""
        try {
            CoordMode "Mouse", "Screen"
            MouseGetPos(&mx, &my)
            h := DllCall("WindowFromPoint", "Int64", mx | (my << 32), "Ptr")
            if h {
                cls := WinClassOf(h)
                pn := WinProcNameOf(h)
                tt := WinTitleOf(h)
                if (StrLen(tt) > 30)
                    tt := SubStr(tt, 1, 30) "..."
                root := DllCall("GetAncestor", "Ptr", h, "UInt", 2, "Ptr")
                rcls := root ? WinClassOf(root) : ""
                info := " | at=" mx "," my " cls=" cls " proc=" pn " root=" rcls " title=" tt
            }
        } catch as e {
            info := " | probe failed: " e.Message
        }
        ; 带上方向与三个计数：一眼能对上「热键收到了几次 / raw 收到了几次 / 决策层跑了几个来回」
        LogWrite("wheel " (dir < 0 ? "up" : "down") " passed to app (cursor not on desktop)"
            . " hk_down=" WHEEL_HK_DOWN " hk_up=" WHEEL_HK_UP " raw_wheel=" RAW_WHEEL_TICKS info)
        ; 透传在"任何非桌面窗口上滚动"都会发生，复用上面这条 30 秒限流：
        ; 审计里只留样本，不跟着滚轮频率刷屏
        AuditLog("wheel", "dir=" (dir < 0 ? -1 : 1) " src=hk act=passthru")
    }
    if (dir < 0)
        Send("{WheelUp}")
    else
        Send("{WheelDown}")
}

; ---- 文件召唤通道：不依赖任何键鼠钩子 ----
; 代理 /summon.gif（以及任何脚本）往 summon.cmd 写一行 show/hide，400ms 内生效。
; ---- 钩子自愈 ----
REARM_TICKS := 0
RearmHooks() {
    global REARM_TICKS
    REARM_TICKS += 1
    try InstallMouseHook(true, true)      ; 强制重装；钩子已死/被摘时这一句就能救回来
    if (Mod(REARM_TICKS, 3) = 1)
        try InstallKeybdHook(true, true)  ; 键盘钩子同理，但没必要 5 秒一次
    if (Mod(REARM_TICKS, 60) = 0)         ; 每 5 分钟留一行心跳，便于事后看"重装还在跑"
        LogWrite("wheel: hooks rearmed x" REARM_TICKS)
}

; ---- 光标诊断：滚轮出问题时，这行日志能说明"它到底把哪儿当成了桌面" ----
; 只在判定结果变化时写一行，正常使用每天也就几十行。
HOVER_LAST := ""
HoverProbe() {
    global HOVER_LAST
    try {
        MouseGetPos(&mx, &my)
        if !PointOnVirtualDesktop(mx, my)
            return                     ; 越界读数（实测出现过 at=2420,-421）直接丢弃，别污染日志
        h := DllCall("WindowFromPoint", "Int64", mx | (my << 32), "Ptr")
        desk := h ? ClassifyDeskWindow(h) : 1
        cls := h ? WinClassOf(h) : ""
        pn := h ? WinProcNameOf(h) : ""
        key := desk "|" cls "|" pn
        if (key = HOVER_LAST)
            return
        HOVER_LAST := key
        LogWrite("hover: desk=" desk " cls=" cls " proc=" pn " at=" mx "," my)
    }
}

; 文件召唤：任何进程往 summon.cmd 写一行命令，这里 400ms 内读到并分发。
; 分发本身不判断命令 —— 命令表在文件顶部的 SUMMON_CMDS（命令名 → 处理函数），
; 加命令只需要「顶部加一条 Map 项 + 文件末尾加一个 Summon_CmdXxx」。
SummonTick() {
    global SUMMON_FILE, SUMMON_CMDS
    if !FileExist(SUMMON_FILE)
        return
    cmd := ""
    ; AHK v2 的 Trim() 默认只去空格和 Tab，**不去 CR/LF**。而 `echo show > summon.cmd`
    ; 写出来的文件末尾一定带换行 —— 以前这种调用会被当成未知命令静默丢弃（文件已删、无日志），
    ; 排查时看起来像"文件通道也是坏的"。这里显式把回车换行也当空白剪掉。
    try cmd := Trim(FileRead(SUMMON_FILE, "UTF-8"), " `t`r`n")
    try FileDelete(SUMMON_FILE)
    if (cmd = "")
        return
    ; 1) 精确匹配（O(1)）
    if SUMMON_CMDS.Has(cmd) {
        SUMMON_CMDS[cmd].fn.Call("")
        return
    }
    ; 2) 前缀匹配（带参数的命令）：arg = 去掉前缀后的剩余部分
    for name, e in SUMMON_CMDS {
        if !e.prefix
            continue
        if (SubStr(cmd, 1, StrLen(name)) = name) {
            e.fn.Call(SubStr(cmd, StrLen(name) + 1))
            return
        }
    }
    ; 未知命令：和以前一样静默忽略（summon.cmd 被别的程序写脏时不刷日志）
}


; ---- 滚轮兜底通道：Raw Input ----
WheelRawInit() {
    global gDrawer, RAW_OK
    ; RAWINPUTDEVICE: USHORT usUsagePage, USHORT usUsage, DWORD dwFlags, HWND hwndTarget
    rid := Buffer(16, 0)
    NumPut("UShort", 0x01, rid, 0)       ; HID_USAGE_PAGE_GENERIC
    NumPut("UShort", 0x02, rid, 2)       ; HID_USAGE_GENERIC_MOUSE
    NumPut("UInt", 0x00000100, rid, 4)   ; RIDEV_INPUTSINK：没有焦点也能收到
    ; 目标窗口必须是脚本主窗口（A_ScriptHwnd）：OnMessage(0x00FF) 只监视主窗口收到的消息，
    ; 挂到 gDrawer.Hwnd 时 WM_INPUT 全进 Gui 的窗口过程，OnRawWheel 永远不会被调用
    ;（实测：rawinput: register=1 但 raw_ticks 恒为 0，兜底通道形同不存在）
    NumPut("Ptr", A_ScriptHwnd, rid, 8)   ; 目标必须是脚本主窗口，见下方注释
    RAW_OK := DllCall("RegisterRawInputDevices", "Ptr", rid, "UInt", 1, "UInt", 16, "Int")
    LogWrite("rawinput: register=" RAW_OK " target=" A_ScriptHwnd)
    return RAW_OK
}

OnRawWheel(wParam, lParam, *) {
    global RAW_BUF, RAW_WARNED, RAW_HWARNED, WHEEL_RAW_TICK, WHEEL_HK_TICK, WHEEL_SELF_UNTIL
    global RAW_TICKS, RAW_LASTLOG, RAW_MSGS, RAW_MOVE_TICKS, RAW_WHEEL_TICKS
    hdrSize := 8 + 2 * A_PtrSize          ; sizeof(RAWINPUTHEADER)
    RAW_MSGS += 1
    size := 0
    DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", 0, "UInt*", &size, "UInt", hdrSize)
    if (size < hdrSize + 24)
        return 0
    if (!IsObject(RAW_BUF) || RAW_BUF.Size < size)
        RAW_BUF := Buffer(size, 0)
    got := 0
    DllCall("GetRawInputData", "Ptr", lParam, "UInt", 0x10000003, "Ptr", RAW_BUF, "UInt*", &got, "UInt", hdrSize)
    if (got < hdrSize + 24)
        return 0
    if (NumGet(RAW_BUF, 0, "UInt") != 0)   ; RIM_TYPEMOUSE
        return 0
    ; 走到这里说明收到的是真实鼠标报文（移动也算）：留个心跳证明 Raw Input 通道活着
    RAW_TICKS += 1
    RAW_MOVE_TICKS += 1                    ; 与 RAW_TICKS 同义，新名字表达更明确（所有鼠标报文）
    if (A_TickCount - RAW_LASTLOG > 300000) {
        RAW_LASTLOG := A_TickCount
        LogWrite("raw: WM_INPUT alive x" RAW_TICKS " move=" RAW_MOVE_TICKS " wheel=" RAW_WHEEL_TICKS)
    }
    flags := NumGet(RAW_BUF, hdrSize + 4, "UShort")
    if (flags & 0x0800) {                  ; RI_MOUSE_HWHEEL：横向滚轮，先只记录，不改行为
        if (!RAW_HWARNED) {
            RAW_HWARNED := true
            hd := NumGet(RAW_BUF, hdrSize + 6, "Short")
            LogWrite("rawinput: horizontal wheel delta=" hd " (vertical not seen yet)")
        }
        return 0
    }
    if (!(flags & 0x0400))                 ; RI_MOUSE_WHEEL
        return 0
    delta := NumGet(RAW_BUF, hdrSize + 6, "Short")
    if (delta = 0)
        return 0
    ; 到这里才算「滚轮报文真的到了本进程」。先计数再走抑制逻辑：
    ; self / hk 那两条去重只决定「要不要动作」，不改变「事件到没到」这个事实。
    RAW_WHEEL_TICKS += 1
    if (RAW_WHEEL_TICKS <= 3)
        LogWrite("raw wheel delta=" delta " ticks=" RAW_WHEEL_TICKS)
    if (A_TickCount < WHEEL_SELF_UNTIL)    ; 自己刚转发出去的那次
        return 0
    if (A_TickCount - WHEEL_HK_TICK < 120) ; 热键通道已经处理过
        return 0
    WHEEL_RAW_TICK := A_TickCount
    if (!RAW_ALIVE) {
        RAW_ALIVE := true
        LogWrite("wheel channel alive: raw")
    }
    if (!RAW_WARNED) {
        RAW_WARNED := true
        LogWrite("rawinput: wheel arrived with no hotkey path (mouse hook likely dead)")
    }
    ; Windows 约定：raw 的 usButtonData 与 WM_MOUSEWHEEL 同号，正数 = 向前（向上）滚；
    ; 而 WheelHandle 的 1 = 向下（召唤）、-1 = 向上（收起），所以这里要取反
    up := (delta > 0)
    ; Ctrl+Alt+向下滚 = 强制召唤（不看光标下方是不是桌面）
    force := (!up && GetKeyState("Ctrl", "P") && GetKeyState("Alt", "P"))
    WheelHandle(up ? -1 : 1, "raw", force)
    return 0
}

; ---- 滚轮桥通道 ----------------------------------------------------------
; wheel-bridge.exe（同目录，C# 编译）装 WH_MOUSE_LL 专门看滚轮。它不吞事件，
; 只把"看到了一次向下/向上滚"通过 PostMessage(0x8001, 1|2) 告诉这里。
; 为什么不让抽屉自己看：本机 AHK 进程的鼠标通道会整条哑掉（键盘钩子还活着），
; 而同一时刻普通 .NET 进程装 WH_MOUSE_LL 能稳定收到 delta=±120，所以把这件事
; 交给一个不受 AHK 影响的小进程。详见 docs\项目地图.md §8。
BridgeAnnounce() {
    global BRIDGE_FILE, BRIDGE_ANNOUNCE_LOG, WHEEL_BRIDGE_TICK
    ; 句柄写文件给桥读。桥那边是「热跟随」：每 5 秒 + 每次投递前重读，
    ; 发现当前目标没了就立刻丢权重读 → 抽屉重启后不需要重启桥。
    ; 写入用「临时文件 + 覆盖移动」，避免桥正好读在 FileDelete 与 FileAppend 之间的空窗。
    ; 注意：AHK v2 的 FileDelete 在「没有文件可删」时会抛 (2) 系统找不到指定的文件，
    ; 所以它必须单独 try —— 放在同一个 try 里会让整个落盘流程一次都不执行（2026-11-05 踩过）。
    tmp := BRIDGE_FILE ".tmp"
    try FileDelete(tmp)
    try {
        FileAppend(A_ScriptHwnd "`n", tmp, "UTF-8")
        FileMove(tmp, BRIDGE_FILE, 1)
    } catch as e {
        LogWrite("bridge: announce 落盘失败 file=" BRIDGE_FILE " err=" e.Message)
    }
    if (A_TickCount - BRIDGE_ANNOUNCE_LOG > 60000) {
        BRIDGE_ANNOUNCE_LOG := A_TickCount
        LogWrite("bridge: announce hwnd=" A_ScriptHwnd
            . " bridge_age=" (WHEEL_BRIDGE_TICK ? A_TickCount - WHEEL_BRIDGE_TICK : -1)
            . " bridge_hits=" WHEEL_BRIDGE_HITS)
    }
}

WheelBridgeMsg(wParam, lParam, msg, hwnd) {
    global WHEEL_HK_TICK, WHEEL_RAW_TICK, WHEEL_BRIDGE_TICK, WHEEL_BRIDGE_HITS, WHEEL_BRIDGE_LOG
    global curPage
    WHEEL_BRIDGE_HITS += 1
    WHEEL_BRIDGE_TICK := A_TickCount
    ; 热键 / Raw Input / 桥 三条通道 120ms 内只算一次（钩子活着时三条会同时到）
    if (A_TickCount - WHEEL_HK_TICK < 120 || A_TickCount - WHEEL_RAW_TICK < 120)
        return 0
    WHEEL_HK_TICK := A_TickCount
    WHEEL_RAW_TICK := A_TickCount
    up := (wParam != 1)
    ; 桥不吞事件，应用本来就收到了这次滚动。所以只在"抽屉真的要动作"时接管：
    ; 抽屉关着、光标又不在桌面（或是在向上滚）→ 什么都别做，免得多滚一屏。
    if (curPage = 0 && (up || !DesktopUnderCursor()))
        return 0
    if (A_TickCount - WHEEL_BRIDGE_LOG > 60000) {
        WHEEL_BRIDGE_LOG := A_TickCount
        mx := 0, my := 0
        try MouseGetPos(&mx, &my)
        LogWrite("bridge: wheel " (up ? "up" : "down") " hits=" WHEEL_BRIDGE_HITS
            . " page=" curPage " at=" mx "," my)
    }
    WheelHandle(up ? -1 : 1, "bridge")
    return 0
}

~Esc:: {
    ; 前缀 ~ 不能少：没有它 AHK 的钩子会把 Esc 全局吞掉，其它程序都收不到 
    ; 只在抽屉可见时接管：否则确认框、重命名框和其它程序都收不到 Esc
    global curPage, gDrawer, gConfirm
    if (!IsObject(gDrawer) || !DllCall("IsWindowVisible", "Ptr", gDrawer.Hwnd))
        return
    if (IsObject(gConfirm) && DllCall("IsWindowVisible", "Ptr", gConfirm.Hwnd)) {
        gConfirm.Hide()
        return
    }
    if (curPage > 0)
        HideDrawer()
    }

^!Space:: {
    global curPage
    if (curPage > 0)
        HideDrawer()
    else
        ShowDrawer()
}

^!d:: ToggleIcons()

; 键盘召唤兜底：键盘钩子只要还活着（^!Space 能用）这两个就一定能用
^!Down:: WheelHandle(1, "key", true)
^!Up:: WheelHandle(-1, "key", true)

; ---- 托盘 ----
A_TrayMenu.Delete()
A_TrayMenu.Add("显示图标页", (*) => ShowDrawer())
A_TrayMenu.Add("隐藏系统桌面图标", ToggleIcons)
A_TrayMenu.Add()
AddCommonMenuItems(A_TrayMenu)
A_TrayMenu.Add()
A_TrayMenu.Add("退出", (*) => ExitApp())
A_IconTip := "Desktop Page - 桌面两页（双击打开图标页）"
try A_TrayMenu.Default := "显示图标页"

ResetLayout(*) {
    FORCE_DIRTY := true
    global LAYOUT_FILE, POS, FOLDERS, GROUP_OF, FORCE_DIRTY
    try FileDelete(LAYOUT_FILE)
    POS := Map(), FOLDERS := [], GROUP_OF := Map()
    ReloadItems()
    LogWrite("layout reset")
}

ExitCleanup(*) {
    global ONESHOT
    ; 一次性任务（--todo-sync / --tiptest 等）不是常驻进程，退出时不能把桌面图标放出来
    if (ONESHOT) {
        LogWrite("exit cleanup (oneshot, icons untouched)")
        return
    }
    try IconsScript("show")
    try FileDelete(APP_DIR "\drawer.pid")
    LogWrite("exit cleanup")
}

OnExit(ExitCleanup)

; ---- 主流程 ----
LoadFonts()
LoadPositions()
LoadItems()
LoadLayout()
ComputeLayout()
if (NormalizePositions())
    SaveLayout()
BuildGui()
; 滚轮兜底通道（鼠标钩子被系统摘掉时靠 Raw Input 兜住）+ 本地代理看门狗
OnMessage(0x00FF, OnRawWheel)
WheelRawInit()
; 滚轮桥：独立 C# 进程（wheel-bridge.exe）装 WH_MOUSE_LL 看滚轮，看懂就 PostMessage(0x8001) 回来。
; 本机 AHK 的鼠标通道会整条哑掉（见 :92 附近注释与 docs\项目地图.md §8 的记录），
; 桥是唯一在"AHK 收不到鼠标"时还能用的滚轮入口，所以默认常开、并且每 30 秒重新宣告一次窗口句柄。
OnMessage(0x8001, WheelBridgeMsg)
BridgeAnnounce()
SetTimer(BridgeAnnounce, 30000)
WHEEL_HK_TICK := A_TickCount
; 钩子：**不再调用 InstallMouseHook / InstallKeybdHook**。
; 对照打包前（11-01）的版本，那一版一次都没有调用过这两个函数，而滚轮上下都正常；
; 打包后加了周期性强制重装，滚轮就彻底收不到事件了（diag 里 hk_down/hk_up 恒 0，
; 而 ^!Space 等键盘热键仍然可用）。上一轮只把它从"每 5 秒"改成"启动后一次"仍然不行，
; 说明只要调用过就会把 AHK 自动装好的鼠标钩子弄坏。这里彻底不碰，交还给 AHK 自己管。
; 排障：summon.cmd 写 diag 看 hk_down/hk_up；确需重装时单独调 RearmHooks()（不挂定时器）。
SetTimer(HoverProbe, 1000)      ; 光标分类变化时写一行 hover: 日志，滚轮排查用
SetTimer(EdgeProbe, 120)        ; 屏幕边缘热区：滚轮通道整个废掉时的等价唤起入口（零配置默认开）
SetTimer(SummonTick, 400)       ; 文件召唤通道（代理 /summon.gif / 手动写 summon.cmd 都能用）
CurPageInit()
RestoreIconState()
StartupArgs()
; 权限自检：UAC 关掉（EnableLUA=0）时所有进程本来就是管理员，那条告警毫无意义；
; 只在 UAC 正常开着、而抽屉却被带高时才值得记一行 —— 那种情况下从抽屉启动的程序都会继承管理员，
; 控制台目标会弹「管理员:」空黑框、鹰角启动器这类会初始化失败、-WindowStyle Hidden 也会失效。
; 不自动重启自己（提权进程 CreateProcess 出来的子进程仍是提权的，只能由普通窗口重开），所以只记日志。
uacLua := 1
try uacLua := RegRead("HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System", "EnableLUA")
if (uacLua = 0)
    LogWrite("startup: note UAC disabled (EnableLUA=0) — all processes are elevated, spawn without consoles")
else if (A_IsAdmin)
    LogWrite("startup: WARNING running ELEVATED while UAC is on")
LogWrite("startup: items=" ITEMS.Length " state=" QueryIcons())
LogWrite("layout: cell=" CELL_W "x" CELL_H " icon=" ICON_PX " grid=" GRID_X "," GRID_Y " cols=" COLS " rows=" ROWS " perPage=" PER_PAGE " items=" ITEMS.Length)
LogWrite("screen: " A_ScreenWidth "x" A_ScreenHeight " dpi=" A_ScreenDPI " scale=" SCALE " hwnd=" gDrawer.Hwnd)
; 记下本进程 pid：ensure-all.ps1 靠它判断"抽屉还活着"。
; 只按进程名 AutoHotkey64 判断会把诊断脚本也算进去（实测 20:03 因此没重启真抽屉）。
try FileDelete(APP_DIR "\drawer.pid")
try FileAppend(DllCall("GetCurrentProcessId", "UInt") "`n", APP_DIR "\drawer.pid")

CurPageInit() {
    global curPage
    curPage := 0
}

CloseRename(g, *) {
    global gFolderGui
    try g.Destroy()
    gFolderGui := 0
}

ApplyRename(f, ed, g, *) {
    global gFolderGui
    n := Trim(ed.Value)
    try g.Destroy()
    gFolderGui := 0
    if (n = "")
        return
    f["name"] := n
    SaveLayout()
    RenderFolders()
    Repaint()
    LogWrite("folder renamed: " n)
}

DissolveFolder(f) {
    FORCE_DIRTY := true
    global FOLDERS, GROUP_OF, gFolderGui, FORCE_DIRTY
    if IsObject(gFolderGui)
        try gFolderGui.Destroy()
    id := f["id"]
    for i, ff in FOLDERS {
        if (ff["id"] = id) {
            FOLDERS.RemoveAt(i)
            break
        }
    }
    for m in f["members"] {
        if GROUP_OF.Has(m)
            GROUP_OF.Delete(m)
        idx := ItemIndex(m)
        if idx
            ShowItemDefault(idx)
    }
    RenderFolders()
    Repaint()
    SaveLayout()
    LogWrite("folder dissolved: " id)
    AuditLog("folder.dissolve", "id=" id " name=" Aq(f["name"]) " n=" f["members"].Length)
}

RemoveItemFromDrawer(path) {
    global HIDDEN, GROUP_OF
    t0 := A_TickCount
    if GROUP_OF.Has(path)
        try RemoveFromFolder(path)
    HIDDEN[path] := true
    SaveHidden()
    idx := ItemIndex(path)
    if (idx > 0)
        try HideItem(idx)
    LastHoverReset()
    LogWrite("item hidden: " path " ms=" (A_TickCount - t0))
    AuditLog("item.hide", "path=" Aq(path) " ms=" (A_TickCount - t0))
}

RestoreHiddenItems(*) {
    global HIDDEN
    HIDDEN := Map()
    SaveHidden()
    ReloadItems()
    LogWrite("hidden list cleared")
}

; 重建抽屉：先建新窗口再销毁旧窗口，避免中间出现空白/闪一下（用户会误以为卡死）
ReloadItems() {
    global gDrawer, curPage, GUI_W, GUI_H, CTRL_POOL, ITEMS
    t0 := A_TickCount
    wasOpen := DrawerVisible()
    LoadItems()
    t1 := A_TickCount
    ComputeLayout()
    NormalizeLayout()
    t2 := A_TickCount
    if !wasOpen
        curPage := 0
    EnsureWindow()
    t3 := A_TickCount
    SyncItems()
    t4 := A_TickCount
    UpdatePage()
    t5 := A_TickCount
    if (wasOpen) {
        try WinMove(0, 0, GUI_W, GUI_H, "ahk_id " gDrawer.Hwnd)
        ShowDrawer(true)
    }
    LastHoverReset()
    LogWrite("reload items=" ITEMS.Length " open=" wasOpen " ms=" (A_TickCount - t0)
        " [load=" (t1 - t0) " layout=" (t2 - t1) " win=" (t3 - t2) " sync=" (t4 - t3) " page=" (t5 - t4) " show=" (A_TickCount - t5) "]")
}

LastHoverReset() {
    global LAST_HOVER
    LAST_HOVER := 0
}

AddFilesToDrawer(*) {
    wasOpen := DrawerVisible()
    try HideOverlay()
    try HideDrawer()
    sel := 0
    try sel := FileSelect("M3", A_Desktop, "选择要加入抽屉的文件（可多选）")
    if (IsObject(sel) && sel.Length)
        AddPathsToDrawer(sel)
    else if wasOpen
        ShowDrawer()
}

AddFolderToDrawer(*) {
    wasOpen := DrawerVisible()
    try HideOverlay()
    try HideDrawer()
    sel := ""
    try sel := FileSelect("D3", A_Desktop, "选择要加入抽屉的文件夹")
    if (sel)
        AddPathsToDrawer([sel])
    else if wasOpen
        ShowDrawer()
}

AddPathsToDrawer(paths, reopen := false) {
    global APP_DIR, HIDDEN
    ps := APP_DIR "\Build-IconCache.ps1"
    if !FileExist(ps)
        return
    args := ""
    for p in paths
        args .= ' -AddPath "' p '"'
    RunWait('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' ps '"' args, , "Hide")
    for p in paths {
        if HIDDEN.Has(p) {
            HIDDEN.Delete(p)
        }
    }
    SaveHidden()
    ReloadItems()
    LogWrite("added to drawer: " paths.Length)
}


DragMove(x, y) {
    global DRAG, gGhost, ITEMS, APP_DIR, ICON_PX, FOLDER_CTRLS
    if !DRAG["active"] {
        if (Abs(x - DRAG["sx"]) + Abs(y - DRAG["sy"]) < 10)
            return
        DRAG["active"] := true
        if DRAG["idx"] {
            it := ITEMS[DRAG["idx"]]
            gGhost.Value := it["icon"]
            it["pic"].Visible := false
            it["txt"].Visible := false
        } else {
            gGhost.Value := APP_DIR "\folder.png"
            ; 拖文件夹时先把它自己藏起来，避免"一个跟手一个留在原地"的错觉
            for c in FOLDER_CTRLS
                try c.Visible := false
        }
        gGhost.Visible := true
    }
    gGhost.Move(x - ICON_PX // 2, y - ICON_PX // 2)
}

FinishDrag(d, cx, cy) {
    global ITEMS, FOLDERS, POS, gGhost, GUI_W, GUI_H, ICON_PX, CELL_W, CELL_H
    try gGhost.Visible := false
    nx := SnapX(cx - ICON_PX // 2)
    ny := SnapY(cy - ICON_PX // 2)
    ; 起手若按在文件夹上，无论落到哪里都只移动这个文件夹（不新建文件夹）
    pf := HitFolder(d["sx"], d["sy"])
    if pf {
        f0 := FOLDERS[pf]
        f0["x"] := nx, f0["y"] := ny
        RenderFolders()
        SaveLayout()
        LogWrite("folder moved: " f0["id"] " -> " nx "," ny)
        return
    }
    if d["idx"] {
        it := ITEMS[d["idx"]]
        tf := HitFolder(cx, cy)
        if tf {
            AddToFolder(tf, it["path"])
            return
        }
        ti := HitItem(cx, cy, d["idx"])
        if ti {
            MakeFolder(d["idx"], ti)
            return
        }
        POS[it["path"]] := [nx, ny]
        PlaceItem(d["idx"], nx, ny)
        SaveLayout()
        LogWrite("moved: " it["path"] " -> " nx "," ny)
        return
    }
    f := FOLDERS[d["folder"]]
    f["x"] := nx, f["y"] := ny
    RenderFolders()
    SaveLayout()
}

; 把落点吸附到网格，保证拖拽后行高列距一致，不会卡在两行之间
SnapX(x) {
    global GRID_X, CELL_W, GUI_W
    s := GRID_X + Round((x - GRID_X) / CELL_W) * CELL_W
    return Max(GRID_X, Min(GUI_W - CELL_W - 4, s))
}

SnapY(y) {
    global GRID_Y, CELL_H, GUI_H
    s := GRID_Y + Round((y - GRID_Y) / CELL_H) * CELL_H
    return Max(GRID_Y, Min(GUI_H - CELL_H - 4, s))
}
; 旧版本自由摆放留下的坐标不在网格上，加载时统一吸回网格，避免出现"卡在两行之间"的历史遗留
NormalizePositions() {
    global POS, FOLDERS
    keys := []
    for k, v in POS
        keys.Push(k)
    changed := false
    for k in keys {
        v := POS[k]
        sx := SnapX(v[1]), sy := SnapY(v[2])
        if (sx != v[1] || sy != v[2]) {
            POS[k] := [sx, sy]
            changed := true
        }
    }
    for f in FOLDERS {
        sx := SnapX(f["x"]), sy := SnapY(f["y"])
        if (sx != f["x"] || sy != f["y"]) {
            f["x"] := sx, f["y"] := sy
            changed := true
        }
    }
    return changed
}
; 两个图标被摆到同一格（拖拽/旧坐标吸附后常见）会视觉重叠：把后来的那个顺移到最近的空格。
ResolveOverlaps() {
    global ITEMS, HIDDEN, GROUP_OF, CELL_W, CELL_H, GRID_X, GRID_Y, GUI_W, GUI_H, POS
    taken := Map()
    changed := false
    for i, it in ITEMS {
        if !it.Has("pic") || !it["pic"].Visible
            continue
        k := Round((it["x"] - GRID_X) / CELL_W) "_" Round((it["y"] - GRID_Y) / CELL_H)
        if !taken.Has(k) {
            taken[k] := i
            continue
        }
        ; 找最近的空格（逐行扫描）
        found := false
        row := 0
        while (row < 40 && !found) {
            col := 0
            while (col < 40 && !found) {
                x := GRID_X + col * CELL_W
                y := GRID_Y + row * CELL_H
                if (x + CELL_W > GUI_W || y + CELL_H > GUI_H) {
                    col := 40
                    continue
                }
                kk := col "_" row
                if !taken.Has(kk) {
                    taken[kk] := i
                    POS[it["path"]] := [x, y]
                    PlaceItem(i, x, y)
                    changed := true
                    found := true
                }
                col += 1
            }
            row += 1
        }
    }
    if changed {
        SaveLayout()
        LogWrite("overlaps resolved")
    }
    return changed
}

PlaceItem(idx, x, y) {
    global ITEMS, CELL_W, ICON_PX, SCALE
    it := ITEMS[idx]
    if (it.Has("dx") && it["dx"] = x && it["dy"] = y && it["pic"].Visible) {
        it["x"] := x, it["y"] := y
        return
    }
    it["x"] := x, it["y"] := y, it["dx"] := x, it["dy"] := y
    py := y + Round(4 * SCALE)
    it["hl"].Move(x + 3, y)
    it["pic"].Move(x + (CELL_W - ICON_PX) // 2, py)
    it["txt"].Move(x, py + ICON_PX + Round(2 * SCALE))
    it["hl"].Visible := false
    it["pic"].Visible := true
    it["txt"].Visible := true
}

ShowItemDefault(idx) {
    global ITEMS
    s := DefaultSlot(idx)
    PlaceItem(idx, s[1], s[2])
}

HideItem(idx) {
    global ITEMS
    it := ITEMS[idx]
    it["dx"] := -99999, it["dy"] := -99999
    if it.Has("pic") {
        it["pic"].Visible := false
        it["txt"].Visible := false
        it["hl"].Visible := false
    }
}

Repaint() {
    global gDrawer
    try DllCall("RedrawWindow", "Ptr", gDrawer.Hwnd, "Ptr", 0, "Ptr", 0, "UInt", 0x0185)
}

MakeFolder(idxA, idxB) {
    FORCE_DIRTY := true
    global ITEMS, FOLDERS, GROUP_OF, POS, DRAG, FORCE_DIRTY
    a := ITEMS[idxA], b := ITEMS[idxB]
    ; 同一对项目已经在同一个文件夹里 → 什么都不做，避免重复建夹
    if (GROUP_OF.Has(a["path"]) && GROUP_OF.Has(b["path"]) && GROUP_OF[a["path"]] = GROUP_OF[b["path"]])
        return
    ; 任一项目已在别的文件夹里 → 先把它从旧文件夹摘出来（不允许一个项目同时属于两个文件夹）
    for p in [a["path"], b["path"]] {
        if GROUP_OF.Has(p) {
            try RemoveFromFolder(p)
        }
    }
    fx := b["x"], fy := b["y"]
    id := "f" (FOLDERS.Length + 1) "_" A_TickCount
    FOLDERS.Push(Map("id", id, "name", "文件夹 " (FOLDERS.Length + 1), "x", fx, "y", fy, "members", [b["path"], a["path"]]))
    GROUP_OF[b["path"]] := id
    GROUP_OF[a["path"]] := id
    if POS.Has(a["path"])
        POS.Delete(a["path"])
    if POS.Has(b["path"])
        POS.Delete(b["path"])
    HideItem(idxA)
    HideItem(idxB)
    RenderFolders()
    SaveLayout()
    LogWrite("folder created: " id " <- " a["path"] ", " b["path"])
    AuditLog("folder.create", "id=" id " a=" Aq(a["path"]) " b=" Aq(b["path"]))
}

AddToFolder(fi, path) {
    FORCE_DIRTY := true
    global FOLDERS, GROUP_OF, POS, FORCE_DIRTY
    f := FOLDERS[fi]
    if HasMember(f, path)
        return
    f["members"].Push(path)
    GROUP_OF[path] := f["id"]
    if POS.Has(path)
        POS.Delete(path)
    idx := ItemIndex(path)
    if idx
        HideItem(idx)
    RenderFolders()
    SaveLayout()
    LogWrite("added to folder: " path)
    AuditLog("folder.add", "name=" Aq(f["name"]) " path=" Aq(path))
}

HasMember(f, path) {
    for m in f["members"]
        if (m = path)
            return true
    return false
}

RemoveFromFolder(path) {
    FORCE_DIRTY := true
    global GROUP_OF, FOLDERS, FORCE_DIRTY
    if !GROUP_OF.Has(path)
        return
    id := GROUP_OF[path]
    GROUP_OF.Delete(path)
    for i, f in FOLDERS {
        if (f["id"] != id)
            continue
        for j, m in f["members"] {
            if (m = path) {
                f["members"].RemoveAt(j)
                break
            }
        }
        if (f["members"].Length <= 1) {
            ; 只剩 0 或 1 个：解散文件夹，成员回桌面
            rest := []
            for m in f["members"]
                rest.Push(m)
            FOLDERS.RemoveAt(i)
            for m in rest {
                GROUP_OF.Delete(m)
                idx := ItemIndex(m)
                if idx
                    ShowItemDefault(idx)
            }
        }
        break
    }
    idx := ItemIndex(path)
    if idx
        ShowItemDefault(idx)
    RenderFolders()
    SaveLayout()
}

RenderFolders() {
    global FOLDERS, FOLDER_CTRLS, POOL_BG, POOL_MINI, POOL_TXT, gDrawer, ITEMS, CELL_W, CELL_H, ICON_PX, SCALE, APP_DIR
    NormalizeLayout()
    if !gDrawer
        return
    for c in POOL_BG
        try c.Visible := false
    for c in POOL_MINI
        try c.Visible := false
    for c in POOL_TXT
        try c.Visible := false

    foldPx := ICON_PX                         ; 和普通图标一样长宽
    m := Round(foldPx * 0.30)
    gap := Max(2, Round(foldPx * 0.03))
    bi := 0, mi := 0, ti := 0

    for f in FOLDERS {
        x := f["x"], y := f["y"]
        tx := x + (CELL_W - foldPx) // 2
        ty := y + Round(2 * SCALE)

        bi += 1
        if (bi > POOL_BG.Length) {
            POOL_BG.Push(gDrawer.Add("Picture", "x" tx " y" ty " w" ICON_PX " h" ICON_PX " BackgroundTrans", APP_DIR "\folder.png"))
            bg := POOL_BG[bi]
        } else {
            bg := POOL_BG[bi]
            bg.Move(tx, ty, foldPx, foldPx)
        }
        bg.Visible := true

        gridW := m * 2 + gap
        bx := tx + (foldPx - gridW) // 2
        by := ty + Round(foldPx * 0.26)
        n := 0
        for path in f["members"] {
            if (n >= 4)
                break
            it := FindItem(path)
            if !it
                continue
            mx := bx + Mod(n, 2) * (m + gap)
            my := by + Floor(n / 2) * (m + gap)
            mi += 1
            if (mi > POOL_MINI.Length) {
                POOL_MINI.Push(gDrawer.Add("Picture", "x" mx " y" my " w" m " h" m " BackgroundTrans", it["icon"]))
                pc := POOL_MINI[mi]
            } else {
                pc := POOL_MINI[mi]
                pc.Value := it["icon"]
                pc.Move(mx, my, m, m)
            }
            pc.Visible := true

            n += 1
        }

        ly := ty + foldPx + Round(2 * SCALE)
        ; 默认只显示名字；只有同名文件夹才加 (序号) 区分钟
        dupN := 0, ord := 0
        for g in FOLDERS {
            if (g["name"] = f["name"]) {
                dupN += 1
                if (g["id"] = f["id"])
                    ord := dupN
            }
        }
        label := f["name"]
        if (dupN > 1)
            label .= " (" ord ")"
        ti += 1
        if (ti > POOL_TXT.Length) {
            POOL_TXT.Push(gDrawer.Add("Text", "x" x " y" ly " w" CELL_W " h" (CELL_H - (ly - y) - 2) " Center -Wrap BackgroundTrans cF2E6D6", label))
            tc := POOL_TXT[ti]
            tc.SetFont("s" Round(6.5 * SCALE), "Microsoft YaHei UI")
        } else {
            tc := POOL_TXT[ti]
            tc.Value := label
            tc.Move(x, ly, CELL_W, CELL_H - (ly - y) - 2)
        }
        tc.Visible := true
    }

    FOLDER_CTRLS := []
    for c in POOL_BG
        FOLDER_CTRLS.Push(c)
    for c in POOL_MINI
        FOLDER_CTRLS.Push(c)
    for c in POOL_TXT
        FOLDER_CTRLS.Push(c)
}
BindOpen(p, g) {
    return (*) => (LaunchItem(p), IsObject(g) ? g.Destroy() : 0)
}

BindRemove(p, g) {
    return (*) => (RemoveFromFolder(p), IsObject(g) ? g.Destroy() : 0)
}

OpenFolder(f) {
    global gFolderGui, APP_DIR, FOLDER_BINDS, FOLDER_POPUP
    if IsObject(gFolderGui)
        try gFolderGui.Destroy()
    ; 先摘掉可能还挂着的旧弹窗监视，免得它在重建过程中途触发一次"弹窗已关闭"收尾
    SetTimer(FolderPopupWatch, 0)
    FOLDER_POPUP := 0
    FOLDER_BINDS := []
    g := Gui("+AlwaysOnTop -DPIScale +ToolWindow", "文件夹 · " f["name"])
    g.BackColor := "1B1613"
    g.MarginX := 18
    g.MarginY := 14
    g.SetFont("s10 c9C8B79", "Microsoft YaHei UI")
    g.Add("Text", "w560 BackgroundTrans c9C8B79", "单击打开   ·   右键移出文件夹   ·   Esc 关闭")
    colW := 96, rowH := 108, cols := 6
    i := 0
    for path in f["members"] {
        it := FindItem(path)
        if !it
            continue
        cx := 18 + Mod(i, cols) * colW
        cy := 58 + Floor(i / cols) * rowH
        pic := g.Add("Picture", "x" cx " y" cy " w48 h48 BackgroundTrans", it["icon"])
        txt := g.Add("Text", "x" (cx - 8) " y" (cy + 50) " w" (colW - 8) " Center -Wrap BackgroundTrans cD6CBBB", FitLabel(it["name"], colW - 16, 7))
        ; 一次 BindOpen 生成一个闭包，图标和文字共用同一个对象，
        ; 同时留一份到 FOLDER_BINDS，自检时才可能"点"到用户真正点到的那个回调
        fn := BindOpen(path, g)
        pic.OnEvent("Click", fn)
        txt.OnEvent("Click", fn)
        FOLDER_BINDS.Push(Map("path", path, "name", it["name"], "fn", fn))
        pic.OnEvent("ContextMenu", BindRemove(path, g))
        txt.OnEvent("ContextMenu", BindRemove(path, g))
        i += 1
    }
    ; 关窗收尾统一走 CloseFolderPopup：先销毁再恢复覆盖层 + 抽屉 z 序。
    ; 注意 BindOpen/BindRemove 里是直接 g.Destroy()，不经过这里，
    ; 所以另有 FolderPopupWatch 计时器兜底（见文件末尾）。
    g.OnEvent("Escape", (*) => CloseFolderPopup(g))
    g.OnEvent("Close", (*) => CloseFolderPopup(g))
    ; 身份和监视计时器都要在 Show/WinActivate 之前立好：这两个调用会让出消息循环，
    ; 计时器有机会插进来，那时若 FOLDER_POPUP 还指着旧对象就会被误判成"弹窗已关闭"
    gFolderGui := g
    FOLDER_POPUP := g
    SetTimer(FolderPopupWatch, 300)
    ; 覆盖层是全屏 HWND_TOPMOST 的点击层，弹窗期间先撤掉，否则弹窗的点击可能被它吃掉
    HideOverlay()
    g.Show("AutoSize Center")
    ; 抽屉和覆盖层都带 AlwaysOnTop，光 Show 不保证 z 序，强制抬到 TOPMOST 顶端
    try DllCall("SetWindowPos", "Ptr", g.Hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0013)
    try WinActivate("ahk_id " g.Hwnd)
    LogWrite("folder: popup open z=top " f["name"])
    LogWrite("folder: opened " f["name"] " tiles=" FOLDER_BINDS.Length)
}

; 自检：走"打开文件夹弹窗 → 调用该成员绑定的点击回调"这条真实链路，
; 用来在没法注入鼠标点击的机器上验证"点文件夹里的文件能不能打开"。
FolderSelfTest(target) {
    global FOLDERS, FOLDER_BINDS, gFolderGui
    for f in FOLDERS {
        for m in f["members"] {
            if (StrLower(m) = StrLower(target)) {
                OpenFolder(f)
                LogWrite("foldertest: opened folder '" f["name"] "' for " target)
                SetTimer(ClickFolderBinding.Bind(target), -1400)
                return true
            }
        }
    }
    LogWrite("foldertest: target not in any folder: " target)
    return false
}

ClickFolderBinding(target) {
    global FOLDER_BINDS, gFolderGui
    for b in FOLDER_BINDS {
        if (StrLower(b["path"]) = StrLower(target)) {
            LogWrite("foldertest: click tile '" b["name"] "' (" b["path"] ")")
            try
                b["fn"]()
            catch as e
                LogWrite("foldertest: handler threw " e.Message " @line " e.Line)
            guiVis := 0
            try guiVis := DllCall("IsWindowVisible", "Ptr", gFolderGui.Hwnd)
            LogWrite("foldertest: done, folder popup visible=" guiVis)
            return true
        }
    }
    LogWrite("foldertest: tile not found in opened folder: " target)
    return false
}


LogWrite(text) {
    global APP_DIR, WPLOG_MAX, WPLOG_BYTES, WPLOG_WRITES
    try {
        wpath := APP_DIR "\wheel.log"
        if (WPLOG_BYTES < 0)
            WPLOG_BYTES := FileExist(wpath) ? FileGetSize(wpath) : 0
        line := FormatTime() "  " text "`n"
        FileAppend(line, wpath, "UTF-8")
        WPLOG_BYTES += StrPut(line, "UTF-8") - 1
        WPLOG_WRITES += 1
        ; 每 32 条与真实尺寸对齐：本进程写的同时可能有人在看，累加值只会偏小
        if (Mod(WPLOG_WRITES, 32) = 0 && FileExist(wpath))
            WPLOG_BYTES := FileGetSize(wpath)
        if (WPLOG_BYTES > WPLOG_MAX) {
            FileMove(wpath, wpath ".1", 1)
            ; 立刻建一个空文件：「存在但为空」比「不存在」好判断
            try {
                fz := FileOpen(wpath, "w", "UTF-8")
                fz.Close()
            }
            WPLOG_BYTES := 0
        }
    }
}

LogError(err, mode) {
    try LogWrite("ERROR: " err.Message " @line " err.Line " [" mode "]")
    return true
}

IconsScript(mode) {
    global APP_DIR
    cmd := 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' APP_DIR '\DesktopIcons.ps1" -Mode ' mode
    try return RunWait(cmd, , "Hide")
    return 1
}

QueryIcons() {
    global APP_DIR
    try {
        shell := ComObject("WScript.Shell")
        cmd := 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' APP_DIR '\DesktopIcons.ps1" -Mode query'
        exec := shell.Exec(cmd)
        out := exec.StdOut.ReadAll()
        if InStr(out, "hidden")
            return "hidden"
    }
    return "shown"
}

RestoreIconState() {
    global ICONS_SHOWN
    ICONS_SHOWN := (QueryIcons() = "shown")
    if ICONS_SHOWN {
        IconsScript("hide")
        ICONS_SHOWN := false
    }
    SyncIconState()
}


SyncIconState() {
    ; 顶栏第一个按钮的文案跟着真实状态走
    global BAR_BTNS, ICONS_SHOWN
    if (IsObject(BAR_BTNS) && BAR_BTNS.Length >= 1) {
        try BAR_BTNS[1]["ctrl"].Value := ICONS_SHOWN ? "隐藏桌面图标" : "显示桌面图标"
    }
}

ToggleIcons(*) {
    global ICONS_SHOWN
    ICONS_SHOWN := (QueryIcons() = "hidden")
    ; ICONS_SHOWN 现在表示「切换后是否为显示状态」
    if ICONS_SHOWN
        IconsScript("show")
    else
        IconsScript("hide")
    SyncIconState()
    LogWrite("icons: " (ICONS_SHOWN ? "shown" : "hidden"))
    AuditLog("icons.toggle", "now=" (ICONS_SHOWN ? "shown" : "hidden"))
}

SelfTest(*) {
    ; 无人值守自检：直接调用业务函数，验证落盘与耗时，不需要注入鼠标
    global ITEMS, FOLDERS, HIDDEN, curPage
    LogWrite("selftest: begin items=" ITEMS.Length)
    try {
        if FileExist(APP_DIR "\layout.dat")
            FileCopy(APP_DIR "\layout.dat", APP_DIR "\layout.bak", 1)
        if FileExist(APP_DIR "\hidden.dat")
            FileCopy(APP_DIR "\hidden.dat", APP_DIR "\hidden.bak", 1)
    }
    ShowDrawer(true)
    Sleep(300)

    ; 1) 从抽屉移除再恢复
    p := ITEMS[1]["path"]
    t0 := A_TickCount
    RemoveItemFromDrawer(p)
    Sleep(200)
    ok1 := HIDDEN.Has(p)
    LogWrite("selftest: remove ok=" ok1 " ms=" (A_TickCount - t0))
    t0 := A_TickCount
    RestoreHiddenItems()
    Sleep(300)
    ok2 := (!HIDDEN.Has(p))
    LogWrite("selftest: restore ok=" ok2 " ms=" (A_TickCount - t0))

    ; 2) 建夹 -> 改名 -> 解散（只动本次新建的那个文件夹，最后把布局还原）
    ia := 2, ib := 3
    if (ITEMS.Length >= ib) {
        before := FOLDERS.Length
        t0 := A_TickCount
        MakeFolder(ia, ib)
        Sleep(300)
        ok3 := (FOLDERS.Length = before + 1)
        LogWrite("selftest: folder ok=" ok3 " ms=" (A_TickCount - t0))
        if ok3 {
            f := FOLDERS[FOLDERS.Length]
            fid := f["id"]
            f["name"] := "自检夹"
            SaveLayout()
            RenderFolders()
            Repaint()
            ok4 := InStr(FileRead(APP_DIR "\layout.dat", "UTF-8"), "自检夹") > 0
            LogWrite("selftest: rename ok=" ok4)
            t0 := A_TickCount
            DissolveFolder(f)
            Sleep(300)
            ok5 := (!InStr(FileRead(APP_DIR "\layout.dat", "UTF-8"), fid) && FOLDERS.Length = before)
            LogWrite("selftest: dissolve ok=" ok5 " ms=" (A_TickCount - t0))
        }
    }
    ; 自检不该改动用户数据：把开头的备份盖回去
    try {
        if FileExist(APP_DIR "\layout.bak")
            FileCopy(APP_DIR "\layout.bak", APP_DIR "\layout.dat", 1)
        if FileExist(APP_DIR "\hidden.bak")
            FileCopy(APP_DIR "\hidden.bak", APP_DIR "\hidden.dat", 1)
        LogWrite("selftest: user data restored")
    } catch as e {
        LogWrite("selftest: restore failed " e.Message)
    }
    LogWrite("selftest: end")
    ExitApp
}

RescanDesktop(*) {
    FORCE_DIRTY := true
    global gDrawer, curPage, CTRL_POOL, FORCE_DIRTY
    t0 := A_TickCount
    wasOpen := DrawerVisible()
    if wasOpen
        HideDrawer()
    RunWait('powershell -NoProfile -ExecutionPolicy Bypass -File "' APP_DIR '\Build-IconCache.ps1"', , "Hide")
    RunWait('powershell -NoProfile -ExecutionPolicy Bypass -File "' APP_DIR '\DesktopPositions.ps1"', , "Hide")
    LoadPositions()
    LoadItems()
    LoadLayout()
    ComputeLayout()
    ; 重建窗口时控件池必须一起作废，否则会拿到已销毁的控件
    if IsObject(gDrawer)
        try gDrawer.Destroy()
    gDrawer := 0
    CTRL_POOL := []
    curPage := 0
    BuildGui()
    if wasOpen
        ShowDrawer(true)
    LogWrite("rescan items=" ITEMS.Length " ms=" (A_TickCount - t0))
}



DebugRename(nm) {
    global FOLDERS
    if (FOLDERS.Length = 0) {
        LogWrite("debug rename: no folder")
        return
    }
    f := FOLDERS[1]
    f["name"] := nm
    SaveLayout()
    RenderFolders()
    Repaint()
    LogWrite("debug rename ok: " nm)
}

; ===== 快捷启动栏（壁纸左侧 6 格）：写 %LOCALAPPDATA%\DesktopPage\dock.txt =====
; 每行：路径|显示名|图标文件名
DockFile() {
    global APP_DIR
    return APP_DIR "\dock.txt"
}

DockAdd(it) {
    f := DockFile()
    name := it["name"]
    iconName := ""
    if (it.Has("icon") && it["icon"] != "") {
        SplitPath(it["icon"], &iconName)
    }
    line := it["path"] "|" name "|" iconName
    cur := ""
    if FileExist(f) {
        try cur := FileRead(f, "UTF-8")
    }
    ; 已存在就不重复加
    if (cur != "" && InStr(cur, it["path"] "|"))
        return
    ; 最多 6 条
    n := 0
    if (cur != "") {
        Loop Parse, cur, "`n", "`r" {
            if (A_LoopField != "")
                n += 1
        }
    }
    if (n >= 6)
        return
    try FileAppend((cur != "" ? "`r`n" : "") line, f, "UTF-8")
}

; ------------------------------------------------------------
;  壁纸目录自动发现（与 hwmon/wxmon/dsh-agent 的顺序一致）：
;    1) 环境变量 DSH_WALLPAPER
;    2) Lively 的 WallpaperLayout.json 里「当前正应用」的那份（权威）
;    3) Lively 库里含 dsh.js 的最新一份
;    4) 兜底 dsqq0001.ab1
;  用途：把 todo.txt 同步成壁纸页面读的 todo-data.js。
; ------------------------------------------------------------
FindWallpaperDir() {
    env := EnvGet('DSH_WALLPAPER')
    if (env != '' && DirExist(env))
        return env
    base := EnvGet('LOCALAPPDATA') '\Lively Wallpaper'
    lay := base '\WallpaperLayout.json'
    if FileExist(lay) {
        try {
            txt := FileRead(lay, 'UTF-8')
            start := 1
            loop 8 {
                if !RegExMatch(txt, '"LivelyInfoPath"\s*:\s*"([^"]+)"', &mm, start)
                    break
                cand := StrReplace(mm[1], '\\', '\')
                if FileExist(cand '\dsh.js')
                    return cand
                start := mm.Pos + mm.Len
            }
        }
    }
    wpBase := base '\Library\wallpapers'
    best := ''
    bestTs := ''
    if DirExist(wpBase) {
        Loop Files, wpBase '\*\dsh.js', 'F' {
            if (!InStr(FileExist(A_LoopFileDir), 'D'))
                continue
            ts := FileGetTime(A_LoopFilePath, 'M')
            if (best = '' || (ts > bestTs)) {
                best := A_LoopFileDir
                bestTs := ts
            }
        }
    }
    if (best != '')
        return best
    return wpBase '\dsqq0001.ab1'
}

; ============================================================
;  以下为本次新增的函数。全部放在文件末尾：
;  AHK 里函数体写在自动执行段中间会截断其后的顶层语句，新增一律追加到这里最安全。
; ============================================================

; ------------------------------------------------------------
;  WinGetTitle("ahk_id " h) 的 DllCall 版 —— 全文件唯一一份取窗口标题的实现
;  （WinFindProc 的 EnumWindows 回调、WheelPassThrough 的取证日志都调它）
;  WinGetTitle 受 DetectHiddenWindows 影响，撞上 WorkerW / 隐藏窗口会抛
;  「Target window not found」。这个封装只取标题文本，窗口不存在就返回空串，
;  绝不抛异常 —— 它是在滚轮热键线程里调用的，抛一次整条热键体就断。
;  cap > 0：最多取 cap 个字符（默认 512）；cap = 0：不截断。
; ------------------------------------------------------------
WinTitleOf(h, cap := 512) {
    if !h
        return ""
    len := 0
    try len := DllCall("GetWindowTextLengthW", "Ptr", h, "Int")
    if (len <= 0)
        return ""
    if (cap > 0 && len > cap)
        len := cap
    buf := Buffer((len + 1) * 2, 0)
    try DllCall("GetWindowTextW", "Ptr", h, "Ptr", buf, "Int", len + 1, "Int")
    catch
        return ""
    return StrGet(buf, len, "UTF-16")
}

; ------------------------------------------------------------
;  屏幕边缘热区：不依赖任何键鼠钩子的等价唤起入口
;  滚轮事件可能物理上进不了本进程（蓝牙 HID 丢报文 / 钩子被系统摘掉 / 驱动层拦截），
;  这条通道只读光标位置，所以一定能用：
;    抽屉关着 + 光标停在屏幕底缘 ≥250ms → 唤出（只认桌面/壁纸窗口，避免全屏游戏误触）
;    抽屉开着 + 光标停在屏幕顶缘 ≥250ms → 收起
;  触发一次后 EDGE_ARMED 置 false，光标必须先离开边缘 40px 以上才重新武装，防连锁触发。
; ------------------------------------------------------------
EdgeProbe() {
    global EDGE_SUMMON, EDGE_PX, EDGE_HOLD_MS, EDGE_LAST_TICK, EDGE_ARMED, GUI_H, curPage, EDGE_INIT_LOGGED
    if !EDGE_SUMMON
        return
    ; 整个函数体包 try：定时器体里冒出去的异常会让 SetTimer 从此不再调用它，
    ; 热区就永久失效了，而且没有任何日志 —— 必须自己吞掉并记一行。
    try {
        edgePx := Round(EDGE_PX * A_ScreenDPI / 96)
        ; 热区的位置要同时躲开「任务栏可见」和「任务栏自动隐藏」两种情况：
        ;   任务栏自动隐藏时 SPI_GETWORKAREA 返回整屏，光标推到最底下会先把任务栏唤出来，
        ;   那一段落在任务栏上（ClassifyDeskWindow 判非桌面），热区就永远不触发。
        ; 所以改成「任务栏上沿往上 8px 起，40px 厚的一条」—— 两种模式下都是壁纸。
        tbH := TaskbarHeight()
        zoneBot := GUI_H - Max(8, tbH) - 8
        zoneTop := zoneBot - 40
        if (!EDGE_INIT_LOGGED) {
            ; 一次性自证：证明定时器真的在跑、热区算得对。没有这行就等于没法远程判断热区是否生效。
            EDGE_INIT_LOGGED := true
            LogWrite("edge: probe init screen=" A_ScreenWidth "x" A_ScreenHeight " taskbar=" tbH " zone=" zoneTop ".." zoneBot " edge=" edgePx " hold=" EDGE_HOLD_MS "ms armed=" (EDGE_ARMED ? 1 : 0))
        }
        CoordMode "Mouse", "Screen"
        MouseGetPos(&mx, &my)
        if !PointOnVirtualDesktop(mx, my) {
            EDGE_LAST_TICK := 0
            return                       ; 越界读数（实测出现过 at=2420,-421）直接丢弃
        }
        if !EDGE_ARMED {
            ; 重新武装：光标得真的走到屏幕中段，而不是贴着边缘左右滑
            if (my > edgePx + 40 && my < GUI_H - edgePx - 40)
                EDGE_ARMED := true
            EDGE_LAST_TICK := 0
            return
        }
        ; 抽屉开着不响应底缘，收起状态不响应顶缘
        onEdge := false
        if (curPage = 0 && my >= zoneTop && my < zoneBot)
            onEdge := true
        if (curPage > 0 && my <= edgePx)
            onEdge := true
        if !onEdge {
            EDGE_LAST_TICK := 0          ; 离开边缘就重新计时，必须连续停留够 EDGE_HOLD_MS
            return
        }
        if (EDGE_LAST_TICK = 0) {
            EDGE_LAST_TICK := A_TickCount
            return
        }
        if (A_TickCount - EDGE_LAST_TICK < EDGE_HOLD_MS)
            return
        if (curPage = 0) {
            if !DesktopUnderCursor()
                return                   ; 全屏视频/游戏不当桌面；保留计时继续等，光标一走自然复位
            EDGE_LAST_TICK := 0
            EDGE_ARMED := false          ; 先解除武装再唤出，任何重入都不会连开两次
            LogWrite("edge: summon bottom at=" mx "," my)
            AuditLog("edge.summon", "at=" mx "," my)
            ShowDrawer()
        } else {
            EDGE_LAST_TICK := 0
            EDGE_ARMED := false
            LogWrite("edge: dismiss top")
            AuditLog("edge.dismiss", "at=" mx "," my)
            HideDrawer()
        }
    } catch as e {
        try LogWrite("edge: probe failed " e.Message)
    }
}

; 底缘热区的"底" = 工作区底边（有任务栏时就是任务栏上沿）。; 为什么不直接用屏幕物理底边：任务栏正好贴着底边，光标去点开始菜单/托盘是高频操作，
; 热区压在那里会跟系统抢点击（停 250ms 就弹抽屉，很容易误触）。
; SPI_GETWORKAREA(0x30) 取主屏工作区；失败就退回屏幕高度。
; 任务栏高度（像素），0 = 读不到。
; 为什么不用 SPI_GETWORKAREA：本机任务栏是自动隐藏，工作区=整屏，取不到任务栏高度；
; 而 Shell_TrayWnd 即使处于隐藏态也保留真实矩形，读它最可靠。
TaskbarHeight() {
    h := 0
    try h := DllCall("FindWindowW", "Str", "Shell_TrayWnd", "Str", "", "Ptr")
    if !h
        return 0
    r := Buffer(16, 0)
    ok := 0
    try ok := DllCall("GetWindowRect", "Ptr", h, "Ptr", r, "Int")
    if !ok
        return 0
    hgt := NumGet(r, 12, "Int") - NumGet(r, 4, "Int")   ; bottom - top
    if (hgt < 8 || hgt > 200)
        return 0
    return hgt
}

; ------------------------------------------------------------
;  文件夹弹窗（OpenFolder）关闭后的收尾
;  两条入口：
;    Esc / 标题栏关闭 → g 的 Escape/Close 事件 → CloseFolderPopup(g)
;    点了弹窗里的图标 → BindOpen 里直接 g.Destroy()（绑定方式按约束不动）
;                      → 由 FolderPopupWatch 计时器发现弹窗已消失后补收尾
;  为什么必须收尾：弹窗期间 gOverlay 是 Hide 掉的，不补回来，抽屉就再也收不到
;  "点空白处收起"的鼠标事件，表现是抽屉开着却关不掉。
; ------------------------------------------------------------
CloseFolderPopup(g) {
    global gFolderGui, FOLDER_POPUP
    if IsObject(g)
        try g.Destroy()
    if (IsObject(gFolderGui) && ObjPtr(gFolderGui) = ObjPtr(g))
        gFolderGui := 0
    if (IsObject(FOLDER_POPUP) && ObjPtr(FOLDER_POPUP) = ObjPtr(g))
        FOLDER_POPUP := 0
    SetTimer(FolderPopupWatch, 0)
    RestoreOverlayForDrawer()
    LogWrite("folder: popup closed")
}

FolderPopupWatch() {
    global gFolderGui, FOLDER_POPUP
    alive := false
    ; 只认 OpenFolder 建的那个 Gui（RenameFolder 也用 gFolderGui 这个全局名，
    ; 用 ObjPtr 身份比较排除掉，免得重命名框被当成"文件夹弹窗"来收尾）
    if (IsObject(FOLDER_POPUP) && IsObject(gFolderGui) && ObjPtr(FOLDER_POPUP) = ObjPtr(gFolderGui)) {
        try alive := DllCall("IsWindowVisible", "Ptr", gFolderGui.Hwnd) ? true : false
    }
    if alive
        return
    SetTimer(FolderPopupWatch, 0)
    FOLDER_POPUP := 0
    gFolderGui := 0
    RestoreOverlayForDrawer()
    LogWrite("folder: popup closed")
}

; 弹窗关掉后恢复：先补覆盖层，再把抽屉抬回覆盖层之上。
; 顺序必须和 ShowDrawer 一致 —— EnsureOverlay 会把覆盖层抬到 TOPMOST 顶端，
; 不重抬抽屉的话图标层就被压在下面点不动了。
RestoreOverlayForDrawer() {
    global gDrawer, curPage
    if (curPage <= 0)
        return
    EnsureOverlay()
    if IsObject(gDrawer)
        try DllCall("SetWindowPos", "Ptr", gDrawer.Hwnd, "Ptr", -1, "Int", 0, "Int", 0, "Int", 0, "Int", 0, "UInt", 0x0013)
}

; 自检：dirtest=<目录> 的定时器回调（单独成函数是为了能用 .Bind() 按值捕获路径）。
; 前后各写一行日志，即使 LaunchItem 内部抛异常也能在 wheel.log 里看到断点。
DirSelfTest(p) {
    LogWrite("dirtest: fire " p " exist=[" FileExist(p) "]")
    try {
        LaunchItem(p)
    } catch as e {
        LogWrite("dirtest: LaunchItem threw " e.Message " @line " e.Line)
    }
    LogWrite("dirtest: done " p)
}

; ============================================================
;  统一审计日志 —— 三端（AHK / 代理 / 壁纸）写同一份 audit.log
;  %LOCALAPPDATA%\DesktopPage\audit.log
;  行格式：2026-11-03 23:30:12.345 [AHK ] open page=1 src=ui
;  规则（改动时务必守住）：
;    1) 只在"用户动作 / 请求 / 状态变化"处调用；绝不放进 120ms~1s 级定时器
;       （EdgeProbe / HoverProbe / RearmHooks / SummonTick 的每轮都不写）；
;    2) FileAppend 必须用 UTF-8-RAW —— 三端追加同一个文件，带 BOM 会污染第一条；
;    3) 整个函数体包 try：审计失败绝不能影响主流程；
;    4) 超过 2MB 用 FileMove(..., 1) 轮转成 audit.log.1（本机安全策略会拦 Remove-Item）。
;  注意：AHK v2 里函数写在脚本中部会截断自动执行段，所以下面三个函数必须留在文件最末尾。
; ============================================================
AuditLog(action, detail := "") {
    global AUDIT_FILE, AUDIT_MAX, AUDIT_BYTES, AUDIT_WRITES
    try {
        if (AUDIT_BYTES < 0)
            AUDIT_BYTES := FileExist(AUDIT_FILE) ? FileGetSize(AUDIT_FILE) : 0
        line := AuditStamp() " [AHK ] " action
        if (detail != "")
            line .= " " detail
        line .= "`n"
        FileAppend(line, AUDIT_FILE, "UTF-8-RAW")
        AUDIT_BYTES += StrPut(line, "UTF-8") - 1
        AUDIT_WRITES += 1
        ; 三端都在往同一个文件追加，本地累加值只会偏小；每 32 条与真实尺寸对齐一次
        if (Mod(AUDIT_WRITES, 32) = 0 && FileExist(AUDIT_FILE))
            AUDIT_BYTES := FileGetSize(AUDIT_FILE)
        if (AUDIT_BYTES > AUDIT_MAX) {
            FileMove(AUDIT_FILE, AUDIT_FILE ".1", 1)
            ; 立刻建一个空文件：「存在但为空」比「不存在」好判断（verify.ps1 / 人肉排查都靠它）
            try {
                fz := FileOpen(AUDIT_FILE, "w", "UTF-8-RAW")
                fz.Close()
            }
            AUDIT_BYTES := 0
        }
    }
}

; 本地时间，精确到毫秒。用 GetLocalTime 的 wMilliseconds：
; A_Now 只有秒，靠它拼不出 .fff；这是三端能按时间对齐同一件事的前提。
AuditStamp() {
    st := Buffer(16, 0)
    DllCall("GetLocalTime", "Ptr", st)
    return Format("{:04d}-{:02d}-{:02d} {:02d}:{:02d}:{:02d}.{:03d}"
        , NumGet(st, 0, "UShort"), NumGet(st, 2, "UShort"), NumGet(st, 6, "UShort")
        , NumGet(st, 8, "UShort"), NumGet(st, 10, "UShort"), NumGet(st, 12, "UShort")
        , NumGet(st, 14, "UShort"))
}

; 审计值转义：路径/名字一律用双引号包起来；值里的双引号换成单引号、换行压成空格
; —— 一行一条是 grep 的前提，不能被路径里的怪字符撑断。
Aq(v) {
    s := StrReplace("" v, "`r", " ")
    s := StrReplace(s, "`n", " ")
    s := StrReplace(s, '"', "'")
    return '"' s '"'
}

; summon.cmd 里的 log=<N>：把 audit.log 末尾 N 行（默认 200，上限 1000）导出成
; %LOCALAPPDATA%\DesktopPage\audit-export.txt。用户不会敲命令，双击这个 txt 就能看。
AuditExport(limit := 200) {
    global AUDIT_FILE, APP_DIR
    if (limit <= 0)
        limit := 200
    if (limit > 1000)
        limit := 1000
    out := APP_DIR "\audit-export.txt"
    n := 0
    try {
        body := ""
        if !FileExist(AUDIT_FILE) {
            body := "（还没有审计记录）`n"
        } else {
            ; 先看大小：超过 256KB 只读尾部 256KB（200 行 × 每行约 120 字节 ≈ 24KB，余量足够），
            ; 绝不整份加载 —— audit.log 上限 2MB，整份读会明显拖慢调用它的 AHK 线程。
            size := FileGetSize(AUDIT_FILE)
            take := (size > 262144) ? 262144 : size
            f := FileOpen(AUDIT_FILE, "r", "UTF-8-RAW")
            if (take < size)
                f.Seek(-take, 2)
            txt := f.Read()
            f.Close()
            lines := StrSplit(txt, "`n", "`r")
            if (take < size)
                lines.RemoveAt(1)          ; 从中间切进来的第一行是半行，丢掉
            k := lines.Length
            while (k > 0 && Trim(lines[k]) = "")
                k -= 1
            start := Max(1, k - limit + 1)
            n := Max(0, k - start + 1)
            loop n
                body .= lines[start + A_Index - 1] "`n"
            if (body = "")
                body := "（最近没有审计记录）`n"
        }
        hdr := "=== DesktopPage 审计导出 " AuditStamp() " · 末尾 " n " 行 · 源 " Aq(AUDIT_FILE) " ===`n"
        f2 := FileOpen(out, "w", "UTF-8-RAW")   ; "w" = 覆盖写，不用 FileDelete
        f2.Write(hdr body)
        f2.Close()
    } catch as e {
        try LogWrite("audit export failed: " e.Message)
    }
    AuditLog("audit.export", "lines=" n)
}

; ============================================================
;  summon.cmd 命令处理 —— SUMMON_CMDS（文件顶部）里每一项都指向这里的一个函数
;  加一条命令：顶部加一行 Map 项 + 这里加一个 Summon_CmdXxx(arg)。
;  arg = 去掉命令前缀后的剩余部分（精确匹配的命令收到空串）。
;  行为（日志文案 / 审计 action / 副作用顺序）与改造前的 if/elseif 逐条一致。
; ============================================================
Summon_CmdShow(arg := "") {
    ShowDrawer()
    LogWrite("summon: show via file")
    AuditLog("summon", "cmd=show")
}

Summon_CmdHide(arg := "") {
    HideDrawer()
    LogWrite("summon: hide via file")
    AuditLog("summon", "cmd=hide")
}

Summon_CmdEdgeOff(arg := "") {
    global EDGE_SUMMON, EDGE_LAST_TICK
    ; 热区必须真的可关：全屏游戏/绘图时它就是个干扰
    EDGE_SUMMON := false
    EDGE_LAST_TICK := 0
    LogWrite("edge: disabled")
    AuditLog("summon", "cmd=edge")
}

Summon_CmdEdgeOn(arg := "") {
    global EDGE_SUMMON, EDGE_ARMED, EDGE_LAST_TICK
    EDGE_SUMMON := true
    EDGE_ARMED := true
    EDGE_LAST_TICK := 0
    LogWrite("edge: enabled")
    AuditLog("summon", "cmd=edge")
}


Summon_CmdDiag(arg := "") {
    global curPage, RAW_OK, RAW_ALIVE, HK_ALIVE, RAW_TICKS, WHEEL_HITS, WHEEL_LASTDIR, WHEEL_LASTSRC
    global gDrawer, WHEEL_HK_TICK, WHEEL_RAW_TICK, RAW_MSGS
    global WHEEL_HK_DOWN, WHEEL_HK_UP, RAW_WHEEL_TICKS, RAW_MOVE_TICKS
    global BRIDGE_FILE, WHEEL_BRIDGE_HITS, WHEEL_BRIDGE_TICK
    global EDGE_SUMMON, EDGE_ARMED
    ; 一条自带上下文的现场快照：不用让用户去翻日志、也不用我远程敲命令
    mx := 0, my := 0
    try MouseGetPos(&mx, &my)
    h := 0
    try h := DllCall("WindowFromPoint", "Int64", mx | (my << 32), "Ptr")
    cls := "", pn := ""
    desk := "?"
    if (h) {
        cls := WinClassOf(h)
        pn := WinProcNameOf(h)
        try desk := ClassifyDeskWindow(h) ? 1 : 0
    }
    vis := 0
    try vis := DllCall("IsWindowVisible", "Ptr", gDrawer.Hwnd)
    LogWrite("diag: page=" curPage " vis=" vis " desk=" desk " cls=" cls " proc=" pn
        . " at=" mx "," my " raw_ok=" RAW_OK " raw_alive=" RAW_ALIVE " hk_alive=" HK_ALIVE
        . " raw_ticks=" RAW_TICKS " raw_msgs=" RAW_MSGS
        . " raw_move=" RAW_MOVE_TICKS " raw_wheel=" RAW_WHEEL_TICKS
        . " hk_down=" WHEEL_HK_DOWN " hk_up=" WHEEL_HK_UP
        . " wheel_hits=" WHEEL_HITS " last_dir=" WHEEL_LASTDIR
        . " last_src=" WHEEL_LASTSRC " hk_age=" (A_TickCount - WHEEL_HK_TICK) " raw_age=" (A_TickCount - WHEEL_RAW_TICK)
        . " edge=" (EDGE_SUMMON ? 1 : 0) " edge_armed=" (EDGE_ARMED ? 1 : 0)
        . " bridge=" (FileExist(BRIDGE_FILE) ? 1 : 0) " bridge_hits=" WHEEL_BRIDGE_HITS
        . " bridge_age=" (WHEEL_BRIDGE_TICK ? A_TickCount - WHEEL_BRIDGE_TICK : -1))
    AuditLog("summon", "cmd=diag")
}

Summon_CmdClassify(arg := "") {
    ; 自检：classify=<hwnd> —— 直接问判定层「这个窗口算不算桌面」，不用挪鼠标。
    ; 排查「某个应用里滚轮误召唤抽屉」的标准动作：
    ;   1) 用 dump 子窗口树的探针拿到那个应用里命中的 hwnd（比如资源管理器的 SHELLDLL_DefView）；
    ;   2) 往 summon.cmd 写 classify=<hwnd>，看 wheel.log 新增的 classify: 行；
    ;   3) desk=1 就该看 root_cls 锚到了哪个顶层窗口，desk=0 说明判定层是对的，问题在别处。
    global curPage
    AuditLog("summon", "cmd=classify")
    h := 0
    try h := Integer(Trim(arg))
    catch
        h := 0
    if !h {
        LogWrite("classify: bad arg=" arg)
        return
    }
    vis := 0
    try vis := DllCall("IsWindowVisible", "Ptr", h, "Int")
    root := 0
    try root := DllCall("GetAncestor", "Ptr", h, "UInt", 2, "Ptr")
    desk := "?"
    try desk := ClassifyDeskWindow(h) ? 1 : 0
    LogWrite("classify: hwnd=" h " cls=" WinClassOf(h) " proc=" WinProcNameOf(h)
        . " vis=" vis " root=" root " root_cls=" WinClassOf(root)
        . " root_proc=" WinProcNameOf(root) " desk=" desk " page=" curPage)
}

Summon_CmdLog(arg := "") {
    ; 用户不会敲命令：log=200 → 把 audit.log 末尾 200 行导出成
    ; %LOCALAPPDATA%\DesktopPage\audit-export.txt，双击就能看最近发生了什么
    AuditLog("summon", "cmd=log")
    n := 200
    try n := Integer(Trim(arg))
    catch
        n := 200
    AuditExport(n)
}

Summon_CmdFolderTest(arg := "") {
    ; 自检：foldertest=<某文件完整路径> —— 打开它所在的文件夹弹窗，再调用该成员绑定的点击回调，
    ; 等价于"抽屉里点开文件夹、点了里面这个文件"，用来验证这条链路真的会打开文件
    AuditLog("summon", "cmd=foldertest")
    FolderSelfTest(arg)
}

Summon_CmdDirTest(arg := "") {
    ; 自检：dirtest=<完整目录路径> —— 1.2 秒后调真实的 LaunchItem，
    ; 走的是和用户点目录图标完全相同的代码路径（含三级回退），
    ; 这样主控不注入鼠标也能验证"目录到底有没有打开窗口"。
    ; 注意：必须 .Bind() 按值捕获路径，不能写成 `SetTimer(() => LaunchItem(dp), -1200)`
    ; —— 箭头函数按引用捕获局部变量，定时器触发时函数早已返回，
    ; 实测只会留下 `dirtest: begin` 一行然后静默失败（本文件 9.7 节记过同一个坑）。
    LogWrite("dirtest: begin " arg)
    AuditLog("summon", "cmd=dirtest")
    SetTimer(DirSelfTest.Bind(arg), -1200)
}

; ------------------------------------------------------------
;  原子写：先写 <file>.tmp，再 FileMove 覆盖。
;  调用点自己包 try（写失败不能中断主流程）——SaveHidden / SaveLayout 两处共用这一份。
; ------------------------------------------------------------
WriteFileAtomic(path, text) {
    tmp := path ".tmp"
    try FileDelete(tmp)
    FileAppend(text, tmp, "UTF-8")
    FileMove(tmp, path, 1)
}

; ------------------------------------------------------------

; ------------------------------------------------------------

; ------------------------------------------------------------

