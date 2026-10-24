// WebSocket link to the Mac helper, with automatic reconnection.

export class Link {
  constructor(handlers) {
    this.h = handlers;
    this.ws = null;
    this.retry = 0;
    this.kicked = false;
    this.rtt = 0;
    this.sent = {};
    this.pingTimer = 0;
    this.retryTimer = 0;
    this.lastRx = 0;
  }

  get open() { return !!this.ws && this.ws.readyState === 1; }
  get buffered() { return this.ws ? this.ws.bufferedAmount : 0; }

  url() {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    return `${proto}://${location.host}/ws`;
  }

  connect() {
    if (this.ws && (this.ws.readyState === 0 || this.ws.readyState === 1)) return;
    clearTimeout(this.retryTimer);
    this.kicked = false;
    let ws;
    try {
      ws = new WebSocket(this.url());
    } catch (e) {
      this.scheduleRetry();
      return;
    }
    ws.binaryType = 'arraybuffer';
    this.ws = ws;
    this.h.onState?.('connecting');
    // Give up on a connection attempt that hangs (e.g. Wi-Fi just woke up).
    const connectTimer = setTimeout(() => { if (this.ws === ws && ws.readyState === 0) this.drop(); }, 4000);

    ws.onopen = () => {
      clearTimeout(connectTimer);
      if (this.ws !== ws) return;
      this.lastRx = performance.now();
      this.retry = 0;
      this.startPing();
      this.h.onState?.('open');
      this.h.onOpen?.();
    };
    ws.onmessage = (ev) => {
      if (this.ws !== ws) return;
      this.lastRx = performance.now();
      if (typeof ev.data === 'string') {
        let m;
        try { m = JSON.parse(ev.data); } catch { return; }
        if (m.t === 'pong') { this.rtt = performance.now() - m.ts; return; }
        if (m.t === 'kicked') this.kicked = true;
        this.h.onMessage?.(m);
      } else {
        this.h.onFrame?.(ev.data);
      }
    };
    ws.onclose = (ev) => {
      clearTimeout(connectTimer);
      if (this.ws !== ws) return;
      if (ev.code === 4001) this.kicked = true; // another device took over
      this.ws = null;
      this.stopPing();
      this.h.onState?.(this.kicked ? 'kicked' : 'closed', ev.code);
      // 4002 idle, 4003 removed on the Mac, 4004 connections off: wait for the user instead of retrying.
      if (!this.kicked && !(ev.code >= 4002 && ev.code <= 4004)) this.scheduleRetry();
    };
    ws.onerror = () => {};
  }

  scheduleRetry() {
    clearTimeout(this.retryTimer);
    const delay = Math.min(4000, 350 * 2 ** this.retry++);
    this.retryTimer = setTimeout(() => this.connect(), delay);
  }

  reconnectNow() {
    this.retry = 0;
    this.kicked = false;
    clearTimeout(this.retryTimer);
    if (this.ws && this.ws.readyState > 1) this.ws = null;
    this.connect();
  }

  close() {
    clearTimeout(this.retryTimer);
    this.stopPing();
    const ws = this.ws;
    this.ws = null;
    try { ws?.close(); } catch {}
  }

  /** Abandon a dead or hung socket right away (its close event may take minutes) and retry. */
  drop() {
    const ws = this.ws;
    if (!ws) return;
    this.ws = null;
    this.stopPing();
    try { ws.close(); } catch {}
    this.h.onState?.('closed', 0);
    this.scheduleRetry();
  }

  sendBinary(buf) {
    const ws = this.ws;
    if (!ws || ws.readyState !== 1 || ws.bufferedAmount > 256 * 1024) return false; // don't pile up audio on a slow link
    ws.send(buf);
    return true;
  }

  send(m) {
    const ws = this.ws;
    if (!ws || ws.readyState !== 1) return false;
    ws.send(JSON.stringify(m));
    this.sent[m.t] = (this.sent[m.t] || 0) + 1;
    return true;
  }

  startPing() {
    this.stopPing();
    this.pingTimer = setInterval(() => {
      // The Mac sends stats every second and answers pings: 6 s of silence means the link is dead.
      if (performance.now() - this.lastRx > 6000) return this.drop();
      this.send({ t: 'ping', ts: performance.now() });
    }, 2000);
    this.send({ t: 'ping', ts: performance.now() });
  }

  stopPing() {
    clearInterval(this.pingTimer);
  }
}
