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
| STA-001 | 24 个核心文件在位 |
| STA-002 | 编码契约：`.ps1` UTF-8 **带 BOM**、`.vbs` UTF-16LE、`.ahk` 无 BOM |
| STA-003 | 壁纸 12 个 JS 过 `node --check` |
| STA-004 | 26 个脚本过 `Parser::ParseFile` |
| STA-005 | **源工程 ↔ `%LOCALAPPDATA%\DesktopPage` 逐字节一致**（不一致=改了半天跑的还是旧代码） |
| STA-006 | 上游不可改文件（`app.js` / 两个 css / 两个 exe）未被改动 |
| STA-007 | `app.js` 依赖的 6 个节点 id 仍在 `index.html` 里 |
| STA-008 | 源码里没有个人绝对路径（`C:\Users\<你>`） |
| STA-009 | **壁纸源工程 ↔ Lively 运行时目录一致**（漏拷 = 屏幕上还是旧页面，404 会被兜底掩盖） |

### 20-contract · 契约一致性（17 条）
| 编号 | 查什么 |
|---|---|
| CON-001 | 代理端口在 9 个文件里一致 |
| CON-002 | 路由表里每个 handler 都有对应函数 |
| CON-003 | 前端调的每条路由都在路由表里（反之=按钮失灵） |
| CON-004 | 路由表与 `项目地图.md` §3 双向对齐（防死文档） |
| CON-005 | `index.html` 脚本加载顺序（`todo-data` → `todo` → `api` → `audit` → `dsh` → `media` 最后） |
| CON-006 | CSP 的 `connect-src` / `object-src` / `base-uri` 仍为 `none` |
| CON-007 | 壁纸侧不出现 `fetch` / `XMLHttpRequest` |
| CON-008 | 8 个 JSONP / 数据变量名（`window.__X`）生产端与消费端一致 |
| CON-009 | `index.html` 引用的每个 `<script src>` 文件都存在 |
| CON-010 | **PowerShell 5.1 兼容**：全部 `.ps1` 不出现 `[Environment]::TickCount64`（5.1 里静默 `$null` → 缓存 age 恒 0 → 面板永远显示旧内容），且 `dsh-agent.ps1` 必须用 `$script:clock`/`Stopwatch` 做缓存时钟 |
| CON-011 | **桥通道不吞向上滚 + 滚动立即生效**：`WheelBridgeMsg` 不许再出现 `(up \|\| !DesktopUnderCursor())`、`curPage=0` 必须调用 `WheelHandle(up ? -1 : 1, "bridge")`；`dsh.js` 的 `/scroll.js` 轮询必须是 40ms、`queueScroll` 不许排 `setTimeout`（2026-11-06 用户报"只能向下滚、卡"的回归） |
| CON-012 | **热重载只走软重载**：`dsh.js` 里裸 `location.reload()` 只允许 `softReload()` 里那 1 处老页面兜底；`/state.js` 的 `st.reload` 分支必须调 `softReload()`（不许硬刷）、`softReload()` 必须先试 `__DSH_RELOAD_OK`；代理 `Invoke-ScrollJs` 仍须调该钩子（Lively WebView2 上硬刷会白屏） |
| CON-013 | **巡检结果落进桌面控制台**：`parseLog` 必须认 `[HH:mm:ss] <<< 文本` 并生成带自己时间的 DSH 气泡；`Nightly-Check.ps1` 必须有 `Send-ConsoleNote`，把结果以 `<<<` 写进 `DesktopPage\dsh-run.log`（写成 `>>>` 就变成"用户说的话"了） |
| CON-014 | **巡检报告不乱码**：`Nightly-Check.ps1` 调 git 前必须把 `[Console]::OutputEncoding` 切到 UTF-8，且 git 带 `-c core.quotepath=false`（PS 5.1 默认用 GBK 解 git 的 UTF-8 输出 → `琛ユ湰…`） |
| CON-015 | **会话区支持按住拖动滚动**：`dsh.js` 的 `#dshLog` 必须有 `pointerdown` 抓拽（4px 阈值、`dsh-dragging` 类、GEN 守卫），`todo.css` 必须有 grabbing 光标 + 禁选词，且滚动条 ≥12px（壁纸 WebView2 里原生滚动条收不到 mousedown；2026-11-06 用户报"滚轮好了但拖不动"） |
| CON-016 | **巡检推送有直连兜底**：`Nightly-Check.ps1` 必须有 `Invoke-GitPush`，先按仓库代理推，只有"连不上"类错误（`Failed to connect` 等）才用 `-c http.proxy= -c https.proxy=` 直连重试一次；rejected/凭据错照旧上报（2026-11-06 代理关着时巡检推送会红） |
| CON-017 | **热重载令牌：两条路径同源判据 + 先清后发**：`Invoke-ScrollJs` 判「有没有令牌」必须走 `Get-ReloadToken > 0`（和 `/state.js` 同源），不许用 `Test-Path page-reload.txt`（空文件也算"有"）；且必须先清令牌、确认清掉再下发，清不掉这一轮不发（否则 40ms 一轮无限重插 `dsh.js`）；发完 `Cache-Drop` 掉 reload 缓存。活体验证：空令牌 0 次下发、真令牌只 1 次（2026-11-07 实测空文件也会触发软重载） |

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
| RUN-005 | `/state.js` 10 个字段齐全（含 `sig/err/reload/dbg`） |
| RUN-006 | `state.lines` 是可渲染字符串数组（防空 `System.Object[]`） |
| RUN-007 | `/state.js` 连测 5 次无抖动 |
| RUN-008 | `/media.js` 8 个字段齐全 |
| RUN-009 | `/dock.js` 项数 ≤6、`__DOCK_BUSY` 存在 |
| RUN-010 | `OPTIONS` 回 204、`.js` 的 `Content-Type` 是 `application/javascript` |
| RUN-011 | **抽屉文件通道可达**：写 `summon.cmd=diag`，验证 400ms 内被消费且 `wheel.log` 落了 `diag:` 快照（唯一能验到 AHK 主循环的手段） |
| RUN-012 | **滚轮桥热跟随**：`wheel-bridge.log` 末条 `beat` 必须有 `follows=`（没有 = 桥还在跑旧脚本，旧版不会跟随抽屉重启），且 `beat target=` 要等于 `wheel-bridge.hwnd` 内容。只读文件、不碰钩子；hwnd 文件比日志新且不到 30 秒时降级 `warn`（抽屉刚 announce、桥还没到下一个 5 秒 tick） |
| RUN-013 | **`/log.js` 会话正文通道**：`window.__DSH_LOG="…"` 前缀、≤60000 字符（超了单线程代理会排队）、`Content-Type` 是 `application/javascript`；日志为空时 `sig` 尚未生成属正常 |

