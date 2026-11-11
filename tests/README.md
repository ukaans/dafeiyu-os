# tests\ —— 漏洞与风险测试模块

一句话：**不改代码就能判断"这套系统现在还健康吗、哪里藏着雷"**，输出一份机器可读的报告给夜里自动跑的修复任务，也给人看。

不需要 Pester，不需要装任何依赖（PS 5.1 自带够用；`node` 有就用，没有自动跳过两条 JS 语法用例）。

---

## 1. 怎么跑

```powershell
# 全套（默认安全模式：只读探测 + 静态分析，不会弹出抽屉、不改待办）
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

# 只跑某一类
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Case SEC      # 安全
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Case 契约     # 中文分类名也行

# 只跑一个用例
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Case STA-005

# 只看高/中危
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Severity high

# 连"会改动桌面可见状态"的用例一起跑（会在跑完还原 todo.txt）
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -Intrusive
```

**退出码 = 高/中危失败用例数**。0 表示干净；非 0 可以直接当 CI 判据用。

产物：

| 路径 | 给谁 |
|---|---|
| `tests\out\last-report.json` | 机器（夜间修复任务读这个：`results[]` 里有 id / severity / status / detail / hint） |
| `tests\out\last-report.md` | 人（总览 → 待修问题 → 风险建议 → 全量明细） |
| `tests\out\history\<时间戳>.json` | 趋势；下次运行会据此算出「新增失败」「对比上次已修复」 |
| `tests\baseline\locked-hashes.json` | 上游不可改文件的基线（首次运行自动生成） |

---

## 2. 安全边界（为什么默认模式不能随便改）

这套系统的测试有一个天然的坑：**大部分接口是"写"而不是"读"**。
发一个 `/summon.gif` 真的会把抽屉弹出来，发 `/todo.gif` 真的会改待办，夜里两点弹一下能吓醒人。

所以规则是：

- **默认（Safe）**：只做静态分析、读文件、`*.js` 接口的 GET、`/icon/` 探测、一条 `/audit.gif` 自测行、一条 `summon.cmd=diag`（只落日志不弹窗）。
- **`-Intrusive`**：额外允许改 `todo.txt`、`panel-rect.txt` 这类状态；用例自己负责备份与还原。
  **2026-11-05 起已无用例需要它**——原来唯一标侵入式的 `SEC-008` 改成"临时目录 + 独立端口 + 独立 `LOCALAPPDATA` 的隔离实例"来验，不碰真实 `todo.txt`。开关保留只为兼容旧脚本。
- **永不**：不重启进程、不调用 `schtasks`、不打开抽屉、不触碰 `layout.dat` / `items.tsv`。

夜间自动任务用默认模式跑。

---

## 3. 结果怎么读

| 状态 | 含义 | 影响退出码 |
|---|---|---|
| `pass` | 断言全过 | 否 |
| `fail` | 断言失败（代码/部署确实有问题） | **是**（high / medium）；low 只记录 |
| `warn` | 能跑但不符合最佳实践：设计取舍、需要白天人工判断 | 否 |
| `skip` | 前置条件不满足（进程没起、没装 node、需要 `-Intrusive`） | 否 |

严重级：

- `high`：会让功能直接坏掉，或构成真实安全面（端口不一致、路由死链、注入、未部署）。
- `medium`：会在"跑一段时间后"或"换机器后"出问题（无轮转日志、字段缺失、抖动）。
- `low`：卫生问题（个人路径残留、备份堆积、孤儿数据）。

---

## 4. 用例清单

