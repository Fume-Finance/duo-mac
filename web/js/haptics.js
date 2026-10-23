// iOS Safari has no vibration API, but a native <input type="checkbox" switch> plays a haptic tick
// when it's toggled. Since iOS 26.5 only a real tap does that (WebKit bug 309082): a scripted
// label.click() no longer ticks. So keys and the trackpad carry an invisible switch right under the
// finger, and the tap's own click toggles it, ticking as the finger lifts. Elsewhere: navigator.vibrate.
import { settings } from './settings.js';

export const isIOS = /iPhone|iPad|iPod/.test(navigator.userAgent) ||
  (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

/** Covers `el` (which must be positioned) with an invisible switch, so tapping it ticks on iOS. */
export function addHapticSwitch(el) {
  if (!isIOS) return;
  const sw = document.createElement('input');
  sw.type = 'checkbox';
  sw.setAttribute('switch', '');
  sw.className = 'hap';
  sw.tabIndex = -1;
  sw.setAttribute('aria-hidden', 'true');
  el.appendChild(sw);
}

/** A tick from script: only possible off iOS. */
export function haptic() {
  if (settings.haptics && !isIOS) navigator.vibrate?.(8);
}
