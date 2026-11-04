/* audit.js — 壁纸侧统一审计
 * 页面是 file://，CSP 里 connect-src 'none'，fetch/XHR 一律被拦；
 * 所以只能走 1x1 GIF 信标：<img src="http://127.0.0.1:17433/audit.gif?e=...&k=...">
 * 代理收到后先回 GIF（信标铁律），再把 [WEB ] <e> <k> 追加进
 * %LOCALAPPDATA%\DesktopPage\audit.log —— 和抽屉 [AHK ]、代理 [API ] 写同一份。
 * 调用约定：window.__AUDIT('media.toggle', 'playing=1')，第二参可省。
 * 节流：同类事件 500ms 内只发一次，连点不会把审计刷爆。
 */
(function () {
  'use strict';

  // 通信层优先走 api.js 的 window.__API；本文件单独部署时回退到内置写法（下面 beacon 里）
  var API = (window.__API || {}).url || 'http://127.0.0.1:17433';
  var THROTTLE_MS = 500;
  var lastAt = new Map();      // e -> 上次发送的时间戳

  function beacon(path) {
    if (window.__API && window.__API.beacon) { window.__API.beacon(path); return; }
    var img = new Image();
    img.onload = img.onerror = function () { img.onload = img.onerror = null; };
    img.src = API + path + (path.indexOf('?') >= 0 ? '&' : '?') + '_=' + Date.now();
  }

  window.__AUDIT = function (e, k) {
    try {
      if (!e) return;
      e = String(e).slice(0, 32);
      k = (k === undefined || k === null) ? '' : String(k).slice(0, 200);
      // 换行会伪造日志行，先掐死
      e = e.replace(/[\r\n\t]+/g, ' ');
      k = k.replace(/[\r\n\t]+/g, ' ');

      var now = Date.now();
      var prev = lastAt.get(e) || 0;
      if (now - prev < THROTTLE_MS) return;
      if (lastAt.size > 200) lastAt.clear();   // 兜底：异常调用不会让这张表无限长
      lastAt.set(e, now);

      beacon('/audit.gif?e=' + encodeURIComponent(e) + (k ? '&k=' + encodeURIComponent(k) : ''));
    } catch (err) { /* 审计永远不能影响页面 */ }
  };
})();
