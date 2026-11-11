(function () {
  // 通信层优先走 api.js 的 window.__API；本文件单独部署时回退到内置写法（jsonp / act 里）
  var API = (window.__API || {}).url || ('http://127.0.0.1:' + window.__DSH_AGENT_PORT);
  var panel = document.getElementById('mediaPanel');
  if (!panel) return;
  var elTitle = document.getElementById('mediaTitle');
  var elSub = document.getElementById('mediaSub');
  var elToggle = document.getElementById('mediaToggle');
  var elBack = document.getElementById('mediaBack');
  var elFwd = document.getElementById('mediaFwd');
  var elBar = document.getElementById('mediaProgress');
  var elTime = document.getElementById('mediaTime');
  var seq = 0;
  var lastOk = false;
  // 播放键的乐观反馈：点下去先翻转图标，等后端真正切完再跟真实状态
  var pendingUntil = 0;
  var pendingPlaying = null;
  // 同一时刻只允许一个轮询在飞，避免连点时脚本标签堆叠造成卡顿
  var polling = false;
  var pollTimer = 0;

  // 统一审计（audit.js 提供的 window.__AUDIT）：单独部署本文件时静默跳过
  function audit(e, k) {
    if (typeof window.__AUDIT !== 'function') return;
    try { window.__AUDIT(e, k); } catch (err) {}
  }

  function fmt(s) {
    s = Math.max(0, Math.floor(s || 0));
    var m = Math.floor(s / 60);
    var r = s % 60;
    return (m < 10 ? '0' : '') + m + ':' + (r < 10 ? '0' : '') + r;
  }

  function prettyApp(app) {
    if (!app) return '';
    if (app.indexOf('MSEdge') === 0) return 'Microsoft Edge';
    if (app.indexOf('Spotify') > -1) return 'Spotify';
    if (app.indexOf('CloudMusic') > -1 || app.indexOf('netease') > -1) return '网易云音乐';
    if (app.indexOf('QQMusic') > -1) return 'QQ 音乐';
    var seg = app.split('!')[0];
    return seg;
  }

  function render(m) {
    if (!m || m.ok !== 1) {
      panel.classList.add('idle');
      elTitle.textContent = '未在播放';
      elSub.textContent = '打开播放器 / 视频就会显示在这里';
      elToggle.textContent = '▶';
      elBar.style.width = '0%';
      elTime.textContent = '00:00 / 00:00';
      lastOk = false;
      return;
    }
    var active = !!m.playing;
    if (pendingPlaying !== null) {
      if (Date.now() > pendingUntil || active === pendingPlaying) {
        pendingPlaying = null;
      } else {
        active = pendingPlaying;
      }
    }
    panel.classList.toggle('idle', !active);
    elTitle.textContent = m.title || '（未知标题）';
    elTitle.title = m.title || '';
    elSub.textContent = (m.artist ? m.artist + ' · ' : '') + prettyApp(m.app);
    elToggle.textContent = active ? '❚❚' : '▶';
    var pct = m.dur > 0 ? Math.min(100, Math.max(0, (m.pos / m.dur) * 100)) : 0;
    elBar.style.width = pct.toFixed(1) + '%';
    elTime.textContent = (m.est ? '≈' : '') + fmt(m.pos) + ' / ' + fmt(m.dur);
    lastOk = true;
  }

  // 让面板一直撑到下方分界线（时钟条上沿），时间行贴底
  function fit() {
    var bottom = document.querySelector('.bottom');
    if (!bottom) { panel.style.height = ''; return; }
    var pt = panel.getBoundingClientRect().top;
    var bt = bottom.getBoundingClientRect().top;
    // 底部时钟条被设置关掉时 .bottom 可能收起（top≈0），此时按窗口高度兜底，别把面板压塌
    if (!(bt > pt + 40)) bt = Math.min(window.innerHeight, pt + 240);
    var h = Math.round(bt - pt - 4);
    if (h >= 140) panel.style.height = h + 'px';
    else panel.style.height = '';
  }
  window.addEventListener('resize', fit);
  setTimeout(fit, 350);

  function schedule(delay) {
    if (pollTimer) clearTimeout(pollTimer);
    pollTimer = setTimeout(poll, delay);
  }

  // 通信层：有 api.js 就用它；没有就退回原来那套「新建 <script> + 自己看守门狗」的写法
  function jsonp(path, ondata, onfail, timeoutMs) {
    if (window.__API && window.__API.jsonp) { window.__API.jsonp(path, ondata, onfail, timeoutMs); return; }
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

  function poll() {
    pollTimer = 0;
    if (polling) { schedule(200); return; }
    polling = true;
    jsonp('/media.js', function () {
      polling = false;
      // 先把下一次排上：即使 render 抛异常，轮询也不会停
      schedule(1500);
      try { render(window.__MEDIA); } catch (e) {}
    }, function (why) {
      polling = false;
      // 看门狗（6 秒）：脚本超时只重试不判死；真 onerror 才按"没在播放"清屏
      if (why === 'timeout') { schedule(1200); return; }
      schedule(3000);
      try { render(null); } catch (e) {}
    }, 6000);
  }

  function act(op) {
    if (!lastOk) return;
    audit('media.' + op, 'ok=' + (lastOk ? 1 : 0));
    if (op === 'toggle') {
      var wasPlaying = elToggle.textContent === '❚❚';
      elToggle.textContent = wasPlaying ? '▶' : '❚❚';
      elToggle.classList.add('pending');
      pendingPlaying = !wasPlaying;
      pendingUntil = Date.now() + 2500;
      setTimeout(function () { elToggle.classList.remove('pending'); }, 1200);
    }
    if (window.__API && window.__API.beacon) window.__API.beacon('/media.gif?op=' + op + '&t=' + Date.now());
    else { var img = new Image(); img.src = API + '/media.gif?op=' + op + '&t=' + Date.now(); }
    // 后端已改成「先回包再执行」；这里尽快补一次刷新接真实状态，连点时只保留最后一次
    schedule(400);
  }

  elBack.addEventListener('click', function (e) { e.stopPropagation(); act('back'); });
  elToggle.addEventListener('click', function (e) { e.stopPropagation(); act('toggle'); });
  elFwd.addEventListener('click', function (e) { e.stopPropagation(); act('fwd'); });

  render(null);
  poll();
})();
