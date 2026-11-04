/* 本机硬件面板：轮询 hw-data.js（由 hwmon.ps1 每 2 秒写入），覆盖壁纸自带的模拟数据 */
(function () {
  'use strict';

  var el = function (id) { return document.getElementById(id); };
  var cpuReal = el('cpuReal'), gpuReal = el('gpuReal');
  var cpuBar = el('cpuBar'), gpuBar = el('gpuBar');
  var cpuName = el('cpuName'), gpuName = el('gpuName');
  var osName = el('osName'), uptimeReal = el('uptimeReal');
  var detailReal = el('detailReal');
  if (!cpuReal) return;

  var lastTs = 0;

  function apply() {
    var d = window.__HW;
    if (!d || !d.ts || d.ts <= lastTs) return;
    lastTs = d.ts;

    var c = Math.max(0, Math.min(100, Number(d.cpu) || 0));
    var g = Math.max(0, Math.min(100, Number(d.gpu) || 0));

    cpuReal.textContent = c.toFixed(1) + '%';
    gpuReal.textContent = g.toFixed(1) + '%';
    if (cpuBar) cpuBar.style.width = c + '%';
    if (gpuBar) gpuBar.style.width = g + '%';

    if (d.cpuName && cpuName) cpuName.textContent = d.cpuName;
    if (d.gpuName && gpuName) gpuName.textContent = d.gpuName;
    if (d.os && osName) osName.textContent = d.os;
    if (d.uptime && uptimeReal) uptimeReal.textContent = d.uptime;
    if (detailReal) {
      var bits = [];
      if (d.cores) bits.push(d.cores);
      if (d.mem) bits.push(d.mem);
      bits.push('实时');
      detailReal.textContent = bits.join(' · ');
    }
    lastOk = Date.now();
  }

  // 数据源（hwmon.ps1）挂掉时别继续显示旧数字：超过 15 秒没新数据就标成 --
  var lastOk = 0;
  function checkFresh() {
    if (!lastOk) return;
    if (Date.now() - lastOk < 15000) return;
    if (cpuReal) cpuReal.textContent = '--';
    if (gpuReal) gpuReal.textContent = '--';
    if (detailReal) detailReal.textContent = '数据源无响应';
    if (cpuBar) cpuBar.style.width = '0%';
    if (gpuBar) gpuBar.style.width = '0%';
  }

  function poll() {
    var old = document.querySelector('script[data-hw]');
    var s = document.createElement('script');
    s.src = 'hw-data.js?v=' + Date.now();
    s.setAttribute('data-hw', '1');
    s.onload = function () {
      apply();
      if (old && old.parentNode) old.parentNode.removeChild(old);
    };
    s.onerror = function () {
      if (s.parentNode) s.parentNode.removeChild(s);
    };
    document.body.appendChild(s);
  }

  apply();
  poll();
  setInterval(poll, 2000);
  setInterval(checkFresh, 3000);
})();
