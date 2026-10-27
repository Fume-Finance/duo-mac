// Duo Mac — wires the screen, keyboard and trackpad to the Mac.
import { settings, setSetting, onSetting, freshInstall, DEFAULTS, upgrade } from './settings.js';
import { Link } from './net.js';
import { loadDevice, saveDevice, forgetDevice, deviceName, passkeysAvailable, createPasskey, getAssertion } from './auth.js';
import { Screen, LidTouch } from './screen.js';
import { Keyboard, MOD } from './keyboard.js';
import { Trackpad } from './trackpad.js';
import { Sheet } from './sheet.js';
import { sound } from './sound.js';
import { haptic, addHapticSwitch } from './haptics.js';
import { showInstall, hideInstall, browserName } from './install.js';
import { Mic } from './mic.js';
import { Speaker } from './speaker.js';
import { MacCursor } from './cursor.js';

const $ = (s) => document.querySelector(s);
const app = $('#app');
const deck = $('#deck');
const overlay = $('#overlay');
const banner = $('#banner');
const statsEl = $('#stats');
const params = new URLSearchParams(location.search);

// ───── Pairing and unlocking (see auth.js and the Mac's Auth.swift) ─────
let device = loadDevice();   // this iPhone's key for the Mac, once paired
let pairCode = (params.get('pair') || '').replace(/[^0-9a-z]/gi, '').toUpperCase();
let ticket = '';             // from the last unlock: reconnecting soon after skips passkey
let authed = false;          // unlocked: may say hello and control the Mac
let need = null;             // the Mac's challenge, while locked
let pairing = null;          // pairing in progress: { passkey }
let passkeyOpts = null;      // while pairing: what passkey needs to make the passkey
let macLabel = '';
let wantPair = false;        // tapped Pair while the link was down
let browserOK = false;       // pair in the browser itself instead of the Home Screen app
let canPasskey = false;
const passkeyReady = passkeysAvailable().then((v) => { canPasskey = v; });

// ───── State ─────
let cfg = null;
let powered = !settings.chime;
let chimed = false;
let everConnected = false;
let failures = 0;
let fatal = null; // a problem that needs the user (bad link, permission…)
let serverStats = null;
let link = null; // created below; declared early so the error logger can use it

// ───── Remote log: phone errors show up in the Mac helper's log ─────
const logQueue = [];
function remoteLog(level, parts) {
  const msg = parts.map((p) => (p instanceof Error ? p.message : typeof p === 'string' ? p : JSON.stringify(p))).join(' ').slice(0, 600);
  if (link?.open) link.send({ t: 'log', level, msg });
  else if (logQueue.length < 30) logQueue.push({ t: 'log', level, msg });
}
for (const level of ['error', 'warn']) {
  const orig = console[level].bind(console);
  console[level] = (...a) => { orig(...a); remoteLog(level, a); };
}
window.addEventListener('error', (e) => remoteLog('error', [`${e.message} @${(e.filename || '').split('/').pop()}:${e.lineno}`]));
window.addEventListener('unhandledrejection', (e) => remoteLog('error', [`unhandled: ${e.reason?.stack || e.reason}`]));

// ───── Screen ─────
const screen = new Screen({ area: $('#screen-area'), wrap: $('#screen-wrap'), canvas: $('#screen'), notch: $('#notch') });
// The Mac's pointer, drawn here so it moves with no lag (the video doesn't include it).
const macCursor = new MacCursor(screen, $('#mac-cursor'));
screen.pointerDrawn = true;
screen.onLayout = () => macCursor.render();

// ───── Input batching ─────
// Pointer and scroll deltas are summed and sent at most ~120×/s; the first after a pause goes out
// right away (no waiting for the batch). Everything else goes out immediately (in order).
const acc = { mx: 0, my: 0, sx: 0, sy: 0 };
let flushTimer = 0, lastFlush = 0, moveSeq = 0;
const r2 = (v) => Math.round(v * 100) / 100;

function flushSoon() {
  if (flushTimer) return;
  const wait = 8 - (performance.now() - lastFlush);
  if (wait <= 0) flush(false);
  else flushTimer = setTimeout(() => flush(false), wait);
}

function flush(force) {
  clearTimeout(flushTimer);
  flushTimer = 0;
  if (!force && link.buffered > 64 * 1024) { flushTimer = setTimeout(() => flush(false), 8); return; } // let a backed-up socket drain
  lastFlush = performance.now();
  // q: which moves the Mac has applied, so the pointer drawn here can be reconciled (js/cursor.js).
  if (acc.mx || acc.my) { link.send({ t: 'm', x: r2(acc.mx), y: r2(acc.my), q: ++moveSeq }); acc.mx = acc.my = 0; }
  if (acc.sx || acc.sy) { link.send({ t: 's', x: r2(acc.sx), y: r2(acc.sy) }); acc.sx = acc.sy = 0; }
}

function sendNow(m) {
  flush(true);
  link.send(m);
}

// Clicks use the keyboard's modifiers (⌘-click, ⇧-click…) and count as "using" a held modifier,
// so letting go of it afterwards doesn't latch it.
const pointer = {
  touched() { keyboard.markUsed(); },
  move(dx, dy) { acc.mx += dx; acc.my += dy; macCursor.moved(dx, dy, moveSeq + 1); flushSoon(); },
  abs(nx, ny) {
    flush(true);
    const x = Math.round(nx * 10000) / 10000, y = Math.round(ny * 10000) / 10000;
    link.send({ t: 'a', x, y, q: ++moveSeq });
    macCursor.jumped(x, y, moveSeq);
  },
  click(b, n) {
    keyboard.markUsed();
    sendNow({ t: 'c', b, n, mod: keyboard.mask() });
    keyboard.consumeLatched();
  },
  button(b, down, n) {
    keyboard.markUsed();
    sendNow({ t: 'b', b, d: down ? 1 : 0, n, mod: keyboard.mask() });
    if (!down) keyboard.consumeLatched();
  },
};

// ───── Keyboard ─────
let feedbackLogs = 0;
const keyboard = new Keyboard($('#keyboard'), $('#keypop'), {
  onKey(code, down, mod, repeat) {
    const m = { t: 'k', c: code, d: down ? 1 : 0, mod };
    if (repeat) m.r = 1;
    sendNow(m);
  },
  onAux(nx) {
    sendNow({ t: 'aux', k: nx, d: 1 });
    link.send({ t: 'aux', k: nx, d: 0 });
  },
  onAction(a) {
    if (a === 'iosKeyboard') openIOSKeyboard();
    else sendNow({ t: 'act', a });
  },
  onPower() { sheet.isOpen ? sheet.close() : openSheet(); },
  onIOSKeyboard() { openIOSKeyboard(); },
  feedback(kind) {
    sound.click(kind);
    haptic();
    if (feedbackLogs++ < 3) remoteLog('info', [`feedback: sounds ${settings.sounds} haptics ${settings.haptics} volume ${settings.volume} audio ${sound.state()}`]);
  },
});

// ───── Trackpad ─────
function scrollMac(dx, dy) {
  keyboard.markUsed();
  const k = 2.4 * settings.scrollSpeed * (settings.naturalScroll ? 1 : -1);
  acc.sx += dx * k;
  acc.sy += dy * k;
  flushSoon();
}
/** Three or four fingers swiping: Mission Control, App Exposé, or the next Space. */
function swipeMac(dir) {
  const a = { up: 'missionControl', down: 'appExpose', left: 'spaceRight', right: 'spaceLeft' }[dir];
  sendNow({ t: 'act', a });
  haptic();
}
// A pinch on a trackpad is the Mac's: the page or app under the pointer zooms, as on a MacBook.
let pinchLast = 1;
function zoomMac(phase, ratio) {
  if (phase === 'start') {
    pinchLast = 1;
    sendNow({ t: 'z', p: 'b' });
  } else if (phase === 'change') {
    const m = ratio / pinchLast - 1;
    if (Math.abs(m) < 0.002) return;
    pinchLast = ratio;
    sendNow({ t: 'z', p: 'c', m: +m.toFixed(4) });
  } else {
    sendNow({ t: 'z', p: 'e' });
  }
}
const trackpad = new Trackpad($('#padzone'), $('#trackpad'), {
  ...pointer,
  probe: () => probeText(),
  tapped: (id) => tappedText(id),
  scroll: scrollMac,
  zoom: zoomMac,
  swipe3: swipeMac,
  touched() {
    keyboard.markUsed();
    const hint = $('#trackpad .hint');
    if (hint && !hint.classList.contains('gone')) {
      hint.classList.add('gone');
      setSetting('hintSeen', true);
    }
  },
});
if (settings.hintSeen) $('#trackpad .hint').classList.add('gone');
addHapticSwitch($('#trackpad'));

