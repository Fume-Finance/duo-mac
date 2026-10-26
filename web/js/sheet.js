// "System Settings" for the Duo: opened with the gear key (top right of the keyboard, where Touch ID would be).
import { settings, setSetting } from './settings.js';

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

function toggle(key, label, note = '') {
  return `<div class="item"><label for="s-${key}">${label}${note ? `<small>${note}</small>` : ''}</label>
    <input type="checkbox" switch id="s-${key}" data-k="${key}" ${settings[key] ? 'checked' : ''}></div>`;
}

function slider(key, label, min, max, step, fmt = (v) => `${v}×`) {
  return `<div class="item"><span class="l">${label}</span>
    <input type="range" data-k="${key}" min="${min}" max="${max}" step="${step}" value="${settings[key] ?? (key === 'hinge' ? (innerHeight / innerWidth > 1.8 ? 0.56 : 0.5) : 1)}">
    <span class="val" data-v="${key}">${fmt(settings[key] ?? (key === 'hinge' ? (innerHeight / innerWidth > 1.8 ? 0.56 : 0.5) : 1))}</span></div>`;
}

/** Picture cards (like System Settings' appearance picker): options are [value, title, art]. */
function cards(key, label, options, note = '') {
  return `<div class="item cards-item"><span class="l">${label}${note ? `<small>${note}</small>` : ''}</span>
    <div class="cards" data-seg="${key}">${options
    .map(([v, t, art]) => `<button type="button" data-val="${v}" class="card ${String(settings[key]) === v ? 'on' : ''}"><span class="art">${art}</span><span class="ct">${t}</span></button>`)
    .join('')}</div></div>`;
}

// ───── Little pictures for the cards (viewBox 80×50, drawn in CSS colours) ─────

const desk = (x, y, w, h) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" class="dt"/><rect x="${x}" y="${y}" width="${w}" height="${Math.max(2, h * 0.09)}" class="mb"/>`;

function scrollArt(natural) {
  const id = natural ? 'n' : 'i';
  return `<svg viewBox="0 0 80 50"><defs><clipPath id="cp-${id}"><rect x="12" y="3" width="56" height="44" rx="5"/></clipPath></defs>
    <rect x="12" y="3" width="56" height="44" rx="5" class="frame"/>
    <g clip-path="url(#cp-${id})"><g class="sc ${natural ? 'up' : 'down'}">
      ${[0, 1, 2, 3, 4, 5, 6].map((i) => `<rect x="18" y="${i * 11 - 8}" width="${i % 2 ? 26 : 38}" height="5" rx="2.5" class="ln"/>`).join('')}
    </g></g>
    <g class="finger up"><circle cx="60" cy="34" r="5.5" class="tip"/></g></svg>`;
}

/** Screen only: tap where you click (a finger on the window), or the screen as a trackpad (a finger
 *  sliding, the pointer following it somewhere else). */
function touchArt(pad) {
  let out = `<svg viewBox="0 0 80 50"><rect x="14" y="2" width="52" height="46" rx="5" class="frame"/>${desk(16, 4, 48, 42)}
    <rect x="24" y="13" width="32" height="22" rx="1.5" class="win"/>`;
  out += pad
    ? `<path d="M30 17l0 9 2.4-2.2 1.8 3.8 1.6-.8-1.8-3.7 3.3-.2z" class="ptr"/>
       <path d="M44 41 L56 33" class="trail"/><circle cx="57" cy="32" r="4.5" class="tip"/>`
    : `<circle cx="42" cy="24" r="7" class="tring"/><circle cx="42" cy="24" r="4.5" class="tip"/>`;
  return out + '</svg>';
}

/** The Mac's screen, with or without the notch in the top middle. */
function notchArt(on) {
  return `<svg viewBox="0 0 80 50"><rect x="4" y="5" width="72" height="40" rx="4" class="frame"/>${desk(6, 7, 68, 36)}
    ${on ? '<path d="M29 7h22v6.5a2.4 2.4 0 0 1-2.4 2.4H31.4a2.4 2.4 0 0 1-2.4-2.4z" class="notch"/>' : ''}</svg>`;
}

