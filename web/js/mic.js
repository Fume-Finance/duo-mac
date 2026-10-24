// The iPhone's microphone, streamed to the Mac (where it becomes the "Duo Mac Microphone").
// Mono, 16-bit, 24 kHz, in ~20 ms binary messages: "M" + samples. It records only while a Mac app is
// listening, so start() usually comes from the Mac, not a tap. iOS only lets a page start audio from a
// tap, so unlock() makes the audio context in one and keeps it (suspended) for later.

const RATE = 24000;
const CHUNK = 480; // 20 ms

/** Rejects if `p` takes longer than `ms` (iOS sometimes leaves audio promises hanging). */
const within = (p, ms, what) => Promise.race([p, new Promise((_, no) => setTimeout(() => no(new Error(`${what} timed out`)), ms))]);

export class Mic {
  constructor(send) {
    this.send = send; // (ArrayBuffer) => void
    this.running = false;
    this.starting = null;
    this.pos = 0;
    this.out = new Int16Array(CHUNK);
    this.n = 0;
  }

  /** Ask for the microphone and start streaming. Resolves to true when it's running. */
  start() {
    if (this.running) return Promise.resolve(true);
    if (this.starting) return this.starting;
    this.starting = this.open().then(() => {
      this.running = true;
      return true;
    }, (err) => {
      this.close();
      this.error = err?.name || String(err);
      return false;
    }).finally(() => { this.starting = null; });
    return this.starting;
  }

  /** From a tap: the audio context, allowed to start later without one. */
  unlock() {
    if (!this.ctx) this.ctx = new (window.AudioContext || window.webkitAudioContext)();
    if (this.ctx.state !== 'running' && !this.running && !this.starting) {
      this.ctx.resume().then(() => { if (!this.running && !this.starting) this.ctx?.suspend(); }, () => {});
    }
  }

  async open() {
    if (!this.ctx) this.ctx = new (window.AudioContext || window.webkitAudioContext)();
    this.ctx.resume().catch(() => {});
    // No timeout here: the first time, iOS waits for the person to answer its permission prompt.
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
    // Answering the prompt can interrupt the context; start it again.
    if (this.ctx.state !== 'running') await within(this.ctx.resume(), 3000, 'audio start');
    const src = this.ctx.createMediaStreamSource(this.stream);
    if (!this.ctx.duoMic) {
      await within(this.ctx.audioWorklet.addModule(new URL('./mic-worklet.js', import.meta.url)), 5000, 'audio worklet');
      this.ctx.duoMic = true;
    }
    this.node = new AudioWorkletNode(this.ctx, 'duo-mic');
    this.node.port.onmessage = (e) => this.push(e.data);
    // A silent path to the output keeps the graph running.
    const mute = this.ctx.createGain();
    mute.gain.value = 0;
    this.src = src;
    src.connect(this.node).connect(mute).connect(this.ctx.destination);
    this.step = this.ctx.sampleRate / RATE;
    this.pos = 0;
  }

  /** Resample to 24 kHz (averaging what falls in each step), pack 20 ms at a time. */
  push(input) {
    const step = this.step;
    while (this.pos < input.length) {
      const a = Math.floor(this.pos), b = Math.min(input.length, Math.floor(this.pos + step));
      let sum = 0;
      for (let i = a; i < Math.max(b, a + 1); i++) sum += input[i];
      const v = sum / Math.max(1, b - a);
      this.out[this.n++] = Math.max(-32768, Math.min(32767, Math.round(v * 32767)));
      if (this.n === CHUNK) {
        const msg = new Uint8Array(1 + CHUNK * 2);
        msg[0] = 0x4D; // 'M'
        msg.set(new Uint8Array(this.out.buffer), 1);
        this.send(msg.buffer);
        this.n = 0;
      }
      this.pos += step;
    }
    this.pos -= input.length;
  }

  stop() {
    this.running = false;
    this.close();
  }

  /** Lets go of the microphone (iOS's orange dot goes away); the context stays, suspended. */
  close() {
    try { this.src?.disconnect(); this.node?.disconnect(); } catch {}
    this.stream?.getTracks().forEach((t) => t.stop());
    this.ctx?.suspend().catch(() => {});
    this.node = this.src = this.stream = null;
    this.n = 0;
  }
}
