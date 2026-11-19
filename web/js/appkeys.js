// The keyboard's top row follows the app in front on the Mac (the Mac says which, see NanoCore's
// frontApp): its most useful shortcuts, then always copy, paste, undo, redo and dictate. All icons;
// fn still gives F1–F12.
// Each key: { l: label (for VoiceOver), i: icon, k: [keyCode, mods] } (a shortcut) or { l, i, act }.

const S = 1, C = 2, O = 4, M = 8; // shift, control, option, command (keyboard.js MOD)
const K = {
  a: 0x00, s: 0x01, d: 0x02, f: 0x03, h: 0x04, g: 0x05, z: 0x06, x: 0x07, c: 0x08, v: 0x09, b: 0x0B, q: 0x0C,
  w: 0x0D, e: 0x0E, r: 0x0F, y: 0x10, t: 0x11, o: 0x1F, u: 0x20, i: 0x22, p: 0x23, l: 0x25, j: 0x26, k: 0x28,
  n: 0x2D, m: 0x2E, '[': 0x21, ']': 0x1E, '/': 0x2C, '.': 0x2F, ',': 0x2B, '`': 0x32, '\\': 0x2A,
  ret: 0x24, tab: 0x30, space: 0x31, del: 0x33, esc: 0x35, left: 0x7B, right: 0x7C, down: 0x7D, up: 0x7E,
};