/** Folded: the cover screen shows a closed lid, or the Mac (the whole screen a trackpad). */
function foldArt(lid) {
  let out = '<svg viewBox="0 0 80 50"><rect x="26" y="1.5" width="28" height="47" rx="5.5" class="frame"/>';
  out += lid
    ? '<rect x="28" y="3.5" width="24" height="43" rx="3.8" class="lidc"/><rect x="28" y="3.5" width="2.2" height="43" class="hinge"/><text x="40" y="25" class="apple" transform="rotate(90 40 25)">&#xF8FF;</text>'
    : `${desk(28, 3.5, 24, 43)}<rect x="31" y="14" width="18" height="12" rx="1" class="win"/>
       <path d="M36 18l0 6 1.6-1.5 1.2 2.6 1.1-.5-1.2-2.5 2.2-.1z" class="ptr"/><circle cx="44" cy="37" r="3.6" class="tip"/>`;
  return out + '</svg>';
}

const fillArt = `<svg viewBox="0 0 80 50"><rect x="4" y="5" width="72" height="40" rx="4" class="frame"/>${desk(6, 7, 68, 36)}</svg>`;
const mirrorArt = `<svg viewBox="0 0 80 50"><rect x="4" y="5" width="72" height="40" rx="4" class="frame"/>${desk(24, 7, 32, 36)}</svg>`;

function sizeArt(dot) {
  // The top-left corner of a window: bigger traffic lights and title bar = larger text.
  const r = dot, y = 10 + r, g = r * 2.9;
  return `<svg viewBox="0 0 80 50"><rect x="4" y="4" width="90" height="60" rx="${r * 2}" class="win"/>
    <circle cx="${10 + r}" cy="${y}" r="${r}" fill="#ff5f57"/><circle cx="${10 + r + g}" cy="${y}" r="${r}" fill="#febc2e"/><circle cx="${10 + r + 2 * g}" cy="${y}" r="${r}" fill="#28c840"/>
    ${[0, 1, 2, 3].map((i) => `<rect x="10" y="${y + r * 2.6 + i * r * 2.6}" width="${48 - i * 6}" height="${r * 1.1}" rx="${r * 0.5}" class="ln"/>`).join('')}</svg>`;
}

const topArt = (full) => `<svg viewBox="0 0 80 50"><rect x="4" y="3" width="72" height="44" rx="5" class="frame"/>
  ${full ? desk(6, 5, 68, 40) : desk(6, 15, 68, 30)}
  <text x="58.5" y="12.2" class="clock" text-anchor="end">9:41</text><circle cx="66.5" cy="10" r="3.3" class="ring"/></svg>`;

