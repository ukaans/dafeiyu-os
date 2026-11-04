window.onerror = function (m, s, l) { try { document.title = 'JSERR ' + m + ' @' + l; } catch (e) {} };
/* dsh.js — 壁纸右侧的 DSH 迷你控制台
 * 页面是 file://，直接 fetch http://127.0.0.1 会被 Chromium 的私有网络策略拦掉，
 * 所以走两条不触发 CORS 的老通道：
 *   读状态：动态插入 <script src="/state.js?v=...">（JSONP 式）
 *   发指令：<img src="/run.gif?t=...">（信标）
 */
function dshInit() {
  'use strict';

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

  box.innerHTML =
    '<div class="dsh-title"><i></i><span>DSH / DESKTOP</span>' +
    '<b id="dshDot" class="dsh-dot" title="DSH 服务状态"></b>' +
    '<span class="barcode short" aria-hidden="true"></span></div>' +
    '<pre id="dshLog">连接中…</pre>' +
    '<div class="dsh-input"><input id="dshText" type="text" placeholder="给 DSH 发指令…" autocomplete="off" spellcheck="false" /><button id="dshSend" type="button">发送</button></div>' +
    '<div class="dsh-actions">' +
    '<button id="dshLaunch" type="button">启动</button>' +
    '<button id="dshOpen" type="button">网页</button>' +
    '<button id="dshClear" type="button">清空</button>' +
    '<button id="dshUp" type="button" title="向上翻日志">▲</button>' +
    '<button id="dshDown" type="button" title="向下翻日志">▼</button>' +
    '<span id="dshState" class="dsh-state">—</span>' +
    '</div>' +
    '<div class="dsh-balance"><span>剩余余额</span><b id="dshBal">—</b></div>';

  if (interaction && interaction.parentNode === aside) aside.insertBefore(box, interaction);
  else aside.appendChild(box);

  var logEl = document.getElementById('dshLog');
  var inputEl = document.getElementById('dshText');
  var stateEl = document.getElementById('dshState');
  var dotEl = document.getElementById('dshDot');
  var balEl = document.getElementById('dshBal');
  var runDot = document.getElementById('drawerDot');

  var lastLines = '';
  var seq = 0;
  var lastScroll = null;
  var lastRect = '';
  var lastPoll = 0;

  // 设置面板：打开时把整屏都算作「控制台区域」，滚轮就不会被抽屉程序当成桌面手势
  var overlayEl = document.getElementById('settingsOverlay');
  var settingsScroll = document.getElementById('settingsScroll');
  function settingsOpen() { return !!(overlayEl && !overlayEl.hidden); }

  var lastCls = '';
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
  // 平滑滚动：轮询只更新目标位置，实际位移用 requestAnimationFrame 缓动插值
  var scrollHost = null;
  var scrollTarget = null;
  var scrollRAF = 0;
  var scrollBusy = false;

  function scrollTargetEl() {
    return (settingsOpen() && settingsScroll) ? settingsScroll : logEl;
  }

  function clampScroll(v, host) {
    var max = Math.max(0, host.scrollHeight - host.clientHeight);
    return Math.max(0, Math.min(max, v));
  }

  function scrollTick() {
    scrollRAF = 0;
    if (!scrollHost || scrollTarget === null) return;
    // 元素被 [hidden] 或移出文档后，scrollTop 恒为 0，再算下去就是死循环
    if (!scrollHost.isConnected || scrollHost.offsetParent === null) { scrollTarget = null; return; }
    var cur = scrollHost.scrollTop;
    var target = clampScroll(scrollTarget, scrollHost);
    if (target !== scrollTarget) { scrollTarget = null; return; }
    var diff = target - cur;
    if (Math.abs(diff) < 0.8) { scrollTarget = null; return; }
    scrollHost.scrollTop = cur + diff * 0.045;
    // 内容变短 / 已到顶到底时 scrollTop 会被夹住，位移为 0 就停，避免 60fps 空转
    if (Math.abs(scrollHost.scrollTop - cur) < 0.5) { scrollTarget = null; return; }
    scrollRAF = requestAnimationFrame(scrollTick);
  }

  function onScrollData() {
    var d = window.__DSH_SCROLL || 0;
    window.__DSH_SCROLL = 0;
    if (!d) return;
    var host = scrollTargetEl();
    if (!host) return;
    scrollHost = host;
    var base = (scrollTarget === null) ? host.scrollTop : scrollTarget;
    scrollTarget = clampScroll(base + d * 120, host);
    if (!scrollRAF) scrollRAF = requestAnimationFrame(scrollTick);
  }

  var scrollPolling = false;
  function scrollPoll() {
    if (!scrollPolling) {
      scrollPolling = true;
      jsonp('/scroll.js', function () { scrollPolling = false; onScrollData(); },
        function () { scrollPolling = false; });
    }
    setTimeout(scrollPoll, 80);
  }

  var stateSeq = 0;
  var stateBusy = false;
  var failStreak = 0;     // 连续失败次数：1-2 次只算「重试中」，≥3 次才判离线
  var lastErr = '';

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
    lastLines = null;     // 哨兵：恢复后的第一份数据必定触发重绘
    logEl.textContent = '本地代理无响应（连续 ' + failStreak + ' 次）。\n' +
      '最后一次错误：' + (lastErr || '未知') + '\n' +
      '双击 %LOCALAPPDATA%\\DesktopPage\\start-all.vbs 可重启。';
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
      if (balEl) balEl.textContent = st.bal || '—';
      if (runDot) {
        runDot.className = 'drawer-dot ' + (st.drawer ? 'on' : 'off');
        runDot.title = st.drawer ? '桌面抽屉：运行中' : '桌面抽屉：未启动';
      }
      var txt = (st.lines || []).join('\n');
      if (txt !== lastLines) {
        var atBottom = (logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight) < 24;
        lastLines = txt;
        logEl.textContent = txt || '（还没有输出）';
        if (atBottom) logEl.scrollTop = logEl.scrollHeight;
        syncNavBtns();
      }
      // 抽屉程序转发的滚轮意图：st.scroll 单调递增，差值×40px 就是页面要滚的距离

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
    audit('dsh.send', 'chars=' + text.length);
    beacon('/run.gif?t=' + encodeURIComponent(text));
    setTimeout(poll, 1200);
  }

  // 日志区：手动处理滚轮（壁纸里原生滚动条点不到 / 拖不动）
  if (logEl) {
    logEl.addEventListener('wheel', function (e) {
      scrollTarget = null;
      var before = logEl.scrollTop;
      logEl.scrollTop = before + (e.deltaY || 0);
      if (logEl.scrollTop !== before) e.preventDefault();
      e.stopPropagation();
    }, { passive: false });
  }

  // 设置面板：滚轮直接滚内容，不往外传
  function wheelScroll(host) {
    return function (e) {
      if (!host) return;
      scrollTarget = null;
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

  // 日志不足一屏时 ▲▼ 点了也没反应，索性禁用并说明原因（避免用户以为按钮坏了）
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
        b.title = '日志不足一屏';
      } else {
        b.classList.remove('dim');
        b.title = (b === btnUp) ? '向上翻日志' : '向下翻日志';
      }
    }
  }

  // 用 scrollBy + smooth：直接改 scrollTop 在 Lively 里会一帧跳到底，看着像"没动"
  if (btnUp) btnUp.addEventListener('click', function () {
    scrollTarget = null;
    logEl.scrollBy({ top: -logEl.clientHeight * 0.8, behavior: 'smooth' });
  });
  if (btnDown) btnDown.addEventListener('click', function () {
    scrollTarget = null;
    logEl.scrollBy({ top: logEl.clientHeight * 0.8, behavior: 'smooth' });
  });
  if (logEl) logEl.addEventListener('scroll', syncNavBtns);
  document.getElementById('dshClear').addEventListener('click', function () {
    lastLines = '';
    logEl.textContent = '（已清空）';
    syncNavBtns();
    audit('dsh.clear', '');
    beacon('/clear.gif');
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
      setTimeout(poll, 1200);
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
    setInterval(function () { reportRect(true); }, 4000);
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
  setInterval(syncConsole, 1000);
  window.addEventListener('storage', syncConsole);

  poll();
  setInterval(poll, 1200);
  scrollPoll();
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
      if (del) { ev.stopPropagation(); beacon('/dock.gif?op=del&i=' + del.getAttribute('data-del')); setTimeout(dockPoll, 400); return; }
      var add = ev.target.closest ? ev.target.closest('[data-add]') : null;
      if (add) {
        if (window.__DOCK_BUSY === 1) return;
        add.querySelector('.dock-name').textContent = '选择中…';
        beacon('/adddock.gif');
        setTimeout(dockPoll, 900);
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
  setInterval(dockPoll, 1500);
}

try {
  dshInit();
} catch (e) {
  try { document.title = 'JSERR dsh-init ' + (e && e.message) + ' @' + (e && e.lineNumber); } catch (e2) {}
}
