// The Mac's sound, on the iPhone's speaker. Binary messages from the Mac (helper MacSound.swift):
// [2] [channels] [rate / 100, UInt16 LE] then interleaved 16-bit samples. They go to an audio
// worklet that buffers and plays them (speaker-worklet.js), in the same audio context as the key
// clicks, which a tap has already unlocked.
import { settings } from './settings.js';
import { sound } from './sound.js';

export class Speaker {
  constructor() {
    this.node = null;
    this.loading = null;
  }

  push(buf) {
    if (!settings.macSound) return;
    if (!this.node) { this.load(); return; } // the first moments are dropped while it loads
    const dv = new DataView(buf);
    const ch = dv.getUint8(1) || 2, rate = dv.getUint16(2, true) * 100;
    const pcm = new Int16Array(buf, 4, (buf.byteLength - 4) >> 1);
    this.node.port.postMessage({ rate, ch, pcm }, [buf]);
  }

  load() {
    const ctx = sound.context();
    if (!ctx || this.loading) return;
    this.loading = ctx.audioWorklet.addModule(new URL('./speaker-worklet.js', import.meta.url)).then(() => {
      this.node = new AudioWorkletNode(ctx, 'duo-speaker', { outputChannelCount: [2] });
      this.node.connect(ctx.destination);
      // Play even with the iPhone's silent switch on, like a video would (Safari 17+).
      if (navigator.audioSession && navigator.audioSession.type !== 'play-and-record') navigator.audioSession.type = 'playback';
    }).catch((e) => console.warn('speaker: ' + (e?.message || e))).finally(() => { this.loading = null; });
  }

  stop() {
    try { this.node?.disconnect(); } catch {}
    this.node = null;
    if (navigator.audioSession?.type === 'playback') navigator.audioSession.type = 'auto';
  }
}
