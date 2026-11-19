// "System Settings" for the Duo: opened with the gear key (top right of the keyboard, where Touch ID would be).
import { settings, setSetting } from './settings.js';
import { native } from './native.js';
import { ICONS } from './appkeys.js';

/** A switch with a coloured icon in front, like iOS Settings. */
function iconToggle(key, label, note, icon, color) {
  return `<div class="item icon-item"><span class="ico" style="background:${color}">${icon}</span>
    <label for="s-${key}">${label}${note ? `<small>${note}</small>` : ''}</label>
    <input type="checkbox" switch id="s-${key}" data-k="${key}" ${settings[key] ? 'checked' : ''}></div>`;
}
const I24 = (body) => `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round">${body}</svg>`;
const SPEAKER_ICON = I24('<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z" fill="currentColor" stroke="none"/><path d="M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11"/>');
const CHIME_ICON = I24('<path d="M9 18V6l10-2v12"/><circle cx="6.5" cy="18" r="2.5" fill="currentColor" stroke="none"/><circle cx="16.5" cy="16" r="2.5" fill="currentColor" stroke="none"/>');
const STATS_ICON = I24('<path d="M5 19V12M10 19V7M15 19v-5M20 19V9"/>');
const PAD_ICON = I24('<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M12 15v4"/>');
const CLICK_ICON = I24('<rect x="3" y="7" width="18" height="11" rx="2"/><path d="M7 11h.5M10.5 11h.5M14 11h.5M8 14.5h8"/>');
const HAPTIC_ICON = I24('<rect x="8" y="3" width="8" height="18" rx="2"/><path d="M4 9v6M20 9v6"/>');
const CLIP_ICON = I24('<rect x="6" y="4" width="12" height="17" rx="2"/><path d="M9.5 4V3h5v1M9 10h6M9 14h4"/>');

/** The keyboard's top row: the Mac app's keys (icons), or F1–F12. */
function topRowArt(fkeys) {
  const n = 5, kw = 12.4, gap = 1.6, x0 = 4.5;
  const keys = [...Array(n)].map((_, i) => `<rect x="${x0 + i * (kw + gap)}" y="13" width="${kw}" height="14" rx="2.2" class="win"/>`).join('');
  const cx = (i) => x0 + i * (kw + gap) + kw / 2;
  const marks = fkeys
    ? [...Array(n)].map((_, i) => `<text x="${cx(i)}" y="22.5" class="fk" text-anchor="middle">F${i + 1}</text>`).join('')
    : [`M${cx(0) + 1.5} 17l-3 3 3 3`, `M${cx(1) - 3} 20a3 3 0 1 0 1-2.2M${cx(1) - 2} 16.8v1.6h1.6`, `M${cx(2) - 3} 20h6M${cx(2)} 17v6`,
      `M${cx(3) - 2.5} 17.5h5v5h-5z`, `M${cx(4) - 2} 17.5h4v5h-4zM${cx(4) - 1} 17.5v-1h2v1`].map((d) => `<path d="${d}" class="km"/>`).join('');
  const below = [...Array(n)].map((_, i) => `<rect x="${x0 + i * (kw + gap)}" y="30" width="${kw}" height="12" rx="2.2" class="dk"/>`).join('');
  return `<svg viewBox="0 0 80 50">${keys}${marks}${below}</svg>`;
}
/** The trackpad, with or without the shortcut buttons on each side. */
function padArt(withButtons) {
  const side = (x) => [0, 1, 2].map((i) => `<rect x="${x}" y="${11 + i * 11}" width="8" height="8" rx="2" class="win"/>`).join('');
  return `<svg viewBox="0 0 80 50"><rect x="${withButtons ? 17 : 8}" y="7" width="${withButtons ? 46 : 64}" height="36" rx="5" class="frame"/>
    ${withButtons ? side(5) + side(67) : ''}</svg>`;
}
/** Dictation, as it looks while you use it. Apple's: you speak and the words appear in the text one by one,
 *  the cursor following. Whisper's: it records while you speak (red dot, sound), then the whole text appears
 *  at once, in any language (the globe). */
