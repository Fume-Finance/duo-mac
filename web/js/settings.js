// Per-device preferences, kept in localStorage (the Home Screen app has its own copy).
const KEY = 'nano.settings.v1';

export const DEFAULTS = {
  tracking: 1,          // pointer speed multiplier
  scrollSpeed: 1,
  naturalScroll: true,  // content follows your fingers
  touchscreen: true,    // tap the screen half to click there (Laptop and Trackpad layouts)
  screenTouch: 'touch', // Screen only: touch (tap where you want to click) | trackpad (the whole screen is one)
  sounds: true,         // key clicks (the keyboard)
  padSounds: true,      // click sounds for the trackpad's drag and the shortcut buttons
  volume: 0.55,
  haptics: true,
  padButtons: true,     // copy, paste, undo, dictate, return beside the trackpad (when there's room)
  toolButtons: 'command,copy,paste,undo,redo,screenshot,dictate,keyboard', // full screen: which buttons show next to ⚙︎ (always there)
  fnStandard: false,    // top row sends F1…F12 instead of the Mac app's keys (appkeys.js)
  quality: 'balanced',  // fast | balanced | sharp
  theme: 'spaceblack',  // spaceblack | silver
  keyboardSize: 'full', // Laptop layout: full (edge to edge, bigger keys) | macbook (margins, speaker grilles)
  hinge: null,          // screen share of the height (the fold); null = automatic for this phone
  hingePad: null,       // the same for the Trackpad layout, kept separately
  hingeKb: null,        // and for the Keyboard layout (null: just enough room for the keys)
  stats: false,
  notch: false,
  topEdge: 'full',      // iPhone Duo: clear (screen starts below the status bar) | full (runs under it)
  chime: true,
  layout: 'laptop',     // laptop | keyboard (no trackpad: the screen is one) | trackpad | screen
  macDisplay: 'nano',   // nano: a Mac display shaped like this screen (fills it) | mirror: the Mac's own screen
  nanoSize: 'default',  // large (bigger text) | default | more (more space)
  hintSeen: false,
  mic: false,           // stream this iPhone's microphone to the Mac (the Duo Mac Microphone)
  macSound: true,       // play the Mac's sound on this iPhone
  video: true,          // H.264 video when the phone can decode it (else JPEG tiles)
  clipSync: true,
  dictationEngine: 'apple', // the iPhone app: apple (fast, live) | whisper (most accurate, any language; a 630 MB download)
  smooth: true,         // the iPhone app on a ProMotion screen: up to 120 frames a second
  foldCloses: false,    // iPhone Duo: folding it shows a closed lid (and lets the Mac sleep); off: full screen
  touchId: '',          // where its Touch ID is (main.js TOUCH_ID_SPOTS): '' until the first passkey
  seenDuo: false,       // this phone has opened up into an iPhone Duo's inner screen
  duoShort: 0,          // that inner screen's short side (CSS px), to tell folded from unfolded
  defaultsRev: 6,       // bumped when a default changes for everyone (see upgrade)
};

/** Settings saved before defaults changed take the new defaults for those keys. */
export function upgrade(v) {
  if (!v || typeof v !== 'object' || Object.keys(v).length === 0) return v;
  if (!(v.defaultsRev >= 2)) {
    delete v.notch;   // rev 2: no notch, Full screen top edge
    delete v.topEdge;
  }
  if (!(v.defaultsRev >= 3)) delete v.foldCloses; // rev 3: folded = keep using it, full screen
  // rev 5: no longer settings (always edge-to-edge keys, no notch, H.264, 120 fps where possible)
  if (!(v.defaultsRev >= 5)) { delete v.keyboardSize; delete v.notch; delete v.video; delete v.smooth; }
  // rev 4: the Screenshot button, shown unless turned off
  if (!(v.defaultsRev >= 4) && typeof v.toolButtons === 'string' && !v.toolButtons.includes('screenshot')) {
    v.toolButtons = v.toolButtons ? `${v.toolButtons},screenshot` : 'screenshot';
  }
  // rev 6: the ⌘ button (held until tapped again), shown unless turned off
  if (!(v.defaultsRev >= 6) && typeof v.toolButtons === 'string' && !v.toolButtons.includes('command')) {
    v.toolButtons = v.toolButtons ? `command,${v.toolButtons}` : 'command';
  }
  v.defaultsRev = DEFAULTS.defaultsRev;
  return v;
}

function load() {
  try {
    const v = JSON.parse(localStorage.getItem(KEY) || '{}');
    return v && typeof v === 'object' ? v : {};
  } catch {
    return {};
  }
}

const stored = upgrade(load());
/** Nothing saved on this phone yet (first run, or the Home Screen app was added again). */
export const freshInstall = Object.keys(stored).length === 0;
export const settings = Object.assign({}, DEFAULTS, stored);

const listeners = new Set();

export function setSetting(key, value) {
  if (settings[key] === value) return;
  settings[key] = value;
  try { localStorage.setItem(KEY, JSON.stringify(settings)); } catch {}
  for (const fn of listeners) fn(key, value);
}

/** Settings › Reset all: back to the defaults, keeping what this phone has learnt about itself. */
export function resetSettings() {
  const keep = { seenDuo: settings.seenDuo, duoShort: settings.duoShort, touchId: settings.touchId, sheetSeen: true, hintSeen: true };
  try { localStorage.setItem(KEY, JSON.stringify({ ...DEFAULTS, ...keep })); } catch {}
}

export function onSetting(fn) {
  listeners.add(fn);
}
