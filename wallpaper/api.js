/* api.js — 壁纸侧的通信层：唯一一处「怎么跟本地代理说话」的实现
 *
 * 页面是 file://，CSP 里 connect-src 'none'，fetch/XHR 一律被拦；所以只有两条老通道：
 *   jsonp(path, ondata, onfail, timeoutMs)  动态插 <script>，脚本执行完调 ondata()
 *   beacon(path)                            new Image().src，1x1 GIF 信标
 *
 * 纯增量：不覆盖任何既有全局，被别的副本抢先装过就直接让位。
 * 任何一个脚本单独部署（没有本文件）时会自己回退到内置写法 —— 见各文件头的降级行。
 *
 * 对外契约：
 *   window.__API.url                     基地址（固定 http://127.0.0.1:17433）
 *   window.__API.jsonp(path, ondata, onfail, timeoutMs)
 *       path      相对路径，以 / 开头；不带 ?v= 也行，本函数自动加去缓存参数
 *       ondata()  脚本加载并执行完（即 window.__XXX 已就绪）时调用，无参
 *       onfail(why)  加载失败或超时调用；why 只有 'error' / 'timeout' 两种
 *       timeoutMs 省略或 0 = 不设看门狗（保持老行为）
 *       回调至多触发一次；<script> 在回调之前已经从 DOM 移除
 *   window.__API.beacon(path)
 *       打一个 1x1 GIF 信标，自动补 &_=<毫秒>；返回 img 元素（调用方可忽略）
 *   window.__API.icon(name)
 *       返回 /icon/<name> 的完整 URL（name 自动 encodeURIComponent）
 */
(function () {
  'use strict';
  if (window.__API) return;                 // 已有副本装好，不抢

  var BASE = 'http://127.0.0.1:17433';
  var seq = 0;

  function append(el) {
    (document.body || document.head || document.documentElement).appendChild(el);
  }

  window.__API = {
    url: BASE,

    jsonp: function (path, ondata, onfail, timeoutMs) {
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
        try {
          if (ok) { if (ondata) ondata(); }
          else { if (onfail) onfail(why || 'error'); }
        } catch (e) { /* 回调抛异常不能把轮询/信标带崩 */ }
      }

      var sep = path.indexOf('?') >= 0 ? '&' : '?';
      s.src = BASE + path + sep + 'v=' + (++seq) + '_' + Date.now();
      s.onload = function () { finish(true); };
      s.onerror = function () { finish(false, 'error'); };
      if (timeoutMs > 0) timer = setTimeout(function () { finish(false, 'timeout'); }, timeoutMs);
      append(s);
      return s;
    },

    beacon: function (path) {
      var img = new Image();
      img.onload = img.onerror = function () { img.onload = img.onerror = null; };
      img.src = BASE + path + (path.indexOf('?') >= 0 ? '&' : '?') + '_=' + Date.now();
      return img;
    },

    icon: function (name) {
      return BASE + '/icon/' + encodeURIComponent(name);
    }
  };
})();
