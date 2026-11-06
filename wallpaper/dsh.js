window.onerror = function (m, s, l) { try { document.title = 'JSERR ' + m + ' @' + l; } catch (e) {} };
/* dsh.js — 壁纸右侧的 DSH 迷你控制台
 * 页面是 file://，直接 fetch http://127.0.0.1 会被 Chromium 的私有网络策略拦掉，
 * 所以走两条不触发 CORS 的老通道：
 *   读状态：动态插入 <script src="/state.js?v=...">（JSONP 式）
 *   发指令：<img src="/run.gif?t=...">（信标）
 *
 * 2026-11-05 改版（两件事）：
 *  1) 会话视图：把 dsh-run.log 解析成「你发的指令 / DSH 的回复」气泡，像网页版一样上下翻，
 *     不再是一坨原始日志尾巴。数据走新增的 /log.js（整段日志，避免只看 40 行看不到上文）。
 *  2) 滚轮可靠化：去掉 requestAnimationFrame 缓动。壁纸页被全屏窗口盖住时 Chromium 可能
 *     暂停 rAF，而 80ms 的 JSONP 轮询照跑 —— 意图收到了、画面却不动，看着就是「滚轮失效」。
 *     现在意图到达后 setTimeout(0) 直接写 scrollTop，不依赖动画帧。
 */