/** An unfolded Duo: the Mac's screen on top (menu bar, a window, the Dock), then keyboard and trackpad. */
function duoArt(share, padOnly = false) {
  const X = 3, Y = 2, W = 40, H = 70, sh = Math.round(H * share);
  let out = `<svg viewBox="0 0 46 74" class="duo-art"><rect x="${X}" y="${Y}" width="${W}" height="${H}" rx="5" class="frame"/>`;
  // screen
  const sx = X + 2, sy = Y + 2, sw = W - 4, shh = sh - 3;
  out += `<rect x="${sx}" y="${sy}" width="${sw}" height="${shh}" rx="2.5" class="dt"/>`;
  out += `<rect x="${sx}" y="${sy}" width="${sw}" height="2.4" class="mb"/>`;
  if (shh > 14) out += `<rect x="${sx + 4}" y="${sy + 5.5}" width="${sw - 8}" height="${Math.max(4, shh - 13)}" rx="1.2" class="win"/>`;
  out += `<rect x="${sx + sw / 2 - 9}" y="${sy + shh - 4}" width="18" height="2.6" rx="1.3" class="dock"/>`;
  if (share < 1) {
    // fold, keyboard rows, trackpad
    out += `<line x1="${X}" x2="${X + W}" y1="${Y + sh}" y2="${Y + sh}" class="fold"/>`;
    const kTop = Y + sh + 2.5, kH = padOnly ? -1.5 : (H - sh) * 0.55, rows = Math.max(2, Math.min(5, Math.round(kH / 3.4)));
    const rh = kH / rows;
    if (!padOnly) for (let r = 0; r < rows; r++) for (let i = 0; i < 8; i++) {
      out += `<rect x="${X + 3 + i * 4.3}" y="${(kTop + r * rh).toFixed(1)}" width="3.5" height="${(rh - 0.9).toFixed(1)}" rx="0.6" class="k"/>`;
    }
    const tTop = kTop + kH + 1.5, tH = Y + H - 2.5 - tTop;
    // Trackpad layout: the pad fills the half; laptop: a MacBook-ish pad under the keys.
    if (tH > 3) out += padOnly
      ? `<rect x="${X + 3}" y="${tTop.toFixed(1)}" width="${W - 6}" height="${tH.toFixed(1)}" rx="2" class="pad"/>`
      : `<rect x="${X + 10}" y="${tTop.toFixed(1)}" width="${W - 20}" height="${tH.toFixed(1)}" rx="1.4" class="pad"/>`;
  }
  return out + '</svg>';
}

function splitSlider() {
  // Laptop and Trackpad layouts each remember their own split.
  const key = settings.layout === 'trackpad' ? 'hingePad' : 'hinge';
  const v = settings[key] ?? (innerHeight / innerWidth > 1.8 ? 0.56 : 0.5);
  // Right to left, so the side with more screen is on the left, like its picture.
  const pad = settings.layout === 'trackpad', what = pad ? 'trackpad' : 'keyboard';
  return `<div class="item split-item"><span class="l">Screen / ${what} split<small>On a foldable, match it to the fold</small></span>
    <div class="split"><figure>${duoArt(0.72, pad)}<figcaption>More screen</figcaption></figure>
      <div class="split-mid"><input type="range" dir="rtl" data-k="${key}" min="0.25" max="0.75" step="0.005" value="${v}">
        <span class="val" data-v="${key}">${FMT.hinge(v)}</span></div>
      <figure>${duoArt(0.3, pad)}<figcaption>More ${what}</figcaption></figure></div></div>`;
}

const qualityArt = (emoji, blur) => `<span class="q"><span class="qe">${emoji}</span><span class="qs" style="filter:blur(${blur}px)">Aa</span></span>`;

function keyboardArt(silver) {
  const rows = [0, 1, 2, 3].map((r) => [...Array(10)].map((_, i) => `<rect x="${9 + i * 6.3}" y="${7 + r * 6.3}" width="5.3" height="5.3" rx="1" class="k"/>`).join('')).join('');
  return `<svg viewBox="0 0 80 50" class="${silver ? 'silver' : 'black'}"><rect x="4" y="3" width="72" height="44" rx="5" class="deck"/>${rows}
    <rect x="22" y="34" width="36" height="10" rx="2" class="pad"/></svg>`;
}

// ───── Gestures: little animated demos ─────

const finger = (x, y, cls = '') => `<g class="fg ${cls}"><circle cx="${x}" cy="${y}" r="9" class="ripple"/><circle cx="${x}" cy="${y}" r="5" class="tip"/></g>`;
const pad = (inner, screen = false) => `<svg viewBox="0 0 80 50"><rect x="6" y="4" width="68" height="42" rx="6" class="${screen ? 'gscreen' : 'gpad'}"/>${inner}</svg>`;
const keycap = (x, label, cls, w = 22) => `<g class="kc ${cls}"><rect x="${x}" y="13" width="${w}" height="22" rx="4"/><text x="${x + w / 2}" y="28.5">${label}</text></g>`;