### 50-resilience · 健壮性与容量（12 条）
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

### 60-data · 数据完整性（7 条）
| 编号 | 查什么 |
|---|---|
| DAT-001 | `layout.dat` 首行 `V2`、`P`/`F` 行字段数、`F` 有成员 |
| DAT-002 | `items.tsv` 4 列、路径有效率 ≥80% |
| DAT-003 | `hidden.dat` 无孤儿条目 |
| DAT-004 | `dock.txt` ≤6 行、`路径\|显示名\|图标`、路径有效 |
| DAT-005 | `hw/wx/todo-data.js` 语法合法（半个对象会让整页脚本挂） |
| DAT-006 | `desktop_positions.tsv` 3 列且坐标是整数 |
| DAT-007 | `items.tsv` 引用的图标文件在 `icons\` 里存在 |

合计 66 条。

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
- **AHK 不能靠 `/validate` 证明没问题**：本机 `AutoHotkey64.exe /validate <script>` 返回 exit=0 且无任何输出（既不是 Syntax OK，也不是失败），所以别把它当验收。 `DesktopPage.ahk` 只查编码、函数定义位置、原子写模式这些静态特征；**改完仍要重启抽屉看 `wheel.log` / `audit.log` 里动作对不对**。`RUN-011` 只能证明"主循环还在转"。滚轮判定层可脚本化验证：`summon.cmd` 写 `classify=<hwnd>`，壁纸页 WebView2 的 RenderWidgetHost 应回 `desk=1`（root=Progman），Chrome 的应回 `desk=0`。
- **`schtasks` 被拉黑**：所以测试不验证计划任务是否注册（那是 `verify.ps1` 用 `Get-ScheduledTask` 查的，走的是 COM 不是 exe）。