function dictArt(whisper) {
  const mic = '<rect x="5.5" y="12" width="9" height="15" rx="4.5" class="mic"/><path d="M2.5 22a7.5 7.5 0 0 0 15 0M10 29.5v5M6 34.5h8" class="km"/>';
  const box = '<rect x="21" y="7" width="56" height="36" rx="6" class="frame"/>';
  return whisper
    ? `<svg viewBox="0 0 80 50">${mic}<circle cx="15" cy="10" r="3" class="rec"/>${box}
       <path d="M30 25v0M35 21v8M40 17v16M45 20v10M50 15v20M55 21v8M60 18v14M65 23v4M70 25v0" class="wave dw-rec"/>
       <g class="dw-all"><rect x="27" y="14" width="44" height="5" rx="2.5" class="ln"/><rect x="27" y="23" width="38" height="5" rx="2.5" class="ln"/><rect x="27" y="32" width="24" height="5" rx="2.5" class="ln"/></g>
       <g class="globe"><circle cx="71" cy="37" r="5"/><path d="M66 37h10M71 32c-2.6 3-2.6 7 0 10M71 32c2.6 3 2.6 7 0 10"/></g></svg>`
    : `<svg viewBox="0 0 80 50">${mic}${box}
       <rect x="27" y="14" width="15" height="5" rx="2.5" class="ln dw-1"/><rect x="44" y="14" width="10" height="5" rx="2.5" class="ln dw-2"/>
       <rect x="56" y="14" width="15" height="5" rx="2.5" class="ln dw-3"/><rect x="27" y="24" width="13" height="5" rx="2.5" class="ln dw-4"/>
       <rect x="41.5" y="23" width="2" height="7" class="caret dw-caret"/></svg>`;
}

/** Touching the screen in the Laptop/Trackpad layouts: a tap clicks there, or nothing. */
function tapArt(on) {
  return `<svg viewBox="0 0 80 50"><rect x="14" y="2" width="52" height="46" rx="5" class="frame"/>${desk(16, 4, 48, 42)}
    <rect x="24" y="13" width="32" height="22" rx="1.5" class="win"/>
    ${on ? '<circle cx="42" cy="24" r="7" class="tring"/><circle cx="42" cy="24" r="4.5" class="tip"/>'
      : '<circle cx="42" cy="24" r="4.5" class="tip" opacity=".35"/><path d="M34 32 50 16" class="cross"/>'}</svg>`;
}

/** The volume of the key and trackpad clicks (one for both), under their switches. */
function volumeRow() {
  return `<div class="item icon-item stack"><div class="vol-row"><span class="vol-ico">${I24('<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z" fill="currentColor" stroke="none"/><path d="M15.5 9a4 4 0 0 1 0 6"/>')}</span>
    <input type="range" data-k="volume" min="0" max="1" step="0.05" value="${settings.volume}" aria-label="Click volume"><span class="val" data-v="volume">${FMT.volume(settings.volume)}</span></div></div>`;
}

/** Full screen: which buttons show next to the settings one (which always does). Tap to turn each on or off. */
const TOOL_BUTTONS = [['command', 'Hold ⌘'], ['copy', 'Copy'], ['paste', 'Paste'], ['undo', 'Undo'], ['redo', 'Redo'], ['screenshot', 'Screenshot'], ['dictate', 'Dictate'], ['keyboard', 'Keyboard']];
function toolButtonsRow() {
  const on = new Set(String(settings.toolButtons).split(','));
  const gear = '<svg viewBox="0 0 16 16" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" d="M12.95 6.79L14.62 7L14.62 9L12.95 9.21L12.36 10.65L13.39 11.98L11.98 13.39L10.65 12.36L9.21 12.95L9 14.62L7 14.62L6.79 12.95L5.35 12.36L4.02 13.39L2.61 11.98L3.64 10.65L3.05 9.21L1.38 9L1.38 7L3.05 6.79L3.64 5.35L2.61 4.02L4.02 2.61L5.35 3.64L6.79 3.05L7 1.38L9 1.38L9.21 3.05L10.65 3.64L11.98 2.61L13.39 4.02L12.36 5.35Z"/><circle cx="8" cy="8" r="2.1" fill="none" stroke="currentColor" stroke-width="1.3"/></svg>';
  return `<div class="item cards-item"><span class="l">Floating buttons<small>Over the screen in Screen only, sideways or folded. Tap one to show or hide it; ⚙︎ always stays.</small></span>
    <div class="tiles">${TOOL_BUTTONS.map(([id, t]) => `<button type="button" data-tool="${id}" class="tile ${on.has(id) ? 'on' : ''}"><span class="ti">${ICONS[id] || ''}</span><span class="tl">${t}</span></button>`).join('')}
      <span class="tile on fixed"><span class="ti">${gear}</span><span class="tl">Settings</span></span></div></div>`;
}

