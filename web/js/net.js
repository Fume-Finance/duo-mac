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
    this.local = null;     // local mode: { port, hosts }
    this.attempts = null;  // a connection race in progress
    this.route = '';       // 'local' or 'tailscale', once open
  }

  get open() { return !!this.ws && this.ws.readyState === 1; }
  get buffered() { return this.ws ? this.ws.bufferedAmount : 0; }

  url() {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    return `${proto}://${location.host}/ws`;
  }

  /** Local mode: the Mac on the same Wi-Fi or hotspot ({ port, hosts }), tried alongside Tailscale. */
  setLocal(info) {
    this.local = info && info.port && info.hosts?.length ? info : null;
  }

  /** Every connection races the routes: the Mac's local address(es) and the usual one (Tailscale).
   *  Local wins if it answers at all (it takes ~15 ms when it's there; Tailscale waits 150 ms for it); otherwise
   *  whichever opens first. So at home or on the hotspot it's direct, anywhere else as before. */
  connect() {
    if (this.ws && (this.ws.readyState === 0 || this.ws.readyState === 1)) return;
    if (this.attempts) return;
    clearTimeout(this.retryTimer);
    this.kicked = false;
    const targets = [];
    if (this.local) {
      for (const h of this.local.hosts.slice(0, 3)) targets.push({ url: `wss://${h.includes(':') ? `[${h}]` : h}:${this.local.port}/ws`, local: true });
    }
    targets.push({ url: this.url(), local: false });
    const attempts = [];
    this.attempts = attempts;
    this.h.onState?.('connecting');
    let chosen = null, grace = 0, giveUp = 0;
    const end = () => { clearTimeout(grace); clearTimeout(giveUp); if (this.attempts === attempts) this.attempts = null; };
    const choose = (a) => {
      if (chosen || this.attempts !== attempts) return;
      chosen = a;
      end();
      for (const o of attempts) {
        if (o === a) continue;
        o.ws.onopen = o.ws.onclose = o.ws.onerror = null;
        try { o.ws.close(); } catch {}
      }
      this.adopt(a.ws, a.local, a.early);
    };
    const failed = (code) => {
      if (chosen || this.attempts !== attempts || attempts.some((o) => o.ws.readyState < 2)) return;
      end();
      this.h.onState?.('closed', code);
      if (!(code >= 4002 && code <= 4004)) this.scheduleRetry();
    };
    for (const t of targets) {
      let ws;
      try { ws = new WebSocket(t.url); } catch { continue; }
      ws.binaryType = 'arraybuffer';
      const a = { ws, local: t.local, early: [] };
      attempts.push(a);
      // The Mac speaks first ('welcome', which starts authentication): keep what arrives before
      // this route is picked, and hand it over then.
      ws.onmessage = (ev) => a.early.push(ev);
      ws.onopen = () => {
        if (a.local || !attempts.some((o) => o.local && o.ws.readyState === 0)) return choose(a);
        clearTimeout(grace);
        grace = setTimeout(() => choose(a), 150);
      };
      ws.onclose = (ev) => {
        if (chosen) return;
        // The usual route opened, then lost the race's grace period: nothing else is coming.
        if (!a.local && attempts.every((o) => o === a || o.ws.readyState > 1)) clearTimeout(grace);
        failed(ev.code);
      };
      ws.onerror = () => {};
    }
    if (!attempts.length) { end(); this.scheduleRetry(); return; }
    // Give up on attempts that hang (e.g. Wi-Fi just woke up): keep one that's open, if any.
    giveUp = setTimeout(() => {
      const open = attempts.find((o) => o.ws.readyState === 1);
      if (open) return choose(open);
      end();
      for (const o of attempts) { o.ws.onopen = o.ws.onclose = null; try { o.ws.close(); } catch {} }
      this.h.onState?.('closed', 0);
      this.scheduleRetry();
    }, 4000);
  }

  /** The route that won: from now on this is the link. */
  adopt(ws, local, early = []) {
    this.ws = ws;
    this.route = local ? 'local' : 'tailscale';
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
      if (this.ws !== ws) return;
      if (ev.code === 4001) this.kicked = true; // another device took over
      this.ws = null;
      this.stopPing();
      this.h.onState?.(this.kicked ? 'kicked' : 'closed', ev.code);
      // 4002 idle, 4003 removed on the Mac, 4004 connections off: wait for the user instead of retrying.
      if (!this.kicked && !(ev.code >= 4002 && ev.code <= 4004)) this.scheduleRetry();
    };
    ws.onerror = () => {};
    this.lastRx = performance.now();
    this.retry = 0;
    this.startPing();
    this.h.onState?.('open');
    this.h.onOpen?.();
    for (const ev of early) ws.onmessage(ev);
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
    for (const o of this.attempts || []) { o.ws.onopen = o.ws.onclose = null; try { o.ws.close(); } catch {} }
    this.attempts = null;
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
