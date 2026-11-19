// Dictation into the app in front on the Mac. In the iPhone app: the iPhone's own speech recognition
// (ios/DuoMac/Dictation.swift), shown live in a bubble and typed on the Mac when you stop. In Safari,
// which can't listen like that: the iPhone keyboard, whose microphone key dictates.
import { native } from './native.js';
import { settings } from './settings.js';

export class Dictation {
  /** cb: { type(text), openKeyboard(), changed(listening), say(text, level) } */
  constructor(bubble, cb) {
    this.bubble = bubble;
    this.cb = cb;
    this.listening = false;
    this.starting = false;
    window.duoDictation = (text, final) => this.heard(text, final);
  }

  get available() { return !!native; }

  toggle() {
    if (!native) return this.cb.openKeyboard();
    if (this.listening) return this.stop();
    if (this.starting) return;
    this.starting = true;
    this.show('Listening…', true);
    native.call({ t: 'dictate', on: true, lang: navigator.language, engine: settings.dictationEngine }).then((r) => {
      if (r?.note) this.cb.say(r.note, 'info'); // e.g. Whisper still getting ready: Apple's this time
      this.starting = false;
      this.listening = true;
      this.cb.changed(true);
    }).catch((e) => {
      this.starting = false;
      this.hide();
      this.cb.say(e?.message || 'Dictation didn’t start.', 'error');
    });
  }

  stop(cancel = false) {
    if (!this.listening) return;
    this.listening = false;
    this.cb.changed(false);
    if (cancel) this.hide();
    native?.call({ t: 'dictate', on: false, cancel }).catch(() => {});
  }

  heard(text, final) {
    if (!final) return this.show(text || 'Listening…', !text);
    this.hide();
    if (this.listening) { this.listening = false; this.cb.changed(false); }
    const t = (text || '').trim();
    if (t) this.cb.type(t);
  }

  show(text, hint) {
    this.bubble.textContent = text;
    this.bubble.classList.toggle('hint', !!hint);
    this.bubble.hidden = false;
  }

  hide() { this.bubble.hidden = true; }
}