### 10-static · 静态完整性（9 条）
| 编号 | 查什么 |
|---|---|
| STA-001 | 25 个核心文件在位 |
| STA-002 | 编码契约：`.ps1` UTF-8 **带 BOM**、`.vbs` UTF-16LE、`.ahk` 无 BOM |
| STA-003 | 壁纸 13 个 JS 过 `node --check` |
| STA-004 | 27 个脚本过 `Parser::ParseFile` |
| STA-005 | **源工程 ↔ `%LOCALAPPDATA%\DesktopPage` 逐字节一致**（不一致=改了半天跑的还是旧代码） |
| STA-006 | 上游不可改文件（`app.js` / 两个 css / 两个 exe）未被改动 |
| STA-007 | `app.js` 依赖的 6 个节点 id 仍在 `index.html` 里 |
| STA-008 | 源码里没有个人绝对路径（`C:\Users\<你>`） |
| STA-009 | **壁纸源工程 ↔ Lively 运行时目录一致**（漏拷 = 屏幕上还是旧页面，404 会被兜底掩盖） |

### 20-contract · 契约一致性（20 条）
| 编号 | 查什么 |
|---|---|
| CON-001 | **代理端口单一配置源**：`drawer\agent-config.ps1` 里 `$AgentPort` 是唯一值；三个 ps1 dot-source 它（`-Port` 默认 0，不再写死）；代理启动写 `agent-port.txt` 与 Lively 目录 `port.js`，AHK / 壁纸都读生成物；`install.ps1` 也生成这两份。运行态再校验 `agent-port.txt` 与配置一致（2026-11-11，原 9 处写死 17433） |
| CON-002 | 路由表里每个 handler 都有对应函数 |
| CON-003 | 前端调的每条路由都在路由表里（反之=按钮失灵） |
| CON-004 | 路由表与 `项目地图.md` §3 双向对齐（防死文档） |
| CON-005 | `index.html` 脚本加载顺序（`todo-data` → `port` → `api` → `todo` → `audit` → `dsh` → `media` 最后） |
| CON-006 | CSP 的 `connect-src` / `object-src` / `base-uri` 仍为 `none` |
| CON-007 | 壁纸侧不出现 `fetch` / `XMLHttpRequest` |
| CON-008 | 8 个 JSONP / 数据变量名（`window.__X`）生产端与消费端一致 |
| CON-009 | `index.html` 引用的每个 `<script src>` 文件都存在 |
| CON-010 | **PowerShell 5.1 兼容**：全部 `.ps1` 不出现 `[Environment]::TickCount64`（5.1 里静默 `$null` → 缓存 age 恒 0 → 面板永远显示旧内容），且 `dsh-agent.ps1` 必须用 `$script:clock`/`Stopwatch` 做缓存时钟 |
| CON-011 | **桥通道不吞向上滚 + 滚动立即生效**：`WheelBridgeMsg` 不许再出现 `(up \|\| !DesktopUnderCursor())`、`curPage=0` 必须调用 `WheelHandle(up ? -1 : 1, "bridge")`；`dsh.js` 的 `/scroll.js` 轮询必须是 40ms、`queueScroll` 不许排 `setTimeout`（2026-11-06 用户报"只能向下滚、卡"的回归） |
| CON-012 | **热重载只走单入口**：页面侧不许再出现 `location.reload()` / `st.reload` 分支（2026-11-11 合并到 `/scroll.js`）；`dsh.js` 仍须定义 `window.__DSH_RELOAD_OK` 供软重载；代理 `Invoke-ScrollJs` 仍须调该钩子（Lively WebView2 上硬刷会白屏） |
| CON-013 | **巡检结果落进桌面控制台**：`parseLog` 必须认 `[HH:mm:ss] <<< 文本` 并生成带自己时间的 DSH 气泡；`Nightly-Check.ps1` 必须有 `Send-ConsoleNote`，把结果以 `<<<` 写进 `DesktopPage\dsh-run.log`（写成 `>>>` 就变成"用户说的话"了） |
| CON-014 | **巡检报告不乱码**：`Nightly-Check.ps1` 调 git 前必须把 `[Console]::OutputEncoding` 切到 UTF-8，且 git 带 `-c core.quotepath=false`（PS 5.1 默认用 GBK 解 git 的 UTF-8 输出 → `琛ユ湰…`） |
| CON-015 | **会话区支持按住拖动滚动**：`dsh.js` 的 `#dshLog` 必须有 `pointerdown` 抓拽（4px 阈值、`dsh-dragging` 类、GEN 守卫），`todo.css` 必须有 grabbing 光标 + 禁选词，且滚动条 ≥12px（壁纸 WebView2 里原生滚动条收不到 mousedown；2026-11-06 用户报"滚轮好了但拖不动"） |
| CON-016 | **巡检推送有直连兜底**：`Nightly-Check.ps1` 必须有 `Invoke-GitPush`，先按仓库代理推，只有"连不上"类错误（`Failed to connect` 等）才用 `-c http.proxy= -c https.proxy=` 直连重试一次；rejected/凭据错照旧上报（2026-11-06 代理关着时巡检推送会红） |
| CON-017 | **热重载令牌：先清后发**：`Invoke-ScrollJs` 判「有没有令牌」必须走 `Get-ReloadToken > 0`，不许用 `Test-Path page-reload.txt`（空文件也算"有"）；且必须先清令牌、确认清掉再下发，清不掉这一轮不发（否则 40ms 一轮无限重插 `dsh.js`）。2026-11-11 起 `/state.js` 不再携带 `reload` 字段，唯一入口是 `/scroll.js`；活体验证：空令牌 0 次下发、真令牌只 1 次 |
| CON-018 | **图标启动：带参快捷方式也必须走代理/队列**：`LaunchItem` 不许再按 `args = ""` 分流（带参 .lnk 会绕过代理直跑，AHK 祖先让鹰角启动器弹 `Load launcher failed, module init error`）；顺序必须是「代理 → 启动队列 → 直连兜底」（2026-11-08 明日方舟：终末地 `--game=Endfield --reason=4` 点一次弹一次） |
| CON-019 | **rect 零矩形三端约定**：控制台隐藏时 `dsh.js` 必须显式上报 `x=0&y=0&w=0&h=0`（不能再退回 `aside` 兜底 —— `display:none` 的 `getBoundingClientRect()` 也是 0×0，与「没上报」无法区分）；代理 `Invoke-RectGif` 必须接受 `w=0` 并原子写 `0 0 0 0`；AHK `PanelRect` 读到 `w<=0` 必须返回零矩形且 `ConsoleUnderCursor` 判「不在控制台」（否则面板关掉后右侧栏继续吃滚轮，2026-11-11 修） |
| CON-020 | **DockAdd 单写者**：AHK `DockAdd` 不许再 `FileAppend` / 自己拼 `DockFile()`，只能发 `AgentDockAdd(...)` → `/dock.gif?op=add`；查重、6 项上限、`Save-Dock` 原子覆盖全在代理。另断言 `op=del` 的整数 `i` 锚定行尾（`i=9831016285b4.png` 这类图标名不能被当 Int32，否则整条 add 返回 `{"ok":false}`，2026-11-11 实测踩到） |

