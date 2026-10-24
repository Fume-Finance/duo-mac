// Per-device preferences, kept in localStorage (the Home Screen app has its own copy).
const KEY = 'nano.settings.v1';

export const DEFAULTS = {
  tracking: 1,          // pointer speed multiplier
  scrollSpeed: 1,
  naturalScroll: true,  // content follows your fingers
  touchscreen: true,    // tap the screen half to click there
  sounds: true,
  volume: 0.55,
  haptics: true,
  fnStandard: false,    // top row sends F1…F12 instead of brightness/volume
  quality: 'balanced',  // fast | balanced | sharp
  theme: 'spaceblack',  // spaceblack | silver
  hinge: null,          // screen share of the height (the fold); null = automatic for this phone
  hingePad: null,       // the same for the Trackpad layout, kept separately
  stats: false,
  notch: false,
  topEdge: 'full',      // iPhone Duo: clear (screen starts below the status bar) | full (runs under it)
  chime: true,
  layout: 'laptop',     // laptop | screen
  macDisplay: 'nano',   // nano: a Mac display shaped like this screen (fills it) | mirror: the Mac's own screen
  nanoSize: 'default',  // large (bigger text) | default | more (more space)
  hintSeen: false,
  mic: false,           // stream this iPhone's microphone to the Mac (the Duo Mac Microphone)
  foldCloses: true,     // iPhone Duo: folding it shows a closed lid (and lets the Mac sleep)
  seenDuo: false,       // this phone has opened up into an iPhone Duo's inner screen
  defaultsRev: 2,       // bumped when a default changes for everyone (see upgrade)
};

/** Settings saved before defaults changed take the new defaults for those keys. */
export function upgrade(v) {
  if (!v || typeof v !== 'object' || Object.keys(v).length === 0) return v;
  if (!(v.defaultsRev >= 2)) {
    delete v.notch;   // rev 2: no notch, Full screen top edge
    delete v.topEdge;
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

export function onSetting(fn) {
  listeners.add(fn);
}