// ───── Touch on the screen half ─────
// Screen only: tapping a text field on the Mac brings up the iPhone's own keyboard. The finger going
// down asks the Mac what's under it; the answer is usually back before the finger lifts, and iOS
// only shows its keyboard from inside the tap. If it's late, a Type button appears instead.
const hits = new Map();
let hitSeq = 0, typeBtnTimer = 0;
function probeText(nx, ny) {
  if (view().layout === 'laptop' || !link.open || !iosBar.hidden) return 0;
  const id = ++hitSeq;
  hits.set(id, { text: null, tapped: 0 });
  if (hits.size > 8) hits.delete(hits.keys().next().value);
  // From the trackpad: whatever is under the Mac's pointer.
  link.send(nx === undefined ? { t: 'hit', id } : { t: 'hit', id, x: nx, y: ny });
  return id;
}
function tappedText(id) {
  const h = hits.get(id);
  if (!h) return;
  if (h.text) openIOSKeyboard();
  else if (h.text === null) h.tapped = performance.now();
}
function hitResult(m) {
  const h = hits.get(m.id);
  if (!h) return;
  h.text = !!m.text;
  if (h.text && h.tapped && performance.now() - h.tapped < 1500 && iosBar.hidden) showTypeButton();
}
function showTypeButton() {
  const b = $('#type-btn');
  if (!b) return;
  b.hidden = false;
  clearTimeout(typeBtnTimer);
  typeBtnTimer = setTimeout(() => { b.hidden = true; }, 4000);
}
$('#type-btn')?.addEventListener('click', () => { $('#type-btn').hidden = true; openIOSKeyboard(); });
// Without the keyboard (Trackpad and Screen only layouts): the iPhone keyboard and Settings, always at hand.
$('#tool-kb')?.addEventListener('click', () => openIOSKeyboard());
$('#tool-set')?.addEventListener('click', () => (sheet.isOpen ? sheet.close() : openSheet()));

// Screen only: the screen is touched where you point (LidTouch), or is one big trackpad.
const screenIsPad = () => { const v = view(); return v.layout === 'screen' && v.screenTouch === 'trackpad'; };
const lidTouch = new LidTouch($('#screen-area'), screen, {
  ...pointer, scroll: scrollMac, swipe3: swipeMac, probe: probeText, tapped: tappedText, enabled: () => !screenIsPad(),
  screenOnly: () => view().layout === 'screen',
});
const screenPad = new Trackpad($('#screen-area'), $('#screen-area'), {
  ...pointer, probe: () => probeText(), tapped: (id) => tappedText(id), scroll: scrollMac, zoom: zoomMac, swipe3: swipeMac,
  touched: () => keyboard.markUsed(), enabled: screenIsPad,
});

// ───── Settings sheet ─────
const sheet = new Sheet($('#sheet'), {
  iosKeyboard: () => { sheet.close(); openIOSKeyboard(); },
  resetZoom: () => screen.resetZoom(),
  refresh: () => link.send({ t: 'refresh' }),
  reconnect: () => { fatal = null; link.reconnectNow(); },
  // Local mode's one-time setup: the profile that makes this iPhone trust the Mac on the local
  // network. iOS installs profiles from Safari only (not from a Home Screen app).
  localSetup: () => {
    const url = `https://${location.host}/duo-mac-local.mobileconfig`;
    if (navigator.standalone) location.href = `x-safari-${url}`;
    else location.href = url;
  },
  endSession: () => {
    sheet.close();
    keyboard.releaseAll();
    trackpad.reset();
    link.send({ t: 'rel' });
    link.send({ t: 'bye' });
    fatal = 'ended';
    setTimeout(() => link.close(), 150);
    setOverlay('error', 'Session ended', 'Your Mac is back to normal.', 'Reconnect');
  },
  display: (i) => { screen.resetZoom(); link.send({ t: 'display', i }); },
  lock: () => {
    sheet.close();
    keyboard.releaseAll();
    trackpad.reset();
    link.send({ t: 'rel' });
    link.send({ t: 'lock' }); // the Mac forgets the unlock and hangs up; reconnecting asks for passkey
    ticket = '';
    authed = false;
    showAuth('Locked', '');
  },
  changePin: () => { sheet.close(); askPin('change'); },
  forget: () => {
    if (!confirm(`Unpair this iPhone from ${macName()}? To use it again you’ll have to pair it at the Mac.`)) return;
    sheet.close();
    link.send({ t: 'rel' });
    link.send({ t: 'forget' });
    unpairLocally();
    showPairing();
  },
});

function sheetInfo() {
  return {
    mac: cfg?.mac, display: cfg?.display, test: cfg?.test,
    displays: cfg?.displays, displayIndex: cfg?.displayIndex, nanoActive: !!cfg?.nano,
    layout: cfg?.keyboard?.layout, connected: link.open, rtt: link.rtt, device, micInstalled: cfg?.mic?.installed, micUpdate: cfg?.mic?.update, micOn: mic.running,
    route: link.open ? link.route : '', localReady: !!link.local,
  };
}

function openSheet() {
  sheet.update(sheetInfo());
  sheet.open();
  powerKey()?.classList.remove('attn');
}

const powerKey = () => document.querySelector('#keyboard .key.power');
if (!settings.sheetSeen) powerKey()?.classList.add('attn');

/** Once per launch, a moment after the Mac appears: light up the ⚙︎ key and label it, then fade away. */
let tipShown = false;
function settingsTip(tries = 0) {
  if (tipShown || sheet.isOpen) return;
  const key = powerKey();
  const ready = app.classList.contains('live') && overlay.className === 'hidden' && key?.offsetParent;
  if (!ready) { if (tries < 5) setTimeout(() => settingsTip(tries + 1), 1000); return; }
  tipShown = true;
  const tip = document.createElement('div');
  tip.id = 'settings-tip';
  tip.textContent = 'Settings';
  app.appendChild(tip);
  const k = key.getBoundingClientRect(), a = app.getBoundingClientRect();
  const right = a.right - k.right;
  tip.style.right = `${right}px`;
  tip.style.top = `${k.top - a.top - tip.offsetHeight - 9}px`;
  tip.style.setProperty('--arrow-right', `${Math.max(6, k.width / 2 - 5)}px`);
  key.classList.add('spot');
  requestAnimationFrame(() => tip.classList.add('on'));
  setTimeout(() => {
    tip.classList.remove('on');
    key.classList.remove('spot');
    setTimeout(() => tip.remove(), 400);
  }, 2600);
}

// ───── Layout ─────
let lastBox = [0, 0];
let resizeTimer = 0;

function px(v) { return parseFloat(v) || 0; }

// CSS custom properties hold the unresolved env(...) text, so measure the safe areas with a probe.
const probe = document.createElement('div');
probe.style.cssText = 'position:fixed;visibility:hidden;pointer-events:none;' +
  'padding:env(safe-area-inset-top,0px) env(safe-area-inset-right,0px) env(safe-area-inset-bottom,0px) env(safe-area-inset-left,0px)';
document.body.appendChild(probe);
function safeArea() {
  const c = getComputedStyle(probe);
  return { top: px(c.paddingTop), right: px(c.paddingRight), bottom: px(c.paddingBottom), left: px(c.paddingLeft) };
}

/** What the screen shows. Upright and open: the Layout setting. Turned sideways, or folded with
 *  "Folding closes the lid" off: all screen, and the whole screen is a trackpad. */
let sideways = false, foldedOpen = false;
function view() {
  if (sideways || foldedOpen) return { layout: 'screen', screenTouch: 'trackpad' };
  return { layout: settings.layout, screenTouch: settings.screenTouch };
}

