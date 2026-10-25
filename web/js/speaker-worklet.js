// Plays the Mac's sound (js/speaker.js): a ring of stereo samples at the Mac's rate (24 kHz),
// resampled to the phone's on the way out. It waits for ~80 ms before playing, so the network's
// jitter doesn't chop it, and skips ahead if it falls more than ~350 ms behind.
class DuoSpeaker extends AudioWorkletProcessor {
  constructor() {
    super();
    this.N = 24000; // 1 s
    this.L = new Float32Array(this.N);
    this.R = new Float32Array(this.N);
    this.w = 0;     // next write
    this.r = 0;     // read position (fractional)
    this.rate = 24000;
    this.playing = false;
    this.port.onmessage = (e) => this.push(e.data);
  }

  avail() { return (this.w - Math.floor(this.r) + this.N) % this.N; }

  push({ rate, ch, pcm }) {
    this.rate = rate;
    const n = Math.floor(pcm.length / ch);
    for (let i = 0; i < n; i++) {
      this.L[this.w] = pcm[i * ch] / 32768;
      this.R[this.w] = pcm[i * ch + (ch > 1 ? 1 : 0)] / 32768;
      this.w = (this.w + 1) % this.N;
    }
    if (this.avail() > rate * 0.35) this.r = (this.w - Math.floor(rate * 0.1) + this.N) % this.N;
  }

  process(_, outputs) {
    const out = outputs[0], L = out[0], R = out[1];
    if (!this.playing && this.avail() >= this.rate * 0.08) this.playing = true;
    if (!this.playing) return true; // outputs are silent by default
    const step = this.rate / sampleRate;
    for (let i = 0; i < L.length; i++) {
      if (this.avail() < 2) { this.playing = false; break; }
      const i0 = Math.floor(this.r), f = this.r - i0, i1 = (i0 + 1) % this.N;
      L[i] = this.L[i0] + (this.L[i1] - this.L[i0]) * f;
      if (R) R[i] = this.R[i0] + (this.R[i1] - this.R[i0]) * f;
      this.r += step;
      if (this.r >= this.N) this.r -= this.N;
    }
    return true;
  }
}
registerProcessor('duo-speaker', DuoSpeaker);
