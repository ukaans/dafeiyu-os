/* wx.js — 把壁纸左侧 IPV6 ROOT 面板换成真实天气模块（由 wxmon.ps1 提供数据） */
(function () {
  'use strict';

  var sec = document.getElementById('weatherInfo');
  if (!sec) return;

  // 原面板（模拟的 IPV6 ROOT / BEIJING 数据）整体隐藏，节点保留以免 app.js 报错
  Array.prototype.forEach.call(sec.children, function (el) {
    el.style.display = 'none';
  });

  var head = document.createElement('h2');
  head.id = 'wxHead';
  head.textContent = '天气 / WEATHER';
  sec.appendChild(head);

  var dl = document.createElement('dl');
  dl.className = 'small-data wx-data';
  sec.appendChild(dl);

  var rows = [
    ['天气', 'wxCond', '—'],
    ['温度', 'wxTemp', '—', 'wx-temp'],
    ['湿 / 雨', 'wxHumRain', '—'],
    ['穿衣建议', 'wxDress', '—']
  ];

  rows.forEach(function (r) {
    var box = document.createElement('div');
    var dt = document.createElement('dt');
    dt.textContent = r[0];
    var dd = document.createElement('dd');
    dd.id = r[1];
    dd.textContent = r[2];
    if (r[3]) dd.className = r[3];
    box.appendChild(dt);
    box.appendChild(dd);
    dl.appendChild(box);
  });

  var foot = document.createElement('div');
  foot.className = 'micro root-credit wx-foot';
  var range = document.createElement('span');
  range.id = 'wxRange';
  range.textContent = '今日 — / —';
  var upd = document.createElement('span');
  upd.id = 'wxUpd';
  upd.textContent = '更新 —';
  foot.appendChild(range);
  foot.appendChild(upd);
  sec.appendChild(foot);

  function setText(id, txt) {
    var el = document.getElementById(id);
    if (el && txt !== undefined && txt !== null) el.textContent = txt;
  }

  var lastTs = 0;

  function apply(d) {
    if (!d || !d.ts || d.ts <= lastTs) return;
    lastTs = d.ts;
    var hd = document.getElementById('wxHead');
  if (hd) hd.textContent = '天气 / WEATHER' + (d.city ? ' · ' + d.city : '');
    setText('wxCond', d.cond || '—');
    setText('wxTemp', (d.temp === undefined ? '—' : d.temp + '°C'));
  setText('wxHumRain', (d.hum === undefined ? '—' : d.hum + '%') + ' / ' + (d.rain === undefined ? '—' : d.rain + '%'));
    setText('wxDress', d.dress || '—');
    setText('wxRange', '今日 ' + (d.tmin === undefined ? '—' : d.tmin + '°') +
      ' / ' + (d.tmax === undefined ? '—' : d.tmax + '°'));
    setText('wxUpd', '更新 ' + (d.upd || '—'));
  }

  function pull() {
    var s = document.createElement('script');
    s.src = 'wx-data.js?v=' + Date.now();
    s.onload = function () {
      apply(window.__WX);
      s.parentNode && s.parentNode.removeChild(s);
    };
    s.onerror = function () {
      s.parentNode && s.parentNode.removeChild(s);
    };
    document.body.appendChild(s);
  }

  pull();
  setInterval(pull, 60000);
})();