/** Screen share of the height: the setting, or automatic (more screen on tall, non-folding phones). */
function split() {
  const own = view().layout === 'trackpad' ? settings.hingePad : settings.hinge; // each layout keeps its own
  if (own) return own;
  // A folded foldable can say where the fold is (Viewport Segments API; behind a flag in Safari 27.1).
  const seg = window.viewport?.segments;
  if (seg?.length === 2 && seg[0].height < innerHeight * 0.9) return (seg[0].y + seg[0].height) / innerHeight;
  return innerHeight / innerWidth > 1.8 ? 0.56 : 0.5;
}

function layout() {
  const H = app.clientHeight || window.innerHeight;
  // iPhone Duo (inner display, fold across): the status bar is an 82 pt strip with the clock and status
  // ring in its right corner only (a regular iPhone's runs across a 47–62 pt one). iOS can't hide it.
  const tallTop = safeArea().top >= 70;
  checkFold(tallTop);
  sideways = innerWidth > innerHeight;
  const v = view();
  const screenOnly = v.layout === 'screen';
  const padOnly = v.layout === 'trackpad';
  app.classList.toggle('screen-only', screenOnly);
  app.classList.toggle('pad-only', padOnly);
  $('#tools').hidden = v.layout === 'laptop';
  app.classList.toggle('nano', settings.macDisplay === 'nano');
  app.classList.toggle('show-notch', !!settings.notch);
  app.classList.toggle('haptics', !!settings.haptics);
  app.classList.toggle('tall-top', tallTop);
  app.classList.toggle('full-top', tallTop && settings.topEdge === 'full');
  app.style.setProperty('--lid-h', `${screenOnly ? H : Math.round(H * split())}px`);
  // Stats live on the trackpad, out of the way; with no trackpad, on the screen.
  const statsHome = screenOnly ? $('#screen-area') : $('#trackpad');
  if (statsEl.parentElement !== statsHome) statsHome.appendChild(statsEl);
  if (!screenOnly) layoutDeck();
  screen.layout();
  const chin = $('#chin');
  chin.classList.toggle('tiny', chin.clientHeight < 12);
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(sendResizeIfNeeded, 350);
}

// ───── Folding the iPhone Duo closes the lid ─────
// Unfolded, an iPhone Duo's inner screen is nearly square (669×951) under its tall 82 pt status bar.
// Folded, the app moves to the cover screen, much the same shape but a third narrower (466×678).
// So the short side, compared with the inner screen's, tells them apart in either orientation.
// Folded: show a closed lid and hang up like a closed MacBook, so the Mac stops sharing its screen
// and can sleep. The setting turns this off.
const closedEl = $('#closed');
let lidClosed = false, foldTimer = 0, lastShort = 0;
function checkFold(tallTop) {
  const long = Math.max(innerWidth, innerHeight), short = Math.min(innerWidth, innerHeight) || 1;
  if (tallTop && long / short < 1.6 && short > settings.duoShort) {
    setSetting('duoShort', short);
    if (!settings.seenDuo) setSetting('seenDuo', true);
  }
  if (Math.abs(short - lastShort) > 20) {
    lastShort = short;
    remoteLog('info', [`fold: ${innerWidth}×${innerHeight} top ${safeArea().top} (inner screen short side ${settings.duoShort})`]);
  }
  const foldedShape = settings.seenDuo && settings.duoShort > 0 && short < settings.duoShort * 0.85;
  const folded = settings.foldCloses && foldedShape;
  foldedOpen = foldedShape && !settings.foldCloses; // used folded: the whole screen is a trackpad
  if (lidClosed) orientLid();
  clearTimeout(foldTimer);
  if (folded === lidClosed) return;
  // Folding and unfolding pass through odd sizes: act on the shape it settles in.
  foldTimer = setTimeout(() => (folded ? closeLid() : openLid()), folded ? 250 : 0);
}
/** Keep the lid fixed to the phone while iOS turns the page with it (see #closed in app.css). */
function orientLid() {
  const turn = typeof window.orientation === 'number' ? window.orientation : ((screen.orientation?.angle || 0) + 180) % 360 - 180;
  const sideways = Math.abs(turn) % 180 === 90;
  closedEl.style.setProperty('--turn', `${-turn}deg`);
  closedEl.style.setProperty('--lid-w', sideways ? '100vh' : '100vw');
  closedEl.style.setProperty('--lid-h2', sideways ? '100vw' : '100vh');
}
function closeLid() {
  if (lidClosed) return;
  lidClosed = true;
  remoteLog('info', [`lid: folded (${innerWidth}×${innerHeight})`]);
  closedEl.classList.toggle('silver', settings.theme === 'silver');
  orientLid();
  closedEl.hidden = false;
  if (sheet.isOpen) sheet.close();
  micWanted = false;
  mic.stop();
  keyboard.releaseAll();
  trackpad.reset();
  lidTouch.reset();
  screenPad.reset();
  link.send({ t: 'rel' });
  if (link.open) link.close();
}
function openLid() {
  if (!lidClosed) return;
  lidClosed = false;
  closedEl.hidden = true;
  if (!document.hidden && !fatal) link.reconnectNow();
}

function layoutDeck() {
  const W = deck.clientWidth, H = deck.clientHeight;
  if (!W || !H) return;
  const sa = safeArea();
  const sab = sa.bottom, sal = sa.left, sar = sa.right;
  const padX = Math.max(8, W * 0.025) + Math.max(sal, sar);
  const padTop = Math.max(9, H * 0.035);
  const padBot = Math.max(6, sab * 0.75); // just clear of the home indicator, like a tab bar
  const aw = W - 2 * padX, ah = H - padTop - padBot;

  if (view().layout === 'trackpad') {
    // No keyboard: the trackpad fills the half, with the same margins.
    const tp = $('#trackpad'), zone = $('#padzone');
    const tw = aw, th = H - padTop - padBot;
    Object.assign(zone.style, { left: '0px', top: '0px', width: `${W}px`, height: `${H}px` });
    Object.assign(tp.style, { left: `${padX}px`, top: `${padTop}px`, width: `${tw}px`, height: `${th}px` });
    for (const id of ['#speaker-l', '#speaker-r']) $(id).classList.remove('on');
    return;
  }

  // Keyboard: 15.6u wide × 6.3u tall (keys + well); leave at least ~38% of the height for the trackpad.
  let u = Math.min(aw / 15.6, (ah * 0.6) / 6.3);
  u = Math.max(12, Math.floor(u * 4) / 4);
  const kbW = u * 15.6, kbH = u * 6.3;
  const kbX = (W - kbW) / 2, kbY = padTop;
  const kb = $('#keyboard');
  kb.style.setProperty('--u', `${u}px`);
  Object.assign(kb.style, { left: `${kbX}px`, top: `${kbY}px`, width: `${kbW}px`, height: `${kbH}px` });
  deck.style.setProperty('--u', `${u}px`);

  // Trackpad: 80% of the keyboard's width (a MacBook's is ~60%, but this one is tiny), down to the bottom.
  const tpTop = kbY + kbH + u * 0.45;
  const tpH = Math.max(36, H - tpTop - padBot);
  const tpW = Math.min(aw, kbW * 0.806);
  const tp = $('#trackpad');
  const zone = $('#padzone');
  const zoneTop = kbY + kbH + 2;
  Object.assign(zone.style, { left: '0px', top: `${zoneTop}px`, width: `${W}px`, height: `${H - zoneTop}px` });
  Object.assign(tp.style, { left: `${(W - tpW) / 2}px`, top: `${tpTop - zoneTop}px`, width: `${tpW}px`, height: `${tpH}px` });

  // Speaker grilles beside the keyboard when there's room.
  const room = kbX - padX * 0.5;
  for (const [id, x] of [['#speaker-l', padX * 0.5], ['#speaker-r', kbX + kbW + u * 0.35]]) {
    const sp = $(id);
    const on = room > u * 1.1;
    sp.classList.toggle('on', on);
    if (on) Object.assign(sp.style, { left: `${x}px`, top: `${kbY}px`, width: `${room - u * 0.35}px`, height: `${kbH}px` });
  }
}

