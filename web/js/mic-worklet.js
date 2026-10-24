// Hands the microphone's samples to the page (js/mic.js), 128 at a time.
class DuoMic extends AudioWorkletProcessor {
  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (ch) this.port.postMessage(ch.slice(0));
    return true;
  }
}
registerProcessor('duo-mic', DuoMic);
