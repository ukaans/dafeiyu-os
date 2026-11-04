# 给 DSH 的部署指南 —— 大肥鱼桌面系统

> 这份文档是写给**另一个人电脑上的 DSH（AI 代理）**看的：它会读完文档、在目标机上执行命令、核对输出。
> 人也可以照着做，命令都是现成的。

---

## 0. 这套东西是什么

两套互相配合的 Windows 桌面系统：

| 系统 | 形态 | 技术栈 | 入口 |
|---|---|---|---|
| **桌面（壁纸）系统** | 动态壁纸，铺满桌面背景 | 纯前端 HTML/CSS/JS，零构建，跑在 Lively Wallpaper 的 WebView2 里 | `wallpaper/index.html` |
| **抽屉系统** | 从屏幕底部滑出的 App 抽屉（图标网格 + 文件夹） | AutoHotkey v2 + PowerShell 5.1 | `drawer/DesktopPage.ahk` |
| **桌面代理**（两套之间的桥） | 本机 HTTP 服务 `127.0.0.1:17433` | PowerShell 5.1 HttpListener | `drawer/dsh-agent.ps1` |

通信方式：壁纸是 `file://` 页面，受私有网络限制不能 `fetch` 本机 HTTP，所以全部用 **JSONP（`<script>` 拉 `*.js`）+ 1×1 GIF 信标（`<img src="*.gif">` 发指令）**。这是本项目的核心设计，改造时不要改成 `fetch`。

---

## 1. 前置条件（缺一不可）

| 项 | 要求 | 检查命令 |
|---|---|---|
| 系统 | Windows 10/11 x64 | `[Environment]::OSVersion.VersionString` |
| PowerShell | 5.1（系统自带） | `$PSVersionTable.PSVersion` |
| .NET Framework | 4.7.2+（`Add-Type` 编 C# 用） | `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full').Release` ≥ 528040 |
| WebView2 运行时 | 装了 Edge 基本就有 | `Get-Item 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'` |
| Lively Wallpaper | ≥ 2.0，**必须装** | 见下方自动探测 |
| AutoHotkey v2 | 已经随包带 `AutoHotkey64.exe`，无需另装 | `drawer\AutoHotkey64.exe` |
| DSH（可选） | 只在用「DSH 控制台」面板时需要 | `E:\DSH\dsh.cmd` 或设置 `DSH_ROOT` |

Lively 壁纸库通常在 `%LOCALAPPDATA%\Lively Wallpaper\Library\wallpapers`；`install.ps1` 会自动找，找不到会提示你装 Lively。

---

## 2. 包内结构

```
大肥鱼桌面系统\
├─ install.ps1          一键安装（复制文件、写环境变量、建两个计划任务、启动）
├─ verify.ps1           自检（文件/任务/进程/HTTP 接口/日志，退出码=失败项数）
├─ uninstall.ps1        卸载（删两个任务；-Purge 连目录一起删）
├─ 安装.cmd / 卸载.cmd  双击入口
├─ README.md            给人看的三分钟上手
├─ 给DSH的部署指南.md    ← 本文
├─ 改造指南.md          怎么改外观/功能/协议
├─ wallpaper\           壁纸系统全部文件（含 assets 立绘）
│   ├─ index.html  app.js  style.css  layout.css
│   ├─ dsh.js  media.js  todo.js  todo.css  hw.js  wx.js  audio-host.js
│   └─ assets\  LivelyInfo.json  project.json  integrity.json
├─ drawer\              抽屉系统全部文件
│   ├─ DesktopPage.ahk  AutoHotkey64.exe
│   ├─ dsh-agent.ps1  start-all.vbs
│   ├─ agent-watch.ps1  ensure-all.ps1  ensure-all.vbs
│   ├─ hwmon.ps1  wxmon.ps1  dock-add.ps1  dock-add-host.ps1
│   ├─ DesktopIcons.ps1  DesktopPositions.ps1  Build-IconCache.ps1  recycle_tmp.ps1
│   ├─ npix.exe  npix.cs  npix.manifest   （读取网易云窗口像素，媒体兜底用）
│   └─ fonts\  icons\
└─ docs\                项目地图.md（全局索引）· 使用手册.md · 实现手册.md · 素材清单 · 第三方声明
```