function sendResizeIfNeeded() {
  if (!link.open || !cfg) return;
  const box = screen.boxPixels();
  if (Math.abs(box[0] - lastBox[0]) > lastBox[0] * 0.06 || Math.abs(box[1] - lastBox[1]) > lastBox[1] * 0.06) {
    // A new shape (the phone rotated, or iOS still growing the viewport just after launch, see
    // app.css): reshape the Duo display to fill the screen instead of letterboxing it.
    const reshaped = Math.abs(Math.log((box[0] / box[1]) / (lastBox[0] / lastBox[1]))) > 0.12;
    lastBox = box;
    if (settings.macDisplay === 'nano' && (performance.now() < 6000 || reshaped)) link.send({ t: 'nano', ...nanoRequest(), box });
    else link.send({ t: 'resize', box });
  }
}

window.addEventListener('resize', layout);
new ResizeObserver(() => layout()).observe(app); // iOS doesn't always fire 'resize' when the viewport grows
window.addEventListener('orientationchange', () => setTimeout(layout, 300));

let hingeTimer = 0;

function applyTheme() {
  document.documentElement.style.setProperty('--page-bg', settings.theme === 'silver' ? '#cdd0d3' : '#1b1c1e');
  app.classList.toggle('theme-silver', settings.theme === 'silver');
  app.classList.toggle('theme-spaceblack', settings.theme !== 'silver');
}

onSetting((k, v) => {
  if (k === 'theme') applyTheme();
  if (k === 'foldCloses') layout();
  if (k === 'screenTouch' || k === 'layout') { lidTouch.reset(); screenPad.reset(); }
  if (k === 'hinge' || k === 'hingePad' || k === 'layout' || k === 'notch' || k === 'topEdge' || k === 'haptics') layout();
  if ((k === 'hinge' || k === 'hingePad' || k === 'topEdge' || k === 'layout') && settings.macDisplay === 'nano') {
    // Reshape the Mac's Duo display to the new screen area once the slider settles.
    clearTimeout(hingeTimer);
    hingeTimer = setTimeout(() => {
      lastBox = screen.boxPixels();
      link.send({ t: 'nano', ...nanoRequest(), box: lastBox });
    }, 700);
  }
  if (k === 'mic') {
    micDenied = false;
    if (v && cfg?.mic && !cfg.mic.installed) {
      // Nothing on the Mac to hear it yet: say where to get it instead of turning on for nothing.
      setSetting('mic', false);
      sheet.update(sheetInfo());
      showBanner(micMissing(), 'warn', 8000);
      return;
    }
    v ? micOn() : micOff();
  }
  if (k === 'quality') link.send({ t: 'quality', q: v });
  if (k === 'video') link.send({ t: 'codec', c: codec() });
  if (k === 'macSound') { link.send({ t: 'sound', on: !!v }); if (!v) speaker.stop(); }
  if (k === 'stats') statsEl.hidden = !v;
  if (k === 'fnStandard') keyboard.renderFnRow();
  if (k === 'macDisplay' || k === 'nanoSize') {
    screen.resetZoom();
    layout(); // the bezel changes with the mode, so measure again before telling the Mac
    lastBox = screen.boxPixels();
    link.send({ t: 'nano', ...nanoRequest(), box: lastBox });
    sheet.update(sheetInfo());
  }
});


// ───── Overlay & banner ─────
const authForm = overlay.querySelector('.field');
const authField = authForm.querySelector('input');
const authActs = overlay.querySelector('.acts');
let onAuthField = null;

function setOverlay(state, msg = '', sub = '', retry = '') {
  hideInstall();
  overlay.className = state;
  if (state === 'hidden') setTimeout(settingsTip, 1500); // the Mac is showing: remind where settings are
  overlay.querySelector('.msg').textContent = msg;
  overlay.querySelector('.sub').textContent = sub;
  const b = overlay.querySelector('.retry');
  b.hidden = !retry;
  b.textContent = retry;
  overlay.querySelector('.match').hidden = true;
  authForm.hidden = true;
  authActs.replaceChildren();
  if (document.activeElement === authField) authField.blur();
}

/** The pairing / unlock screens: a message, maybe a code to compare, a field, buttons. */
function showAuth(msg, sub = '', { field = null, buttons = [], match = '' } = {}) {
  setOverlay('auth', msg, sub);
  const m = overlay.querySelector('.match');
  m.hidden = !match;
  m.textContent = match;
  if (field) {
    authForm.hidden = false;
    authField.value = '';
    authField.placeholder = field.placeholder || '';
    authField.inputMode = field.numeric ? 'numeric' : 'text';
    authField.maxLength = field.max || 12;
    authField.classList.toggle('secret', !!field.secret);
    authField.setAttribute('autocapitalize', field.numeric ? 'off' : 'characters');
    authForm.querySelector('button').textContent = field.go || 'OK';
    onAuthField = field.submit;
  }
  authActs.replaceChildren(...buttons.map((b) => {
    const el = document.createElement('button');
    el.type = 'button';
    el.className = b.primary ? 'act primary' : 'act';
    el.textContent = b.label;
    el.addEventListener('click', b.onClick);
    return el;
  }));
}

authForm.addEventListener('submit', (e) => {
  e.preventDefault();
  const v = authField.value.trim();
  if (v && onAuthField) onAuthField(v);
});
// PINs go as soon as the 6th digit is in.
authField.addEventListener('input', () => {
  if (authField.inputMode === 'numeric' && authField.value.replace(/\D/g, '').length === 6 && onAuthField) {
    const v = authField.value;
    authField.blur();
    onAuthField(v);
  }
});

let bannerTimer = 0;
function showBanner(text, level = 'info', ms = 0) {
  clearTimeout(bannerTimer);
  banner.textContent = text;
  banner.className = level;
  banner.hidden = false;
  if (ms) bannerTimer = setTimeout(() => { banner.hidden = true; }, ms);
}
function hideBanner() { banner.hidden = true; }

overlay.querySelector('.retry').addEventListener('click', () => {
  fatal = null;
  setOverlay('booting', 'Connecting…');
  if (link.open && authed) sendHello(); // still connected (e.g. capture stopped): ask the Mac to start again
  else link.reconnectNow();
});

function macName() { return cfg?.mac?.name || macLabel || 'your Mac'; }

const isIOS = /iPhone|iPad|iPod/.test(navigator.userAgent);
/** Under "Tap to power on": the Mac's name, plus a nudge to install the full-screen app. */
function offSub() {
  return isIOS && !navigator.standalone
    ? `${macName()} · Tip: add it to your Home Screen for full screen`
    : macName();
}

function reveal() {
  if (fatal || !authed) return;
  setOverlay('hidden');
  if (settings.chime && !chimed) {
    chimed = true;
    sound.chime();
  }
}

function powerOn() {
  if (powered) return;
  powered = true;
  sound.unlock();
  if (fatal || !authed) return; // the pairing / unlock screen stays
  if (screen.gotFrame) reveal();
  else setOverlay('booting', link.open ? `Starting ${macName()}…` : 'Looking for your Mac…');
}

screen.onFirstFrame = () => { if (powered) reveal(); macCursor.render(); };

// iOS only lets audio start from a touch *end*; unlock there too.
app.addEventListener('pointerup', () => {
  sound.unlock();
  // The microphone's audio too, for when a Mac app starts listening. If one already is and iOS
  // wouldn't start without a tap, this is that tap.
  if (settings.mic) {
    mic.unlock();
    if (micWanted && !mic.running && !micDenied) record();
  }
}, true);

// The first tap anywhere powers the Nano on (and unlocks audio on iOS); it isn't sent to the Mac.
app.addEventListener('pointerdown', (e) => {
  sound.unlock();
  if (!powered && !e.target.closest('#sheet, button, input')) {
    e.stopPropagation();
    e.preventDefault();
    powerOn();
  }
}, true);