/** The iPhone app: Apple's dictation or Whisper's. Whisper's model downloads only when you say so. */
function dictationRow(w) {
  const whisper = settings.dictationEngine === 'whisper';
  const mb = Math.round((w?.bytes || 632e6) / 1e6);
  let note = 'Fast, shows the words as you speak; in the iPhone’s language.', btn = '';
  if (whisper) {
    const st = w?.state;
    note = 'Most accurate, any language; types it all when you stop.';
    if (st === 'ready') note += ' Ready.';
    else if (st === 'downloading') note = w.pct >= 100 ? 'Preparing the model (the first time takes a few minutes)…' : `Downloading the model: ${w.pct}%.`;
    else if (st === 'loading') note = 'Preparing the model…';
    else if (st === 'wifi') { note = `Waiting for Wi-Fi to download the model (${mb} MB). Apple’s is used meanwhile.`; btn = '<button type="button" class="btn" data-act="whisperCellular">Use Mobile Data</button>'; }
    else if (st === 'failed') { note = 'The model couldn’t be loaded; Apple’s is used.'; btn = '<button type="button" class="btn" data-act="whisperDownload">Try Again</button>'; }
    else if (w?.downloaded) note += ' It loads the first time you dictate (Apple’s meanwhile).';
    else { note += ` Its model is a ${mb} MB download, once, on Wi-Fi. Apple’s is used until then.`; btn = '<button type="button" class="btn blue" data-act="whisperDownload">Download</button>'; }
  }
  return cards('dictationEngine', 'Dictation', [
    ['apple', 'Apple<small class="res">types as you speak</small>', dictArt(false)],
    ['whisper', 'Whisper<small class="res">any language, at the end</small>', dictArt(true)],
  ], note)
    + (btn ? `<div class="item"><span class="l"><small>Whisper’s model</small></span>${btn}</div>` : '');
}

/** The iPhone app: the Macs it connects to; it opens the one marked until you switch. */
function macsGroup(m) {
  const label = (x) => esc(x.name || x.host.split('.')[0]);
  return `<div class="group"><h3>Macs</h3><div class="box">
    ${m.list.map((x) => `<div class="item mac-item"><span class="macpic">${x.picture ? `<img src="${esc(x.picture)}" alt="">` : macPicture(x)}</span><span class="l">${label(x)}<small>${esc(x.product || x.host.split('.')[0])}</small></span>
      ${x.current ? '<span class="state on">In use</span>'
        : `<button type="button" class="btn blue" data-mac-open="${esc(x.host)}">Switch</button><button type="button" class="btn" data-mac-remove="${esc(x.host)}">Remove</button>`}</div>`).join('')}
    <div class="item"><span class="l">Add a Mac<small>On that Mac: Duo Mac › Add iPhone…, then scan its QR code. Or type its name as the Tailscale app lists it.</small></span>
      <button type="button" class="btn blue" data-act="macScan">Scan…</button><button type="button" class="btn" data-act="macType">Type…</button></div>
  </div></div>`;
}

/** Makes `a`'s children look like `b`'s, touching only the nodes that differ. */
function patchChildren(a, b) {
  const an = [...a.childNodes], bn = [...b.childNodes];
  if (an.length !== bn.length) return a.replaceChildren(...bn);
  an.forEach((n, i) => patch(n, bn[i]));
}
function patch(a, b) {
  if (a.nodeType !== b.nodeType || a.nodeName !== b.nodeName) return a.replaceWith(b);
  if (a.nodeType !== 1) { if (a.nodeValue !== b.nodeValue) a.nodeValue = b.nodeValue; return; }
  if (a.isEqualNode(b)) return;
  for (const at of [...a.attributes]) if (!b.hasAttribute(at.name)) a.removeAttribute(at.name);
  let changed = false;
  for (const at of [...b.attributes]) if (a.getAttribute(at.name) !== at.value) { a.setAttribute(at.name, at.value); changed = true; }
  // A control shows its current value, not its attribute: set it too (unless it's being used).
  if (changed && (a.tagName === 'INPUT' || a.tagName === 'SELECT') && a !== document.activeElement) {
    a.value = b.value;
    a.checked = b.checked;
  }
  patchChildren(a, b);
}

/** A small picture of the Mac: from its model, else its name ("Fabio's iMac"); a MacBook if neither says. */
function macPicture(x) {
  const s = `${x.product || ''} ${x.name || ''} ${x.host}`.toLowerCase();
  const kind = /imac/.test(s) ? 'imac' : /mini/.test(s) ? 'mini' : /studio/.test(s) ? 'studio'
    : /mac pro|macpro/.test(s) && !/book/.test(s) ? 'pro' : 'laptop';
  const p = {
    laptop: '<rect x="7" y="5" width="26" height="17" rx="2"/><path d="M3 25.5h34l-1.5 2h-31z" fill="currentColor" stroke="none"/><rect x="9.5" y="7.5" width="21" height="12" rx=".5" class="scr"/>',
    imac: '<rect x="5" y="3" width="30" height="21" rx="2"/><rect x="7" y="5" width="26" height="15" rx=".5" class="scr"/><path d="M16.5 24l-1.2 5h9.4l-1.2-5"/><path d="M13 29.5h14"/>',
    mini: '<rect x="5" y="16" width="30" height="9" rx="3"/><path d="M8 25.5h24"/><circle cx="30" cy="20.5" r=".9" fill="currentColor" stroke="none"/>',
    studio: '<rect x="9" y="11" width="22" height="16" rx="3"/><path d="M13 22h3M18 22h1"/><path d="M12 27.5h16"/>',
    pro: '<rect x="11" y="3" width="18" height="26" rx="2"/><path d="M15 8h10M15 12h10M15 16h10M15 20h10M15 24h10" stroke-dasharray="1.5 1.5"/>',
  }[kind];
  return `<svg viewBox="0 0 40 32" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round" stroke-linecap="round">${p}</svg>`;
}