> **改动前先读 `docs\项目地图.md`**：它是架构、接口全表、文件职责、数据格式、排障工具、文档同步矩阵的唯一索引；`docs\实现手册.md` 讲的是「为什么这样做」和踩过的坑。

---

## 3. 安装（两条命令）

在解压目录里开 PowerShell：

```powershell
# 先空跑，确认路径都对
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun

# 真装
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

可选参数：

| 参数 | 作用 |
|---|---|
| `-InstallDir "D:\Tools\DesktopPage"` | 抽屉装到别处（默认 `%LOCALAPPDATA%\DesktopPage`） |
| `-LivelyLibrary "D:\Lively\Library\wallpapers"` | 手动指定 Lively 壁纸库 |
| `-WallpaperName "我的桌面"` | 壁纸在 Lively 里显示的名字 |
| `-DshRoot "E:\DSH"` | 写入用户环境变量 `DSH_ROOT`，供代理调用 DSH |
| `-SkipTask` | 不建开机自启任务（只想试一下） |

安装脚本做了 5 件事：复制 `drawer\` → 安装目录；复制 `wallpaper\` → Lively 库；建空数据文件；建两个计划任务（`DesktopPage Autostart` 登录自启、`DesktopPage Ensure` 每 2 分钟兜底巡检）；立刻运行一次。

> 壁纸数据落点（`hw-data.js` / `wx-data.js` / `todo-data.js` 写哪个目录）**不用配**：三个采样脚本会自己按「`DSH_WALLPAPER` → Lively `WallpaperLayout.json` 里当前应用的壁纸目录 → 库里含 `dsh.js` 的最新一份」解析。机器上同时有多份壁纸副本时，只有 Lively 自己知道哪份在显示。

**如果计划任务创建失败**（非管理员偶发）：脚本会把该执行的命令打印出来，用管理员 PowerShell 跑一遍即可。没有计划任务也能用：手动双击 `%LOCALAPPDATA%\DesktopPage\start-all.vbs`。

---

## 4. 装完怎么验证

### 4.1 自检脚本

```powershell
powershell -ExecutionPolicy Bypass -File .\verify.ps1
```

期望全部 `[ OK ]`，重点看这三行：

- `抽屉进程 AutoHotkey64 运行中`
- `桌面代理运行中（1 个实例）`
- `GET /state.js -> window.__DSH_STATE={...}`、`GET /media.js -> window.__MEDIA={...}`

退出码 0 = 全通过；非 0 = 有几项失败（脚本里逐项标了原因）。

### 4.2 手动验收清单

1. **壁纸**：打开 Lively → 「已安装的壁纸」里找到 `大肥鱼桌面系统` → 应用。桌面出现：左上硬件卡片、中上待办条、右侧 DSH 面板、右侧当前播放、左下快捷启动、底部时钟条与当天进度。
2. **抽屉**：鼠标移到屏幕右下角（或按 `Ctrl+Alt+Space`）→ 底部滑出图标抽屉；`Esc` 收起。
3. **图标整理**：拖动图标挪位置（吸附网格）；把一个图标拖到另一个上 → 合成文件夹；右键文件夹可重命名/解散。
4. **滚轮分流**（关键技术验证）：鼠标在 DSH 面板上滚 → 面板内日志滚动；在设置面板里滚 → 设置面板内滚动（**不应**弹出抽屉）；在桌面空白处向下滚 → 弹出抽屉。
5. **当前播放**：随便放首歌（网易云/Edge/Spotify）→ 面板出现歌名，三个按钮是「上一首 / 播放暂停 / 下一首」，点击不弹窗。

### 4.3 接口层面的快速验证（复制即用）

```powershell
curl.exe -s http://127.0.0.1:17433/state.js
curl.exe -s http://127.0.0.1:17433/media.js
curl.exe -s http://127.0.0.1:17433/dock.js
curl.exe -s "http://127.0.0.1:17433/media.gif?op=toggle"   # 会立刻返回 1x1 GIF
Get-Content "$env:LOCALAPPDATA\DesktopPage\panel-rect.txt"  # 形如 "8459 1011 1343 3132"
```

`panel-rect.txt` 有值 = 壁纸页面在跟代理通信（万分比坐标，用于滚轮命中判定）。

---

## 5. 目录与数据文件（装完会在哪）

| 路径 | 内容 |
|---|---|
| `%LOCALAPPDATA%\DesktopPage\` | 抽屉与代理程序、`fonts\`、`icons\`、数据文件、`wheel.log` |
| `%LOCALAPPDATA%\Lively Wallpaper\Library\wallpapers\<壁纸名>\` | 壁纸页面与其 `assets\` 立绘。目录名 = 安装时的 `-WallpaperName`（默认 `大肥鱼桌面系统`）；**哪个目录在生效**看 `%LOCALAPPDATA%\Lively Wallpaper\WallpaperLayout.json` 的 `LivelyInfoPath` |
| `%LOCALAPPDATA%\DesktopPage\layout.dat` | 图标位置（首行 `V2`，之后 `P<TAB>路径<TAB>x<TAB>y`） |
| `hidden.dat` | 被收进抽屉的桌面图标路径列表 |
| `items.tsv` | 图标索引：`名称<TAB>路径<TAB>图标<TAB>类型` |
| `dock.txt` | 快捷启动栏：`路径|名称|图标文件名` |
| `todo.txt` | 待办纯文本（壁纸待办条的数据源） |
| `scroll.dat` | 滚轮增量（`+1`/`-1` 每行，被 `/scroll.js` 取走后清空） |
| `panel-rect.txt` | 壁纸 DSH 面板在屏幕上的位置（0..10000 万分比） |
| `media-pos.json` | 当前播放进度持久化（重启后接续） |
| 壁纸库里的 `todo-data.js` / `hw-data.js` / `wx-data.js` | 由代理/采样脚本**生成**，不要手改 |

---

## 6. 代理接口一览（改东西时的地图）

`http://127.0.0.1:17433/...`