// ───── Pairing ─────
function showPairing(note = '') {
  pairing = null;
  if (!pairCode) {
    showAuth('Pair this iPhone', note || 'On your Mac, open Duo Mac and scan its QR code with the Camera — or type the pairing code shown there.', {
      field: { placeholder: 'ABCD-EFGH', max: 9, go: 'Pair', submit: (v) => { pairCode = v.replace(/[^0-9a-z]/gi, '').toUpperCase(); requestPair(); } },
    });
    return;
  }
  if (isIOS && !navigator.standalone && !browserOK) {
    const useHere = () => { browserOK = true; showPairing(); };
    showAuth('Add it to your Home Screen', note || 'Then open Duo Mac from your Home Screen to pair it — it runs full screen there.', {
      buttons: [{ label: 'Show me how', primary: true, onClick: () => showInstall({ useHere }) }, { label: `Pair in ${browserName} instead`, onClick: useHere }],
    });
    showInstall({ useHere });
    return;
  }
  showAuth(`Pair with ${macName()}`, note || 'You’ll confirm it on the Mac.', {
    buttons: [{ label: 'Pair this iPhone', primary: true, onClick: requestPair }],
  });
}

function requestPair() {
  powered = true;
  sound.unlock();
  if (!link.open) {
    wantPair = true;
    link.reconnectNow();
    showAuth('Connecting…');
    return;
  }
  link.send({ t: 'pair', code: pairCode, name: deviceName() });
  showAuth('Asking your Mac…');
}

function pairFailed(reason) {
  const notes = {
    'bad-code': 'That pairing code is out of date. Scan the QR code on your Mac again, or type the code shown there.',
    busy: 'Another device is pairing right now. Try again in a minute.',
    denied: 'Your Mac said no.',
    timeout: 'Nobody answered on the Mac. Try again.',
  };
  if (reason === 'bad-code') pairCode = '';
  if (reason === 'no-unlock') return askPin('required');
  showPairing(notes[reason] || 'Pairing didn’t work. Try again.');
}

/** Allowed on the Mac: set up passkey (or a PIN) before the Mac saves this iPhone. */
function setUpUnlock() {
  if (canPasskey && window.isSecureContext) {
    link.send({ t: 'passkey-begin' });
    showAuth('Allowed', 'One moment…');
  } else {
    askPin('required', 'Choose a 6-digit PIN. You’ll enter it each time you open Duo Mac.');
  }
}

function showFaceIDSetup(note = '') {
  if (!passkeyOpts) return askPin('required', 'A passkey can’t be used here. Choose a 6-digit PIN instead.');
  showAuth('Unlock with a passkey', note || `Each time you open Duo Mac, your passkey unlocks ${macName()}.`, {
    buttons: [
      { label: 'Set Up Passkey', primary: true, onClick: () => {
        const p = createPasskey(passkeyOpts); // straight from the tap, or Safari won't show passkey
        showAuth('Passkey…');
        p.then((r) => link.send({ t: 'passkey-register', ...r }))
          .catch((e) => {
            console.warn('passkey setup failed:', e?.name, e?.message);
            showFaceIDSetup(e?.name === 'NotAllowedError' ? 'Cancelled. Try again, or use a PIN instead.' : `That didn’t work (${e?.name || 'error'}).`);
          });
      } },
      { label: 'Use a PIN instead', onClick: () => askPin('required') },
    ],
  });
}

let pinFirst = '';
/** mode: 'required' (only unlock method) | 'backup' (after passkey) | 'change' (from settings). */
function askPin(mode, note = '') {
  pinFirst = '';
  const title = mode === 'backup' ? 'Choose a backup PIN' : mode === 'change' ? 'Choose a new PIN' : 'Choose a PIN';
  const sub = note || (mode === 'backup' ? 'For when the passkey isn’t available. 6 digits.' : '6 digits. You’ll need it to unlock Duo Mac.');
  const buttons = mode === 'backup' ? [{ label: 'Skip', onClick: finishPairing }]
    : mode === 'change' ? [{ label: 'Cancel', onClick: () => { setOverlay('hidden'); reveal(); } }] : [];
  showAuth(title, sub, { field: pinField('Next', (v) => pinEntered(v, mode)), buttons });
}

function pinField(go, submit) {
  return { numeric: true, secret: true, max: 6, placeholder: '6 digits', go, submit };
}

function weakPin(p) {
  return /^(\d)\1{5}$/.test(p) || '0123456789'.includes(p) || '9876543210'.includes(p);
}

function pinEntered(v, mode) {
  const pin = v.replace(/\D/g, '');
  if (pin.length !== 6) return askPin(mode, 'Use exactly 6 digits.');
  if (!pinFirst) {
    if (weakPin(pin)) return askPin(mode, 'That one is too easy to guess. Pick another.');
    pinFirst = pin;
    showAuth('Enter it again', '', { field: pinField(mode === 'change' ? 'Save' : 'Next', (v2) => pinEntered(v2, mode)) });
    return;
  }
  if (pin !== pinFirst) return askPin(mode, 'The two PINs didn’t match. Try again.');
  pinFirst = '';
  link.send({ t: 'pin-set', pin });
  showAuth('Saving…');
}

function finishPairing() {
  link.send({ t: 'pair-finish' });
  showAuth('Finishing…');
}

// ───── Unlocking ─────
let unlockNote = '';

function fmtWait(s) {
  return s >= 5400 ? `${Math.round(s / 3600)} hours` : s >= 90 ? `${Math.round(s / 60)} minutes` : `${s} seconds`;
}

function showUnlock(note = unlockNote) {
  unlockNote = '';
  const n = need;
  if (!n) return;
  const face = n.passkey && canPasskey;
  const buttons = [];
  if (face) buttons.push({ label: 'Unlock with Passkey', primary: true, onClick: faceIdUnlock });
  if (n.pin) buttons.push({ label: face ? 'Use PIN' : 'Enter PIN', primary: !face, onClick: () => askUnlockPin() });
  if (!buttons.length) {
    showAuth('Can’t unlock here', 'This iPhone’s passkey was set up for another address of the Mac, and it has no PIN. Pair it again.', {
      buttons: [{ label: 'Pair Again', primary: true, onClick: () => { unpairLocally(); showPairing(); } }],
    });
    return;
  }
  if (n.pin && n.pinWait > 0 && !note) note = `PIN paused for ${fmtWait(n.pinWait)} after wrong tries.`;
  showAuth(`Unlock ${macName()}`, note, { buttons });
}

function faceIdUnlock() {
  const p = getAssertion({ challenge: need.challenge, rpId: need.rpId, cred: need.cred }); // straight from the tap
  powered = true;
  sound.unlock();
  showAuth('Passkey…');
  p.then((r) => link.send({ t: 'auth-passkey', ...r }))
    .catch((e) => {
      console.warn('passkey unlock failed:', e?.name, e?.message);
      showUnlock(e?.name === 'NotAllowedError' ? '' : `The passkey didn’t work (${e?.name || 'error'}).`);
    });
}

function askUnlockPin(note = '') {
  powered = true;
  sound.unlock();
  const face = need?.passkey && canPasskey;
  showAuth('Enter your PIN', note, {
    field: pinField('Unlock', (v) => { link.send({ t: 'auth-pin', pin: v.replace(/\D/g, '') }); showAuth('Checking…'); }),
    buttons: face ? [{ label: 'Use Passkey', onClick: faceIdUnlock }] : [],
  });
}

function authFailed(m) {
  switch (m.reason) {
    case 'unknown-device':
      unpairLocally();
      showPairing(`${macName()} doesn’t know this iPhone any more. Pair it again.`);
      break;
    case 'passkey':
      unlockNote = 'The passkey didn’t match. Try again.'; // a fresh challenge follows
      break;
    case 'pin':
      askUnlockPin(m.left > 0 ? `Wrong PIN. ${m.left} ${m.left === 1 ? 'try' : 'tries'} left before a pause.`
        : `Wrong PIN. The PIN is paused for ${fmtWait(m.wait)}.`);
      break;
    case 'pin-locked':
      showUnlock(`Too many wrong PINs: paused for ${fmtWait(m.wait)}.`);
      break;
    case 'off':
      connectionsOff();
      break;
  }
}

function connectionsOff() {
  showAuth('Connections are off', `Turn on “Allow iPhone connections” in Duo Mac on ${macName()}.`, {
    buttons: [{ label: 'Try Again', primary: true, onClick: () => { showAuth('Connecting…'); link.reconnectNow(); } }],
  });
}