function dshInit() {
  'use strict';

  // ---- 热重载（不导航）----
  // Lively 的 WebView2 上 location.reload() 会把页面弄成白屏（2026-11-06 复现两次，panel-rect 不再更新），
  // 所以改成「再插一份 dsh.js」：先清掉上一代的定时器、删掉旧面板，再跑一遍初始化。
  var GEN = (window.__DSH_GEN = (window.__DSH_GEN || 0) + 1);
  (window.__DSH_TIMERS || []).forEach(function (t) { clearTimeout(t); clearInterval(t); });
  window.__DSH_TIMERS = [];
  function alive() { return window.__DSH_GEN === GEN; }
  function every(ms, fn) { var id = setInterval(function () { if (alive()) fn(); }, ms); window.__DSH_TIMERS.push(id); return id; }
  function after(ms, fn) { var id = setTimeout(function () { if (alive()) fn(); }, ms); window.__DSH_TIMERS.push(id); return id; }
  var oldPanel = document.getElementById('dshPanel');
  if (oldPanel && oldPanel.parentNode) oldPanel.parentNode.removeChild(oldPanel);

  // 通信层优先走 api.js 的 window.__API；本文件单独部署时回退到内置写法（jsonp / beacon 里）
  var API = (window.__API || {}).url || 'http://127.0.0.1:17433';

  var aside = document.querySelector('aside.right-panel');
  var consolePanel = document.getElementById('consolePanel');
  var recognition = document.querySelector('.recognition-panel');
  var interaction = document.querySelector('.interaction-panel');
  if (!aside) return;

  // 原面板只隐藏不删除（app.js 会往里写事件流）
  if (consolePanel) consolePanel.style.display = 'none';
  if (recognition) recognition.style.display = 'none';

  var box = document.createElement('section');
  box.id = 'dshPanel';
  box.className = 'dsh-panel';

  // 面板高度预算（右侧栏窄、下面还有行为参数/当前播放/时钟）：日志区尽量大，
  // 标题、输入、按钮三行压到最小，余额并进按钮行的右端。
  box.innerHTML =
    '<div class="dsh-title"><i></i><span>DSH / DESKTOP</span>' +
    '<span id="dshState" class="dsh-state">—</span>' +
    '<b id="dshDot" class="dsh-dot" title="DSH 服务状态"></b></div>' +
    '<div id="dshLog" class="dsh-log"><div class="dsh-note">连接中…</div></div>' +
    '<div id="dshErr" class="dsh-err" hidden></div>' +
    '<div class="dsh-input"><input id="dshText" type="text" placeholder="给 DSH 发指令…" autocomplete="off" spellcheck="false" /><button id="dshSend" type="button">发送</button></div>' +
    '<div class="dsh-actions">' +
    '<button id="dshLaunch" type="button">启动</button>' +
    '<button id="dshOpen" type="button">网页</button>' +
    '<button id="dshClear" type="button">清空</button>' +
    '<button id="dshUp" type="button" title="向上翻对话">▲</button>' +
    '<button id="dshDown" type="button" title="向下翻对话">▼</button>' +
    '<b id="dshBal" class="dsh-bal">—</b>' +
    '</div>';

  if (interaction && interaction.parentNode === aside) aside.insertBefore(box, interaction);
  else aside.appendChild(box);

  var logEl = document.getElementById('dshLog');
  var inputEl = document.getElementById('dshText');
  var stateEl = document.getElementById('dshState');
  var dotEl = document.getElementById('dshDot');
  var balEl = document.getElementById('dshBal');
  var errEl = document.getElementById('dshErr');
  var runDot = document.getElementById('drawerDot');

  var seq = 0;
  var lastRect = '';
  var lastPoll = 0;

  // 每格滚轮折多少像素：120 的原始 deltaY 档位（Windows 默认 3 行/格）换算成面板里的可见位移
  var SCROLL_STEP = 110;

  // ---- 调试信标：只在代理侧存在 dsh-debug.flag 时落盘（验证期开关，平时零成本）----
  var DEBUG = false;
  function dbg(m) {
    if (!DEBUG) return;
    try { beacon('/dbg.gif?m=' + encodeURIComponent(String(m).slice(0, 300))); } catch (e) {}
  }

  // 设置面板：打开时把整屏都算作「控制台区域」，滚轮就不会被抽屉程序当成桌面手势
  var overlayEl = document.getElementById('settingsOverlay');
  var settingsScroll = document.getElementById('settingsScroll');
  function settingsOpen() { return !!(overlayEl && !overlayEl.hidden); }

  var lastCls = '';
  var failStreak = 0;
  function setState(text, cls) {
    var prev = lastCls;
    lastCls = cls || '';
    if (stateEl) stateEl.textContent = text;
    if (dotEl) dotEl.className = 'dsh-dot' + (cls ? ' ' + cls : '');
    // 只在「就绪/运行中 → 离线」真正发生的那一次记审计，且要求连续失败 ≥3 次：
    // 1-2 次是代理单线程偶发排队，不算故障；每 1.2 秒一轮的轮询绝不写审计。
    if (cls === 'off' && (prev === 'ok' || prev === 'busy') && failStreak >= 3) {
      audit('dsh.offline', 'fail=' + failStreak);
    }
  }

  // ---- 通信层：有 api.js 就走 window.__API，没有就退回原来那套内置写法 ----
  function jsonp(path, ondata, onfail, timeoutMs) {
    if (window.__API && window.__API.jsonp) { window.__API.jsonp(path, ondata, onfail, timeoutMs); return; }
    // 必须每次新建元素：script 插入后再改 src 不会重新执行（HTML 规范的 already-started 标志）
    var s = document.createElement('script');
    var done = false;
    var timer = 0;
    function finish(ok, why) {
      if (done) return;
      done = true;
      if (timer) { clearTimeout(timer); timer = 0; }
      s.onload = s.onerror = null;
      if (s.parentNode) s.parentNode.removeChild(s);
      if (ok) { if (ondata) ondata(); } else { if (onfail) onfail(why); }
    }
    s.src = API + path + (path.indexOf('?') >= 0 ? '&' : '?') + 'v=' + (++seq) + '_' + Date.now();
    s.onload = function () { finish(true); };
    s.onerror = function () { finish(false, 'error'); };
    if (timeoutMs > 0) timer = setTimeout(function () { finish(false, 'timeout'); }, timeoutMs);
    document.head.appendChild(s);
  }

  function iconUrl(name) {
    if (window.__API && window.__API.icon) return window.__API.icon(name);
    return API + '/icon/' + encodeURIComponent(name);
  }

  function beacon(path) {
    if (window.__API && window.__API.beacon) { window.__API.beacon(path); return; }
    var img = new Image();
    img.onload = img.onerror = function () { img.onload = img.onerror = null; };
    img.src = API + path + (path.indexOf('?') >= 0 ? '&' : '?') + '_=' + Date.now();
  }

  // 统一审计（audit.js 提供的 window.__AUDIT）。单独部署本文件时它可能不存在，
  // 所以每次都判类型并整体 try —— 审计永远不能影响面板。
  function audit(e, k) {
    if (typeof window.__AUDIT !== 'function') return;
    try { window.__AUDIT(e, k); } catch (err) {}
  }


  // 把面板在屏幕上的矩形上报给代理，抽屉程序据此判断"滚轮是否落在控制台"
  function reportRect(force) {
    try {
      var q;
      if (settingsOpen()) {
        // 设置面板铺满整屏：告诉抽屉程序「这块归控制台」，滚轮就不会弹出图标抽屉
        q = 'x=0&y=0&w=10000&h=10000';
      } else {
        var r = box.getBoundingClientRect();
        if (!r || r.width < 40) r = aside.getBoundingClientRect();
        if (!r || r.width < 40) return;
        var vw = window.innerWidth || 1, vh = window.innerHeight || 1;
        q = 'x=' + Math.round(r.left / vw * 10000) + '&y=' + Math.round(r.top / vh * 10000) + '&w=' + Math.round(r.width / vw * 10000) + '&h=' + Math.round(r.height / vh * 10000);
      }
      if (!force && q === lastRect) return;
      lastRect = q;
      beacon('/rect.gif?' + q);
    } catch (e) {}
  }
  // ===== 滚轮 =====
  // 两个来源都会把位移堆到 scrollPending：页面原生 wheel 事件、抽屉程序转发的意图（__DSH_SCROLL）。
  // 处理方式改成「立即写 scrollTop」：不排 rAF。壁纸被全屏窗口遮住时 rAF 可能整段不跑，
  // 而 setTimeout/JSONP 轮询还在跑 —— 那就是用户看到「滚轮没反应」的直接原因。
  var scrollPending = 0;
  var scrollTimer = 0;

  function scrollHostEl() {
    return (settingsOpen() && settingsScroll) ? settingsScroll : logEl;
  }

  function clampScroll(v, host) {
    var max = Math.max(0, host.scrollHeight - host.clientHeight);
    return Math.max(0, Math.min(max, v));
  }

  function scrollByPx(px) {
    var host = scrollHostEl();
    if (!host) return;
    // 元素被 [hidden] 或移出文档后 scrollTop 恒为 0，别在这里死循环
    if (!host.isConnected || host.offsetParent === null) { scrollPending = 0; return; }
    var before = host.scrollTop;
    host.scrollTop = clampScroll(before + px, host);
    syncNavBtns();
    dbg('scroll gen=' + GEN + ' d=' + px + ' at=' + Math.round(before) + '->' + Math.round(host.scrollTop) +
      ' max=' + Math.max(0, host.scrollHeight - host.clientHeight) + ' ch=' + host.clientHeight);
  }

  function flushScroll() {
    scrollTimer = 0;
    if (!scrollPending) return;
    var d = scrollPending;
    scrollPending = 0;
    scrollByPx(d);
  }

  function queueScroll(px) {
    if (!px) return;
    scrollPending += px;
    // 立即写 scrollTop：不排 setTimeout —— 壁纸被全屏窗口盖住时定时器可能被节流，
    // 而且多等一帧就是用户说的"滚轮发黏、卡卡的"。
    flushScroll();
  }

  function onScrollData() {
    var d = window.__DSH_SCROLL || 0;
    window.__DSH_SCROLL = 0;
    if (!d) return;
    queueScroll(d * SCROLL_STEP);
  }

  var scrollPolling = false;
  function scrollPoll() {
    if (!scrollPolling) {
      scrollPolling = true;
      jsonp('/scroll.js', function () { scrollPolling = false; onScrollData(); },
        function () { scrollPolling = false; });
    }
    // 40ms 一轮：80ms 时"一格滚轮要等小半秒"的感觉很明显，40ms 是本地 HTTP 轮询还能稳住的频率
    after(40, scrollPoll);
  }

  // ===== 会话视图 =====
  // dsh-run.log 的格式（dsh-agent.ps1 的 Start-Run；巡检等机器来源另有 <<<）：
  //   [23:41:02] >>> 用户的指令
  //   <DSH 的最终回答，stdout 多行>
  //   [07:30:12] <<< 机器发言（每日巡检结果等，不跟用户指令锚定，自带时间）
  //   （stderr 已改到 dsh-run.err.log；旧日志里混进来的 "dsh: reasoning:" 段一律跳过）
  var parsedMsgs = [];       // [{role:'user'|'dsh'|'err', time:'HH:MM:SS', text:''}]
  var msgEls = [];           // 与 parsedMsgs 对齐的 DOM
  var logSig = null;         // 已成功取回的日志签名
  var logWant = '';          // 最近一次 /state.js 报的签名
  var logBusy = false;
  var logFails = 0;
  var busyNow = false;
  var pendingSend = null;    // 刚发出、日志里还没出现的那条指令 → 先乐观显示

  function hhmm(t) { return t ? String(t).slice(0, 5) : ''; }

  function trimMsg(s) {
    var t = String(s || '').replace(/[ \t]+$/mg, '').replace(/\n{3,}/g, '\n\n').replace(/^\n+|\n+$/g, '');
    // 单条上限 12000 字符：够放一整段长回复（面板本身 200px 高，再多也只是滚动量），
    // 又不至于让一次长回答把 DOM 撑爆；截断处留一句提示，全文去「网页」里看。
    if (t.length > 12000) t = t.slice(0, 12000) + '\n…（过长已截断，全文点「网页」看）';
    return t;
  }

  function parseLog(text) {
    var raw = String(text || '').split('\n');
    var msgs = [];
    var cur = null;      // 正在累积的回复块
    var skip = false;    // 处在 "dsh: reasoning:" 块里（旧日志的思考过程）
    for (var i = 0; i < raw.length; i++) {
      var ln = raw[i].replace(/\r$/, '');
      var m = /^\[(\d{2}:\d{2}:\d{2})\]\s*>>>\s?(.*)$/.exec(ln);
      if (m) {
        skip = false;
        cur = null;
        msgs.push({ role: 'user', time: m[1], text: trimMsg(m[2]) });
        continue;
      }
      var n = /^\[(\d{2}:\d{2}:\d{2})\]\s*<<<\s?(.*)$/.exec(ln);
      if (n) {
        // 机器发言（每日巡检等）：自带时间，成一条独立的 DSH 气泡；后续行继续并入这条
        skip = false;
        cur = { role: 'dsh', time: n[1], text: n[2] };
        msgs.push(cur);
        continue;
      }
      if (/^dsh:\s*reasoning:/.test(ln)) { skip = true; cur = null; continue; }
      if (/^(dsh:|FATAL:|Unhandled)/.test(ln)) {
        skip = false;
        cur = null;
        msgs.push({ role: 'err', time: '', text: trimMsg(ln) });
        continue;
      }
      if (skip) continue;
      if (!cur) {
        // 回复块的时间锚 = 最近一条用户指令的时间
        var t = '';
        for (var k = msgs.length - 1; k >= 0; k--) { if (msgs[k].role === 'user') { t = msgs[k].time; break; } }
        cur = { role: 'dsh', time: t, text: '' };
        msgs.push(cur);
      }
      cur.text += (cur.text ? '\n' : '') + ln;
    }
    // 去掉空块；只保留最近的 200 条（日志还有 /log.js 的 60KB 上限兜底）
    var out = [];
    for (var j = 0; j < msgs.length; j++) {
      var mm = msgs[j];
      if (mm.role !== 'user' && mm.role !== 'err') {
        mm.text = trimMsg(mm.text);
        if (!mm.text) continue;
      }
      out.push(mm);
    }
    if (out.length > 200) out = out.slice(out.length - 200);
    return out;
  }

  function viewMsgs() {
    var v = parsedMsgs.slice();
    if (pendingSend && !hasUserTail(parsedMsgs, pendingSend.text)) {
      v.push({ role: 'user', time: pendingSend.time, text: pendingSend.text, temp: true });
    }
    if (busyNow) {
      var last = v.length ? v[v.length - 1] : null;
      if (!last || last.role === 'user') v.push({ role: 'dsh', time: '', text: '思考中…', thinking: true });
    }
    return v;
  }

  function hasUserTail(list, text) {
    for (var i = list.length - 1; i >= 0 && i >= list.length - 3; i--) {
      if (list[i].role === 'user' && list[i].text === text) return true;
    }
    return false;
  }

  function msgSig(m) { return (m.role || '') + '|' + (m.time || '') + '|' + (m.text || ''); }

  function buildMsgEl(m) {
    var el = document.createElement('div');
    el.className = 'dsh-msg ' + (m.role === 'user' ? 'you' : (m.role === 'err' ? 'err' : 'dsh')) + (m.thinking ? ' thinking' : '');
    var meta = document.createElement('div');
    meta.className = 'dsh-meta';
    var who = document.createElement('span');
    who.className = 'dsh-who';
    who.textContent = m.role === 'user' ? '你' : (m.role === 'err' ? '错误' : 'DSH');
    meta.appendChild(who);
    if (m.time) {
      var tt = document.createElement('span');
      tt.className = 'dsh-time';
      tt.textContent = hhmm(m.time);
      meta.appendChild(tt);
    }
    el.appendChild(meta);
    var body = document.createElement('div');
    body.className = 'dsh-text';
    body.textContent = m.text || '';
    el.appendChild(body);
    el.__sig = msgSig(m);
    return el;
  }

  function noteEl(text) {
    var d = document.createElement('div');
    d.className = 'dsh-note';
    d.textContent = text;
    return d;
  }

  function atBottom() {
    return (logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight) < 28;
  }

  function renderMessages(list) {
    var atB = atBottom();
    var keep = 0;
    if (msgEls.length && msgEls.length <= list.length) {
      keep = msgEls.length;
      for (var i = 0; i < keep; i++) {
        if (msgEls[i].__sig !== msgSig(list[i])) { keep = i; break; }
      }
    }
    while (msgEls.length > keep) {
      var dead = msgEls.pop();
      if (dead && dead.parentNode) dead.parentNode.removeChild(dead);
    }
    if (!keep) logEl.textContent = '';
    if (!list.length && !msgEls.length) {
      logEl.appendChild(noteEl('还没有对话，发一条指令试试'));
      syncNavBtns();
      return;
    }
    for (var j = keep; j < list.length; j++) {
      var el = buildMsgEl(list[j]);
      logEl.appendChild(el);
      msgEls.push(el);
    }
    // 最后一条的内容可能还在增长（运行中/流式），只重绘它的正文
    if (msgEls.length) {
      var lastNew = list[list.length - 1];
      var lastEl = msgEls[msgEls.length - 1];
      if (lastEl.__sig !== msgSig(lastNew)) {
        var body = lastEl.querySelector('.dsh-text');
        if (body && body.textContent !== (lastNew.text || '')) body.textContent = lastNew.text || '';
        lastEl.__sig = msgSig(lastNew);
      }
    }
    if (atB) logEl.scrollTop = logEl.scrollHeight;
    syncNavBtns();
  }

  function fetchLog() {
    if (logBusy) return;
    logBusy = true;
    jsonp('/log.js', function () {
      logBusy = false;
      logFails = 0;
      var t = '';
      try {
        t = window.__DSH_LOG;
        window.__DSH_LOG = '';
      } catch (e) {}
      if (typeof t !== 'string') { logFails += 1; return; }
      logSig = logWant;
      parsedMsgs = parseLog(t);
      if (pendingSend && hasUserTail(parsedMsgs, pendingSend.text)) pendingSend = null;
      dbg('log n=' + parsedMsgs.length + ' sig=' + logSig);
      renderMessages(viewMsgs());
      if (logWant !== logSig) fetchLog();   // 取的这段时间又有新内容 → 立刻补一次
    }, function () {
      logBusy = false;
      logFails += 1;
    });
  }

  var stateSeq = 0;
  var stateBusy = false;
  var lastErr = '';
  var lastReload = 0;
  try { lastReload = parseInt(localStorage.getItem('dsh.reload') || '0', 10) || 0; } catch (e) {}

  // ---- 热重载：只有「软重载」一条路 ----
  // 两条入口都会拿到令牌 —— /scroll.js（40ms，搭便车）与 /state.js 的 reload 字段（1.2s，兜底）。
  // 两条必须走同一个函数，否则走 /state.js 那条就会退回 location.reload() 把页面刷成白屏
  // （2026-11-06 实测两次：白屏后 panel-rect 不再更新，抽屉的滚轮落点全错）。
  // 给 /state.js 加了 500ms 缓存，所以「/scroll.js 已消费令牌、/state.js 缓存还没过期」这半秒里
  // 页面仍会收到同一个令牌 —— 这就是那条硬重载路径真实可达的原因。
  function softReload(tag) {
    dbg('reload ' + tag);
    if (typeof window.__DSH_RELOAD_OK === 'function') {
      try { window.__DSH_RELOAD_OK(); return; } catch (e) { document.title = 'JSERR reload ' + e.message; }
    }
    // 老页面（没有钩子）才退回硬重载
    setTimeout(function () { location.reload(); }, 60);
  }

  // 失败分级：代理是单线程，偶发一条请求排队（几百毫秒到 1 秒）不该让整块日志区
  // 变成「连接失败」。1-2 次保留上次内容只提升级，连续 3 次（≈4 秒）才判死。
  function pollFailed(why) {
    failStreak += 1;
    if (why) lastErr = why;
    if (failStreak < 3) {
      setState('重试中', 'busy');
      return;
    }
    setState('离线', 'off');
    parsedMsgs = [];
    msgEls = [];
    logSig = null;
    logEl.textContent = '';
    logEl.appendChild(noteEl('本地代理无响应（连续 ' + failStreak + ' 次）\n' +
      '最后一次错误：' + (lastErr || '未知') + '\n' +
      '双击 %LOCALAPPDATA%\\DesktopPage\\start-all.vbs 可重启。'));
    syncNavBtns();
  }

  function poll() {
    var now = Date.now();
    if (now - lastPoll < 1200) return;
    if (stateBusy) return;              // 上一次还没回来就跳过，避免响应乱序覆盖
    lastPoll = now;
    stateBusy = true;
    stateSeq += 1;
    var mySeq = stateSeq;
    // 兜底看门狗 4000ms：HTTP 侧已经优化到几十毫秒，这里只防真正的卡死
    jsonp('/state.js', function () {
      stateBusy = false;
      if (mySeq !== stateSeq) return;   // 已有更新的请求在跑，丢掉这份旧数据
      var st = window.__DSH_STATE;
      if (!st) { pollFailed('/state.js 没有定义 __DSH_STATE（响应被截断）'); return; }
      failStreak = 0;
      lastErr = '';
      // 热重载令牌（/reload.gif → page-reload.txt）：改完壁纸文件没法从外部刷新页面，代理借令牌让页面自己重载。
      // 只做软重载（重插 dsh.js?hot=），绝不 location.reload()。
      if (st.reload && st.reload !== lastReload) {
        lastReload = st.reload;
        try { localStorage.setItem('dsh.reload', String(lastReload)); } catch (e) {}
        softReload('token=' + lastReload);
        return;
      }
      DEBUG = !!st.dbg;
      if (balEl) balEl.textContent = st.bal || '—';
      if (runDot) {
        runDot.className = 'drawer-dot ' + (st.drawer ? 'on' : 'off');
        runDot.title = st.drawer ? '桌面抽屉：运行中' : '桌面抽屉：未启动';
      }
      // 上一轮失败原因（stderr 里的 dsh: xxx）挂成一行提示，不占对话气泡
      if (errEl) {
        if (st.err) { errEl.textContent = '⚠ ' + st.err; errEl.hidden = false; }
        else if (!errEl.hidden) { errEl.textContent = ''; errEl.hidden = true; }
      }
      logWant = st.sig || '';
      busyNow = !!st.busy;
      if (logWant !== logSig) fetchLog();
      // 没有 /log.js 时退化成只显示 /state.js 的尾巴（老代理兼容）
      if (logFails >= 2 && !parsedMsgs.length && st.lines && st.lines.length) {
        parsedMsgs = parseLog(st.lines.join('\n'));
        renderMessages(viewMsgs());
      } else {
        renderMessages(viewMsgs());
      }

      if (st.busy) setState('运行中', 'busy');
      else if (st.web) setState('就绪', 'ok');
      else setState('未启动', 'off');
    }, function (why) {
      stateBusy = false;
      pollFailed(why === 'timeout'
        ? '/state.js 超时 4000ms 未返回'
        : '/state.js 加载失败（代理未监听或端口被占）');
    }, 4000);
  }

  function send() {
    var text = (inputEl.value || '').trim();
    if (!text) return;
    inputEl.value = '';
    setState('已发送', 'busy');
    pendingSend = { text: text, time: new Date().toTimeString().slice(0, 8) };
    audit('dsh.send', 'chars=' + text.length);
    beacon('/run.gif?t=' + encodeURIComponent(text));
    after(1200, poll);
  }

  // 日志区：手动处理滚轮（壁纸里原生滚动条点不到 / 拖不动）
  if (logEl) {
    logEl.addEventListener('wheel', function (e) {
      var host = logEl;
      var before = host.scrollTop;
      host.scrollTop = before + (e.deltaY || 0);
      if (host.scrollTop !== before) e.preventDefault();
      e.stopPropagation();
    }, { passive: false });
  }

  // 设置面板：滚轮直接滚内容，不往外传
  function wheelScroll(host) {
    return function (e) {
      if (!host) return;
      var before = host.scrollTop;
      host.scrollTop = before + (e.deltaY || 0);
      e.preventDefault();
      e.stopPropagation();
    };
  }
  if (settingsScroll) settingsScroll.addEventListener('wheel', wheelScroll(settingsScroll), { passive: false });
  if (overlayEl) overlayEl.addEventListener('wheel', wheelScroll(settingsScroll), { passive: false });

  document.getElementById('dshSend').addEventListener('click', send);
  inputEl.addEventListener('keydown', function (e) {
    if (e.key === 'Enter') { e.preventDefault(); send(); e.stopPropagation(); return; }
    if (e.key === 'Escape') return; // 交还给 app.js：Esc 关设置 / 退出输入
    e.stopPropagation();
  });
  inputEl.addEventListener('keyup', function (e) { if (e.key !== 'Escape') e.stopPropagation(); });
  inputEl.addEventListener('keypress', function (e) { if (e.key !== 'Escape') e.stopPropagation(); });

  document.getElementById('dshLaunch').addEventListener('click', function () {
    setState('启动中', 'busy');
    audit('dsh.launch', '');
    beacon('/launch.gif?quiet=1');
  });
  document.getElementById('dshOpen').addEventListener('click', function () {
    audit('dsh.open', '');
    beacon('/open.gif');
  });
  var btnUp = document.getElementById('dshUp');
  var btnDown = document.getElementById('dshDown');

  // 对话不足一屏时 ▲▼ 点了也没反应，索性禁用并说明原因（避免用户以为按钮坏了）
  function syncNavBtns() {
    if (!logEl) return;
    var few = logEl.scrollHeight <= logEl.clientHeight + 4;
    var list = [btnUp, btnDown];
    for (var i = 0; i < list.length; i++) {
      var b = list[i];
      if (!b) continue;
      b.disabled = few;
      if (few) {
        b.classList.add('dim');
        b.title = '对话不足一屏';
      } else {
        b.classList.remove('dim');
        b.title = (b === btnUp) ? '向上翻对话' : '向下翻对话';
      }
    }
  }

  // ▲▼ 用 scrollBy + smooth：直接跳一屏在 Lively 里会一帧到底，看着像"没动"
  if (btnUp) btnUp.addEventListener('click', function () {
    logEl.scrollBy({ top: -logEl.clientHeight * 0.8, behavior: 'smooth' });
  });
  if (btnDown) btnDown.addEventListener('click', function () {
    logEl.scrollBy({ top: logEl.clientHeight * 0.8, behavior: 'smooth' });
  });
  if (logEl) logEl.addEventListener('scroll', syncNavBtns);
  document.getElementById('dshClear').addEventListener('click', function () {
    parsedMsgs = [];
    msgEls = [];
    logSig = null;
    pendingSend = null;
    logEl.textContent = '';
    logEl.appendChild(noteEl('已清空'));
    if (errEl) { errEl.textContent = ''; errEl.hidden = true; }
    syncNavBtns();
    audit('dsh.clear', '');
    beacon('/clear.gif');
    after(400, poll);
  });
  syncNavBtns();

  // 顶栏右上角按钮 → 启动「桌面抽屉」程序（DesktopPage），旁边小点显示它是否在跑
  var btn = document.getElementById('settingsButton');
  if (btn) {
    btn.title = '启动桌面抽屉（右键打开模拟器设置）';
    btn.setAttribute('aria-label', '启动桌面抽屉');
    btn.addEventListener('click', function (e) {
      e.preventDefault();
      e.stopPropagation();
      runDot.className = 'drawer-dot busy';
      audit('dsh.drawer', '');
      beacon('/drawer.gif');
      after(1200, poll);
    }, true);
    btn.addEventListener('contextmenu', function (e) {
      e.preventDefault();
      e.stopPropagation();
      var pb = document.getElementById('panelSettingsButton');
      if (pb && typeof pb.click === 'function') { pb.click(); return; }
      var ov = document.getElementById('settingsOverlay');
      if (ov) ov.hidden = false;
    }, true);
  }

  aside.addEventListener('mousedown', function (e) { e.stopPropagation(); });
  aside.addEventListener('click', function (e) { e.stopPropagation(); });

  try { reportRect(); } catch (e) {}
  try {
    if (window.ResizeObserver) new ResizeObserver(function () { reportRect(); }).observe(box);
    window.addEventListener('resize', function () { reportRect(); syncNavBtns(); });
    every(4000, function () { reportRect(true); });
  } catch (e) {}

  // 设置面板开关：立刻重报矩形（打开=整屏，关闭=控制台面板），并把焦点从输入框挪走
  if (overlayEl && window.MutationObserver) {
    try {
      new MutationObserver(function () {
        reportRect();
        if (settingsOpen()) {
          try { if (document.activeElement && document.activeElement.blur) document.activeElement.blur(); } catch (e) {}
        }
      }).observe(overlayEl, { attributes: true, attributeFilter: ['hidden', 'style', 'class'] });
    } catch (e) {}
  }

  // 设置里的「DSH 控制台」开关：app.js 把设置写进 localStorage，这里跟着隐藏/显示面板
  var SETTINGS_KEY = 'deepseek-room.standalone.settings.v1';
  function consoleOn() {
    try {
      var raw = localStorage.getItem(SETTINGS_KEY);
      if (!raw) return true;
      var s = JSON.parse(raw);
      return !s || s.showConsole !== false;
    } catch (e) { return true; }
  }
  function syncConsole() {
    if (!box) return;
    box.style.display = consoleOn() ? '' : 'none';
    syncNavBtns();   // 隐藏时 scrollHeight 被算成 0，重新显示后要把 ▲▼ 的状态纠正回来
  }
  syncConsole();
  every(1000, syncConsole);
  window.addEventListener('storage', syncConsole);

  dbg('boot ' + API);
  poll();
  every(1200, poll);
  scrollPoll();

  // 代理热重载入口：/scroll.js 读到令牌时会调它（老页面没有这个钩子，代理会退回 location.reload）
  window.__DSH_RELOAD_OK = function () {
    try {
      var s = document.createElement('script');
      s.src = 'dsh.js?hot=' + Date.now();
      s.async = true;
      (document.body || document.documentElement).appendChild(s);
    } catch (e) {
      document.title = 'JSERR reload ' + e.message;
    }
  };
  // ===== 快捷启动栏（6 格，2 行 x 3 列）=====
  var dockGrid = document.getElementById('dockGrid');
  var dockHint = document.getElementById('dockHint');
  var lastDockSig = '';
  function renderDock(list) {
    if (!dockGrid) return;
    var items = list || [];
    // 每 1.5s 重建 innerHTML 会让图标反复请求、hover 与「×」状态丢失，先比签名
    var sig = (window.__DOCK_BUSY === 1 ? 'B' : '') + items.map(function (it) {
      return (it && it.i) + '|' + (it && it.n) + '|' + (it && it.p);
    }).join('~');
    if (sig === lastDockSig) return;
    lastDockSig = sig;
    var html = '';
    for (var i = 0; i < 6; i++) {
      var it = items[i];
      if (it) {
        var src = it.i ? iconUrl(it.i) : '';
        var nm = String(it.n || '').replace(/[&<>"]/g, function (c) {
          return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
        });
        html += '<div class="dock-tile" data-i="' + i + '">' +
          (src ? '<img src="' + src + '" alt="">' : '<div class="dock-plus">·</div>') +
          '<span class="dock-name" title="' + nm + '">' + nm + '</span>' +
          '<span class="dock-del" data-del="' + i + '" title="移除">×</span></div>';
      } else {
        var busyNow = (window.__DOCK_BUSY === 1);
        html += busyNow
          ? '<div class="dock-tile empty busy" data-add="1"><div class="dock-plus">…</div><span class="dock-name">选择中</span></div>'
          : '<div class="dock-tile empty" data-add="1"><div class="dock-plus">+</div><span class="dock-name">添加</span></div>';
      }
    }
    dockGrid.innerHTML = html;
    if (dockHint) dockHint.style.display = items.length >= 6 ? 'none' : '';
  }
  if (dockGrid) {
    dockGrid.addEventListener('click', function (ev) {
      var del = ev.target.closest ? ev.target.closest('[data-del]') : null;
      if (del) { ev.stopPropagation(); beacon('/dock.gif?op=del&i=' + del.getAttribute('data-del')); after(400, dockPoll); return; }
      var add = ev.target.closest ? ev.target.closest('[data-add]') : null;
      if (add) {
        if (window.__DOCK_BUSY === 1) return;
        add.querySelector('.dock-name').textContent = '选择中…';
        beacon('/adddock.gif');
        after(900, dockPoll);
        return;
      }
      var tile = ev.target.closest ? ev.target.closest('.dock-tile[data-i]') : null;
      if (tile) {
        var idx = parseInt(tile.getAttribute('data-i'), 10);
        if (window.__DOCK && window.__DOCK[idx]) beacon('/launchpath.gif?t=' + encodeURIComponent(window.__DOCK[idx].p));
      }
    });
  }
  var dockBusy = false;
  function dockPoll() {
    if (dockBusy) return;
    dockBusy = true;
    jsonp('/dock.js', function () {
      dockBusy = false;
      try { renderDock(window.__DOCK || []); } catch (e) {}
    }, function () { dockBusy = false; });
  }
  dockPoll();
  every(1500, dockPoll);
}

try {
  dshInit();
} catch (e) {
  try { document.title = 'JSERR dsh-init ' + (e && e.message) + ' @' + (e && e.lineNumber); } catch (e2) {}
}
