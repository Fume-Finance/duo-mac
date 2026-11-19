// The Mac's sound, on the iPhone's speaker. Binary messages from the Mac (helper MacSound.swift):
// [6] [channels] [rate / 100, UInt16 LE] then one Opus packet (when this phone decodes Opus), or
// [2] [channels] [rate / 100, UInt16 LE] then interleaved 16-bit samples (eight times the data).
// They go to an audio worklet that buffers and plays them (speaker-worklet.js), in the same audio
// context as the key clicks, which a tap has already unlocked.
import { settings } from './settings.js';
import { sound } from './sound.js';

// The Mac sends silence too. While it's silent (and while the app isn't in front) the phone's audio
// pauses, so iOS doesn't show a player that's always "playing"; when it plays, the player says what
// it is: "<Mac name> Audio", with Duo Mac's icon.
const QUIET_MS = 4000;

/** Can this phone decode Opus (WebCodecs)? Then the Mac sends that. */
export const opusSupported = (async () => {
  if (!('AudioDecoder' in window) || !('EncodedAudioChunk' in window)) return false;
  try {
    return !!(await AudioDecoder.isConfigSupported({ codec: 'opus', sampleRate: 48000, numberOfChannels: 2 })).supported;
  } catch {
    return false;
  }
})();

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
    if (dv.getUint8(0) === 6) return this.decodeOpus(buf);
    const ch = dv.getUint8(1) || 2, rate = dv.getUint16(2, true) * 100;
    const pcm = new Int16Array(buf, 4, (buf.byteLength - 4) >> 1);
    let peak = 0;
    for (let i = 0; i < pcm.length; i += 16) { const v = pcm[i] < 0 ? -pcm[i] : pcm[i]; if (v > peak) peak = v; }
    if (this.heard(peak / 32768)) this.node.port.postMessage({ rate, ch, pcm }, [buf]);
  }

  /** Something audible: play (resume first if paused). False while paused and silent: nothing to play. */
  heard(peak) {
    if (peak > 0.002) {
      this.lastSound = performance.now();
      if (!this.playing && !document.hidden) this.play();
    }
    return this.playing;
  }

  decodeOpus(buf) {
    if (!this.decoder || this.decoder.state === 'closed') {
      this.decoder = new AudioDecoder({
        output: (data) => this.decoded(data),
        error: (e) => { console.warn('speaker: ' + (e?.message || e)); this.decoder = null; },
      });
      this.decoder.configure({ codec: 'opus', sampleRate: 48000, numberOfChannels: 2 });
      this.ts = 0;
    }
    this.ts += 20000; // µs: each packet is 20 ms
    try {
      this.decoder.decode(new EncodedAudioChunk({ type: 'key', timestamp: this.ts, data: new Uint8Array(buf, 4) }));
    } catch (e) {
      console.warn('speaker: ' + (e?.message || e));
      this.decoder = null;
    }
  }

  decoded(data) {
    const n = data.numberOfFrames, ch = Math.min(2, data.numberOfChannels), rate = data.sampleRate;
    const planes = [];
    for (let c = 0; c < ch; c++) {
      const p = new Float32Array(n);
      data.copyTo(p, { planeIndex: c, format: 'f32-planar' });
      planes.push(p);
    }
    data.close();
    const f32 = new Float32Array(n * 2);
    let peak = 0;
    for (let i = 0; i < n; i++) {
      const l = planes[0][i], r = planes[ch - 1][i];
      f32[i * 2] = l;
      f32[i * 2 + 1] = r;
      if (i % 16 === 0) peak = Math.max(peak, l < 0 ? -l : l);
    }
    if (this.heard(peak) && this.node) this.node.port.postMessage({ rate, ch: 2, f32 }, [f32.buffer]);
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
    try { this.decoder?.close(); } catch {}
    this.decoder = null;
    try { this.node?.disconnect(); } catch {}
    this.node = null;
  }
}
