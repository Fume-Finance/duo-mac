// iOS Safari has no vibration API, but a native <input type="checkbox" switch> plays a haptic tick
// when it's toggled. Since iOS 26.5 only a real tap does that (WebKit bug 309082): a scripted
// label.click() no longer ticks. So keys and the trackpad carry an invisible switch right under the
// finger, and the tap's own click toggles it, ticking as the finger lifts. Elsewhere: navigator.vibrate.
import { settings } from './settings.js';
import { native } from './native.js';

export const isIOS = /iPhone|iPad|iPod/.test(navigator.userAgent) ||
  (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

/** Covers `el` (which must be positioned) with an invisible switch, so tapping it ticks on iOS. */
export function addHapticSwitch(el) {
  if (!isIOS || native) return; // the iPhone app ticks for real
  const sw = document.createElement('input');
  sw.type = 'checkbox';
  sw.setAttribute('switch', '');
  sw.className = 'hap';
  sw.tabIndex = -1;
  sw.setAttribute('aria-hidden', 'true');
  el.appendChild(sw);
}

/** A tick from script: in the iPhone app, or off iOS. */
export function haptic(kind = 'light') {
  if (!settings.haptics) return;
  if (native) native.haptic(kind);
  else if (!isIOS) navigator.vibrate?.(8);
}

/** Where Safari ticks through a switch (a tap on the trackpad): only the iPhone app needs a call. */
export function tapHaptic() {
  if (settings.haptics && native) native.haptic('light');
}