### 30-security · 安全风险（8 条）
| 编号 | 查什么 |
|---|---|
| SEC-001 | `/icon/` 挡住 4 种路径穿越写法 |
| SEC-002 | 未知路由只回 `{"ok":false}`，不泄露堆栈/路径 |
| SEC-003 | `/audit.gif` 不能被 `%0A` 注入伪造日志行 |
| SEC-004 | `/launchpath.gif` 有无来源校验（无 = 本机任意进程可拉起任意 exe） |
| SEC-005 | CSP 是否收敛 `script-src` |
| SEC-006 | 代理只监听 `127.0.0.1`（不是 `+` / `0.0.0.0`） |
| SEC-007 | 4 份日志里没有 `sk-` 密钥明文 |
| SEC-008 | 待办正文换行不能注入多行 —— 用**隔离实例**验（临时目录 + 独立端口 + 独立 `LOCALAPPDATA`），不写真实 `todo.txt`，因此 Safe 模式也会跑 |

### 40-runtime · 运行时健康（13 条）
| 编号 | 查什么 |
|---|---|
| RUN-001 | 抽屉 / 代理 / 看门狗 / Lively 存活，且抽屉只有 1 个实例 |
| RUN-002 | `drawer.pid` 等 pid 文件与实际进程一致 |
| RUN-003 | 心跳 ≤45s **且空闲也前进**（历史事故：只在有请求时刷 → 被看门狗误杀）；采样最多 3 次 × 800ms，三次都不动才红（单次 1.3s 会因整机瞬时抢占假红，2026-11-07 实测一次） |
| RUN-004 | 4 个数据接口 200 且 **<200ms**（单线程代理的连坐红线） |
| RUN-005 | `/state.js` 9 个字段齐全（含 `sig/err/dbg`；`reload` 已于 2026-11-11 收敛到 `/scroll.js`，不再要求） |
| RUN-006 | `state.lines` 是可渲染字符串数组（防空 `System.Object[]`） |
| RUN-007 | `/state.js` 连测 5 次无抖动 |
| RUN-008 | `/media.js` 8 个字段齐全 |
| RUN-009 | `/dock.js` 项数 ≤6、`__DOCK_BUSY` 存在 |
| RUN-010 | `OPTIONS` 回 204、`.js` 的 `Content-Type` 是 `application/javascript` |
| RUN-011 | **抽屉文件通道可达**：写 `summon.cmd=diag`，验证 400ms 内被消费且 `wheel.log` 落了 `diag:` 快照（唯一能验到 AHK 主循环的手段） |
| RUN-012 | **滚轮桥热跟随**：`wheel-bridge.log` 末条 `beat` 必须有 `follows=`（没有 = 桥还在跑旧脚本，旧版不会跟随抽屉重启），且 `beat target=` 要等于 `wheel-bridge.hwnd` 内容。只读文件、不碰钩子。**过渡窗口不算故障**：beat 是 60 秒一行、follow 是 5 秒一次 tick，抽屉刚重启时「最后一次 beat 之后已经有 `target: follow hwnd=<当前目标>` 行」直接判过（2026-11-09 修：旧判据只看 30 秒窗口，重启后 30~60 秒那段会直接抛红）；hwnd 文件比日志新且不到 30 秒时降级 `warn` |
| RUN-013 | **`/log.js` 会话正文通道**：`window.__DSH_LOG="…"` 前缀、≤60000 字符（超了单线程代理会排队）、`Content-Type` 是 `application/javascript`；日志为空时 `sig` 尚未生成属正常 |