const svg = (body) => `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;

/** Icons, 16×16, drawn like SF Symbols' outlines. */
export const ICONS = {
  back: svg('<path d="M10 3 5 8l5 5"/>'),
  forward: svg('<path d="M6 3l5 5-5 5"/>'),
  reload: svg('<path d="M13 8a5 5 0 1 1-1.5-3.6"/><path d="M13 2.5v3h-3"/>'),
  address: svg('<circle cx="8" cy="8" r="5.5"/><path d="M2.5 8h11M8 2.5c-1.8 2-1.8 9 0 11M8 2.5c1.8 2 1.8 9 0 11"/>'),
  newTab: svg('<rect x="2" y="3" width="12" height="10" rx="2"/><path d="M8 6v4M6 8h4"/>'),
  closeTab: svg('<rect x="2" y="3" width="12" height="10" rx="2"/><path d="M6.3 6.3l3.4 3.4M9.7 6.3 6.3 9.7"/>'),
  reopen: svg('<path d="M4 6h6a3.5 3.5 0 0 1 0 7H7"/><path d="M6.5 3.5 4 6l2.5 2.5"/>'),
  interrupt: svg('<rect x="3" y="3" width="10" height="10" rx="2"/><path d="M6 6.5h1.6M6 9.5h1.6M6 6.5v3M9.3 6.5v3"/>'),
  mode: svg('<path d="M3 5.5h8M8.5 3l2.5 2.5L8.5 8M13 10.5H5M7.5 8 5 10.5 7.5 13"/>'),
  clear: svg('<path d="M3 13h10M5.5 10.5 11 5M4.5 9.5l2 2L13 5l-2-2z"/>'),
  prevTab: svg('<rect x="2" y="3" width="12" height="10" rx="2"/><path d="M9 6 7 8l2 2"/>'),
  nextTab: svg('<rect x="2" y="3" width="12" height="10" rx="2"/><path d="M7 6l2 2-2 2"/>'),
  close: svg('<path d="M4 4l8 8M12 4l-8 8"/>'),
  commands: svg('<rect x="2" y="3" width="12" height="10" rx="2"/><path d="M5 7l1.8 1.5L5 10M8 10h3"/>'),
  open: svg('<path d="M4 2.5h5l3 3V13a.5.5 0 0 1-.5.5h-7.5a.5.5 0 0 1-.5-.5V3a.5.5 0 0 1 .5-.5z"/><path d="M9 2.5v3h3"/>'),
  find: svg('<circle cx="7" cy="7" r="4"/><path d="M10 10l3.5 3.5"/>'),
  comment: svg('<path d="M6.5 3 4 13M12 3 9.5 13"/>'),
  terminal: svg('<rect x="2" y="3" width="12" height="10" rx="2"/><path d="M5 6.5 7 8l-2 1.5M8.5 10H11"/>'),
  save: svg('<path d="M8 2.5v7M5 7l3 3 3-3M3 11.5V13h10v-1.5"/>'),
  run: svg('<path d="M5 3.5v9l7-4.5z"/>'),
  stop: svg('<rect x="4" y="4" width="8" height="8" rx="1"/>'),
  build: svg('<path d="M9.5 2.5 13.5 6.5 12 8l-4-4zM10 6 3 13"/>'),
  up: svg('<path d="M8 13V3M4 7l4-4 4 4"/>'),
  newFolder: svg('<path d="M2 4.5V12a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1H8L6.5 3.5H3a1 1 0 0 0-1 1z"/><path d="M8 7.5v3.5M6.25 9.25h3.5"/>'),
  info: svg('<circle cx="8" cy="8" r="5.5"/><path d="M8 7.5V11M8 5.2v.1"/>'),
  look: svg('<path d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z"/><circle cx="8" cy="8" r="2"/>'),
  trash: svg('<path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5"/>'),
  compose: svg('<path d="M12.5 2.5l1 1L8 9l-1.5.5L7 8z"/><path d="M12 8.5V13H3V4h4.5"/>'),
  reply: svg('<path d="M6.5 4 3 7.5 6.5 11"/><path d="M3 7.5h6a4 4 0 0 1 4 4V12"/>'),
  replyAll: svg('<path d="M8.5 4 5 7.5 8.5 11M5 4 1.5 7.5 5 11"/><path d="M5 7.5h5a4 4 0 0 1 4 4V12"/>'),
  forwardMail: svg('<path d="M9.5 4 13 7.5 9.5 11"/><path d="M13 7.5H7a4 4 0 0 0-4 4V12"/>'),
  archive: svg('<rect x="2" y="3" width="12" height="3" rx=".8"/><path d="M3 6v7h10V6M6.5 8.5h3"/>'),
  send: svg('<path d="M2.5 8 13.5 3 10 13.5 7.5 9z"/><path d="M7.5 9l6-6"/>'),
  note: svg('<rect x="3" y="2.5" width="10" height="11" rx="1.5"/><path d="M5.5 6h5M5.5 8.5h5M5.5 11h3"/>'),
  checklist: svg('<path d="M2.5 4.5 4 6l2-2.5M2.5 10.5 4 12l2-2.5M8 5h5.5M8 11h5.5"/>'),
  bold: svg('<path d="M5 3h4a2.5 2.5 0 0 1 0 5H5zM5 8h4.5a2.5 2.5 0 0 1 0 5H5z"/>'),
  emoji: svg('<circle cx="8" cy="8" r="5.5"/><path d="M5.5 9.5a3 3 0 0 0 5 0M6 6.3v.4M10 6.3v.4"/>'),
  play: svg('<rect x="2" y="3" width="12" height="9" rx="1.5"/><path d="M7 5.8v3.4l2.8-1.7zM8 12v2"/>'),
  newSlide: svg('<rect x="2" y="4" width="12" height="9" rx="1.5"/><path d="M8 6.5v4M6 8.5h4M4 2.5h8"/>'),
  prevSlide: svg('<path d="M8 13V3M4 7l4-4 4 4"/>'),
  nextSlide: svg('<path d="M8 3v10M4 9l4 4 4-4"/>'),
  spotlight: svg('<circle cx="7" cy="7" r="4"/><path d="M10 10l3.5 3.5"/>'),
  mission: svg('<rect x="2" y="3" width="5" height="4" rx="1"/><rect x="9" y="3" width="5" height="4" rx="1"/><rect x="2" y="9" width="5" height="4" rx="1"/><rect x="9" y="9" width="5" height="4" rx="1"/>'),
  windows: svg('<rect x="2" y="5" width="9" height="8" rx="1.3"/><path d="M5 3h8a1 1 0 0 1 1 1v6"/>'),
  switchApp: svg('<path d="M3 5.5h9M9.5 3 12 5.5 9.5 8M13 10.5H4M6.5 8 4 10.5 6.5 13"/>'),
  copy: svg('<rect x="5" y="5" width="8.5" height="8.5" rx="1.6"/><path d="M11 5V3.6A1.6 1.6 0 0 0 9.4 2H3.6A1.6 1.6 0 0 0 2 3.6v5.8A1.6 1.6 0 0 0 3.6 11H5"/>'),
  paste: svg('<rect x="3" y="3" width="10" height="11.5" rx="1.6"/><path d="M6 3V2h4v1M5.5 7h5M5.5 10h3.5"/>'),
  undo: svg('<path d="M5 3.5 2.5 6 5 8.5"/><path d="M2.5 6h7a4 4 0 0 1 0 8H7"/>'),
  redo: svg('<path d="M11 3.5 13.5 6 11 8.5"/><path d="M13.5 6h-7a4 4 0 0 0 0 8H9"/>'),
  dictate: svg('<rect x="5.8" y="1.5" width="4.4" height="8" rx="2.2"/><path d="M3.5 7.5a4.5 4.5 0 0 0 9 0M8 12v2.5"/>'),
  ret: svg('<path d="M13.5 3v5.5a2 2 0 0 1-2 2H3"/><path d="M5.5 8 3 10.5 5.5 13"/>'),
  screenshot: svg('<path d="M2 5V3.5A1.5 1.5 0 0 1 3.5 2H5M11 2h1.5A1.5 1.5 0 0 1 14 3.5V5M14 11v1.5a1.5 1.5 0 0 1-1.5 1.5H11M5 14H3.5A1.5 1.5 0 0 1 2 12.5V11"/><path d="M8 5.5v5M5.5 8h5"/>'),
  command: svg('<path d="M6 6h4v4H6zM6 6V4.6A1.6 1.6 0 1 0 4.6 6H6M10 6V4.6A1.6 1.6 0 1 1 11.4 6H10M6 10v1.4A1.6 1.6 0 1 1 4.6 10H6M10 10v1.4a1.6 1.6 0 1 0 1.4-1.4H10"/>'),
  keyboard: svg('<rect x="1.5" y="4" width="13" height="8" rx="1.6"/><path d="M4 6.5h.5M6.5 6.5h.5M9 6.5h.5M11.5 6.5h.5M5 9.5h6"/>'),
};

const key = (l, i, k, mods = 0) => ({ l, i, k: [K[k], mods] });

/** Always at the end of the row (and beside the trackpad). */
export const COPY = key('Copy', 'copy', 'c', M);
export const PASTE = key('Paste', 'paste', 'v', M);
export const UNDO = key('Undo', 'undo', 'z', M);
export const REDO = key('Redo', 'redo', 'z', M | S);
export const DICTATE = { l: 'Dictate', i: 'dictate', act: 'dictate' };
export const RETURN = key('Return', 'ret', 'ret');
const ALWAYS = [COPY, PASTE, UNDO, REDO, DICTATE];

const BROWSER = [key('Back', 'back', '[', M), key('Forward', 'forward', ']', M), key('Reload', 'reload', 'r', M),
  key('Address bar', 'address', 'l', M), key('New tab', 'newTab', 't', M), key('Close tab', 'closeTab', 'w', M),
  key('Reopen closed tab', 'reopen', 't', M | S)];
const TERMINAL = [key('Interrupt (⌃C)', 'interrupt', 'c', C), key('Shift-Tab', 'mode', 'tab', S), key('Clear', 'clear', 'k', M),
  key('New tab', 'newTab', 't', M), key('Previous tab', 'prevTab', '[', M | S), key('Next tab', 'nextTab', ']', M | S),
  key('Close', 'close', 'w', M)];
const CODE = [key('Command palette', 'commands', 'p', M | S), key('Open file', 'open', 'p', M), key('Find in files', 'find', 'f', M | S),
  key('Comment', 'comment', '/', M), key('Terminal', 'terminal', '`', C), key('Save', 'save', 's', M)];
