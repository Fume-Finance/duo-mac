// Duo Mac website: the 3D iPhone Duo in the hero (built from the app's own keyboard layout and
// colours), the little Mac demo playing on it, and the copy buttons.
(() => {
  const $ = (s, r = document) => r.querySelector(s);
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  // #shot&t=8&rx=-20&ry=-18 (or #og…): a still frame for README images and the social card.
  const shot = /^#(shot|og)/.test(location.hash) ? Object.fromEntries(new URLSearchParams(location.hash.slice(1))) : null;
  if (shot) document.documentElement.classList.add('shot', 'og' in shot ? 'og' : 'plain');

  // ───── Keyboard: the app's Space Black MacBook keyboard (US layout) ─────
  const svg = (body, fill = false) =>
    `<svg viewBox="0 0 16 16" fill="${fill ? 'currentColor' : 'none'}" stroke="${fill ? 'none' : 'currentColor'}" ` +
    `stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
  const sun = (r, ray) => {
    let s = `<circle cx="8" cy="8" r="${r}"/>`;
    for (let i = 0; i < 8; i++) {
      const a = (i * Math.PI) / 4, r1 = r + 1.5, r2 = r + 1.5 + ray;
      s += `<path d="M${(8 + Math.cos(a) * r1).toFixed(2)} ${(8 + Math.sin(a) * r1).toFixed(2)}L${(8 + Math.cos(a) * r2).toFixed(2)} ${(8 + Math.sin(a) * r2).toFixed(2)}"/>`;
    }
    return s;
  };
  const SPEAKER = '<path d="M2 6h2.5L8 3v10L4.5 10H2z" fill="currentColor" stroke="none"/>';
  const ICONS = {
    brightDown: svg(sun(2.1, 1.1)),
    brightUp: svg(sun(2.5, 2.2)),
    mission: svg('<rect x="1.5" y="2.5" width="5.5" height="4.5" rx="1"/><rect x="9" y="2.5" width="5.5" height="4.5" rx="1"/><rect x="4" y="9" width="8" height="4.5" rx="1"/>'),
    search: svg('<circle cx="7" cy="7" r="4.2"/><path d="M10.2 10.2 14 14"/>'),
    mic: svg('<rect x="5.8" y="1.5" width="4.4" height="8" rx="2.2"/><path d="M3.5 7.5a4.5 4.5 0 0 0 9 0M8 12v2.5"/>'),
    moon: svg('<path d="M11.8 10.6A5.5 5.5 0 0 1 5.4 4.2a5.5 5.5 0 1 0 6.4 6.4z"/>'),
    rew: svg('<path d="M7.5 4 2 8l5.5 4zM14 4 8.5 8 14 12z"/>', true),
    play: svg('<path d="M1.5 4 7 8l-5.5 4z"/><rect x="9" y="4" width="2" height="8" rx=".4"/><rect x="12.5" y="4" width="2" height="8" rx=".4"/>', true),
    ff: svg('<path d="M2 4l5.5 4L2 12zM8.5 4 14 8l-5.5 4z"/>', true),
    mute: svg(SPEAKER),
    volDown: svg(SPEAKER + '<path d="M10.5 6.2a2.6 2.6 0 0 1 0 3.6"/>'),
    volUp: svg(SPEAKER + '<path d="M10.5 6.2a2.6 2.6 0 0 1 0 3.6M12.4 4.4a5.2 5.2 0 0 1 0 7.2"/>'),
    globe: svg('<circle cx="8" cy="8" r="6"/><path d="M2 8h12M8 2c-2.2 2.5-2.2 9.5 0 12M8 2c2.2 2.5 2.2 9.5 0 12"/>'),
    gear: svg('<path stroke-linejoin="round" d="M12.95 6.79L14.62 7L14.62 9L12.95 9.21L12.36 10.65L13.39 11.98L11.98 13.39L10.65 12.36L9.21 12.95L9 14.62L7 14.62L6.79 12.95L5.35 12.36L4.02 13.39L2.61 11.98L3.64 10.65L3.05 9.21L1.38 9L1.38 7L3.05 6.79L3.64 5.35L2.61 4.02L4.02 2.61L5.35 3.64L6.79 3.05L7 1.38L9 1.38L9.21 3.05L10.65 3.64L11.98 2.61L13.39 4.02L12.36 5.35Z"/><circle cx="8" cy="8" r="2.1"/>'),
  };
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

  function keyboardHTML() {
    const char = (k) => `<div class="key" data-k="${k}"><span class="c">${k.toUpperCase()}</span></div>`;
    const dual = (k, up) => `<div class="key" data-k="${esc(k)}"><span class="dual"><span>${esc(up)}</span><span>${esc(k)}</span></span></div>`;
    const word = (label, w, align, k = '') => `<div class="key word ${align}" style="--w:${w}"${k ? ` data-k="${k}"` : ''}><span class="w">${label}</span></div>`;
    const mod = (label, sym, w, align, k = '') => `<div class="key word ${align}" style="--w:${w}"${k ? ` data-k="${k}"` : ''}><span class="s">${sym}</span><span class="w">${label}</span></div>`;
    const fn = (icon) => `<div class="key fn">${ICONS[icon]}</div>`;
    const rows = [
      [word('esc', 1.5, 'l'), ...['brightDown', 'brightUp', 'mission', 'search', 'mic', 'moon', 'rew', 'play', 'ff', 'mute', 'volDown', 'volUp'].map(fn),
        `<div class="key power">${ICONS.gear}</div>`],
      [dual('`', '~'), dual('1', '!'), dual('2', '@'), dual('3', '#'), dual('4', '$'), dual('5', '%'), dual('6', '^'), dual('7', '&'),
        dual('8', '*'), dual('9', '('), dual('0', ')'), dual('-', '_'), dual('=', '+'), word('delete', 1.5, 'r')],
      [word('tab', 1.5, 'l'), ...[...'qwertyuiop'].map(char), dual('[', '{'), dual(']', '}'), dual('\\', '|')],
      ['<div class="key word l caps" style="--w:1.8"><i class="led"></i><span class="w">caps lock</span></div>', ...[...'asdfghjkl'].map(char),
        dual(';', ':'), dual("'", '"'), word('return', 1.7, 'r', 'enter')],
      [mod('shift', '⇧', 2.3, 'l'), ...[...'zxcvbnm'].map(char), dual(',', '<'), dual('.', '>'), dual('/', '?'), mod('shift', '⇧', 2.2, 'r')],
      [`<div class="key globe"><span class="fnl">fn</span>${ICONS.globe.replace('<svg', '<svg class="g"')}</div>`,
        mod('control', '⌃', 1, 'r'), mod('option', '⌥', 1, 'r'), mod('command', '⌘', 1.3, 'r', 'cmd'),
        '<div class="key" style="--w:4.9" data-k=" "></div>', mod('command', '⌘', 1.3, 'l'), mod('option', '⌥', 1, 'l'),
        '<div class="arrows"><div class="key arrow">◀</div><div class="mid"><div class="key arrow">▲</div><div class="key arrow">▼</div></div><div class="key arrow">▶</div></div>'],
    ];
    return rows.map((r, i) => `<div class="row${i ? '' : ' fnrow'}">${r.join('')}</div>`).join('');
  }

  // ───── The Mac desktop on the top half ─────
  const g = (d) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
  const DOCK = [
    ['linear-gradient(#6ec3ff,#1f7cf2)', g('<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>')],
    ['linear-gradient(#7fe0ff,#1a8cff)', g('<circle cx="12" cy="12" r="9"/><path d="m15.5 8.5-2.2 4.8-4.8 2.2 2.2-4.8z"/>')],
    ['linear-gradient(#72f08a,#20b84a)', g('<path d="M4 12c0-4 3.6-7 8-7s8 3 8 7-3.6 7-8 7c-1 0-2-.2-2.9-.5L5 20l1.2-3.4C4.8 15.4 4 13.8 4 12z"/>')],
    ['linear-gradient(#ffb36b,#ff6a3d)', g('<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="9" cy="10" r="2"/><path d="m21 15-5-5L5 19"/>')],
    ['linear-gradient(#ff7aa2,#f2335c)', g('<path d="M9 18V6l11-2v12"/><circle cx="6.5" cy="18" r="2.5"/><circle cx="17.5" cy="16" r="2.5"/>')],
    ['linear-gradient(#fff3a6,#ffd23f)', g('<path d="M7 4h10a2 2 0 0 1 2 2v14H5V6a2 2 0 0 1 2-2zM8 9h8M8 13h8M8 17h5"/>'), '#9a7a00'],
    ['linear-gradient(#3a3a3e,#111)', g('<path d="m5 8 4 4-4 4M12 17h7"/>'), '#fff', 'run'],
  ];
  const WAVES = `<svg viewBox="0 0 100 70" preserveAspectRatio="none" aria-hidden="true">
    <path d="M0 50C18 34 34 64 56 44S86 18 100 28V70H0Z" fill="rgba(255,255,255,.09)"/>
    <path d="M0 60C22 46 44 72 68 54S94 40 100 46V70H0Z" fill="rgba(255,140,90,.26)"/>
    <path d="M0 18C26 34 56 4 100 14V0H0Z" fill="rgba(40,70,255,.25)"/>
    <path d="M0 34C30 20 48 46 74 30S96 22 100 24V36C88 30 76 46 56 50S18 30 0 44Z" fill="rgba(255,255,255,.07)"/></svg>`;
  const CURSOR = '<svg viewBox="0 0 17 24" aria-hidden="true"><path d="M1.6 1.6v18.3l4.3-4.2 2.9 6.8 3.2-1.4-2.9-6.6h6.1z" fill="#000" stroke="#fff" stroke-width="1.5" stroke-linejoin="round"/></svg>';
  const file = (name, kind = '') => `<div class="file ${kind}"><i></i><span>${name}</span></div>`;

  function macHTML() {
    return `
      <div class="wall">${WAVES}</div>
      <div class="menubar"><i class="logo"></i><b>Terminal</b><span>Shell</span><span>Edit</span><span>View</span><span>Window</span><span>Help</span></div>
      <div class="ios-status">9:41<i></i></div>
      <div class="win finder"><div class="tbar"><span class="tl"><i></i><i></i><i></i></span><span>duo-mac</span></div>
        <div class="body"><div class="side"><b>Favourites</b><div>Recents</div><div>Applications</div><div class="on">Projects</div><div>Desktop</div><div>Downloads</div></div>
          <div class="files">${file('helper')}${file('web')}${file('site')}${file('launcher')}${file('README.md', 'doc')}${file('build.sh', 'doc')}${file('LICENSE', 'doc')}${file('Duo Mac', 'app')}</div></div></div>
      <div class="win term front"><div class="tbar"><span class="tl"><i></i><i></i><i></i></span><span>duo-mac — zsh</span></div><pre></pre></div>
      <div class="dock">${DOCK.map(([bg, glyph, color = '#fff', run = '']) => `<i class="app ${run}" style="background:${bg};color:${color}">${glyph}</i>`).join('')}<i class="app img run"></i><i class="sep"></i>
        <i class="app" style="background:linear-gradient(#f4f4f6,#c9c9ce);color:#6c6c74">${g('<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/>')}</i></div>
      <div class="cursor">${CURSOR}</div>
      <div class="fold-shade"></div>`;
  }

  // The terminal's text at a given moment of the demo.
  const PROMPT = '<span class="p">~/duo-mac</span> % ';
  const CMD = './build.sh';
  const OUT = [
    '<span class="d">▸ Building helper…</span>',
    '<span class="d">▸ Installing to ~/Library/Application Support/Duo Mac</span>',
    '<span class="ok">✓ Done.</span> Open Duo Mac from Applications.',
  ];
  function termText(typed, lines, done) {
    let s = PROMPT + CMD.slice(0, typed);
    if (lines < 0) return s + '<i class="caret"></i>';
    for (let i = 0; i < lines; i++) s += '\n' + OUT[i];
    return s + (done ? '\n' + PROMPT + '<i class="caret"></i>' : '');
  }

  // ───── The phone's titanium edges, following the rounded outline ─────
  function edges(half, side) {
    const W = 66.9, H = 47.55, R = 5.6, N = 9;
    const pts = [];
    const arc = (cx, cy, a0, a1) => { for (let i = 0; i <= N; i++) { const a = a0 + ((a1 - a0) * i) / N; pts.push([cx + R * Math.cos(a), cy + R * Math.sin(a)]); } };
    if (side === 'lid') { pts.push([0, H]); arc(R, R, Math.PI, 1.5 * Math.PI); arc(W - R, R, 1.5 * Math.PI, 2 * Math.PI); pts.push([W, H]); }
    else { pts.push([0, 0]); arc(R, H - R, Math.PI, 0.5 * Math.PI); arc(W - R, H - R, 0.5 * Math.PI, 0); pts.push([W, 0]); }
    const light = side === 'lid' ? [-0.45, -0.89] : [0.3, -0.95];
    let html = '';
    for (let i = 0; i < pts.length - 1; i++) {
      const [ax, ay] = pts[i], [bx, by] = pts[i + 1];
      const dx = bx - ax, dy = by - ay, len = Math.hypot(dx, dy);
      if (len < 0.01) continue;
      const tx = dx / len, ty = dy / len;
      const n = side === 'lid' ? [ty, -tx] : [-ty, tx]; // outward
      const lit = Math.max(0, n[0] * light[0] + n[1] * light[1]);
      const top = Math.round(78 + 70 * lit), mid = Math.round(46 + 40 * lit), bot = Math.round(30 + 22 * lit);
      html += `<i class="edge" style="width:${(len + 0.08).toFixed(3)}em;` +
        `transform:translate(${ax.toFixed(3)}em,${ay.toFixed(3)}em) rotateZ(${Math.atan2(dy, dx).toFixed(4)}rad) rotateX(-90deg);` +
        `background:linear-gradient(rgb(${top},${top},${top + 4}),rgb(${mid},${mid},${mid + 3}) 35%,rgb(${bot},${bot},${bot + 2}))"></i>`;
    }
    half.insertAdjacentHTML('beforeend', html);
  }

  // ───── Build ─────
  const duo = $('#duo'), lid = $('#lid'), mac = $('#mac'), stage = $('#stage');
  $('#keyboard').innerHTML = keyboardHTML();
  mac.innerHTML = macHTML();
  edges(lid, 'lid');
  edges($('.base'), 'base');

  const mini = $('#mac-mini');
  if (mini) {
    mini.innerHTML = macHTML();
    mini.querySelector('.cursor').remove();
    mini.querySelector('.term pre').innerHTML = termText(CMD.length, 3, true);
    $('#keyboard-mini').innerHTML = keyboardHTML();
  }

  const finder = $('.finder', mac), term = $('.term', mac), pre = $('.term pre', mac), cursor = $('.cursor', mac);
  const pad = $('#trackpad'), finger = $('#finger');
  const keys = {};
  for (const k of $('#keyboard').querySelectorAll('[data-k]')) keys[k.dataset.k] = k;

  // ───── The demo: drag a window, click the terminal, type ./build.sh, ⌘K to clear ─────
  const LOOP = 14.5;
  const PATH = [[0, 46, 31], [1.2, 13.5, 5.6], [1.45, 13.5, 5.6], [2.8, 20.5, 8.1], [3.05, 20.5, 8.1], [4.0, 44, 27], [9.6, 44, 27],
    [10.6, 20.8, 8.1], [10.85, 20.8, 8.1], [12.15, 13.8, 5.6], [12.5, 13.8, 5.6], [LOOP, 46, 31]];
  const FINDER = [[0, 0, 0], [1.45, 0, 0], [2.8, 7, 2.5], [10.85, 7, 2.5], [12.15, 0, 0], [LOOP, 0, 0]];
  const PRESS = [[1.3, 2.9], [4.05, 4.25], [10.7, 12.25]];
  const FINDER_FRONT = [[0, 4.05], [10.7, LOOP]];
  const TYPE_AT = 4.6, TYPE_DT = 0.16, ENTER_AT = 6.45, LINES_AT = [6.9, 7.5, 8.2], DONE_AT = 8.5, CLEAR_AT = 13.4;

  const ease = (p) => (p < 0.5 ? 2 * p * p : 1 - Math.pow(-2 * p + 2, 2) / 2);
  function track(frames, t) {
    for (let i = 0; i < frames.length - 1; i++) {
      const a = frames[i], b = frames[i + 1];
      if (t >= a[0] && t <= b[0]) {
        const p = b[0] > a[0] ? ease((t - a[0]) / (b[0] - a[0])) : 1;
        return [a[1] + (b[1] - a[1]) * p, a[2] + (b[2] - a[2]) * p, a[1] !== b[1] || a[2] !== b[2]];
      }
    }
    const l = frames[frames.length - 1];
    return [l[1], l[2], false];
  }
  const within = (spans, t) => spans.some(([a, b]) => t >= a && t < b);

  let lastText = '', lastTyped = -1, lastEnter = false, lastClear = false, moveSeen = -1;
  const press = (k, ms = 140) => {
    const el = keys[k];
    if (!el) return;
    el.classList.add('pressed');
    setTimeout(() => el.classList.remove('pressed'), ms);
  };

  function demo(t, now) {
    const [x, y, moving] = track(PATH, t);
    cursor.style.transform = `translate(${x}em, ${y}em)`;
    const down = within(PRESS, t);
    cursor.classList.toggle('down', down);
    const [fx, fy] = track(FINDER, t);
    finder.style.transform = `translate(${fx}em, ${fy}em)`;
    const ff = within(FINDER_FRONT, t);
    finder.classList.toggle('front', ff);
    term.classList.toggle('front', !ff);

    // A fingertip on the trackpad moves the pointer.
    if (moving || down) moveSeen = now;
    finger.classList.toggle('on', now - moveSeen < 350);
    finger.classList.toggle('press', down);
    pad.classList.toggle('dragging', down && t < 4 || t > 10.7 && down);
    finger.style.transform = `translate(${(x / 66) * pad.clientWidth}px, ${(y / 47) * pad.clientHeight}px)`;

    // Typing on the keyboard shows up in the terminal.
    const typed = t < TYPE_AT ? 0 : Math.min(CMD.length, Math.floor((t - TYPE_AT) / TYPE_DT) + 1);
    if (typed !== lastTyped) {
      if (typed > lastTyped && typed > 0) press(CMD[typed - 1]);
      lastTyped = typed;
    }
    const entered = t >= ENTER_AT;
    if (entered && !lastEnter) press('enter', 180);
    lastEnter = entered;
    const cleared = t >= CLEAR_AT;
    if (cleared && !lastClear) { press('cmd', 320); setTimeout(() => press('k', 160), 90); }
    lastClear = cleared;

    const lines = entered ? LINES_AT.filter((a) => t >= a).length : -1;
    const text = cleared ? PROMPT + '<i class="caret"></i>' : termText(typed, lines, t >= DONE_AT);
    if (text !== lastText) { pre.innerHTML = text; lastText = text; }
  }

  // ───── 3D: follow the mouse; sway gently when it's still ─────
  // Resting angle: a three-quarter view (straighter on narrow screens, so it fits).
  const narrow = matchMedia('(max-width: 600px)').matches;
  const RX0 = -22, RY0 = narrow ? -7 : -16, SWAY = narrow ? 5 : 9;
  let rx = shot ? +(shot.rx || -20) : RX0, ry = shot ? +(shot.ry || -18) : RY0, trx = rx, tryy = ry, pointerAt = -1e9;
  addEventListener('pointermove', (e) => {
    if (e.pointerType !== 'mouse') return;
    trx = RX0 - (e.clientY / innerHeight - 0.5) * 16;
    tryy = RY0 + (e.clientX / innerWidth - 0.5) * 38;
    pointerAt = performance.now();
  }, { passive: true });

  let visible = true;
  new IntersectionObserver(([e]) => { visible = e.isIntersecting; }).observe(stage);

  const OPEN = 12, CLOSED = -86;
  let start = 0, woke = false, demoStart = 0;
  if (shot) {
    lid.style.transform = `rotateX(${OPEN}deg)`;
    duo.style.transform = `rotateX(${rx}deg) rotateY(${ry}deg)`;
    const t = +(shot.t || 7.9);
    requestAnimationFrame(function still(now) { demo(t, now); if (now < 4000) requestAnimationFrame(still); });
  } else if (reduce) {
    lid.style.transform = `rotateX(${OPEN}deg)`;
    demo(9.2, 0);
    finger.classList.remove('on');
  } else {
    lid.style.transform = `rotateX(${CLOSED}deg)`;
    mac.classList.add('asleep');
  }

  function frame(now) {
    requestAnimationFrame(frame);
    if (!visible) return;
    if (!start) start = now;
    if (now - pointerAt > 2500) {
      const s = now / 1000;
      tryy = RY0 + Math.sin(s * 0.42) * SWAY;
      trx = RX0 + Math.sin(s * 0.31) * 2.5;
    }
    rx += (trx - rx) * 0.06;
    ry += (tryy - ry) * 0.06;
    duo.style.transform = `rotateX(${rx.toFixed(3)}deg) rotateY(${ry.toFixed(3)}deg)`;
    if (reduce) return;

    // Unfold once, like opening a laptop, then wake the Mac.
    const p = Math.min(1, Math.max(0, (now - start - 350) / 1500));
    if (p < 1 || !woke) {
      const e = 1 - Math.pow(1 - p, 3);
      lid.style.transform = `rotateX(${(CLOSED + (OPEN - CLOSED) * e).toFixed(2)}deg)`;
      if (p > 0.6 && !woke) { woke = true; mac.classList.remove('asleep'); demoStart = now + 500; }
    }
    if (woke && now > demoStart) demo(((now - demoStart) / 1000) % LOOP, now);
  }
  if (!shot) {
    if (!reduce) demo(0, 0);
    requestAnimationFrame(frame);
  }

  // ───── Copy for your agent ─────
  for (const b of document.querySelectorAll('.copy')) {
    b.addEventListener('click', async () => {
      const text = b.dataset.copy;
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        const ta = document.createElement('textarea');
        ta.value = text;
        document.body.append(ta);
        ta.select();
        document.execCommand('copy');
        ta.remove();
      }
      b.textContent = 'copied ✓';
      b.classList.add('done');
      setTimeout(() => { b.textContent = 'copy'; b.classList.remove('done'); }, 1800);
    });
  }
})();
