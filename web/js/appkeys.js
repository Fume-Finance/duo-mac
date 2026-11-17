// The keyboard's top row follows the app in front on the Mac (the Mac says which, see NanoCore's
// frontApp): its most useful shortcuts, sized for a finger. fn still gives F1–F12.
// Each key: { l: label, k: [keyCode, mods] } (a shortcut) or { l, act } (a Duo Mac action).

const S = 1, C = 2, O = 4, M = 8; // shift, control, option, command (keyboard.js MOD)
const K = {
  a: 0x00, s: 0x01, d: 0x02, f: 0x03, h: 0x04, g: 0x05, z: 0x06, x: 0x07, c: 0x08, v: 0x09, b: 0x0B, q: 0x0C,
  w: 0x0D, e: 0x0E, r: 0x0F, y: 0x10, t: 0x11, o: 0x1F, u: 0x20, i: 0x22, p: 0x23, l: 0x25, j: 0x26, k: 0x28,
  n: 0x2D, m: 0x2E, '[': 0x21, ']': 0x1E, '/': 0x2C, '.': 0x2F, ',': 0x2B, '`': 0x32, '\\': 0x2A,
  ret: 0x24, tab: 0x30, space: 0x31, del: 0x33, esc: 0x35, left: 0x7B, right: 0x7C, down: 0x7D, up: 0x7E,
};
const key = (l, k, mods = 0) => ({ l, k: [K[k], mods] });

const undo = key('Undo', 'z', M), redo = key('Redo', 'z', M | S);
const copy = key('Copy', 'c', M), paste = key('Paste', 'v', M);

const BROWSER = [key('‹ Back', '[', M), key('Fwd ›', ']', M), key('Reload', 'r', M), key('Address', 'l', M),
  key('New Tab', 't', M), key('Close Tab', 'w', M), key('Reopen', 't', M | S)];
const TERMINAL = [key('⌃C', 'c', C), key('⇧Tab', 'tab', S), key('Clear', 'k', M), key('New Tab', 't', M),
  key('‹ Tab', '[', M | S), key('Tab ›', ']', M | S), key('Close', 'w', M)];
const CODE = [key('Commands', 'p', M | S), key('Open…', 'p', M), key('Find', 'f', M | S), key('Comment', '/', M),
  key('Terminal', '`', C), key('Save', 's', M), undo];
const CHAT = [key('Find', 'k', M), key('‹ Chat', 'tab', C | S), key('Chat ›', 'tab', C), key('Emoji', 'space', C | M),
  key('New', 'n', M), undo, paste];

const SETS = [
  [/^com\.apple\.Safari|^com\.google\.Chrome|^company\.thebrowser\.|^com\.brave\.Browser|^org\.mozilla\.firefox|^com\.microsoft\.edgemac|^com\.operasoftware\.|^com\.vivaldi\./, BROWSER],
  [/^com\.apple\.Terminal$|^com\.googlecode\.iterm2$|^com\.mitchellh\.ghostty$|^dev\.warp\.|^net\.kovidgoyal\.kitty$|^com\.github\.wez\.wezterm$|^co\.zeit\.hyper$|^io\.alacritty$/, TERMINAL],
  [/^com\.microsoft\.VSCode|^com\.todesktop\.230313mzl4w4u92$|^dev\.zed\.Zed|^com\.sublimetext\./, CODE],
  [/^com\.apple\.dt\.Xcode$/, [key('Run', 'r', M), key('Stop', '.', M), key('Build', 'b', M), key('Open…', 'o', M | S),
    key('Find', 'f', M | S), key('Comment', '/', M), undo]],
  [/^com\.apple\.finder$/, [key('‹ Back', '[', M), key('Fwd ›', ']', M), key('Up', 'up', M), key('New Folder', 'n', M | S),
    key('Info', 'i', M), key('Quick Look', 'space'), key('Trash', 'del', M)]],
  [/^com\.apple\.mail$/, [key('New', 'n', M), key('Reply', 'r', M), key('Reply All', 'r', M | S), key('Forward', 'f', M | S),
    key('Archive', 'a', M | C), key('Send', 'd', M | S), key('Delete', 'del')]],
  [/^com\.apple\.Notes$/, [key('New Note', 'n', M), key('Checklist', 'l', M | S), key('Bold', 'b', M), key('Find', 'f', M),
    copy, paste, undo]],
  [/^com\.apple\.MobileSMS$|^net\.whatsapp\.|^com\.tinyspeck\.slackmacgap$|^ru\.keepcoder\.Telegram$|^com\.hnc\.Discord$/, CHAT],
  [/^com\.apple\.iWork\.Keynote$/, [key('Play', 'p', M | O), key('New Slide', 'n', M | S), key('‹ Slide', 'up'),
    key('Slide ›', 'down'), copy, paste, undo]],
  [/^com\.anthropic\.claudefordesktop$|^com\.openai\.chat$/, [key('New Chat', 'n', M), key('Find', 'k', M), copy, paste, undo, redo]],
];

const DEFAULT = [key('Spotlight', 'space', M), { l: 'Mission', act: 'missionControl' }, { l: 'Windows', act: 'appExpose' },
  key('Switch', 'tab', M), copy, paste, undo, redo];

/** The keys for the app in front ({ id: bundle ID, name }). */
export function appKeysFor(app) {
  const id = app?.id || '';
  for (const [re, keys] of SETS) if (re.test(id)) return keys;
  return DEFAULT;
}

export const MAX_APP_KEYS = 8;