const GESTURES = {
  Trackpad: [
    ['Move the pointer', 'Slide 1 finger', pad(finger(40, 25, 'g-move'))],
    ['Click', 'Tap', pad(finger(40, 25, 'g-tap'))],
    ['Double-click', 'Tap twice', pad(finger(40, 25, 'g-dbl'))],
    ['Drag', 'Tap, then slide', pad(`<rect x="24" y="12" width="14" height="10" rx="2" class="gwin g-dragwin"/>${finger(31, 31, 'g-drag')}`)],
    ['Right-click', 'Tap with 2 fingers', pad(finger(33, 25, 'g-tap') + finger(47, 25, 'g-tap'))],
    ['Scroll', 'Slide 2 fingers', pad(`<g class="g-scroll">${finger(33, 25)}${finger(47, 25)}</g>`)],
    ['Zoom in the app', 'Pinch', pad(finger(36, 27, 'g-pinch-l') + finger(44, 23, 'g-pinch-r'))],
    ['Mission Control', '3 fingers up', pad(`<g class="g-up">${finger(28, 27)}${finger(40, 25)}${finger(52, 27)}</g>`)],
    ['Switch Spaces', '3 fingers sideways', pad(`<g class="g-side">${finger(28, 27)}${finger(40, 25)}${finger(52, 27)}</g>`)],
  ],
  Screen: [
    ['Click right there', 'Tap the screen', pad(`<rect x="10" y="8" width="60" height="4" class="gmb"/>${finger(48, 28, 'g-tap')}`, true)],
    ['Zoom and pan', 'Pinch or 2 fingers', pad(`<rect x="10" y="8" width="60" height="4" class="gmb"/>${finger(36, 29, 'g-pinch-l')}${finger(44, 25, 'g-pinch-r')}`, true)],
    ['Right-click', 'Tap with 2 fingers', pad(`<rect x="10" y="8" width="60" height="4" class="gmb"/>${finger(33, 28, 'g-tap')}${finger(47, 28, 'g-tap')}`, true)],
  ],
  Keyboard: [
    ['Shortcuts', 'Hold ⌘, tap C', `<svg viewBox="0 0 80 50">${keycap(12, '⌘', 'k-hold')}${keycap(44, 'C', 'k-tap2')}</svg>`],
    ['…or one at a time', 'Tap ⌘, then C', `<svg viewBox="0 0 80 50">${keycap(12, '⌘', 'k-sticky')}${keycap(44, 'C', 'k-tap3')}</svg>`],
    ['Lock a modifier', 'Double-tap it', `<svg viewBox="0 0 80 50">${keycap(26, '⇧', 'k-lock', 28)}</svg>`],
    ['F-keys, Home, End', 'Hold fn', `<svg viewBox="0 0 80 50">${keycap(8, 'fn', 'k-hold')}<g class="kc fkey"><rect x="40" y="13" width="30" height="22" rx="4"/><text x="55" y="28.5" class="f-a">☀︎</text><text x="55" y="28.5" class="f-b">F1</text></g></svg>`],
    ['Dictation, emoji', 'Long-press 🌐', `<svg viewBox="0 0 80 50">${keycap(10, '🌐', 'k-long', 26)}<g class="g-ios"><rect x="44" y="12" width="28" height="24" rx="4"/><text x="58" y="29">🎙</text></g></svg>`],
    ['These settings', 'The ⚙︎ key', `<svg viewBox="0 0 80 50">${keycap(29, '⚙︎', 'k-tap1')}</svg>`],
  ],
};

function gestures() {
  return Object.entries(GESTURES).map(([group, items]) => `<div class="group"><h3>${group === 'Trackpad' ? 'Gestures · Trackpad' : group}</h3>
    <div class="gestures">${items.map(([t, sub, art]) => `<div class="gesture"><div class="gart">${art}</div><b>${t}</b><small>${sub}</small></div>`).join('')}</div></div>`).join('');
}

function seg(key, label, options) {
  return `<div class="item"><span class="l">${label}</span><div class="seg" data-seg="${key}">${options
    .map(([v, t]) => `<button type="button" data-val="${v}" class="${settings[key] === v ? 'on' : ''}">${t}</button>`)
    .join('')}</div></div>`;
}