/** The iPhone app's own Tailscale (ios/DuoMac/Tailnet.swift). */
function tailnetRow(t) {
  const [note, btn] = !t.enabled ? ['Off: the Tailscale app’s VPN is needed away from the Mac’s network.', '<button type="button" class="btn" data-act="tailnetOn">Turn On</button>']
    : t.state === 'running' ? ['On: reaches the Mac without the Tailscale VPN.', '<button type="button" class="btn" data-act="tailnetOff">Turn Off</button>']
    : t.state === 'needs-login' ? ['Sign in once, and the Tailscale VPN can stay off.', '<button type="button" class="btn blue" data-act="tailnetLogin">Sign In…</button>']
    : t.state === 'needs-approval' ? ['Signed in; waiting for approval in the Tailscale admin console (Machines › duo-mac-iphone › Approve).', '']
    : t.state === 'failed' ? ['Didn’t start. Turn it off and on again.', '<button type="button" class="btn" data-act="tailnetOff">Turn Off</button>']
    : ['Starting…', ''];
  return `<div class="item"><span class="l">Tailscale in this app<small>${note}</small></span>${btn}</div>`;
}

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

// Tailscale's relay regions near here, by the code the Mac reports.
const RELAYS = { fra: 'Frankfurt', ams: 'Amsterdam', par: 'Paris', lhr: 'London', mad: 'Madrid', waw: 'Warsaw', nue: 'Nuremberg', hel: 'Helsinki' };

function toggle(key, label, note = '') {
  return `<div class="item"><label for="s-${key}">${label}${note ? `<small>${note}</small>` : ''}</label>
    <input type="checkbox" switch id="s-${key}" data-k="${key}" ${settings[key] ? 'checked' : ''}></div>`;
}

function slider(key, label, min, max, step, fmt = (v) => `${v}×`) {
  return `<div class="item"><span class="l">${label}</span>
    <input type="range" data-k="${key}" aria-label="${label}" min="${min}" max="${max}" step="${step}" value="${settings[key] ?? (key === 'hinge' ? (innerHeight / innerWidth > 1.8 ? 0.56 : 0.5) : 1)}">
    <span class="val" data-v="${key}">${fmt(settings[key] ?? (key === 'hinge' ? (innerHeight / innerWidth > 1.8 ? 0.56 : 0.5) : 1))}</span></div>`;
}

