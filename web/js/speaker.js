// The Mac's sound, on the iPhone's speaker. Binary messages from the Mac (helper MacSound.swift):
// [2] [channels] [rate / 100, UInt16 LE] then interleaved 16-bit samples. They go to an audio
// worklet that buffers and plays them (speaker-worklet.js), in the same audio context as the key
// clicks, which a tap has already unlocked.
import { settings } from './settings.js';
import { sound } from './sound.js';

// The Mac sends silence too. While it's silent (and while the app isn't in front) the phone's audio
// pauses, so iOS doesn't show a player that's always "playing"; when it plays, the player says what
// it is: "<Mac name> Audio", with Duo Mac's icon.
const QUIET_MS = 4000;

export class Speaker {
  constructor() {
    this.node = null;
    this.loading = null;
    this.lastSound = 0;
    this.playing = false;
    this.macName = 'Mac';
    setInterval(() => this.checkQuiet(), 1000);
    document.addEventListener('visibilitychange', () => { if (document.hidden) this.pause(); });
  }

  setMacName(name) { if (name) this.macName = name; }

  push(buf) {
    if (!settings.macSound) return;
    if (!this.node) { this.load(); return; } // the first moments are dropped while it loads
    const dv = new DataView(buf);
    const ch = dv.getUint8(1) || 2, rate = dv.getUint16(2, true) * 100;
    const pcm = new Int16Array(buf, 4, (buf.byteLength - 4) >> 1);
    let peak = 0;
    for (let i = 0; i < pcm.length; i += 16) { const v = pcm[i] < 0 ? -pcm[i] : pcm[i]; if (v > peak) peak = v; }
    if (peak > 60) {
      this.lastSound = performance.now();
      if (!this.playing && !document.hidden) this.play();
    }
    if (!this.playing) return; // silence while paused: nothing to play
    this.node.port.postMessage({ rate, ch, pcm }, [buf]);
  }

  /** Sound again: resume, and tell iOS what's playing. */
  play() {
    this.playing = true;
    const ctx = sound.context();
    if (ctx && ctx.state !== 'running') ctx.resume().catch(() => {});
    if (navigator.audioSession && navigator.audioSession.type !== 'play-and-record') navigator.audioSession.type = 'playback';
    const ms = navigator.mediaSession;
    if (ms && window.MediaMetadata) {
      ms.metadata = new MediaMetadata({
        title: `${this.macName} Audio`, artist: 'Duo Mac',
        artwork: [{ src: new URL('../icon-512.png', import.meta.url).href, sizes: '512x512', type: 'image/png' }],
      });
      ms.playbackState = 'playing';
    }
  }

  /** Quiet (or the app went to the background): let go of the audio, so the player goes away. */
  pause() {
    if (!this.playing) return;
    this.playing = false;
    const ms = navigator.mediaSession;
    if (ms) { ms.playbackState = 'none'; ms.metadata = null; }
    if (navigator.audioSession?.type === 'playback') navigator.audioSession.type = 'auto';
    const ctx = sound.context();
    // Key clicks share the context; sound.click() resumes it when needed.
    if (ctx && ctx.state === 'running' && navigator.audioSession?.type !== 'play-and-record') ctx.suspend().catch(() => {});
  }

  checkQuiet() {
    if (this.playing && performance.now() - this.lastSound > QUIET_MS) this.pause();
  }

  load() {
    const ctx = sound.context();
    if (!ctx || this.loading) return;
    this.loading = ctx.audioWorklet.addModule(new URL('./speaker-worklet.js', import.meta.url)).then(() => {
      this.node = new AudioWorkletNode(ctx, 'duo-speaker', { outputChannelCount: [2] });
      this.node.connect(ctx.destination);
      console.warn(`speaker: playing the Mac's sound (${ctx.sampleRate} Hz, ${ctx.state}, session ${navigator.audioSession?.type ?? 'n/a'})`);
      // ('playback' while sound plays: it plays even with the iPhone's silent switch on, like a video.)
    }).catch((e) => console.warn('speaker: ' + (e?.message || e))).finally(() => { this.loading = null; });
  }

  stop() {
    this.pause();
    try { this.node?.disconnect(); } catch {}
    this.node = null;
  }
}