const FMT = {
  tracking: (v) => `${(+v).toFixed(1)}×`,
  scrollSpeed: (v) => `${(+v).toFixed(1)}×`,
  volume: (v) => `${Math.round(v * 100)}%`,
  hinge: (v) => `${Math.round(v * 100)}%`,
  hingePad: (v) => `${Math.round(v * 100)}%`,
};

export class Sheet {
  constructor(el, actions) {
    this.el = el;
    this.actions = actions;
    this.info = null;
    el.addEventListener('click', (e) => {
      if (e.target === el) return this.close();
      const act = e.target.closest('[data-act]')?.dataset.act;
      if (act) {
        if (act === 'close') this.close();
        else this.actions[act]?.();
        return;
      }
      const d = e.target.closest('[data-display]');
      if (d) {
        this.actions.display?.(+d.dataset.display);
        for (const x of d.parentElement.children) x.classList.toggle('on', x === d);
        return;
      }
      const b = e.target.closest('[data-seg] button');
      if (b) {
        const key = b.parentElement.dataset.seg;
        const v = b.dataset.val;
        setSetting(key, v === 'true' ? true : v === 'false' ? false : v);
        for (const x of b.parentElement.children) x.classList.toggle('on', x === b);
        if (key === 'layout' || key === 'screenTouch' || key === 'foldCloses') {
          // Which of the options below apply depends on the layout.
          const p = this.el.querySelector('.panel'), y = p?.scrollTop || 0;
          this.render();
          const q = this.el.querySelector('.panel');
          if (q) q.scrollTop = y;
        }
      }
    });
    el.addEventListener('input', (e) => {
      const t = e.target, key = t.dataset?.k;
      if (!key) return;
      if (t.type === 'checkbox') {
        setSetting(key, t.checked);
        if (key === 'sounds') this.update(this.info); // the volume goes with the clicks
      }
      else if (t.type === 'range') {
        setSetting(key, +t.value);
        const v = el.querySelector(`[data-v="${key}"]`);
        if (v) v.textContent = (FMT[key] || ((x) => x))(t.value);
      }
    });
  }

  get isOpen() { return !this.el.hidden; }

  open() {
    this.render();
    this.el.hidden = false;
    setSetting('sheetSeen', true);
  }

  close() {
    this.el.hidden = true;
  }

  update(info) {
    this.info = info;
    if (this.isOpen) {
      const scroll = this.el.querySelector('.panel')?.scrollTop || 0;
      this.render();
      const p = this.el.querySelector('.panel');
      if (p) p.scrollTop = scroll;
    }
  }

