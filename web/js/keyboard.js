// A MacBook keyboard (ANSI or ISO, labelled with the Mac's own layout).
//
// Modifiers work three ways: hold one finger on ⌘ and tap C with another (a real chord),
// tap ⌘ then C (one-shot, like sticky keys), or double-tap a modifier to lock it.
// Holding the globe/fn key turns the top row into F1–F12 and arrows into Home/End/Page Up/Down;
// a long press on it opens the iPhone's own keyboard (dictation, emoji…).
import { settings } from './settings.js';
import { addHapticSwitch } from './haptics.js';

export const MOD = { shift: 1, control: 2, option: 4, command: 8 };

// US labels (plain, shift) used until the Mac sends its real layout.
const US = {
  0x32: ['`', '~'], 0x0A: ['§', '±'], 0x12: ['1', '!'], 0x13: ['2', '@'], 0x14: ['3', '#'], 0x15: ['4', '$'],
  0x17: ['5', '%'], 0x16: ['6', '^'], 0x1A: ['7', '&'], 0x1C: ['8', '*'], 0x19: ['9', '('], 0x1D: ['0', ')'],
  0x1B: ['-', '_'], 0x18: ['=', '+'], 0x0C: ['q', 'Q'], 0x0D: ['w', 'W'], 0x0E: ['e', 'E'], 0x0F: ['r', 'R'],
  0x11: ['t', 'T'], 0x10: ['y', 'Y'], 0x20: ['u', 'U'], 0x22: ['i', 'I'], 0x1F: ['o', 'O'], 0x23: ['p', 'P'],
  0x21: ['[', '{'], 0x1E: [']', '}'], 0x2A: ['\\', '|'], 0x00: ['a', 'A'], 0x01: ['s', 'S'], 0x02: ['d', 'D'],
  0x03: ['f', 'F'], 0x05: ['g', 'G'], 0x04: ['h', 'H'], 0x26: ['j', 'J'], 0x28: ['k', 'K'], 0x25: ['l', 'L'],
  0x29: [';', ':'], 0x27: ["'", '"'], 0x06: ['z', 'Z'], 0x07: ['x', 'X'], 0x08: ['c', 'C'], 0x09: ['v', 'V'],
  0x0B: ['b', 'B'], 0x2D: ['n', 'N'], 0x2E: ['m', 'M'], 0x2B: [',', '<'], 0x2F: ['.', '>'], 0x2C: ['/', '?'],
};

const F_CODES = [0, 0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F];

// What the top row does by default (like a MacBook); nx = NX_KEYTYPE media key code.
const FN_DEFS = [
  null,
  { nx: 3, icon: 'brightDown', repeat: true },
  { nx: 2, icon: 'brightUp', repeat: true },
  { act: 'missionControl', icon: 'mission' },
  { act: 'spotlight', icon: 'search' },
  { act: 'iosKeyboard', icon: 'mic' },
  { icon: 'moon' },
  { nx: 18, icon: 'rew' },
  { nx: 16, icon: 'play' },
  { nx: 17, icon: 'ff' },
  { nx: 7, icon: 'mute' },
  { nx: 1, icon: 'volDown', repeat: true },
  { nx: 0, icon: 'volUp', repeat: true },
];

// fn + key, like on a MacBook
const FN_REMAP = { 0x7E: 0x74, 0x7D: 0x79, 0x7B: 0x73, 0x7C: 0x77, 0x33: 0x75 };

