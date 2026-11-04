# 大肥鱼桌面系统

一套给你桌面「加层皮」的 Windows 桌面增强包，包含两个互相配合的系统：

- **桌面（壁纸）系统**：动态壁纸，铺满桌面背景。左上本机硬件、中上待办条、右侧 DSH 控制台、右侧当前播放、左下快捷启动、底部时钟条与当天进度、角色立绘与互动。
- **抽屉系统**：光标在桌面/壁纸上向下滚（全屏应用挡住桌面时用 `Ctrl+Alt+滚轮↓`，或按 `Ctrl+Alt+Space`）滑出的 App 抽屉，图标网格、拖动整理、自动吸进文件夹，还能一键隐藏/还原系统桌面图标。

两套系统通过本机 HTTP 服务 `127.0.0.1:17433` 通信，**不联网、不上传、全部本机运行**。

---

## 30 秒上手

```powershell
# 1) 解压后进入本目录，先空跑确认路径
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun

# 2) 真装
powershell -ExecutionPolicy Bypass -File .\install.ps1

# 3) 自检（文件 / 抽屉 / 代理 / 看门狗 / 心跳 / 端口 / 接口 / 日志健康）
powershell -ExecutionPolicy Bypass -File .\verify.ps1
```

然后打开 **Lively Wallpaper** → 「已安装的壁纸」里选 **大肥鱼桌面系统** → 应用。

> 需要先装 [Lively Wallpaper](https://www.rocksdanister.com/lively/)（免费开源）。没有它，壁纸系统无法显示；抽屉系统不受影响。

---

## 仓库与分支

| 分支 | 用途 | 约定 |
|---|---|---|
| `main` | 稳定发布版 | 只收自检（`verify.ps1`）与测试（`tests\Run-Tests.ps1`）都通过的快照 |
| `dev` | 日常开发 | 允许半成品；功能改完再合回 `main` |

```bash
git switch dev     # 开发
git switch main    # 发版
```

---

## 常用操作

| 操作 | 方式 |
|---|---|
| 呼出 / 收起抽屉 | **光标移到壁纸最下沿停 0.25 秒**（最稳，任何鼠标都行）/ 光标在桌面向下滚 / `Ctrl+Alt+滚轮↓`（任意窗口）/ `Ctrl+Alt+Space` / `Esc` 收起 |
| 隐藏 / 显示系统桌面图标 | `Ctrl+Alt+D` |
| 添加应用到抽屉 | 把快捷方式拖到抽屉里，或顶部「添加应用」 |
| 合成文件夹 | 把一个图标拖到另一个图标上 |
| 文件夹操作 | 右键：重命名 / 解散 |
| 图标操作 | 右键：从抽屉移除（保留文件）/ 删除文件到回收站 |
| 打开设置面板 | 右键顶栏右侧的「系统配置」 |
| 当前播放控制 | 壁纸右侧面板：上一首 / 播放暂停 / 下一首 |
| 重启整套系统 | `schtasks /run /tn "DesktopPage Autostart"`（**不要**直接双击进程，会被随会话回收） |
| 查看系统做了什么 | `%LOCALAPPDATA%\DesktopPage\audit.log`（三方共写的操作日志）；不想敲命令就写 `summon.cmd` 一行 `log=200`，再看 `audit-export.txt` |

更详细的操作说明见 `docs\使用手册.md`。

---

## 目录结构

```
大肥鱼桌面系统\
├─ install.ps1 / verify.ps1 / uninstall.ps1   安装、自检、卸载
├─ 安装.cmd / 卸载.cmd                        双击入口
├─ 给DSH的部署指南.md    ← 让 AI 代理独立完成部署的说明
├─ 改造指南.md           ← 改外观/加功能/扩协议
├─ tests\                漏洞与风险测试模块（54 条用例，退出码=高/中危失败数）
│  └─ Run-Tests.ps1      入口；报告落 tests\out\
├─ wallpaper\            壁纸系统（HTML/CSS/JS + assets 立绘）
└─ drawer\               抽屉系统（AutoHotkey v2 + PowerShell）
    ├─ DesktopPage.ahk   抽屉主程序
    ├─ dsh-agent.ps1     本地代理（127.0.0.1:17433）
    ├─ start-all.vbs     开机启动链
    ├─ agent-watch.ps1   代理看门狗（5 秒）
    └─ ensure-all.ps1    兜底巡检（每 2 分钟，由计划任务 DesktopPage Ensure 拉起）

docs\
├─ 项目地图.md          ← **改代码前先读这份**：架构、接口全表、文件职责、文档同步矩阵
├─ 使用手册.md          ← 每个功能怎么用
├─ 实现手册.md          ← 每个文件干什么、协议怎么设计、踩过哪些坑
├─ 测试与重构日志.md     ← 每天测了什么、修了什么（改完代码来这里记一段）
└─ 素材清单 / 第三方声明 / LICENSE-wallpaper
```

> **维护约定**：任何代码改动都要同步更新 `docs\项目地图.md` 里的对应章节（§3 接口表 / §4 文件表 / §5 数据文件 / §2 启动链），并在 §9 变更记录追加一行。矩阵见该文档 §7.2——这样下一个人或下一个 AI 才能五分钟摸清现状再动手。

---

## 环境要求

- Windows 10 / 11 x64
- PowerShell 5.1（系统自带）
- Lively Wallpaper ≥ 2.0（壁纸宿主）
- WebView2 运行时（装了 Edge 一般就有）
- AutoHotkey v2（**已随包附带** `drawer\AutoHotkey64.exe`，无需另装）
- 可选：DSH（桌面 AI 代理），装了才有右侧「DSH 控制台」的日志与指令功能

---

## 数据放在哪

| 路径 | 内容 |
|---|---|
| `%LOCALAPPDATA%\DesktopPage\` | 抽屉程序、图标缓存、布局/隐藏列表/快捷启动/待办等数据 |
| `%LOCALAPPDATA%\Lively Wallpaper\Library\wallpapers\大肥鱼桌面系统\` | 壁纸页面与立绘资源 |
| `%LOCALAPPDATA%\DesktopPage\wheel.log` | 抽屉运行日志（排查问题看这个） |

卸载时用 `uninstall.ps1`，加 `-Purge` 会连数据一起删。

---

## 许可与致谢

- 壁纸基础框架来自上游开源项目 `fjdsjd/deepseek-companion-wallpaper`（许可证随 `wallpaper\LICENSE` 一起分发），本项目在其上做了大量本地化改造。
- AutoHotkey v2 为 GPL-2.0 授权，本包附带其官方二进制 `drawer\AutoHotkey64.exe`，源码见 <https://github.com/AutoHotkey/AutoHotkey>。
- Lively Wallpaper 为壁纸宿主，**不随本包分发**，请自行安装。
- 字体 `drawer\fonts\*`（Barlow Condensed、Oxanium）为 SIL OFL 授权的开源字体。

详见 `docs\壁纸第三方声明.md` 与 `docs\LICENSE-wallpaper`。
