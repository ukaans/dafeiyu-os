/* 待办面板逻辑
   数据源优先级：todo-data.js（带 __TODO_TS 时间戳）与 localStorage 谁更新用谁。
   todo-data.js 由外部程序/记事本写入，壁纸每 10 秒热加载一次。 */
(function () {
  'use strict';

  var LS_KEY = 'dp-todo-v1';
  var MAX_SHOWN = 5;

  var panel = document.getElementById('todoPanel');
  var list = document.getElementById('todoList');
  var empty = document.getElementById('todoEmpty');
  var count = document.getElementById('todoCount');
  var input = document.getElementById('todoInput');
  var more = document.getElementById('todoMore');
  if (!panel || !list || !empty || !count || !input) return;

  // 通信层优先走 api.js 的 window.__API；本文件单独部署时回退到内置写法（下面 beacon 里）
  var API = (window.__API || {}).url || 'http://127.0.0.1:17433';
  var items = [];
  var localTs = 0;
  var lastFileTs = 0;

  function beacon(op, text) {
    var q = '/todo.gif?op=' + op;
    if (text !== undefined) q += '&t=' + encodeURIComponent(text);
    if (window.__API && window.__API.beacon) { window.__API.beacon(q); return; }
    var img = new Image();
    img.src = API + q + '&_=' + Date.now();
  }

  // 统一审计（audit.js 提供的 window.__AUDIT）：只记长度 / 状态，绝不记待办正文（隐私）
  function audit(e, k) {
    if (typeof window.__AUDIT !== 'function') return;
    try { window.__AUDIT(e, k); } catch (err) {}
  }

  function normalize(raw) {
    if (!Array.isArray(raw)) return [];
    var out = [];
    for (var i = 0; i < raw.length; i++) {
      var it = raw[i];
      if (!it) continue;
      if (typeof it === 'string') {
        out.push({ t: it, d: false });
      } else if (typeof it.t === 'string' && it.t.length) {
        out.push({ t: it.t, d: !!it.d });
      }
    }
    return out;
  }

  function loadLocal() {
    try {
      var s = localStorage.getItem(LS_KEY);
      if (!s) return null;
      var o = JSON.parse(s);
      if (!o || !Array.isArray(o.items)) return null;
      localTs = Number(o.ts) || 0;
      return normalize(o.items);
    } catch (e) {
      return null;
    }
  }

  // 启动时把「本地缓存」和「todo-data.js」按时间戳合并一次，
  // 否则壁纸关着的时候外部改过文件，页面会一直拿本地旧数据。
  function pickInitial() {
    var local = loadLocal();
    var fileTs = Number(window.__TODO_TS) || 0;
    var fileItems = Array.isArray(window.__TODO) ? normalize(window.__TODO) : null;
    lastFileTs = fileTs;
    if (!fileItems) return local || [];
    if (!local) return fileItems;
    // 文件比本地缓存新（或本地缓存没有时间戳）就用文件
    if (!localTs || fileTs > localTs) return fileItems;
    return local;
  }

  function saveLocal() {
    localTs = Date.now();
    try {
      localStorage.setItem(LS_KEY, JSON.stringify({ ts: localTs, items: items }));
    } catch (e) {
      /* file:// 下可能不可用，忽略：本会话内仍然生效 */
    }
  }

  function render() {
    list.textContent = '';
    var shown = Math.min(items.length, MAX_SHOWN);
    for (var i = 0; i < shown; i++) {
      (function (idx) {
        var it = items[idx];
        var li = document.createElement('li');
        li.className = 'todo-item';
        li.dataset.done = it.d ? '1' : '0';
        li.title = it.t;

        var box = document.createElement('span');
        box.className = 'box';
        box.textContent = it.d ? '\u00d7' : '';

        var txt = document.createElement('span');
        txt.className = 'txt';
        txt.textContent = it.t;

        var del = document.createElement('span');
        del.className = 'del';
        del.textContent = '\u00d7';
        del.title = '删除';
        del.addEventListener('click', function (ev) {
          ev.stopPropagation();
          var gone = items[idx].t;
          items.splice(idx, 1);
          saveLocal();
          render();
          audit('todo.del', 'len=' + String(gone || '').length);
          beacon('del', gone);
          setTimeout(reloadFile, 900);
        });

        li.appendChild(box);
        li.appendChild(txt);
        li.appendChild(del);
        li.addEventListener('click', function () {
          items[idx].d = !items[idx].d;
          saveLocal();
          render();
          audit('todo.toggle', 'done=' + (items[idx].d ? 1 : 0));
          beacon('toggle', items[idx].t);
        });
        list.appendChild(li);
      })(i);
    }

    if (more) {
      var rest = items.length - shown;
      more.textContent = rest > 0 ? '+' + rest : '';
      more.hidden = rest <= 0;
    }

    var open = items.length - items.filter(function (x) { return x.d; }).length;
    list.hidden = items.length === 0;
    empty.hidden = items.length !== 0;
    count.textContent = items.length
      ? String(itemPad(items.length)) + ' \u00b7 ' + String(itemPad(open))
      : '00';
    count.title = items.length ? '共 ' + items.length + ' 项，未完成 ' + open + ' 项' : '没有待办任务';
  }

  function itemPad(n) {
    return n < 10 ? '0' + n : String(n);
  }

  // 文件（todo-data.js）是唯一真源：只要它的时间戳变了就整份采用，
  // 不再做「谁新用谁」的仲裁——那会让前端删掉的任务被旧文件覆盖回来。
  function adoptFile() {
    var fileTs = Number(window.__TODO_TS) || 0;
    if (!Array.isArray(window.__TODO)) return;
    if (fileTs && fileTs === lastFileTs) return;
    lastFileTs = fileTs;
    items = normalize(window.__TODO);
    try { localStorage.setItem(LS_KEY, JSON.stringify({ ts: fileTs, items: items })); } catch (e) { /* ignore */ }
    render();
  }

  function reloadFile() {
    var old = document.querySelector('script[data-todo-data]');
    var s = document.createElement('script');
    s.src = 'todo-data.js?v=' + Date.now();
    s.setAttribute('data-todo-data', '1');
    s.onload = function () {
      adoptFile();
      if (old && old.parentNode) old.parentNode.removeChild(old);
    };
    s.onerror = function () {
      if (s.parentNode) s.parentNode.removeChild(s);
    };
    document.body.appendChild(s);
  }

  input.addEventListener('keydown', function (ev) {
    if (ev.key !== 'Enter') return;
    var v = input.value.trim();
    if (!v) return;
    items.push({ t: v, d: false });
    input.value = '';
    saveLocal();
    render();
    audit('todo.add', 'len=' + v.length);
    beacon('add', v);
    setTimeout(reloadFile, 900);
  });
  input.addEventListener('click', function (ev) { ev.stopPropagation(); });

  items = pickInitial();
  render();

  setInterval(reloadFile, 10000);
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) reloadFile();
  });
})();