const svg = (body, fill = false) =>
  `<svg viewBox="0 0 16 16" fill="${fill ? 'currentColor' : 'none'}" stroke="${fill ? 'none' : 'currentColor'}" ` +
  `stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;

function sun(r, ray) {
  let s = `<circle cx="8" cy="8" r="${r}"/>`;
  for (let i = 0; i < 8; i++) {
    const a = (i * Math.PI) / 4, r1 = r + 1.5, r2 = r + 1.5 + ray;
    s += `<path d="M${(8 + Math.cos(a) * r1).toFixed(2)} ${(8 + Math.sin(a) * r1).toFixed(2)}L${(8 + Math.cos(a) * r2).toFixed(2)} ${(8 + Math.sin(a) * r2).toFixed(2)}"/>`;
  }
  return s;
}

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
  touchid: svg('<path stroke-linejoin="round" d="M12.95 6.79L14.62 7L14.62 9L12.95 9.21L12.36 10.65L13.39 11.98L11.98 13.39L10.65 12.36L9.21 12.95L9 14.62L7 14.62L6.79 12.95L5.35 12.36L4.02 13.39L2.61 11.98L3.64 10.65L3.05 9.21L1.38 9L1.38 7L3.05 6.79L3.64 5.35L2.61 4.02L4.02 2.61L5.35 3.64L6.79 3.05L7 1.38L9 1.38L9.21 3.05L10.65 3.64L11.98 2.61L13.39 4.02L12.36 5.35Z"/><circle cx="8" cy="8" r="2.1"/>'), // settings (where a MacBook has Touch ID)
};

const escapeHTML = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

function rows(iso) {
  const K = (c) => ({ c, w: 1, kind: 'char' });
  const S = (c, w, label, align, extra = {}) => ({ c, w, kind: 'special', label, align, ...extra });
  const M = (c, w, mod, sym, label, align) => ({ c, w, kind: 'mod', mod, sym, label, align });
  const fnRow = [S(0x35, 1.5, 'esc', 'l', { esc: true })];
  for (let n = 1; n <= 12; n++) fnRow.push({ c: F_CODES[n], w: 1, kind: 'fn', n });
  fnRow.push({ c: -1, w: 1, kind: 'power' });
  return [
    fnRow,
    [K(iso ? 0x0A : 0x32), K(0x12), K(0x13), K(0x14), K(0x15), K(0x17), K(0x16), K(0x1A), K(0x1C), K(0x19), K(0x1D),
      K(0x1B), K(0x18), S(0x33, 1.5, 'delete', 'r')],
    [S(0x30, 1.5, 'tab', 'l'), K(0x0C), K(0x0D), K(0x0E), K(0x0F), K(0x11), K(0x10), K(0x20), K(0x22), K(0x1F), K(0x23),
      K(0x21), K(0x1E), iso ? S(0x24, 1, 'return', 'r', { isoTop: true }) : K(0x2A)],
    [{ c: 0x39, w: 1.8, kind: 'caps', label: 'caps lock', align: 'l' }, K(0x00), K(0x01), K(0x02), K(0x03), K(0x05),
      K(0x04), K(0x26), K(0x28), K(0x25), K(0x29), K(0x27),
      ...(iso ? [K(0x2A), S(0x24, 0.7, '', 'r', { isoBottom: true })] : [S(0x24, 1.7, 'return', 'r')])],
    [M(0x38, iso ? 1.3 : 2.3, 'shift', '⇧', 'shift', 'l'), ...(iso ? [K(0x32)] : []), K(0x06), K(0x07), K(0x08), K(0x09),
      K(0x0B), K(0x2D), K(0x2E), K(0x2B), K(0x2F), K(0x2C), M(0x3C, 2.2, 'shift', '⇧', 'shift', 'r')],
    [{ c: 0x3F, w: 1, kind: 'mod', mod: 'fn', globe: true }, M(0x3B, 1, 'control', '⌃', 'control', 'r'),
      M(0x3A, 1, 'option', '⌥', 'option', 'r'), M(0x37, 1.3, 'command', '⌘', 'command', 'r'),
      S(0x31, 4.9, '', 'c', { space: true }), M(0x36, 1.3, 'command', '⌘', 'command', 'l'),
      M(0x3D, 1, 'option', '⌥', 'option', 'l'), { kind: 'arrows', w: 3 }],
  ];
}

const newMod = () => ({ held: 0, latched: false, locked: false, used: false, lastTap: 0, downAt: 0 });

export class Keyboard {
  constructor(root, pop, cb) {
    this.root = root;
    this.pop = pop;
    this.cb = cb;
    this.iso = false;
    this.labels = {};
    this.keys = [];
    this.touches = new Map();
    this.caps = false;
    this.mods = { shift: newMod(), control: newMod(), option: newMod(), command: newMod(), fn: newMod() };
    this.popKey = null;

    root.addEventListener('pointerdown', (e) => {
      const el = e.target.closest('.key');
      if (!el || !root.contains(el)) return;
      e.preventDefault();
      try { el.setPointerCapture(e.pointerId); } catch {}
      const k = this.keys[+el.dataset.i];
      if (!k) return;
      // A primary pointer means no other finger is down: anything still held is stale.
      if (e.isPrimary && this.touches.size) {
        for (const old of this.touches.values()) this.release(old, true);
        this.touches.clear();
      }
      this.touches.set(e.pointerId, k);
      this.press(k);
    });
    const end = (e) => {
      const k = this.touches.get(e.pointerId);
      if (!k) return;
      this.touches.delete(e.pointerId);
      this.release(k, e.type !== 'pointerup');
    };
    root.addEventListener('pointerup', end);
    root.addEventListener('pointercancel', end);
    root.addEventListener('lostpointercapture', end);
    this.build();
  }

  setLayout({ iso, labels }) {
    const changed = !!iso !== this.iso;
    this.iso = !!iso;
    this.labels = labels || {};
    if (changed) this.build();
    else this.refreshLabels();
  }

  keyEl(code) {
    return this.keys.find((k) => k.c === code)?.el;
  }

  // ───── Building ─────

  build() {
    this.releaseAll();
    this.root.textContent = '';
    this.keys = [];
    rows(this.iso).forEach((row, i) => {
      const r = document.createElement('div');
      r.className = i === 0 ? 'row fnrow' : 'row';
      for (const k of row) r.appendChild(k.kind === 'arrows' ? this.makeArrows(k) : this.makeKey(k));
      this.root.appendChild(r);
    });
    const top = this.keys.find((k) => k.isoTop), bot = this.keys.find((k) => k.isoBottom);
    if (top && bot) { top.twin = bot; bot.twin = top; }
    this.refreshLabels();
    this.renderMods();
    this.renderFnRow();
  }

  makeKey(spec) {
    const k = { ...spec };
    const el = document.createElement('div');
    el.className = 'key';
    el.style.setProperty('--w', k.w);
    el.dataset.i = this.keys.length;
    k.el = el;
    switch (k.kind) {
      case 'char':
        el.classList.add('ch');
        el.innerHTML = '<span class="lab"></span>'; // labels change under the finger; the switch must not
        k.lab = el.firstChild;
        break;
      case 'special':
        if (k.esc) { el.classList.add('esc'); el.textContent = 'esc'; }
        else if (k.label) { el.classList.add('word', k.align); el.innerHTML = `<span class="w">${k.label}</span>`; }
        if (k.isoTop) el.classList.add('iso-top');
        if (k.isoBottom) el.classList.add('iso-bot');
        break;
      case 'caps':
        el.classList.add('word', 'l', 'caps');
        el.innerHTML = `<i class="led"></i><span class="w">${k.label}</span>`;
        break;
      case 'mod':
        if (k.globe) {
          el.classList.add('globe');
          el.innerHTML = `<span class="fnl">fn</span>${ICONS.globe.replace('<svg', '<svg class="g"')}`;
        } else {
          el.classList.add('word', k.align);
          el.innerHTML = `<span class="s">${k.sym}</span><span class="w">${k.label}</span>`;
        }
        break;
      case 'fn':
        el.classList.add('fn');
        el.innerHTML = `${ICONS[FN_DEFS[k.n].icon]}<span class="fl">F${k.n}</span>`;
        break;
      case 'power':
        el.classList.add('power');
        el.innerHTML = ICONS.touchid;
        break;
      case 'arrow':
        el.classList.add('arrow');
        el.textContent = k.label;
        break;
    }
    addHapticSwitch(el);
    this.keys.push(k);
    return el;
  }

  makeArrows(spec) {
    const box = document.createElement('div');
    box.className = 'arrows';
    box.style.setProperty('--w', spec.w);
    const A = (c, label) => this.makeKey({ c, w: 1, kind: 'arrow', label });
    const mid = document.createElement('div');
    mid.className = 'mid';
    mid.append(A(0x7E, '▲︎'), A(0x7D, '▼︎'));
    box.append(A(0x7B, '◀︎'), mid, A(0x7C, '▶︎'));
    return box;
  }

  row(code) {
    return this.labels[code] || US[code] || ['', '', '', ''];
  }

  isLetter(code) {
    const r = this.row(code), base = r[0] || '';
    return base.length === 1 && base.toLowerCase() !== base.toUpperCase() && (r[1] || '') === base.toUpperCase();
  }

  layer() {
    return (this.active('shift') ? 1 : 0) + (this.active('option') ? 2 : 0);
  }

  /** The character a key would type right now (for labels and the pop-up). */
  charFor(code) {
    const r = this.row(code);
    let layer = this.layer();
    if (this.caps && this.isLetter(code)) layer |= 1;
    return r[layer] || r[0] || '';
  }

  refreshLabels() {
    const layered = this.layer() > 0 || this.caps;
    for (const k of this.keys) {
      if (k.kind !== 'char') continue;
      const r = this.row(k.c), base = r[0] || '';
      let html;
      if (layered && (this.layer() > 0 || this.isLetter(k.c))) {
        html = `<span class="c">${escapeHTML(this.charFor(k.c))}</span>`;
      } else if (this.isLetter(k.c)) {
        html = `<span class="c">${escapeHTML(base.toUpperCase())}</span>`;
      } else if (r[1] && r[1] !== base) {
        html = `<span class="dual"><span>${escapeHTML(r[1])}</span><span>${escapeHTML(base)}</span></span>`;
      } else {
        html = `<span class="c">${escapeHTML(base)}</span>`;
      }
      if (k.html !== html) {
        k.lab.innerHTML = html;
        k.html = html;
      }
      k.el.classList.toggle('layer', layered && this.layer() > 0);
    }
  }

  renderFnRow() {
    const standard = settings.fnStandard ? !this.active('fn') : this.active('fn');
    for (const k of this.keys) if (k.kind === 'fn') k.el.classList.toggle('flabel', standard);
  }

  renderMods() {
    for (const k of this.keys) {
      if (k.kind !== 'mod') continue;
      const s = this.mods[k.mod];
      k.el.classList.toggle('latched', s.latched && !s.locked);
      k.el.classList.toggle('locked', s.locked);
    }
    const caps = this.keys.find((k) => k.kind === 'caps');
    caps?.el.classList.toggle('on', this.caps);
    this.refreshLabels();
    this.renderFnRow();
  }

  // ───── Modifier state ─────

  active(name) {
    const s = this.mods[name];
    return s.held > 0 || s.latched || s.locked;
  }

  mask() {
    let m = 0;
    if (this.active('shift')) m |= MOD.shift;
    if (this.active('control')) m |= MOD.control;
    if (this.active('option')) m |= MOD.option;
    if (this.active('command')) m |= MOD.command;
    return m;
  }

  markUsed() {
    for (const s of Object.values(this.mods)) if (s.held > 0) s.used = true;
  }

  /** One-shot modifiers end after the next key or click. */
  consumeLatched() {
    let changed = false;
    for (const s of Object.values(this.mods)) {
      if (s.latched) { s.latched = false; changed = true; }
    }
    if (changed) this.renderMods();
  }

  // ───── Pressing ─────

  press(k) {
    k.el.classList.add('pressed');
    k.twin?.el.classList.add('pressed');
    switch (k.kind) {
      case 'mod': {
        const s = this.mods[k.mod];
        s.held++;
        s.used = false;
        s.downAt = performance.now();
        this.cb.feedback?.('mod');
        this.renderMods();
        return;
      }
      case 'caps':
        this.caps = !this.caps;
        this.cb.feedback?.('mod');
        this.renderMods();
        return;
      case 'power':
        this.cb.feedback?.('mod');
        this.cb.onPower?.();
        return;
      case 'fn':
        this.pressFn(k);
        return;
      default:
        this.pressKey(k);
    }
  }

  /** `cancelled`: the touch was interrupted (not a real tap), so modifiers don't latch. */
  release(k, cancelled = false) {
    k.el.classList.remove('pressed');
    k.twin?.el.classList.remove('pressed');
    this.stopRepeat(k);
    if (k.pendingIOS) {
      k.pendingIOS = false;
      if (!cancelled) this.cb.onAction('iosKeyboard'); // iOS only shows its keyboard from a touchend
      return;
    }
    switch (k.kind) {
      case 'mod': {
        const s = this.mods[k.mod];
        s.held = Math.max(0, s.held - 1);
        const now = performance.now();
        if (!s.used && !cancelled) {
          if (k.mod === 'fn' && now - s.downAt > 550) {
            s.latched = false;
            this.cb.onIOSKeyboard?.();
          } else if (s.locked) {
            s.locked = false;
          } else if (s.latched) {
            s.latched = false;
            if (now - s.lastTap < 450) s.locked = true;
          } else {
            s.latched = true;
            s.lastTap = now;
          }
        }
        this.renderMods();
        return;
      }
      case 'caps':
      case 'power':
        return;
      default:
        if (k.down) {
          this.cb.onKey(k.down.code, false, k.down.mask, false);
          k.down = null;
          this.consumeLatched();
        }
        if (this.popKey === k) this.hidePop();
    }
  }

  pressKey(k) {
    let code = k.c;
    if (this.active('fn') && FN_REMAP[code] !== undefined) code = FN_REMAP[code];
    let mask = this.mask();
    if (this.caps && k.kind === 'char' && this.isLetter(k.c)) mask |= MOD.shift;
    this.markUsed();
    k.down = { code, mask };
    this.cb.onKey(code, true, mask, false);
    this.cb.feedback?.(k.space ? 'space' : 'key');
    if (k.kind === 'char' || k.space) this.showPop(k, mask);
    this.startRepeat(k, () => this.cb.onKey(code, true, mask, true));
  }

  pressFn(k) {
    const def = FN_DEFS[k.n];
    const fnHeld = this.active('fn');
    const standard = settings.fnStandard ? !fnHeld : fnHeld;
    this.markUsed();
    this.cb.feedback?.('key');
    if (!standard && def.nx !== undefined) {
      this.cb.onAux(def.nx);
      if (def.repeat) this.startRepeat(k, () => this.cb.onAux(def.nx), 140);
    } else if (!standard && def.act === 'iosKeyboard') {
      k.pendingIOS = true;
    } else if (!standard && def.act) {
      this.cb.onAction(def.act);
    } else {
      const mask = this.mask();
      k.down = { code: k.c, mask };
      this.cb.onKey(k.c, true, mask, false);
      this.startRepeat(k, () => this.cb.onKey(k.c, true, mask, true));
    }
  }

  startRepeat(k, fn, every = 42) {
    this.stopRepeat(k);
    const started = performance.now();
    k.rt = setTimeout(() => {
      k.ri = setInterval(() => {
        if (performance.now() - started > 15000) return this.stopRepeat(k); // safety net
        fn();
      }, every);
    }, 380);
  }

  stopRepeat(k) {
    clearTimeout(k.rt);
    clearInterval(k.ri);
    k.rt = k.ri = 0;
  }

  showPop(k, mask) {
    const prefix = (mask & MOD.control ? '⌃' : '') + (mask & MOD.option && (mask & (MOD.command | MOD.control)) ? '⌥' : '') +
      (mask & MOD.command ? '⌘' : '');
    let ch = k.space ? '␣' : this.charFor(k.c);
    if (prefix) ch = prefix + (this.row(k.c)[0] || ch).toUpperCase();
    if (!ch) return;
    const deck = this.pop.offsetParent || this.root.parentElement;
    const r = k.el.getBoundingClientRect(), d = deck.getBoundingClientRect();
    this.pop.textContent = ch;
    this.pop.style.left = `${r.left + r.width / 2 - d.left}px`;
    this.pop.style.top = `${r.top - d.top - 3}px`;
    this.pop.classList.add('on');
    this.popKey = k;
  }

  hidePop() {
    this.pop.classList.remove('on');
    this.popKey = null;
  }

  /** Let go of everything (app hidden, connection lost…). */
  releaseAll() {
    for (const k of this.touches.values()) this.release(k, true);
    this.touches.clear();
    for (const k of this.keys) {
      this.stopRepeat(k);
      k.el?.classList.remove('pressed');
      if (k.down) {
        this.cb.onKey(k.down.code, false, k.down.mask, false);
        k.down = null;
      }
    }
    for (const s of Object.values(this.mods)) s.held = 0;
    this.hidePop?.();
    if (this.keys.length) this.renderMods();
  }
}