### 50-resilience · 健壮性与容量（18 条）
| 编号 | 查什么 |
|---|---|
| RES-001 | `wheel.log` / `dsh-run.log` **有 256KB 轮转**（查写入方代码里的阈值 + `FileMove`/`Move-Item` 改名，不只看尺寸）+ 未超 1MB |
| RES-002 | 有上限的 4 份日志未超限 |
| RES-003 | 安装目录 `.bak` 堆积情况（`layout.bak`/`hidden.bak` 是 `--selftest` 的功能文件，不算堆积） |
| RES-004 | `launch-queue.txt` 无残留（有残留=点了图标没反应） |
| RES-005 | 数据落盘用 tmp + 原子覆盖（hw / wx / 代理侧 todo、todo-data、dock 共六处） |
| RES-006 | `panel-rect.txt` 是 4 个 0..10000 的整数 |
| RES-007 | 看门狗没有"10 分钟内 ≥3 次"的重启风暴；**且最近一次重启在 60 分钟内才算"仍在风暴中"**（几小时前调试留下的旧风暴判为已恢复，数字仍写进 detail） |
| RES-008 | `start-all.log` **最近一轮**走到 `done`、无 `STILL DOWN`。按 `start: appDir=` 切轮次，不拿末尾 N 行一刀切（一轮只写 4~6 行，40 行窗口里能躺 8 轮，一次失败会连着红七八轮）；最新一轮若还在跑（无 `done` 且 ≤120 秒）先跳过、判上一轮；**没 `done` 又超过 120 秒 = 卡住了**（2026-11-05 `start-all.vbs` 漏 `Dim`，wscript 弹不可见模态框，日志停在中途、计划任务一直 `Running`，旧判据只会报 `STILL DOWN` 或干脆看不出来） |
| RES-009 | `hw-data.js` ≤15s、`wx-data.js` ≤330s 在更新 |
| RES-010 | `scroll.dat` 有上限：写入方超 64KB 截断（`$script:SCROLL_MAX`）、读取方超 1MB 兜底；否则消费方一停就只增不减，而 `Take-Scroll` 是整份 `ReadAllText`，会拖死单线程代理 |
| RES-011 | **启动队列「删掉才算消费」**：`agent-watch.ps1`（1s 一轮）与 `ensure-all.ps1`（2min 一轮）消费 `launch-queue.txt` 时不许再用 `Remove-Item -Force -ErrorAction SilentlyContinue`（两处的错误偏好都是静默，删失败不抛也不记 → 队列留着 → 下一次 tick 把同一批路径**再启动一遍**）；必须有 `File::Delete` + `Test-Path` 复核 + `$consumed` 闸，且启动循环在闸内（2026-11-08 修） |
| RES-012 | **信标落盘也原子替换**：`Invoke-RectGif` / `Invoke-SummonGif` 必须 tmp + `Move-Item -Force` 覆盖 `panel-rect.txt` / `summon.cmd`。AHK 每 400ms 读这两个文件，而 `SummonTick` **读完无论读成什么都会删文件** —— 直写时「存在但为空」的那一瞬就等于命令被静默吞掉；另带一条活体并发探针（连打 `/rect.gif` 的幂等值 30 轮 × 每轮读 6 次，读到空/字段不足 4 个即失败） |
| RES-013 | **滚轮意图「读到≠取走」**：`Take-Scroll` 不许「读完就 `File::Delete`、删没删掉不管」，必须有 `$cleared` 闸（删 → `Test-Path` 复核 → 截空复核 → 都不成就这一轮返回 0）。删除失败时（写方持有句柄 / 杀软）旧写法会把同一批意图 40ms 后再交付一次 = 滚一格跳两格。**活体是把 `Take-Scroll` 单独取出来在临时目录里跑**（不碰真实 `scroll.dat`、不占端口）：正常路径取走 4 → 占住句柄后两轮都必须是 0 → 放开后恰好交付一次 5 |
| RES-014 | **文件召唤「删掉才算消费」**（AHK 侧）：`SummonTick` 必须在 `FileDelete(SUMMON_FILE)` 之后、派发之前有一道「文件还在就 `return`」。旧写法删失败也照样派发 → 同一条命令每 400ms 重放（`foldertest=` 反复弹窗、`log=N` 反复导出）。判据只认「FileDelete 之后紧跟 FileExist→return」——函数头的 `if !FileExist(SUMMON_FILE) return` 和 `if (cmd = "") return` 都会让弱判据永远为绿；活体走文件通道写一条 `diag` 证明没把正常命令挡掉 |
| RES-015 | **审计轮转判据要对齐真实尺寸**：`audit.log` 是 `[AHK ]`/`[API ]`/`[WEB ]` 三端共写（实测 2331 行里 1999 行来自抽屉 ≈ 90%），只累加「自己写进去的字节」会与真实尺寸脱钩 —— 偏小则代理那段轮转形同虚设，偏大则在别人刚轮转完时「提前轮转」一个小文件、把上一份真历史 `audit.log.1` 覆盖掉。要求代理侧 `Write-Audit` 每 32 条回到 `FileInfo.Length`，AHK 侧 `AuditLog` 的 `Mod(AUDIT_WRITES, 32)` + `FileGetSize` 不许被删；活体：把 `Write-Audit` 取到临时目录、造「计数器 1KB / 真实 2.2MB」，补一条写入必须当场轮转（2026-11-10 修） |
| RES-016 | **轮转是两步，改名失败不许截空**：老写法 `Move-Item … -ErrorAction SilentlyContinue` 之后无条件 `WriteAllText($log,'')` —— 改名失败（AHK 正持有句柄追加 / 有人开着 `audit.log.1` / 上一轮 dsh 的 `>>` 占着 `dsh-run.log`）时整份历史被抹成 0 字节，而 `.1` 还是上一代内容，**历史与它唯一的备份一起没了**，且哪儿都不报错。要求 `audit.log` 与 `dsh-run.log` 两处都「改名成功才许截空」，失败要把计数器拉回真实尺寸并写一行 `dsh-agent.log`；静态只看代码（剥注释，注释里引用了旧写法）；活体：`.1` 被只读句柄占住时 2.68MB 原样留着，放开句柄再写一条必须当场轮转（2026-11-11 修） |
| RES-017 | **审计轮转互斥**：`audit.log` 的 AHK 与代理两个轮转者必须共用 `Global\DesktopPage_audit` 命名互斥体，`WaitForSingleObject` / `WaitOne(250)` 抢到锁后**复检真实尺寸**再改名；抢不到就跳过本轮。否则两端同时越过 2MB 时，后一个会把 `.1` 覆盖成刚建的小文件，前一个 2MB 历史丢失（2026-11-11 修） |
| RES-018 | **AHK 滚动写入有 64KB 上限；桥日志改名成功才截空**：`AgentScroll` 追加前必须 `FileGetSize(SCROLL_FILE) > 65536` 先截空（读取方 1MB 兜底是第二道，不是唯一一道）；`wheel-bridge.ps1` 的 `Log()` 不许再 `File.Copy` + 截空，必须 `File.Replace` / `File.Move` 成功后才 `WriteAllText(empty)`（2026-11-11 修） |