function unpairLocally() {
  forgetDevice();
  device = null;
  ticket = '';
  authed = false;
  need = null;
}

/** The link just opened: prove who we are, or offer to pair. */
function startAuth() {
  authed = false;
  if (device) {
    link.send({ t: 'auth', dev: device.dev, tok: device.tok, ticket: ticket || undefined });
    if (overlay.className !== 'hidden') setOverlay('booting', 'Connecting…');
  } else if (wantPair) {
    wantPair = false;
    requestPair();
  } else {
    showPairing();
  }
}

/** The Mac keeps a copy of these settings, so they survive adding the Home Screen app again. */
let prefsTimer = 0;
function backUpPrefs() {
  clearTimeout(prefsTimer);
  prefsTimer = setTimeout(() => { if (authed) link.send({ t: 'prefs', v: settings }); }, 800);
}
onSetting(backUpPrefs);
let prefsRestored = false;

function onAuthed(m) {
  if (freshInstall && !prefsRestored && m.prefs && typeof m.prefs === 'object') {
    for (const [k, v] of Object.entries(upgrade({ ...m.prefs }))) if (k in DEFAULTS && typeof v === typeof DEFAULTS[k] || k === 'hinge' || k === 'hingePad') setSetting(k, v);
  }
  prefsRestored = true;
  authed = true;
  backUpPrefs();
  need = null;
  pairing = null;
  ticket = m.ticket || '';
  if (device && m.device) {
    Object.assign(device, { name: m.device.name, passkey: m.device.passkey, pin: m.device.pin, mac: macLabel });
    saveDevice(device);
  }
  if (pairCode && location.search) history.replaceState(null, '', location.pathname); // the code isn't needed any more
  for (const q of logQueue.splice(0)) link.send(q);
  // The Duo display takes its shape from the hello, so give iOS a moment after launch to settle the viewport.
  clearTimeout(helloTimer);
  helloTimer = setTimeout(() => {
    if (!link.open || !authed) return;
    sendHello();
    const r = (sel) => Math.round(document.querySelector(sel).getBoundingClientRect().bottom);
    const sa = safeArea();
    remoteLog('info', [`layout: inner ${innerWidth}×${innerHeight} screen ${window.screen.width}×${window.screen.height} app ${app.clientHeight} ` +
      `vv ${Math.round(visualViewport?.height || 0)} sat ${sa.top} sab ${sa.bottom} ` +
      `deck→${r('#deck')} trackpad→${r('#trackpad')}`]);
    remoteLog('info', [`hello from ${navigator.platform} ${innerWidth}×${innerHeight}@${devicePixelRatio}x ` +
      `${navigator.standalone ? 'home-screen app' : 'browser'} · ${navigator.userAgent.replace(/^Mozilla\/5.0 /, '')}`]);
  }, Math.max(0, 800 - performance.now()));
  if (fatal) return;
  if (screen.gotFrame && powered) reveal();
  else if (powered) setOverlay('booting', `Starting ${macName()}…`);
  else setOverlay('off', 'Tap to power on', offSub());
}

// ───── Connection ─────
let helloTimer = 0;
let lastProbe = '';
link = new Link({
  onState(state, code) {
    app.classList.toggle('connecting', state === 'connecting');
    app.classList.toggle('live', state === 'open');
    if (state === 'open') {
      failures = 0;
      everConnected = true;
      hideBanner();
      return;
    }
    if (state === 'kicked') {
      authed = false;
      fatal = 'kicked';
      setOverlay('error', 'Connected somewhere else', `${macName()} is now being used from another tab or device.`, 'Use here');
      return;
    }
    if (state === 'closed') {
      failures++;
      authed = false;
      keyboard.releaseAll();
      trackpad.reset();
      lidTouch.reset();
      screenPad.reset();
      if (code === 4002) {
        ticket = '';
        showAuth('Disconnected', 'After 30 minutes without use. Unlock again to carry on.', {
          buttons: [{ label: 'Reconnect', primary: true, onClick: () => { showAuth('Connecting…'); link.reconnectNow(); } }],
        });
        return;
      }
      if (code === 4003) {
        unpairLocally();
        showPairing('This iPhone was removed on the Mac. Pair it again to use it.');
        return;
      }
      if (code === 4004) return connectionsOff();
      if (fatal) return;
      if (screen.gotFrame && overlay.className === 'hidden') showBanner('Reconnecting…');
      else setOverlay('booting', 'Looking for your Mac…', failures > 2 ? 'Is Duo Mac open on the Mac, and Tailscale on on this iPhone?' : '');
    }
  },
  /** Moving a Tailscale session to the local route signs in with the reconnect ticket. */
  authMessage() {
    return authed && device && ticket ? { t: 'auth', dev: device.dev, tok: device.tok, ticket } : null;
  },
  onProbe(what) {
    if (what !== lastProbe) remoteLog('info', [`local route: ${what}`]);
    lastProbe = what;
  },
  onOpen() {
    // A fresh connection: earlier problems (permission, capture stopped) are re-reported by the Mac if still there.
    if (fatal === 'permission' || fatal === 'kicked') fatal = null;
    // The Mac says 'welcome' (with its name) first; authentication starts from there.
  },
  onMessage(m) {
    switch (m.t) {
      case 'hit':
        hitResult(m);
        break;
      case 'welcome':
        macLabel = m.mac || '';
        passkeyReady.then(startAuth);
        break;
      case 'auth-need':
        need = m;
        passkeyReady.then(() => showUnlock());
        break;
      case 'auth-fail':
        authFailed(m);
        break;
      case 'authed':
        onAuthed(m);
        break;
      case 'pair-wait':
        showAuth('Check your Mac', `Click Allow in the Duo Mac window on ${macName()}. It shows the same code:`, { match: m.match });
        break;
      case 'pair-fail':
        pairFailed(m.reason);
        break;
      case 'pair-approved':
        pairing = { passkey: false };
        setUpUnlock();
        break;
      case 'passkey-options':
        passkeyOpts = m.unavailable ? null : m;
        showFaceIDSetup();
        break;
      case 'passkey-ok':
        if (pairing) pairing.passkey = true;
        askPin('backup');
        break;
      case 'passkey-fail':
        link.send({ t: 'passkey-begin' }); // a fresh challenge, then try again
        break;
      case 'pin-ok':
        if (pairing) finishPairing();
        else { reveal(); showBanner('New PIN saved.', 'info', 3000); }
        break;
      case 'pin-fail':
        askPin(pairing ? (pairing.passkey ? 'backup' : 'required') : 'change', 'That PIN can’t be used. Choose 6 digits.');
        break;
      case 'paired':
        device = { dev: m.dev, tok: m.tok, mac: macLabel };
        saveDevice(device);
        break;
      case 'revoked':
        unpairLocally();
        break;
      case 'config':
        cfg = m;
        if (m.local?.hosts) {
          link.setLocal(m.local);
          try { localStorage.setItem(LOCAL_KEY, JSON.stringify(link.local)); } catch {}
        }
        screen.setDisplay(m.display);
        keyboard.setLayout({ iso: m.keyboard?.iso, labels: m.keyboard?.labels });
        layout();
        sheet.update(sheetInfo());
        if (m.perms && !m.perms.input) showBanner('Keyboard and trackpad are off: allow Accessibility for Duo Mac on the Mac.', 'error');
        if (powered && !screen.gotFrame && !fatal) setOverlay('booting', `Starting ${macName()}…`);
        if (!powered && !fatal) setOverlay('off', 'Tap to power on', offSub());
        break;
      case 'perms':
        if (m.input) hideBanner();
        else showBanner('Keyboard and trackpad are off: allow Accessibility for Duo Mac on the Mac.', 'error');
        if (cfg) cfg.perms = { screen: m.screen, input: m.input };
        break;
      case 'mic':
        if (cfg) cfg.mic = { installed: m.installed, update: m.update };
        if (m.status) { // just installed on the Mac
          sheet.update(sheetInfo());
          if (m.installed) showBanner('The Duo Mac Microphone is ready. Turn it on in Settings › Microphone.', 'info', 5000);
          break;
        }
        remoteLog('info', [`mic: the Mac says on=${m.on} installed=${m.installed}`]);
        if (!m.on) {
          micWanted = false;
          mic.stop();
          setSetting('mic', false);
          sheet.update(sheetInfo());
          showBanner(m.installed ? 'The Mac couldn’t use the iPhone microphone.' : micMissing(), 'warn', 8000);
        }
        break;
      case 'mic-listen':
        // A Mac app started (or stopped) listening to the Duo Mac Microphone.
        micWanted = !!m.on && settings.mic;
        clearTimeout(micIdle);
        if (micWanted) record();
        else micIdle = setTimeout(() => { if (!micWanted) mic.stop(); }, 3000); // dictation often stops and restarts
        break;
      case 'notice':
        if (m.level === 'error' && (m.code === 'screen-permission' || m.code === 'capture')) {
          fatal = 'permission';
          setOverlay('error', m.code === 'capture' ? 'Screen sharing stopped' : 'One more step on the Mac', m.msg, 'Try again');
        } else if (m.code !== 'idle') {
          showBanner(m.msg, m.level === 'error' ? 'error' : 'info', m.level === 'info' ? 4000 : 0);
        }
        break;
      case 'p': // where the Mac's pointer really is
        macCursor.server(m);
        break;
      case 'cursor': // what it looks like
        macCursor.setShape(m);
        break;
      case 'stats':
        serverStats = m;
        break;
    }
  },
  onFrame(buf) {
    if (new Uint8Array(buf, 0, 1)[0] === 2) { speaker.push(buf); return; } // the Mac's sound
    screen.enqueue(buf).then((id) => {
      if (id == null) return; // the video's description, not a frame
      link.send({ t: 'ack', f: id });
      if (powered && overlay.className !== 'hidden' && overlay.className !== 'auth') {
        if (fatal === 'permission') fatal = null; // frames again: the problem is gone
        reveal();
      }
    });
  },
});