/** Picture cards (like System Settings' appearance picker): options are [value, title, art]. */
function cards(key, label, options, note = '') {
  return `<div class="item cards-item"><span class="l">${label}${note ? `<small>${note}</small>` : ''}</span>
    <div class="cards" data-seg="${key}">${options
    .map(([v, t, art]) => `<button type="button" data-val="${v}" aria-pressed="${String(settings[key]) === v}" class="card ${String(settings[key]) === v ? 'on' : ''}"><span class="art" aria-hidden="true">${art}</span><span class="ct">${t}</span></button>`)
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
function duoArt(share, padOnly = false) { // padOnly: true = Trackpad layout, 'kb' = Keyboard layout
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
    const kbOnly = padOnly === 'kb';
    const kTop = Y + sh + 2.5, kH = kbOnly ? H - sh - 5 : padOnly ? -1.5 : (H - sh) * 0.55, rows = Math.max(2, Math.min(5, Math.round(kH / 3.4)));
    const rh = kH / rows;
    if (!padOnly || kbOnly) for (let r = 0; r < rows; r++) for (let i = 0; i < 8; i++) {
      out += `<rect x="${X + 3 + i * 4.3}" y="${(kTop + r * rh).toFixed(1)}" width="3.5" height="${(rh - 0.9).toFixed(1)}" rx="0.6" class="k"/>`;
    }
    const tTop = kTop + kH + 1.5, tH = Y + H - 2.5 - tTop;
    // Trackpad layout: the pad fills the half; laptop: a MacBook-ish pad under the keys.
    if (tH > 3 && !kbOnly) out += padOnly
      ? `<rect x="${X + 3}" y="${tTop.toFixed(1)}" width="${W - 6}" height="${tH.toFixed(1)}" rx="2" class="pad"/>`
      : `<rect x="${X + 10}" y="${tTop.toFixed(1)}" width="${W - 20}" height="${tH.toFixed(1)}" rx="1.4" class="pad"/>`;
  }
  return out + '</svg>';
}

/** The split in use when it's automatic (main.js sets it: the layout's own, or the fold's). */
export let autoSplit = null;
export function setAutoSplit(f) { autoSplit = f; }

function splitSlider() {
  // Laptop and Trackpad layouts each remember their own split.
  const key = { trackpad: 'hingePad', keyboard: 'hingeKb' }[settings.layout] || 'hinge';
  const v = settings[key] ?? autoSplit?.() ?? 0.5;
  // Right to left, so the side with more screen is on the left, like its picture.
  const pad = settings.layout === 'trackpad' ? true : settings.layout === 'keyboard' ? 'kb' : false, what = pad === true ? 'trackpad' : 'keyboard';
  const auto = settings[key] == null;
  return `<div class="item split-item"><span class="l">Screen / ${what} split<small>${auto ? 'Automatic: matches the fold.' : 'Set by hand.'}</small></span>
    ${auto ? '' : '<button type="button" class="btn" data-act="splitAuto">Automatic</button>'}
    <div class="split"><figure>${duoArt(0.72, pad)}<figcaption>More screen</figcaption></figure>
      <div class="split-mid"><input type="range" dir="rtl" data-k="${key}" aria-label="Screen share" min="0.25" max="0.75" step="0.005" value="${v}">
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
    ['Drag', 'Hold still, then slide', pad(`<rect x="24" y="12" width="14" height="10" rx="2" class="gwin g-dragwin"/>${finger(31, 31, 'g-drag')}`)],
    ['Right-click', 'Tap with 2 fingers', pad(finger(33, 25, 'g-tap') + finger(47, 25, 'g-tap'))],
    ['Scroll', 'Slide 2 fingers', pad(`<g class="g-scroll">${finger(33, 25)}${finger(47, 25)}</g>`)],
    ['Zoom in the app', 'Pinch', pad(finger(36, 27, 'g-pinch-l') + finger(44, 23, 'g-pinch-r'))],
    ['Mission Control', '3 fingers up', pad(`<g class="g-up">${finger(28, 27)}${finger(40, 25)}${finger(52, 27)}</g>`)],
    ['Switch Spaces', '3 fingers sideways', pad(`<g class="g-side">${finger(28, 27)}${finger(40, 25)}${finger(52, 27)}</g>`)],
  ],
  Screen: [
    ['Click right there', 'Tap the screen', pad(`<rect x="10" y="8" width="60" height="4" class="gmb"/>${finger(48, 28, 'g-tap')}`, true)],
    ['Scroll', 'Slide 2 fingers', pad(`<rect x="10" y="8" width="60" height="4" class="gmb"/><g class="g-scroll">${finger(33, 28)}${finger(47, 28)}</g>`, true)],
    ['Zoom in here', 'Pinch (tap the chip to reset)', pad(`<rect x="10" y="8" width="60" height="4" class="gmb"/>${finger(36, 29, 'g-pinch-l')}${finger(44, 25, 'g-pinch-r')}`, true)],
    ['Right-click', 'Tap with 2 fingers', pad(`<rect x="10" y="8" width="60" height="4" class="gmb"/>${finger(33, 28, 'g-tap')}${finger(47, 28, 'g-tap')}`, true)],
  ],
  Keyboard: [
    ['Shortcuts', 'Hold ⌘, tap C', `<svg viewBox="0 0 80 50">${keycap(12, '⌘', 'k-hold')}${keycap(44, 'C', 'k-tap2')}</svg>`],
    ['…or one at a time', 'Tap ⌘, then C', `<svg viewBox="0 0 80 50">${keycap(12, '⌘', 'k-sticky')}${keycap(44, 'C', 'k-tap3')}</svg>`],
    ['Lock a modifier', 'Double-tap it', `<svg viewBox="0 0 80 50">${keycap(26, '⇧', 'k-lock', 28)}</svg>`],
    ['F-keys, Home, End', 'Hold fn', `<svg viewBox="0 0 80 50">${keycap(8, 'fn', 'k-hold')}<g class="kc fkey"><rect x="40" y="13" width="30" height="22" rx="4"/><text x="55" y="28.5" class="f-a">☀︎</text><text x="55" y="28.5" class="f-b">F1</text></g></svg>`],
    ['Dictation, emoji', 'The 🎙 key, top row', `<svg viewBox="0 0 80 50">${keycap(10, '🎙', 'k-tap1', 26)}<g class="g-ios"><rect x="44" y="12" width="28" height="24" rx="4"/><text x="58" y="29">😀</text></g></svg>`],
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
  hingeKb: (v) => `${Math.round(v * 100)}%`,
};