**JSONP（返回 `window.__XXX=...;`）**
`/state.js`（日志/余额/忙闲）、`/dock.js`（快捷启动列表）、`/scroll.js`（滚轮增量）、`/media.js`（当前播放）

**信标（返回 1×1 透明 GIF，靠 `onload` 不算结果）**
`/run.gif?t=指令`、`/launch.gif`、`/open.gif`、`/clear.gif`、`/drawer.gif`、`/summon.gif?d=1|hide`（写 `summon.cmd`，不依赖键鼠钩子地开合抽屉）、`/rect.gif?x&y&w&h`、`/scroll.gif?d=±1`、`/todo.gif?op=&t=`、`/dock.gif?op=del&i=`、`/adddock.gif`、`/launchpath.gif?t=`、`/media.gif?op=toggle|back|fwd`

**静态**
`/icon/<文件名.png>` —— 抽屉图标缓存。

细节、字段含义、扩展方法见 `docs\实现手册.md`。

---

## 7. 常见失败对照表

| 现象 | 原因 | 处理 |
|---|---|---|
| 壁纸全黑/只有角色 | Lively 没应用这套壁纸，或 `assets\` 没复制全 | Lively 里重新应用；确认 `wallpapers\大肥鱼桌面系统\assets\` 有 25 个文件 |
| 右边 DSH 面板一直「离线」 | 代理没起来 / 17433 被占 | `Get-NetTCPConnection -LocalPort 17433`；杀掉占用或改 `dsh-agent.ps1` 的 `param([int]$Port)` |
| 抽屉不出现 | `AutoHotkey64.exe` 被安全软件拦 / 脚本加载报错 | 手动运行 `AutoHotkey64.exe DesktopPage.ahk`，看弹窗；`wheel.log` 里也有启动记录 |
| 抽屉出现了但图标空白 | `icons\` 没复制或图标缓存过期 | 顶部「重新扫描」按钮，或删掉 `icons\*.png` 重启 |
| 滚轮在设置面板里还会弹抽屉 | 壁纸没把整屏矩形上报（`panel-rect.txt` 没变 `0 0 10000 10000`） | 确认 `dsh.js` 是最新的；点一下设置面板里的空白处让它重新上报 |
| 当前播放永远「未在播放」 | 播放器不发布 SMTC（典型：网易云 3.1.x） | 这是已知的；本系统对网易云做了兜底（窗口标题+音频峰值），需要 `npix.exe` 与网易云在跑 |
| 待办条不刷新 | 代理写 `todo-data.js` 失败 | 检查壁纸目录是否可写；确认 `todo.txt` 存在 |
| 硬件 / 天气面板一直 `--`、`—` | 采样脚本写错了壁纸目录（机器上有多份副本、或 Lively 里应用的是另一份） | 看 `WallpaperLayout.json` 的 `LivelyInfoPath` 指向哪个目录，确认里面有 `hw-data.js` / `wx-data.js`；确认 `hwmon.pid` / `wxmon.pid` 对应的进程在跑；确实需要指到别处时用手写环境变量 `DSH_WALLPAPER=<目录>` 覆盖，然后重启 `start-all.vbs` |
| 快捷键全失效、滚轮也不召唤 | 鼠标/键盘底层钩子被系统摘掉（脚本线程被长时间阻塞过） | 用文件召唤：`%LOCALAPPDATA%\DesktopPage\summon.cmd` 写一行 `show`；抽屉每 5 秒自动重装钩子，稍等即可恢复。要定位就写 `diag` 看 `wheel.log` |
| 计划任务不会自启 | 任务建成了但被禁用 | 任务计划程序里启用 `DesktopPage Autostart` |

---

## 8. 卸载 / 回滚

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1          # 停进程、删任务，保留文件
powershell -ExecutionPolicy Bypass -File .\uninstall.ps1 -Purge   # 连安装目录和壁纸一起删
```