function nanoRequest() {
  return { on: settings.macDisplay === 'nano', size: settings.nanoSize };
}

function sendHello() {
  lastBox = screen.boxPixels();
  link.send({ t: 'hello', v: 1, box: lastBox, q: settings.quality, standalone: !!navigator.standalone, nano: nanoRequest(), sound: !!settings.macSound, codec: codec() });
  if (settings.mic) link.send({ t: 'mic', on: true });
}

// ───── H.264 video: much less data than JPEG tiles when a lot changes (if the phone can decode it) ─────
let videoOK = false;
const codec = () => (videoOK && settings.video ? 'h264' : 'jpeg');
Screen.videoSupported().then((ok) => {
  videoOK = ok;
  remoteLog('info', [`video: H.264 decoding ${ok ? 'available' : 'not available'}`]);
  if (ok && settings.video && link.open) link.send({ t: 'codec', c: codec() });
});
let keyAsked = 0;
screen.onNeedKey = () => {
  if (performance.now() - keyAsked < 500) return;
  keyAsked = performance.now();
  link.send({ t: 'key' });
};

// ───── The Mac's sound, on the iPhone ─────
const speaker = new Speaker();

// ───── The iPhone's microphone, for the Mac ─────
const mic = new Mic((buf) => link.sendBinary(buf));
let micDenied = false;
let micWanted = false; // a Mac app is listening
let micIdle = 0;
const micMissing = () => cfg?.mic?.update
  ? 'Update the Duo Mac Microphone on your Mac first: menu bar › Settings… › General › Update….'
  : 'Add the Duo Mac Microphone on your Mac first: menu bar › Settings… › General › Install….';
/** The setting turned on (a tap): the Mac makes the Duo Mac Microphone its input; the iPhone records
 *  once an app listens to it. */
function micOn() {
  mic.unlock();
  link.send({ t: 'mic', on: true });
}
function micOff() {
  micWanted = false;
  mic.stop();
  link.send({ t: 'mic', on: false });
}
async function record() {
  if (document.hidden || mic.running) return;
  remoteLog('info', ['mic: a Mac app is listening, recording']);
  if (await mic.start()) {
    if (!micWanted) mic.stop(); // it stopped listening meanwhile
    else remoteLog('info', [`mic: recording at ${mic.ctx?.sampleRate} Hz`]);
    return;
  }
  remoteLog('warn', [`mic: couldn't start: ${mic.error}`]);
  if (mic.error === 'NotAllowedError') {
    micDenied = true; // don't ask again on every tap; flipping the setting retries
    showBanner('Microphone access was denied. Allow it for this app in iPhone Settings, then turn it on again.', 'warn', 7000);
  } else {
    // iOS wants a tap before it starts audio: the next one starts it (see pointerup).
    showBanner('The Mac wants your microphone: tap the screen to start it.', 'info', 6000);
  }
}

// ───── iPhone keyboard (dictation, emoji, accents) ─────
const iosInput = $('#ios-input');
const iosBar = $('#ios-bar');

function tapKey(code, mod = 0) {
  sendNow({ t: 'k', c: code, d: 1, mod });
  link.send({ t: 'k', c: code, d: 0, mod });
}

function resetIOSInput() {
  iosInput.value = ' ';
  try { iosInput.setSelectionRange(1, 1); } catch {}
}

function openIOSKeyboard() {
  resetIOSInput();
  iosInput.style.pointerEvents = 'auto';
  iosInput.focus({ preventScroll: true });
  iosBar.hidden = false;
}

function closeIOSKeyboard() {
  iosInput.blur();
}

iosInput.addEventListener('blur', () => {
  iosBar.hidden = true;
  iosInput.style.pointerEvents = 'none';
});
iosInput.addEventListener('beforeinput', (e) => {
  const t = e.inputType || '';
  if (t === 'insertText' || t === 'insertReplacementText' || t === 'insertFromPaste' || t === 'insertFromDictation') {
    const s = e.data ?? e.dataTransfer?.getData('text/plain') ?? '';
    if (s) sendNow({ t: 'txt', s });
    e.preventDefault();
  } else if (t === 'insertLineBreak' || t === 'insertParagraph') {
    tapKey(0x24);
    e.preventDefault();
  } else if (t === 'deleteContentBackward') {
    tapKey(0x33);
    e.preventDefault();
  } else if (t === 'deleteWordBackward') {
    tapKey(0x33, MOD.option);
    e.preventDefault();
  } else if (t === 'deleteContentForward') {
    tapKey(0x75);
    e.preventDefault();
  }
});
iosInput.addEventListener('compositionend', (e) => {
  if (e.data) sendNow({ t: 'txt', s: e.data });
  resetIOSInput();
});
iosInput.addEventListener('input', (e) => {
  if (!e.isComposing) resetIOSInput();
});
iosInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.isComposing && e.keyCode !== 229) {
    tapKey(0x24);
    e.preventDefault();
  }
});
$('#ios-done').addEventListener('click', closeIOSKeyboard);