### 60-data · 数据完整性（8 条）
| 编号 | 查什么 |
|---|---|
| DAT-001 | `layout.dat` 首行 `V2`、`P`/`F` 行字段数、`F` 有成员 |
| DAT-002 | `items.tsv` 4 列、路径有效率 ≥80% |
| DAT-003 | `hidden.dat` 无孤儿条目 |
| DAT-004 | `dock.txt` ≤6 行、`路径\|显示名\|图标`、路径有效 |
| DAT-005 | `hw/wx/todo-data.js` 语法合法（半个对象会让整页脚本挂） |
| DAT-006 | `desktop_positions.tsv` 3 列且坐标是整数 |
| DAT-007 | `items.tsv` 引用的图标文件在 `icons\` 里存在 |
| DAT-008 | **待办生成物整份替换**：`SyncTodoFile` 不许「先 `FileDelete(TODO_JS)` 再 `FileAppend`」（删成功后有「文件不存在」空窗，壁纸 10 秒热加载会读到空面板；删失败则追加在旧内容后面，每次同步再叠一份 `__TODO_TS`，只增不减且 `node --check` 照样过）；必须走 `WriteFileAtomic`（tmp + `FileMove`，`UTF-8-RAW` 与代理侧一致）。活体看真实 `todo-data.js` 是否只有 1 份定义（2026-11-10 修） |

合计 76 条。

---

## 5. 加一条用例

在 `cases\` 下对应的文件末尾追一段，不用改框架：

```powershell
Test-Case XXX-001 '分类' '一句话说明' medium {
    # 断言失败就 throw '原因'；通过就返回一句明细
    $p = Join-Path (Get-DshInstall) 'some-file'
    Assert-File $p 'some-file'
    '检查通过'
} -Hint '失败时人会看到的修复建议'

