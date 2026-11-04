# 组件契约（抽屉 / 代理 / 壁纸）

三份独立进程/文档，靠**文件**和**HTTP 路由**对接，互相不 import、不共享内存。
加功能前先查这张表：改哪一格，就只动那个组件。

| 组件 | 职责 | 对外契约 | 依赖方向 | 能单独部署？ | 单独自检 |
|---|---|---|---|---|---|
| **抽屉**<br>`drawer\DesktopPage.ahk` | 桌面图标页、滚轮/热区唤起、文件夹、启动程序、写审计 `[AHK ]` | **文件**：读 `items.tsv`/`layout.dat`/`hidden.dat`/`dock.txt`；写 `layout.dat`/`hidden.dat`/`drawer.pid`/`wheel.log`/`drag` 等<br>**文件命令**：轮询 `summon.cmd`（`show`/`hide`/`diag`/`edge=0`/`edge=1`/`log=N`/`foldertest=`/`dirtest=`，表在 `SUMMON_CMDS`）<br>**出站 HTTP**：`GET /launchpath.gif?t=`、`/scroll.gif?d=`、`/rect` 类不上报 | → 代理（可选，失败回退 `Run`）；→ 壁纸目录（只写 `todo-data.js`） | 是（代理不在时启动走 `Run`、召唤走热键/热区） | `AutoHotkey64.exe /ErrorStdOut /validate DesktopPage.ahk`；运行时自检：向 `summon.cmd` 写 `diag`，看 `wheel.log` 的 `diag:` 行 |
| **代理**<br>`drawer\dsh-agent.ps1` | 单线程 HttpListener（17433）：把页面能干的动作翻译成文件/进程操作；写审计 `[API ]` | **路由**：`/state.js /state /media.js /media.gif /dock.js /dock.gif /adddock.gif /launchpath.gif /scroll.js /scroll.gif /rect.gif /summon.gif /todo.gif /run.gif /launch.gif /open.gif /drawer.gif /clear.gif /audit.gif` + 前缀 `/icon/<file>`（表在 `$script:ROUTES`）<br>**返回协议**：`window.__XXX=...` / 1×1 GIF / 未知路径 `{"ok":false}`<br>**文件**：读 `dock.txt`/`todo.txt`/`scroll.dat`；写 `todo-data.js`/`summon.cmd`/`panel-rect.txt`/`audit.log`/`dsh-agent.hb`/`dsh-agent.pid` | → 文件系统、`schtasks`（`/drawer.gif`）、`Start-Process`；**不依赖**抽屉与壁纸 | 是（不依赖另两个组件即可起；只是没人调它） | `powershell -File dsh-agent.ps1 -Port 17499`（另开一个实例，只测接口）；`Parser::ParseFile` 零错误 + 前三字节 `EF BB BF` |
| **壁纸**<br>`wallpaper\*.js` | 渲染页面；把用户动作发出去；写审计 `[WEB ]` | **入站**：`window.__DSH_STATE`/`__MEDIA`/`__DOCK`/`__DSH_SCROLL`/`__TODO`/`__TODO_TS`<br>**出站**：JSONP `GET *.js`、GIF 信标 `GET *.gif`（**禁用 fetch/XHR**，CSP `connect-src 'none'`）<br>**通信层**：`api.js` → `window.__API.{url,jsonp,beacon,icon}` | → 代理（唯一外部依赖）；`api.js` 是所有脚本的公共下层 | 是：任一脚本在没有 `api.js` 时自带走内置 JSONP/信标回退 | `node --check *.js`；浏览器控制台看 `window.__API` 存在且 `document.title` 无 `JSERR` |

## 依赖方向（单向，不许反向）

```
壁纸 --HTTP(JSONP/信标)--> 代理 --文件/进程--> 系统
抽屉 --文件(summon.cmd/dock.txt)--> 代理     抽屉 --文件--> 壁纸目录(todo-data.js)
```

- 壁纸**不认识**抽屉：它只打 17433 的路由。
- 抽屉**不认识**壁纸的 DOM：它只写 `todo-data.js` 和读 `panel-rect.txt`。
- 代理**不认识**任何 UI：它只读写文件、起进程。

## 加功能的落点

| 想加的东西 | 改哪里 | 不用改哪里 |
|---|---|---|
| 新接口 `/foo.gif` | `$script:ROUTES` 加一行 + 一个 `Invoke-Foo` 函数 | 主循环、审计白名单（`audit` 字段） |
| 新 summon 命令 `foo=1` | `SUMMON_CMDS` 加一行 + 一个 `Summon_CmdFoo` | `SummonTick` |
| 新的页面动作 | 壁纸脚本里 `window.__API.beacon('/foo.gif?...')` | 其它壁纸脚本、抽屉 |
| 新的持久化数据 | 抽屉数据层加一对 `Load*/Save*`（写走 `WriteFileAtomic`） | 渲染层/交互层 |

审计三端写同一份 `%LOCALAPPDATA%\DesktopPage\audit.log`，靠行首 `[AHK ]` / `[API ]` / `[WEB ]` 区分；
**改动任何一端都不许改这个行格式**（`verify.ps1` 会统计三种标签）。