export class Sheet {
  constructor(el, actions) {
    this.el = el;
    this.actions = actions;
    this.info = null;
    el.setAttribute('role', 'dialog');
    el.setAttribute('aria-modal', 'true');
    el.setAttribute('aria-label', 'Settings');
    this.swipeToClose();
    el.addEventListener('click', (e) => {
      if (e.target === el) return this.close();
      const act = e.target.closest('[data-act]')?.dataset.act;
      if (act) {
        if (act === 'close') this.close();
        else this.actions[act]?.();
        return;
      }
      const mo = e.target.closest('[data-mac-open]');
      if (mo) return this.actions.macOpen?.(mo.dataset.macOpen);
      const mr = e.target.closest('[data-mac-remove]');
      if (mr) return this.actions.macRemove?.(mr.dataset.macRemove);
      const tb = e.target.closest('[data-tool]');
      if (tb) {
        const on = new Set(String(settings.toolButtons).split(',').filter(Boolean));
        if (on.has(tb.dataset.tool)) on.delete(tb.dataset.tool); else on.add(tb.dataset.tool);
        setSetting('toolButtons', [...on].join(','));
        tb.classList.toggle('on', on.has(tb.dataset.tool));
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
        for (const x of b.parentElement.children) { x.classList.toggle('on', x === b); x.setAttribute('aria-pressed', String(x === b)); }
        if (key === 'layout' || key === 'screenTouch' || key === 'foldCloses' || key === 'keyboardSize') {
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
        if (key === 'sounds' || key === 'padSounds') this.update(this.info); // the volume goes with the clicks
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
    // A dialog: what's behind it is out of reach (VoiceOver too) until it closes.
    for (const el of this.behind()) el.inert = true;
    this.el.querySelector('.x')?.focus({ preventScroll: true });
  }

  close() {
    this.el.hidden = true;
    for (const el of this.behind()) el.inert = false;
  }

  behind() { return [...(this.el.parentElement?.children || [])].filter((el) => el !== this.el && el.tagName !== 'INPUT'); }

  /** Pulling the header down closes it, like an iOS sheet. */
  swipeToClose() {
    let y0 = null;
    this.el.addEventListener('touchstart', (e) => {
      y0 = e.target.closest('.panel header') && e.touches.length === 1 ? e.touches[0].clientY : null;
    }, { passive: true });
    this.el.addEventListener('touchmove', (e) => {
      if (y0 != null && e.touches[0].clientY - y0 > 70) { y0 = null; this.close(); }
    }, { passive: true });
  }

  update(info) {
    this.info = info;
    if (this.isOpen) {
      this.render();
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
    // Through Tailscale: peer to peer, or bounced off one of its relays (slower).
    const relayed = i.route === 'tailscale' && i.path && !i.path.direct;
    const via = !i.path ? '' : i.path.direct ? `, peer to peer (${i.path.ipv6 ? 'IPv6' : 'IPv4'})`
      : `, relayed via ${RELAYS[i.path.relay] || esc(i.path.relay.toUpperCase()) || 'its servers'}`;
    const route = { local: 'Directly, on the same network', tailscale: `Through Tailscale${via}` }[i.route] || '';
    // Local mode: in use now, set up (it has connected this way before), or still to set up.
    const local = i.route === 'local'
      ? { note: 'Straight to the Mac: the fastest way, and it works without internet.', state: '<span class="state on">In use</span>' }
      : i.localTrusted
        ? { note: 'Set up. Used by itself whenever this iPhone and the Mac are on the same Wi-Fi, or the Mac is on this iPhone’s hotspot.', state: '<span class="state">Not in use</span>' }
        : { note: 'Connects straight to the Mac when you’re on the same network (or it’s on your hotspot), once this iPhone trusts it. One-time setup: install the profile, then Settings › General › About › Certificate Trust Settings › turn on Duo Mac.',
            state: '<button type="button" class="btn" data-act="localSetup">Set up…</button>' };
    const L = settings.layout, keys = L === 'laptop' || L === 'keyboard';
    const layoutNote = `${{ laptop: 'Keyboard and trackpad below the screen.', keyboard: 'Just the keyboard below the screen; the screen is the trackpad.', trackpad: 'Just a big trackpad below the screen. Tap a text field, or ⌨︎, to type.', screen: 'Screen only. Tap a text field, or ⌨︎, to type.' }[L] || ''} With the iPhone upright. Turned sideways${settings.seenDuo ? ' or folded' : ''}, it’s Screen only and the whole screen is a trackpad.`;
    const html = `
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

  ${i.macs ? macsGroup(i.macs) : ''}

  <div class="group"><h3>Layout</h3><div class="box">
    ${cards('layout', 'Layout', [['laptop', 'Laptop', duoArt(0.5)], ['keyboard', 'Keyboard', duoArt(0.64, 'kb')], ['trackpad', 'Trackpad', duoArt(0.5, true)], ['screen', 'Screen only', duoArt(1)]], layoutNote)}
    ${L !== 'screen' ? splitSlider() : ''}
    ${L === 'screen'
      ? cards('screenTouch', 'Touching the screen', [['touch', 'Touch screen', touchArt(false)], ['trackpad', 'Trackpad', touchArt(true)]],
        settings.screenTouch === 'trackpad'
          ? 'The whole screen is a trackpad: slide to move the pointer, tap to click, two fingers scroll, three or four swipe.'
          : 'Tap where you want to click, drag to drag. Two fingers scroll, three or four swipe.')
      : L === 'keyboard' ? '' : cards('touchscreen', 'Touching the screen', [['true', 'Tap to click', tapArt(true)], ['false', 'Ignore', tapArt(false)]], 'A tap on the Mac’s screen clicks there')}
    ${L === 'trackpad'
      ? cards('padButtons', 'Beside the trackpad', [['true', 'Shortcut buttons', padArt(true)], ['false', 'Just the trackpad', padArt(false)]], 'Copy, paste, undo, redo, dictate, return')
      : ''}
    ${L === 'laptop' ? cards('theme', 'Finish', [['spaceblack', 'Space Black', keyboardArt(false)], ['silver', 'Silver', keyboardArt(true)]]) : ''}
    ${settings.seenDuo ? cards('foldCloses', 'When folded', [['true', 'Closed lid', foldArt(true)], ['false', 'Keep using it', foldArt(false)]],
      settings.foldCloses ? 'Shows a closed MacBook and lets the Mac sleep.' : 'Screen only, and the whole screen is a trackpad.') : ''}
    ${toolButtonsRow()}
  </div></div>

  <div class="group"><h3>Mac display</h3><div class="box">
    ${cards('macDisplay', 'Duo display', [['nano', 'On', fillArt], ['mirror', 'Off', mirrorArt]],
      nano ? 'The Mac gets a display shaped exactly like this screen, and its own screen shows the same (with black bars). Windows may move when it switches on or off.'
        : 'The Mac’s own screen as it is, with black bars around it.')}
    ${nano ? cards('nanoSize', 'Desktop size', [['large', 'Larger text', sizeArt(4.2)], ['default', 'Default', sizeArt(3)], ['more', 'More space', sizeArt(2.1)]]
      .map(([v, t, a]) => [v, i.nanoSizes?.[v] ? `${t}<small class="res">${i.nanoSizes[v][0]} × ${i.nanoSizes[v][1]}</small>` : t, a])) : ''}
    ${nano && document.getElementById('app')?.classList.contains('tall-top')
      ? cards('topEdge', 'Top edge', [['clear', 'Below the clock', topArt(false)], ['full', 'Edge to edge', topArt(true)]], 'Edge to edge: the clock covers the Mac’s top-right corner')
      : ''}
    ${displays}
    ${cards('quality', 'Quality', [['fast', 'Fast', qualityArt('🐇', 1.6)], ['balanced', 'Balanced', qualityArt('🐈', 0.6)], ['sharp', 'Sharp', qualityArt('🐌', 0)]],
      native?.maxFPS >= 120 ? 'Faster and softer, or slower and crisper. At 120 frames a second the picture is a little smaller, except with Sharp.' : 'Faster and softer, or slower and crisper')}
  </div></div>

  <div class="group"><h3>Trackpad</h3><div class="box">
    ${slider('tracking', 'Tracking speed', 0.4, 3, 0.1, FMT.tracking)}
    ${slider('scrollSpeed', 'Scrolling speed', 0.4, 3, 0.1, FMT.scrollSpeed)}
    ${cards('naturalScroll', 'Scroll direction', [['true', 'Natural', scrollArt(true)], ['false', 'Inverted', scrollArt(false)]], 'Swipe up on the trackpad and…')}
  </div></div>

  ${keys ? `<div class="group"><h3>Keyboard</h3><div class="box">
    ${cards('fnStandard', 'Top row', [['false', 'Mac app keys', topRowArt(false)], ['true', 'F1–F12', topRowArt(true)]], 'fn switches to the other one')}
  </div></div>` : ''}

  <div class="group"><h3>Sound and haptics</h3><div class="box">
    ${iconToggle('macSound', 'Play the Mac’s sound here', 'Music, videos, calls and alerts from the Mac, on this iPhone’s speaker', SPEAKER_ICON, 'linear-gradient(#5ac8fa, #0a84ff)')}
    <div class="item icon-item"><span class="ico mic-ico"><svg viewBox="0 0 24 24" aria-hidden="true"><rect x="9" y="3" width="6" height="11" rx="3" fill="currentColor"/><path d="M6 11a6 6 0 0 0 12 0M12 17v3.5M9 20.5h6" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg></span>
      <label for="s-mic">Use this iPhone’s microphone${i.micInstalled === false
        ? `<small class="warn">⚠︎ Not on your Mac yet. ${i.micUpdate ? 'Update' : 'Add'} the Duo Mac Microphone there: menu bar › Settings… › General › ${i.micUpdate ? 'Update…' : 'Install…'}</small>`
        : '<small>Dictation, calls and voice modes on the Mac hear this iPhone. It only records while a Mac app is listening.</small>'}</label>
      <input type="checkbox" switch id="s-mic" data-k="mic" ${settings.mic ? 'checked' : ''}></div>
    ${keys ? iconToggle('sounds', 'Key clicks', '', CLICK_ICON, 'linear-gradient(#8e8e93, #636366)') : ''}
    ${iconToggle('padSounds', 'Trackpad and button clicks', 'The click when you hold to drag, and on the shortcut buttons', PAD_ICON, 'linear-gradient(#8e8e93, #636366)')}
    ${(keys && settings.sounds) || settings.padSounds ? volumeRow() : ''}
    ${iconToggle('haptics', 'Haptic taps', 'Keys and trackpad taps', HAPTIC_ICON, 'linear-gradient(#bf5af2, #9b40d0)')}
    ${iconToggle('chime', 'Startup chime', 'The Mac’s chime when it comes on', CHIME_ICON, 'linear-gradient(#ff6482, #ff375f)')}
  </div></div>

  ${native ? `<div class="group"><h3>Dictation and clipboard</h3><div class="box">
    ${dictationRow(i.whisper)}
    ${iconToggle('clipSync', 'Shared clipboard', 'Copy on the Mac, paste on the iPhone, and back. Text and pictures; passwords from a password manager stay on the Mac.', CLIP_ICON, 'linear-gradient(#ffd60a, #ff9f0a)')}
  </div></div>` : ''}

  ${i.device ? `<div class="group"><h3>Security</h3><div class="box">
    <div class="item"><span class="l">${esc(i.device.name || 'This iPhone')}<small>Paired with ${esc(i.device.mac || mac.name || 'your Mac')} · unlocks with ${[i.device.passkey ? 'passkey' : '', i.device.pin ? 'PIN' : ''].filter(Boolean).join(' or ') || '—'}</small></span>
      <button type="button" class="btn" data-act="lock">Lock</button></div>
    <div class="item"><span class="l">${i.device.pin ? 'PIN' : 'Backup PIN'}<small>For when the passkey isn’t available.</small></span>
      <button type="button" class="btn" data-act="changePin">${i.device.pin ? 'Change…' : 'Add…'}</button></div>
    ${settings.seenDuo && !native ? `<div class="item"><span class="l">Touch ID marker<small>Shows where the Touch ID button is while a passkey is asked for.</small></span>
      <button type="button" class="btn" data-act="touchIdSpot">${settings.touchId ? 'Set again…' : 'Set…'}</button></div>` : ''}
    <div class="item"><span class="l">Unpair this iPhone<small>To use it again you’ll pair it at the Mac.</small></span>
      <button type="button" class="btn" data-act="forget">Unpair…</button></div>
  </div></div>` : ''}

  <div class="group"><h3>Connection</h3><div class="box">
    <div class="item"><span class="l">${conn}<small>${route ? `${route} · ` : ''}<span class="mono">${esc(location.host)}</span></small></span>
      ${i.connected ? `<span class="state ${i.route === 'local' ? 'on' : relayed ? 'slow' : 'via'}">${i.route === 'local' ? 'Direct' : relayed ? 'Relayed' : 'Tailscale'}</span>`
        : '<button type="button" class="btn blue" data-act="reconnect">Reconnect</button>'}</div>
    ${i.localReady ? `<div class="item"><span class="l">Same Wi-Fi or hotspot<small>${local.note}</small></span>
      ${local.state}</div>` : ''}
    ${i.tailnet ? tailnetRow(i.tailnet) : ''}
    ${iconToggle('stats', 'Show stats', `<span class="stat-pill">${i.connected ? `${i.fps ?? 0} fps · ${i.kbps ?? 0} KB/s · ${Math.round(i.rtt || 0)} ms` : 'fps · KB/s · ms'}</span>`, STATS_ICON, 'linear-gradient(#30d158, #248a3d)')}
    <div class="item"><span class="l">End session<small>Disconnects and gives the Mac its normal screen back right away.</small></span>
      <button type="button" class="btn" data-act="endSession">End</button></div>
  </div></div>

  <div class="group"><h3>Reset</h3><div class="box">
    <div class="item"><span class="l">Reset all settings<small>Everything on this page goes back to how it came. The pairing with your Mac stays.</small></span>
      <button type="button" class="btn" data-act="resetAll">Reset…</button></div>
  </div></div>

  ${gestures()}
</div>`;
    // Nothing changed (the connection's updates come often): leave it as it is, so nothing blinks.
    if (html === this.html && this.el.firstElementChild) return;
    this.html = html;
    // Open already: change only what changed, so scrolling (and its glide) and pictures carry on.
    if (this.el.querySelector('.panel')) {
      const t = document.createElement('template');
      t.innerHTML = html;
      patchChildren(this.el, t.content);
    } else {
      this.el.innerHTML = html;
    }
  }
}
