// The iPhone's microphone, streamed to the Mac (where it becomes the "Duo Mac Microphone").
// Mono, 16-bit, 24 kHz, in ~20 ms binary messages: "M" + samples. iOS only lets a page start audio
// from a tap, so start() is called from one.

const RATE = 24000;
const CHUNK = 480; // 20 ms

const WORKLET = `class DuoMic extends AudioWorkletProcessor {
  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (ch) this.port.postMessage(ch.slice(0));
    return true;
  }
}
registerProcessor('duo-mic', DuoMic);`;

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

  async open() {
    // The context first, while we're still inside the tap.
    this.ctx = new (window.AudioContext || window.webkitAudioContext)();
    const resumed = this.ctx.resume();
    this.stream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true },
    });
    await resumed;
    const src = this.ctx.createMediaStreamSource(this.stream);
    const url = URL.createObjectURL(new Blob([WORKLET], { type: 'application/javascript' }));
    await this.ctx.audioWorklet.addModule(url);
    URL.revokeObjectURL(url);
    this.node = new AudioWorkletNode(this.ctx, 'duo-mic');
    this.node.port.onmessage = (e) => this.push(e.data);
    // A silent path to the output keeps the graph running.
    const mute = this.ctx.createGain();
    mute.gain.value = 0;
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

  close() {
    try { this.node?.disconnect(); } catch {}
    this.stream?.getTracks().forEach((t) => t.stop());
    this.ctx?.close().catch(() => {});
    this.node = this.stream = this.ctx = null;
    this.n = 0;
  }
}
