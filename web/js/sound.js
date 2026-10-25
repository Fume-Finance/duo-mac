// Synthesised sounds: soft MacBook-style key thocks (glass has no travel, so a sound helps) and a startup chord.
import { settings } from './settings.js';

let ctx = null;
let noise = null;

function audio() {
  if (!ctx) {
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return null;
    try { ctx = new AC({ latencyHint: 'interactive' }); } catch { return null; }
  }
  // iOS also uses a non-standard 'interrupted' state (calls, Siri, backgrounding).
  if (ctx.state !== 'running') ctx.resume().catch(() => {});
  return ctx;
}

export const sound = {
  /** Call from a user gesture once, so iOS lets us play audio later. */
  unlock() {
    const c = audio();
    if (!c) return;
    // A silent blip actually unlocks output on iOS.
    const b = c.createBuffer(1, 1, c.sampleRate);
    const s = c.createBufferSource();
    s.buffer = b;
    s.connect(c.destination);
    s.start(0);
  },

  state() { return ctx ? ctx.state : 'none'; },

  /** The shared audio context (also plays the Mac's sound, js/speaker.js). */
  context() { return audio(); },

  click(kind = 'key') {
    if (!settings.sounds) return;
    const c = audio();
    if (!c) return;
    if (c.state !== 'running') {
      // Suspended (e.g. after the passkey sheet): resume, and still click if that's quick.
      const asked = performance.now();
      c.resume().then(() => { if (performance.now() - asked < 150) this.click(kind); }).catch(() => {});
      return;
    }
    const t = c.currentTime + 0.002;
    const vol = settings.volume;
    // A MacBook key is a soft, low "thok", not a sharp tick: a short muffled thump from the keycap
    // bottoming out, a woody body around 500–700 Hz (iPhone speakers lose much below that) and little above 2 kHz.
    const p = { key: [230, 650, 1900, 1.1], mod: [250, 720, 2100, 0.95], space: [170, 480, 1400, 1.2] }[kind] || [230, 650, 1900, 1.1];
    const [low, body, cut, amp] = p;
    const jit = 1 + (Math.random() - 0.5) * 0.08; // no two keystrokes sound quite the same
    if (!noise) {
      noise = c.createBuffer(1, Math.floor(c.sampleRate * 0.05), c.sampleRate);
      const d = noise.getChannelData(0);
      for (let i = 0; i < d.length; i++) d[i] = (Math.random() * 2 - 1) * Math.exp(-i / (c.sampleRate * 0.007));
    }
    const out = c.createGain();
    out.gain.value = vol * amp;
    out.connect(c.destination);

    // The muffled impact: filtered noise, rounded off so the attack doesn't click.
    const src = c.createBufferSource();
    src.buffer = noise;
    src.playbackRate.value = jit;
    const lp = c.createBiquadFilter();
    lp.type = 'lowpass';
    lp.frequency.value = cut * jit;
    lp.Q.value = 0.6;
    const pk = c.createBiquadFilter();
    pk.type = 'peaking';
    pk.frequency.value = body * jit;
    pk.Q.value = 1.4;
    pk.gain.value = 9;
    const ng = c.createGain();
    ng.gain.setValueAtTime(0, t);
    ng.gain.linearRampToValueAtTime(1.5, t + 0.003);
    ng.gain.exponentialRampToValueAtTime(0.001, t + (kind === 'space' ? 0.06 : 0.04));
    src.connect(lp).connect(pk).connect(ng).connect(out);
    src.start(t);
    src.stop(t + 0.07);

    // The "thoog": two damped tones for the keycap and the chassis under it.
    for (const [f, a, d] of [[low, 0.5, kind === 'space' ? 0.07 : 0.045], [body, 0.24, 0.022]]) {
      const o = c.createOscillator();
      o.type = 'sine';
      o.frequency.setValueAtTime(f * 1.25 * jit, t);
      o.frequency.exponentialRampToValueAtTime(f * jit, t + 0.012);
      const g = c.createGain();
      g.gain.setValueAtTime(0, t);
      g.gain.linearRampToValueAtTime(a, t + 0.004);
      g.gain.exponentialRampToValueAtTime(0.0005, t + d);
      o.connect(g).connect(out);
      o.start(t);
      o.stop(t + d + 0.01);
    }
  },

  /** A warm F♯-major startup chord (skipped if audio can't start within a second). */
  chime() {
    const c = audio();
    if (!c) return;
    if (c.state === 'running') return playChime(c);
    const asked = performance.now();
    c.resume().then(() => { if (performance.now() - asked < 1200) playChime(c); }).catch(() => {});
  },
};

function playChime(c) {
  const t = c.currentTime + 0.03;
  const vol = Math.max(0.15, settings.volume);
  const master = c.createGain();
  master.gain.setValueAtTime(0.0001, t);
  master.gain.exponentialRampToValueAtTime(0.42 * vol, t + 0.015);
  master.gain.setTargetAtTime(0.0001, t + 0.35, 0.85);
  const lp = c.createBiquadFilter();
  lp.type = 'lowpass';
  lp.frequency.setValueAtTime(5200, t);
  lp.frequency.exponentialRampToValueAtTime(700, t + 3);
  master.connect(lp).connect(c.destination);
  const notes = [92.5, 185.0, 277.18, 369.99, 466.16, 554.37];
  notes.forEach((f, i) => {
    for (const [type, det, amp] of [['sawtooth', -5, 0.12], ['triangle', 4, 0.3]]) {
      const o = c.createOscillator();
      o.type = type;
      o.frequency.value = f;
      o.detune.value = det;
      const g = c.createGain();
      g.gain.value = amp * (i === 0 ? 1.1 : 1 - i * 0.08);
      o.connect(g).connect(master);
      o.start(t);
      o.stop(t + 4.5);
    }
  });
}