// ───── Hardware keyboard (Bluetooth keyboard on the iPhone, or a desktop browser) ─────
// Physical key position (KeyboardEvent.code) → Mac virtual keycode, so the Mac's own layout applies.
const HW = {
  KeyA: 0x00, KeyS: 0x01, KeyD: 0x02, KeyF: 0x03, KeyH: 0x04, KeyG: 0x05, KeyZ: 0x06, KeyX: 0x07, KeyC: 0x08,
  KeyV: 0x09, IntlBackslash: 0x0A, KeyB: 0x0B, KeyQ: 0x0C, KeyW: 0x0D, KeyE: 0x0E, KeyR: 0x0F, KeyY: 0x10,
  KeyT: 0x11, Digit1: 0x12, Digit2: 0x13, Digit3: 0x14, Digit4: 0x15, Digit6: 0x16, Digit5: 0x17, Equal: 0x18,
  Digit9: 0x19, Digit7: 0x1A, Minus: 0x1B, Digit8: 0x1C, Digit0: 0x1D, BracketRight: 0x1E, KeyO: 0x1F, KeyU: 0x20,
  BracketLeft: 0x21, KeyI: 0x22, KeyP: 0x23, Enter: 0x24, KeyL: 0x25, KeyJ: 0x26, Quote: 0x27, KeyK: 0x28,
  Semicolon: 0x29, Backslash: 0x2A, Comma: 0x2B, Slash: 0x2C, KeyN: 0x2D, KeyM: 0x2E, Period: 0x2F, Tab: 0x30,
  Space: 0x31, Backquote: 0x32, Backspace: 0x33, Escape: 0x35, NumpadEnter: 0x4C, Delete: 0x75, Home: 0x73,
  End: 0x77, PageUp: 0x74, PageDown: 0x79, ArrowLeft: 0x7B, ArrowRight: 0x7C, ArrowDown: 0x7D, ArrowUp: 0x7E,
  F1: 0x7A, F2: 0x78, F3: 0x63, F4: 0x76, F5: 0x60, F6: 0x61, F7: 0x62, F8: 0x64, F9: 0x65, F10: 0x6D, F11: 0x67, F12: 0x6F,
};
const hwMods = (e) => (e.shiftKey ? MOD.shift : 0) | (e.ctrlKey ? MOD.control : 0) | (e.altKey ? MOD.option : 0) | (e.metaKey ? MOD.command : 0);
for (const type of ['keydown', 'keyup']) {
  window.addEventListener(type, (e) => {
    if (document.activeElement === iosInput || document.activeElement === authField || sheet.isOpen || !link.open || !authed) return;
    const code = HW[e.code];
    if (code === undefined) return;
    e.preventDefault();
    const m = { t: 'k', c: code, d: type === 'keydown' ? 1 : 0, mod: hwMods(e) };
    if (e.repeat) m.r = 1;
    sendNow(m);
  });
}

// ───── Stop the browser from zooming, selecting or scrolling ─────
document.addEventListener('touchstart', (e) => {
  if (!e.target.closest('#sheet, #ios-bar, button, input')) e.preventDefault();
}, { passive: false });
document.addEventListener('touchmove', (e) => {
  if (!e.target.closest('#sheet .panel')) e.preventDefault();
}, { passive: false });
for (const ev of ['gesturestart', 'gesturechange', 'gestureend', 'contextmenu', 'dblclick']) {
  document.addEventListener(ev, (e) => e.preventDefault());
}

// ───── Background / foreground ─────
// Folded shut / switched apps: let go of everything and hang up, so the Mac stops capturing and can
// sleep. Coming back reconnects (≈half a second) instead of trusting a socket iOS may have frozen.
// While pairing or unlocking the link stays up (the passkey sheet may hide the page for a moment).
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    micWanted = false;
    mic.stop(); // the link closes; reconnecting turns it back on
    keyboard.releaseAll();
    trackpad.reset();
    lidTouch.reset();
    screenPad.reset();
    link.send({ t: 'rel' });
    if (link.open && authed) link.close();
  } else if (!fatal && !lidClosed) {
    link.reconnectNow();
  }
});
window.addEventListener('pagehide', () => link.send({ t: 'rel' }));

// ───── Stats overlay ─────
let prev = { frames: 0, bytes: 0, decodeMs: 0 };
setInterval(() => {
  const f = screen.frames - prev.frames, b = screen.bytes - prev.bytes, d = screen.decodeMs - prev.decodeMs;
  prev = { frames: screen.frames, bytes: screen.bytes, decodeMs: screen.decodeMs };
  if (!settings.stats) return;
  statsEl.hidden = false;
  statsEl.innerHTML =
    `<b>${f}</b> fps · <b>${(b / 1024).toFixed(0)}</b> KB/s · <b>${Math.round(link.rtt)}</b> ms\n` +
    `<span class="dim">${screen.streamW}×${screen.streamH} · ${settings.quality} ${serverStats?.q ?? 100}% · frame ${serverStats?.frameRtt ?? '–'} ms · ` +
    `decode ${f ? (d / f).toFixed(1) : '–'} · encode ${serverStats?.encodeMs ?? '–'} ms${screen.zoom.s > 1.01 ? ` · zoom ${screen.zoom.s.toFixed(1)}×` : ''}</span>`;
}, 1000);

// Debug handle (Safari Web Inspector / tests).
window.__nano = { screen, keyboard, trackpad, sheet, get link() { return link; }, settings };

// ───── Start ─────
applyTheme();
statsEl.hidden = !settings.stats;
layout();
requestAnimationFrame(layout);

setOverlay('booting', 'Looking for your Mac…');
// Local mode: where the Mac was on the local network last time (it says so in each config).
const LOCAL_KEY = 'nano.local.v1';
try { link.setLocal(JSON.parse(localStorage.getItem(LOCAL_KEY) || 'null')); } catch {}
link.connect();
// A copy of the app on this iPhone, so it opens even when Tailscale can't be reached (offline,
// abroad): it then finds the Mac on the same Wi-Fi or hotspot (sw.js).
if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('sw.js').catch(() => {});

// ───── Self-test (?autotest=1): drives the UI with synthetic touches ─────
if (params.has('autotest')) {
  const wait = (ms) => new Promise((r) => setTimeout(r, ms));
  const fire = (el, type, id, x, y) => el.dispatchEvent(new PointerEvent(type, {
    pointerId: id, pointerType: 'touch', isPrimary: id === 1, clientX: x, clientY: y,
    bubbles: true, cancelable: true, buttons: type === 'pointerup' ? 0 : 1,
  }));
  const tapEl = async (el, id) => {
    const r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
    fire(el, 'pointerdown', id, x, y);
    await wait(50);
    fire(el, 'pointerup', id, x, y);
    await wait(60);
  };
  const run = async () => {
    while (!screen.gotFrame) await wait(100);
    if (!powered) powerOn();
    await wait(300);
    const log = (msg) => link.send({ t: 'log', level: 'test', msg });
    log('autotest: start');
    const pad = $('#padzone'), r = $('#trackpad').getBoundingClientRect();
    const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
    // move
    fire(pad, 'pointerdown', 1, cx, cy);
    for (let i = 1; i <= 15; i++) { await wait(16); fire(pad, 'pointermove', 1, cx - i * 8, cy - i * 4); }
    fire(pad, 'pointerup', 1, cx - 120, cy - 60);
    await wait(400);
    // click
    fire(pad, 'pointerdown', 2, cx, cy); await wait(50); fire(pad, 'pointerup', 2, cx, cy);
    await wait(400);
    // type "Nano!" (shift latched for N, then shift held for !)
    await tapEl(keyboard.keyEl(0x38), 3);
    for (const code of [0x2D, 0x00, 0x2D, 0x1F]) await tapEl(keyboard.keyEl(code), 4);
    await tapEl(keyboard.keyEl(0x31), 5);
    for (const code of [0x12, 0x13, 0x14]) await tapEl(keyboard.keyEl(code), 6);
    // two-finger scroll
    fire(pad, 'pointerdown', 7, cx - 20, cy); fire(pad, 'pointerdown', 8, cx + 20, cy);
    for (let i = 1; i <= 10; i++) { await wait(16); fire(pad, 'pointermove', 7, cx - 20, cy - i * 6); fire(pad, 'pointermove', 8, cx + 20, cy - i * 6); }
    fire(pad, 'pointerup', 7, cx - 20, cy - 60); fire(pad, 'pointerup', 8, cx + 20, cy - 60);
    await wait(900);
    // two-finger tap
    fire(pad, 'pointerdown', 9, cx - 20, cy); fire(pad, 'pointerdown', 10, cx + 20, cy); await wait(60);
    fire(pad, 'pointerup', 9, cx - 20, cy); fire(pad, 'pointerup', 10, cx + 20, cy);
    await wait(300);
    // tap on the screen half (touchscreen click near the top-left)
    const sr = $('#screen').getBoundingClientRect();
    fire($('#screen-area'), 'pointerdown', 11, sr.left + sr.width * 0.25, sr.top + sr.height * 0.25);
    await wait(40);
    fire($('#screen-area'), 'pointerup', 11, sr.left + sr.width * 0.25, sr.top + sr.height * 0.25);
    await wait(500);
    log(`autotest: done sent=${JSON.stringify(link.sent)} frames=${screen.frames} stream=${screen.streamW}x${screen.streamH}`);
    window.__autotest = { done: true, sent: { ...link.sent }, frames: screen.frames };
  };
  run().catch((e) => console.error('autotest failed', e));
}