const CHAT = [key('Find', 'find', 'k', M), key('Previous chat', 'back', 'tab', C | S), key('Next chat', 'forward', 'tab', C),
  key('Emoji', 'emoji', 'space', C | M), key('New', 'compose', 'n', M)];

const SETS = [
  [/^com\.apple\.Safari|^com\.google\.Chrome|^company\.thebrowser\.|^com\.brave\.Browser|^org\.mozilla\.firefox|^com\.microsoft\.edgemac|^com\.operasoftware\.|^com\.vivaldi\./, BROWSER],
  [/^com\.apple\.Terminal$|^com\.googlecode\.iterm2$|^com\.mitchellh\.ghostty$|^dev\.warp\.|^net\.kovidgoyal\.kitty$|^com\.github\.wez\.wezterm$|^co\.zeit\.hyper$|^io\.alacritty$/, TERMINAL],
  [/^com\.microsoft\.VSCode|^com\.todesktop\.230313mzl4w4u92$|^dev\.zed\.Zed|^com\.sublimetext\./, CODE],
  [/^com\.apple\.dt\.Xcode$/, [key('Run', 'run', 'r', M), key('Stop', 'stop', '.', M), key('Build', 'build', 'b', M),
    key('Open quickly', 'open', 'o', M | S), key('Find in project', 'find', 'f', M | S), key('Comment', 'comment', '/', M)]],
  [/^com\.apple\.finder$/, [key('Back', 'back', '[', M), key('Forward', 'forward', ']', M), key('Enclosing folder', 'up', 'up', M),
    key('New folder', 'newFolder', 'n', M | S), key('Get info', 'info', 'i', M), key('Quick Look', 'look', 'space'),
    key('Move to Trash', 'trash', 'del', M)]],
  [/^com\.apple\.mail$/, [key('New message', 'compose', 'n', M), key('Reply', 'reply', 'r', M), key('Reply all', 'replyAll', 'r', M | S),
    key('Forward', 'forwardMail', 'f', M | S), key('Archive', 'archive', 'a', M | C), key('Send', 'send', 'd', M | S),
    key('Delete', 'trash', 'del')]],
  [/^com\.apple\.Notes$/, [key('New note', 'note', 'n', M), key('Checklist', 'checklist', 'l', M | S), key('Bold', 'bold', 'b', M),
    key('Find', 'find', 'f', M)]],
  [/^com\.apple\.MobileSMS$|^net\.whatsapp\.|^com\.tinyspeck\.slackmacgap$|^ru\.keepcoder\.Telegram$|^com\.hnc\.Discord$/, CHAT],
  [/^com\.apple\.iWork\.Keynote$/, [key('Play', 'play', 'p', M | O), key('New slide', 'newSlide', 'n', M | S),
    key('Previous slide', 'prevSlide', 'up'), key('Next slide', 'nextSlide', 'down')]],
  [/^com\.anthropic\.claudefordesktop$|^com\.openai\.chat$/, [key('New chat', 'compose', 'n', M), key('Find', 'find', 'k', M)]],
];

const DEFAULT = [key('Spotlight', 'spotlight', 'space', M), { l: 'Mission Control', i: 'mission', act: 'missionControl' },
  { l: 'App windows', i: 'windows', act: 'appExpose' }, key('Switch app', 'switchApp', 'tab', M)];

/** The top row for the app in front ({ id: bundle ID, name }): its keys, then copy … dictate. */
export function appKeysFor(app) {
  const id = app?.id || '';
  const own = (SETS.find(([re]) => re.test(id)) || [null, DEFAULT])[1];
  return [...own.slice(0, MAX_APP_KEYS - ALWAYS.length), ...ALWAYS];
}

export const MAX_APP_KEYS = 12;