Lively 里如果还挂着这套壁纸，换成别的壁纸即可；它不会再被用到。

---

## 9. 与 DSH 的集成（可选）

- 壁纸右侧「DSH 控制台」面板通过代理 `/run.gif?t=...` 执行 `dsh.cmd headless`。代理默认找 `E:\DSH\dsh.cmd`，可用环境变量 `DSH_ROOT` 改（`install.ps1 -DshRoot "D:\DSH"`）。
- 没有 DSH 也能用：面板会显示离线，其余功能（待办、硬件、天气、当前播放、快捷启动、抽屉）不受影响。
- 想让代理把任务跑起来，需要本机已登录 DSH 网页端（3080 端口在跑），否则 `/state.js` 里 `web:false`。

---

## 10. 升级

1. 关掉抽屉（托盘右键 →「退出程序」）与代理（任务管理器结束 `dsh-agent.ps1` 的 powershell）。
2. 直接覆盖安装：把新版 `drawer\*`、`wallpaper\*` 复制到位（**不要**覆盖 `layout.dat`/`hidden.dat`/`items.tsv`/`dock.txt`/`todo.txt`，那是你的数据）。
3. 重新跑 `install.ps1`（它会保留已有数据文件），或手动 `wscript start-all.vbs`。
4. `verify.ps1` 跑一遍确认。

---

## 11. 给 DSH 的执行建议

- 每一步都看**退出码**和**产物**，不要只看有没有报错输出。
- 改任何 `.ps1` 前先 `Get-Content` 读一遍；PowerShell 5.1 对**无 BOM 的 UTF-8 中文**会按 GBK 解析，改完保存为 `UTF8 BOM`。
- 改 `.vbs` 必须存成 **UTF-16 LE（带 BOM）** 或 ANSI，UTF-8 会导致 `无效字符`。
- 改 `.ahk` 时注意：函数定义写在脚本中部会**截断自动执行段**，必须在所有顶层语句之后。
- 重启整套系统：`schtasks /run /tn "DesktopPage Autostart"`（比手动逐个启动稳，Lively 会以正确权限与 DPI 感知启动）。
