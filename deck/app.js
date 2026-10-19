/* ===== 主题 ===== */
function toggleTheme() {
  const body = document.body;
  const icon = document.getElementById('theme-icon');
  const label = document.getElementById('theme-label');
  if (body.classList.contains('theme-dark')) {
    body.classList.replace('theme-dark', 'theme-light');
    icon.textContent = '🌙'; label.textContent = '深色';
    localStorage.setItem('dxt-theme', 'light');
  } else {
    body.classList.replace('theme-light', 'theme-dark');
    icon.textContent = '☀️'; label.textContent = '浅色';
    localStorage.setItem('dxt-theme', 'dark');
  }
}
(function () {
  const saved = localStorage.getItem('dxt-theme');
  if (saved === 'light') {
    document.body.classList.replace('theme-dark', 'theme-light');
    document.getElementById('theme-icon').textContent = '🌙';
    document.getElementById('theme-label').textContent = '深色';
  }
})();

/* ===== 阅读器 ===== */
function initViewer() {
  const PAGES = JSON.parse(document.getElementById('deck-pages').textContent);
  const N = PAGES.length;
  const PARTS = [
    { start: 2,  label: '为什么现在必须关注能源' },
    { start: 11, label: '我们能带来什么' },
    { start: 19, label: '我们为什么能做到' },
    { start: 25, label: '我们做过的项目' },
    { start: 35, label: '为什么选择电小团' }
  ];
  const $ = (id) => document.getElementById(id);
  const viewer = $('viewer'), stage = $('stage');
  const layers = [$('layer-a'), $('layer-b')];
  const counter = $('counter'), bar = $('progress-bar'), progress = $('progress');
  const btnPrev = $('btn-prev'), btnNext = $('btn-next');
  const sheet = $('sheet');
  let cur = 0, front = 0, built = false, lastFocus = null;

  counter.innerHTML = '<b>01</b> / ' + N;
  progress.setAttribute('aria-valuemax', String(N));

  const preload = (i) => {
    if (i < 0 || i >= N) return;
    const im = new Image();
    im.src = PAGES[i].src;
    if (im.decode) im.decode().catch(() => {});
  };

  function show(i) {
    const next = 1 - front;
    const layer = layers[next];
    const prev = layers[front];
    const img = layer.querySelector('img');
    let fired = false;
    const done = () => {
      if (fired) return;
      fired = true;
      layer.classList.add('on');
      prev.classList.remove('on');
      front = next;
    };
    img.onload = done;
    img.onerror = done;
    img.alt = '第 ' + (i + 1) + ' 页';
    img.src = PAGES[i].src;
    if (img.complete) done();
  }

  function goTo(i, opts) {
    i = Math.max(0, Math.min(N - 1, i));
    cur = i;
    show(i);
    counter.innerHTML = '<b>' + String(i + 1).padStart(2, '0') + '</b> / ' + N;
    bar.style.width = ((i + 1) / N * 100).toFixed(2) + '%';
    progress.setAttribute('aria-valuenow', String(i + 1));
    btnPrev.disabled = i === 0;
    btnNext.disabled = i === N - 1;
    preload(i + 1); preload(i + 2); preload(i - 1);
    if (built) {
      const th = sheet.querySelectorAll('.th');
      th.forEach((el) => el.classList.toggle('cur', Number(el.dataset.page) === i + 1));
      const active = sheet.querySelector('.th.cur');
      if (active && opts && opts.scrollThumb !== false) active.scrollIntoView({ block: 'nearest', inline: 'center' });
    }
    try { history.replaceState(null, '', '#p=' + (i + 1)); } catch (e) {}
  }

  function buildSheet() {
    const frag = document.createDocumentFragment();
    // 封面单独一组，其余按 PART 分段；保证 39 页一页不落
    const groups = [{ start: 1, end: 1, label: '封面', no: 0 }].concat(PARTS.map((p, idx) => ({
      start: p.start,
      end: idx + 1 < PARTS.length ? PARTS[idx + 1].start - 1 : N,
      label: p.label,
      no: idx + 1
    })));
    groups.forEach((p) => {
      const end = p.end;
      const group = document.createElement('div');
      group.className = 'th-group';
      const lab = document.createElement('div');
      lab.className = 'th-label';
      lab.innerHTML = p.no === 0
        ? '<b>封面</b> · P1'
        : 'PART ' + String(p.no).padStart(2, '0') + ' · <b>' + p.label + '</b> · P' + p.start + (end > p.start ? '–P' + end : '');
      group.appendChild(lab);
      const grid = document.createElement('div');
      grid.className = 'th-grid';
      for (let n = p.start; n <= end; n++) {
        const b = document.createElement('button');
        b.className = 'th';
        b.dataset.page = String(n);
        b.setAttribute('aria-label', '第 ' + n + ' 页');
        b.innerHTML = '<img src="' + PAGES[n - 1].thumb + '" alt="" loading="lazy" width="320" height="180"><span class="num">' + n + '</span>';
        b.addEventListener('click', () => { goTo(n - 1); toggleSheet(false); });
        grid.appendChild(b);
      }
      group.appendChild(grid);
      frag.appendChild(group);
    });
    sheet.appendChild(frag);
    built = true;
  }

  function toggleSheet(force) {
    const open = force === undefined ? !sheet.classList.contains('open') : force;
    sheet.classList.toggle('open', open);
    if (open && !built) buildSheet();
    if (open) setTimeout(() => {
      const a = sheet.querySelector('.th.cur');
      if (a) a.scrollIntoView({ block: 'center', inline: 'center' });
    }, 60);
  }

  function open(idx) {
    lastFocus = document.activeElement;
    if (!built) buildSheet();
    viewer.classList.add('open');
    document.body.classList.add('locked');
    goTo(idx === undefined ? 0 : idx);
    $('btn-close').focus({ preventScroll: true });
  }

  function close() {
    viewer.classList.remove('open');
    document.body.classList.remove('locked');
    toggleSheet(false);
    try { history.replaceState(null, '', location.pathname + location.search); } catch (e) {}
    if (lastFocus && lastFocus.focus) lastFocus.focus({ preventScroll: true });
  }

  $('open-deck').addEventListener('click', () => open(0));
  $('cover').addEventListener('click', () => open(0));
  $('cover').addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); open(0); } });
  document.querySelectorAll('.part').forEach((b) => {
    b.addEventListener('click', () => open(Number(b.dataset.page) - 1));
  });
  $('btn-close').addEventListener('click', close);
  btnPrev.addEventListener('click', () => goTo(cur - 1));
  btnNext.addEventListener('click', () => goTo(cur + 1));
  $('btn-thumbs').addEventListener('click', () => toggleSheet());
  stage.addEventListener('click', (e) => {
    if (e.target === stage || e.target.classList.contains('layer')) toggleSheet(false);
  });
  progress.addEventListener('click', (e) => {
    const r = progress.getBoundingClientRect();
    goTo(Math.round((e.clientX - r.left) / r.width * (N - 1)));
  });

  const btnFull = $('btn-full');
  if (document.fullscreenEnabled) {
    btnFull.addEventListener('click', () => {
      if (document.fullscreenElement) document.exitFullscreen();
      else document.documentElement.requestFullscreen().catch(() => {});
    });
    document.addEventListener('fullscreenchange', () => {
      btnFull.innerHTML = document.fullscreenElement
        ? '<i class="fa-solid fa-compress"></i>'
        : '<i class="fa-solid fa-expand"></i>';
    });
  } else {
    btnFull.style.display = 'none';
  }

  document.addEventListener('keydown', (e) => {
    if (!viewer.classList.contains('open')) return;
    if (e.key === 'Escape') { if (sheet.classList.contains('open')) toggleSheet(false); else close(); }
    else if (e.key === 'ArrowRight' || e.key === 'ArrowDown' || e.key === ' ' || e.key === 'PageDown') { e.preventDefault(); goTo(cur + 1); }
    else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp' || e.key === 'PageUp') { e.preventDefault(); goTo(cur - 1); }
    else if (e.key === 'Home') { e.preventDefault(); goTo(0); }
    else if (e.key === 'End') { e.preventDefault(); goTo(N - 1); }
  });

  // 滑动手势
  let tx = 0, ty = 0, tt = 0;
  stage.addEventListener('touchstart', (e) => {
    const t = e.changedTouches[0];
    tx = t.clientX; ty = t.clientY; tt = Date.now();
  }, { passive: true });
  stage.addEventListener('touchend', (e) => {
    const t = e.changedTouches[0];
    const dx = t.clientX - tx, dy = t.clientY - ty;
    if (Date.now() - tt > 800) return;
    if (Math.abs(dx) > 44 && Math.abs(dx) > Math.abs(dy) * 1.4) goTo(cur + (dx < 0 ? 1 : -1));
  }, { passive: true });

  // 深链：#p=12
  const m = /p=(\d+)/.exec(location.hash);
  if (m) {
    const idx = Math.min(N, Math.max(1, parseInt(m[1], 10))) - 1;
    open(idx);
  }

}
if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', initViewer);
} else {
  initViewer();
}