  render() {
    const i = this.info || {};
    const mac = i.mac || {};
    const disp = i.display || {};
    const pt = disp.pt ? `${Math.round(disp.pt[0])} × ${Math.round(disp.pt[1])}` : '';
    const nano = settings.macDisplay === 'nano';
    const displays = !nano && (i.displays || []).length > 1
      ? `<div class="item"><span class="l">Show</span><div class="seg">${i.displays
        .map((d) => `<button type="button" data-display="${d.i}" class="${d.i === i.displayIndex ? 'on' : ''}">${esc(d.main ? 'Built-in' : d.name)}</button>`)
        .join('')}</div></div>`
      : '';
    const conn = i.connected
      ? `Connected to ${esc(mac.name || 'your Mac')}${i.rtt ? ` · ${Math.round(i.rtt)} ms` : ''}`
      : 'Not connected';
    this.el.innerHTML = `
<div class="panel">
  <header><h2>Settings</h2><button type="button" class="x" data-act="close" aria-label="Close settings"><svg viewBox="0 0 16 16" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg></button></header>
  <div class="about">
    <img src="icon-180.png" alt="">
    <div>
      <div class="t">Duo Mac</div>
      <div class="d">Fold-inch, 2026 · Duo edition<br>
        Brain: ${esc(mac.name || 'your Mac')}${mac.chip ? ` (${esc(mac.chip)}${mac.memory ? `, ${mac.memory} GB` : ''})` : ''}<br>
        ${esc(mac.os || '')}${pt ? ` · Display ${pt}` : ''}${i.layout ? `<br>Keyboard: ${esc(i.layout)}` : ''}
        ${i.test ? '<br><b style="color:#ffb340">Test pattern mode</b>' : ''}</div>
    </div>
  </div>

  <div class="group"><h3>Trackpad</h3><div class="box">
    ${slider('tracking', 'Tracking speed', 0.4, 3, 0.1, FMT.tracking)}
    ${slider('scrollSpeed', 'Scrolling speed', 0.4, 3, 0.1, FMT.scrollSpeed)}
    ${cards('naturalScroll', 'Scroll direction', [['true', 'Natural', scrollArt(true)], ['false', 'Inverted', scrollArt(false)]], 'Swipe up on the trackpad and…')}
  </div></div>

  <div class="group"><h3>Keyboard</h3><div class="box">
    ${toggle('sounds', 'Key clicks')}
    ${settings.sounds ? slider('volume', 'Volume', 0, 1, 0.05, FMT.volume) : ''}
    ${toggle('haptics', 'Haptic taps', 'Keys and trackpad taps, felt as you lift your finger')}
    ${toggle('fnStandard', 'Use F1, F2, etc. as standard function keys')}
    <div class="item"><span class="l">iPhone keyboard<small>Dictation, emoji, accents. Or hold the 🌐 fn key.</small></span>
      <button type="button" class="btn" data-act="iosKeyboard">Type…</button></div>
  </div></div>

  <div class="group"><h3>Sound</h3><div class="box">
    ${toggle('macSound', 'Play the Mac’s sound here', 'Music, videos, calls and alerts from the Mac, on this iPhone’s speaker')}
    <div class="item icon-item"><span class="ico mic-ico"><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="3" width="6" height="11" rx="3" fill="currentColor"/><path d="M6 11a6 6 0 0 0 12 0M12 17v3.5M9 20.5h6" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg></span>
      <label for="s-mic">Use this iPhone’s microphone${i.micInstalled === false
        ? `<small class="warn">⚠︎ Not on your Mac yet. ${i.micUpdate ? 'Update' : 'Add'} the Duo Mac Microphone there: menu bar › Settings… › General › ${i.micUpdate ? 'Update…' : 'Install…'}</small>`
        : '<small>Dictation, calls and voice modes on the Mac hear this iPhone. It only records while a Mac app is listening.</small>'}</label>
      <input type="checkbox" switch id="s-mic" data-k="mic" ${settings.mic ? 'checked' : ''}></div>
  </div></div>

  <div class="group"><h3>Display</h3><div class="box">
    ${cards('macDisplay', 'Mac screen', [['nano', 'Fill', fillArt], ['mirror', 'Mirror as is', mirrorArt]])}
    ${nano ? cards('nanoSize', 'Desktop size', [['large', 'Larger text', sizeArt(4.2)], ['default', 'Default', sizeArt(3)], ['more', 'More space', sizeArt(2.1)]]) : ''}
    ${nano && document.getElementById('app')?.classList.contains('tall-top')
      ? cards('topEdge', 'Top edge', [['clear', 'Below the clock', topArt(false)], ['full', 'Full screen', topArt(true)]], 'Full screen: the clock covers the Mac’s top-right corner')
      : ''}
    ${nano ? `<div class="item"><span class="l"><small>The Mac gets a display shaped exactly like this screen, and its own screen mirrors it (with black bars). Your windows may rearrange when it switches on or off.</small></span></div>` : ''}
    ${displays}
    ${cards('quality', 'Quality', [['fast', 'Fast', qualityArt('🐇', 1.6)], ['balanced', 'Balanced', qualityArt('🐈', 0.6)], ['sharp', 'Sharp', qualityArt('🐌', 0)]], 'Faster and softer, or slower and crisper')}
    ${toggle('video', 'Video compression', 'H.264: smoother on slow connections, less data. Turn off if the picture looks wrong.')}
    ${cards('layout', 'Layout', [['laptop', 'Laptop', duoArt(0.5)], ['trackpad', 'Trackpad', duoArt(0.5, true)], ['screen', 'Screen only', duoArt(1)]],
      `${{ laptop: 'Keyboard and trackpad below the screen.', trackpad: 'Just a big trackpad below the screen. Tap a text field, or ⌨︎, to type.', screen: 'All screen. Tap a text field, or ⌨︎, to type.' }[settings.layout] || ''} With the iPhone upright. Turned sideways${settings.seenDuo ? ' or folded' : ''}, it’s all screen and the whole screen is a trackpad.`)}
    ${settings.layout === 'screen'
      ? cards('screenTouch', 'Touching the screen', [['touch', 'Touch screen', touchArt(false)], ['trackpad', 'Trackpad', touchArt(true)]],
        settings.screenTouch === 'trackpad'
          ? 'The whole screen is a trackpad: slide to move the pointer, tap to click, two fingers scroll, three or four swipe.'
          : 'Tap where you want to click, drag to drag. Two fingers scroll, three or four swipe.')
      : toggle('touchscreen', 'Touch screen', 'Tap the screen to click there')}
    ${settings.layout === 'laptop' ? cards('theme', 'Finish', [['spaceblack', 'Space Black', keyboardArt(false)], ['silver', 'Silver', keyboardArt(true)]]) : ''}
    ${settings.layout !== 'screen' ? splitSlider() : ''}
    ${cards('notch', 'Notch', [['false', 'No notch', notchArt(false)], ['true', 'Notch', notchArt(true)]],
      settings.topEdge === 'full' && document.getElementById('app')?.classList.contains('tall-top') ? 'Purely cosmetic. Not shown in Full screen (no room above the screen).' : 'Purely cosmetic')}
    ${settings.seenDuo ? cards('foldCloses', 'When folded', [['true', 'Closed lid', foldArt(true)], ['false', 'Keep using it', foldArt(false)]],
      settings.foldCloses ? 'Shows a closed MacBook and lets the Mac sleep.' : 'All screen, and the whole screen is a trackpad.') : ''}
    ${toggle('chime', 'Startup chime')}
    ${toggle('stats', 'Show stats', 'Frame rate, bandwidth, latency')}
    <div class="item"><span class="l">Screen</span>
      <button type="button" class="btn" data-act="resetZoom">Reset zoom</button>
      <button type="button" class="btn" data-act="refresh">Refresh</button></div>
  </div></div>

  ${i.device ? `<div class="group"><h3>Security</h3><div class="box">
    <div class="item"><span class="l">${esc(i.device.name || 'This iPhone')}<small>Paired with ${esc(i.device.mac || mac.name || 'your Mac')} · unlocks with ${[i.device.passkey ? 'passkey' : '', i.device.pin ? 'PIN' : ''].filter(Boolean).join(' or ') || '—'}</small></span>
      <button type="button" class="btn" data-act="lock">Lock</button></div>
    <div class="item"><span class="l">${i.device.pin ? 'PIN' : 'Backup PIN'}<small>For when the passkey isn’t available.</small></span>
      <button type="button" class="btn" data-act="changePin">${i.device.pin ? 'Change…' : 'Add…'}</button></div>
    <div class="item"><span class="l">Unpair this iPhone<small>To use it again you’ll pair it at the Mac.</small></span>
      <button type="button" class="btn" data-act="forget">Unpair…</button></div>
  </div></div>` : ''}

  <div class="group"><h3>Connection</h3><div class="box">
    <div class="item"><span class="l">${conn}<small class="mono">${esc(location.host)}</small></span>
      <button type="button" class="btn blue" data-act="reconnect">Reconnect</button></div>
    <div class="item"><span class="l">End session<small>Disconnects and gives the Mac its normal screen back right away.</small></span>
      <button type="button" class="btn" data-act="endSession">End</button></div>
  </div></div>

  ${gestures()}
</div>`;
  }
}