# 要 warn / skip 时返回哈希表
Test-Case XXX-002 '分类' '需要人工判断的' low {
    return @{ Status = 'warn'; Detail = '现象描述' }
}
```

可用工具（`lib\DshTest.ps1`）：

| 函数 | 用途 |
|---|---|
| `Get-DshRoot` / `Get-DshInstall` / `Get-DshWall` / `Get-DshTestsDir` | 路径。**不要用 `$PSScriptRoot`**（跨文件调用时它指向调用方） |
| `Read-Raw <path>` | 按 UTF-8 读全文（不经过 cmdlet 的编码猜测） |
| `Invoke-DshHttp -Path '/x.js' [-Method OPTIONS] [-TimeoutMs 3000]` | 本机探测，返回 `@{Ok;Status;Ms;Body;ContentType;Error}`；已绕开 `HTTPS_PROXY` |
| `Test-DshApiUp` | 代理是否在线 |
| `Assert-True/Equal/Match/NotMatch/File`、`Fail` | 断言（失败即 throw） |
| `Contract-RouteTable` | 解析 `dsh-agent.ps1` 的 `$script:ROUTES`，返回 `@{Src;Routes;Handlers}` |

编号规则：`STA/CON/SEC/RUN/RES/DAT` + 三位序号，新增往后排，**不要复用已删除的编号**（历史报告靠它对齐）。

---

## 6. 已知的假阳性与不适用场景

- **RUN-004 会消耗一次 `scroll.dat`**：`/scroll.js` 是"读后清零"的语义，探测一次最多吃掉一个滚轮刻度，无实际影响。
- **STA-005 / STA-009 在"故意只改源工程、还没部署"时会红**：这是设计意图，不是误报 —— 那正是最容易骗人的状态。
- **SEC-003 会在 `audit.log` 留一行 `SELFTEST-INJECT`**：这是探针本身，`grep -v SELFTEST` 可以滤掉。
- **RUN-011 会往 `wheel.log` 追加一行 `diag:`**，并临时创建/由抽屉删除 `summon.cmd`。`diag` 只写快照不弹窗，但确实会改一个运行时文件；不想要它就 `-Case` 排除。
- **RES-012 会重写一次 `panel-rect.txt`**：它把文件里当前的四个数原样再打一遍 `/rect.gif`（幂等、不改实际矩形），只为制造写入压力看会不会读到半截。壁纸页每 4 秒也会重报同一个值，不想要它就 `-Case` 排除。
- **RES-014 会往 `wheel.log` 追加一行 `diag:`**（与 RUN-011 同类，走文件通道写 `summon.cmd=diag`）。
- **临时探针绝不放 `tests\out`**：`STA-002`（BOM）与 `STA-004`（Parser 全量 `.ps1`）会扫到，放进去就是假红；一律放 `%TEMP%`，跑完删。
- **RES-015 / DAT-008 / RES-016 各会写一份临时目录**（`%TEMP%\dsh_audit_*` / `dsh_todo_*` / `dsh_rot_*`）：`RES-015` 把 `Write-Audit` 取出来跑一次轮转，`DAT-008` 只读真实 `todo-data.js`，`RES-016` 先把 `.1` 用只读句柄占住再造一次「改名失败」；跑完自己删目录，**不碰真实 `audit.log`**。
- **用例里绝对不要用 `/summon.gif` 造测试数据**：那条路由只认 `d=1|hide`，其余一切（包括 `d=diag`）都会写成 `show` —— 深夜跑测试会把抽屉弹到用户脸上（2026-11-09 踩过，改成直接写 `summon.cmd` 文件）。
- **AHK 不能靠 `/validate` 证明没问题**：本机 `AutoHotkey64.exe /validate <script>` 返回 exit=0 且无任何输出（既不是 Syntax OK，也不是失败），所以别把它当验收。 `DesktopPage.ahk` 只查编码、函数定义位置、原子写模式这些静态特征；**改完仍要重启抽屉看 `wheel.log` / `audit.log` 里动作对不对**。`RUN-011` 只能证明"主循环还在转"。滚轮判定层可脚本化验证：`summon.cmd` 写 `classify=<hwnd>`，壁纸页 WebView2 的 RenderWidgetHost 应回 `desk=1`（root=Progman），Chrome 的应回 `desk=0`。
- **`schtasks` 被拉黑**：所以测试不验证计划任务是否注册（那是 `verify.ps1` 用 `Get-ScheduledTask` 查的，走的是 COM 不是 exe）。
