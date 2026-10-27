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
    this.probing = false;  // trying to move a Tailscale session to the local route
    this.probeTimer = 0;
    this.lastProbe = -Infinity;
  }

  get open() { return !!this.ws && this.ws.readyState === 1; }
  get buffered() { return this.ws ? this.ws.bufferedAmount : 0; }

  url() {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    return `${proto}://${location.host}/ws`;
  }

  /** Local mode: the Mac on the same Wi-Fi or hotspot ({ port, hosts }), tried alongside Tailscale.
   *  Addresses the Mac had on its other networks are kept too (home, the hotspot…), newest first,
   *  so the first connection there is already direct. Old names are dropped: the Mac was renamed. */
  setLocal(info) {
    if (!info?.port || !info.hosts?.length) return;
    const isName = (h) => /[a-z]/i.test(h) && !h.includes(':');
    const hosts = [...new Set([...info.hosts, ...(this.local?.hosts || [])])]
      .filter((h) => !isName(h) || info.hosts.includes(h))
      .slice(0, 5);
    this.local = { port: info.port, hosts };
    // On Tailscale, and the Mac just said where it is: see if it's right here.
    if (this.open && this.route === 'tailscale') setTimeout(() => this.tryLocal(), 500);
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
      for (const h of this.local.hosts) targets.push({ url: this.localURL(h), local: true });
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

  localURL(h) {
    return `wss://${h.includes(':') ? `[${h}]` : h}:${this.local.port}/ws`;
  }

  /** On Tailscale while the Mac may be right here (it just told us its local addresses, then every
   *  30 s): quietly try the local route and, if the Mac answers and the reconnect ticket gets us in,
   *  move over. The Mac hands the session to the new connection when it says hello, so it's a
   *  blink, not a reconnect. */
  tryLocal() {
    if (!this.open || this.route !== 'tailscale' || !this.local || this.probing) return;
    if (performance.now() - this.lastProbe < 5000) return;
    const auth = this.h.authMessage?.();
    if (!auth) return;
    this.probing = true;
    this.lastProbe = performance.now();
    const socks = [];
    let picked = null, done = false, timer = 0;
    const finish = (win, early, why) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      this.probing = false;
      for (const s of socks) {
        if (s === win) continue;
        s.onmessage = s.onclose = null;
        try { s.close(); } catch {}
      }
      if (!win) return this.h.onProbe?.(why);
      if (!this.open || this.route !== 'tailscale') { try { win.close(); } catch {} return; }
      const old = this.ws;
      old.onmessage = old.onclose = null;
      this.adopt(win, true, early);
      this.h.onProbe?.('moved to the local route');
      // The Mac closes the old connection when the new one says hello; in case it doesn't:
      setTimeout(() => { try { old.close(); } catch {} }, 3000);
    };
    for (const h of this.local.hosts) {
      let ws;
      try { ws = new WebSocket(this.localURL(h)); } catch { continue; }
      ws.binaryType = 'arraybuffer';
      socks.push(ws);
      ws.onmessage = (ev) => {
        if (typeof ev.data !== 'string') return;
        let m;
        try { m = JSON.parse(ev.data); } catch { return; }
        if (m.t === 'welcome' && !picked) {
          // The first address to answer is the one: drop the others, sign in with the ticket.
          picked = ws;
          for (const s of socks) if (s !== ws) { s.onmessage = s.onclose = null; try { s.close(); } catch {} }
          ws.send(JSON.stringify(auth));
        } else if (ws === picked) {
          if (m.t === 'authed') finish(ws, [ev]);
          else finish(null, null, `the Mac answered but wants ${m.t}`);
        }
      };
      ws.onclose = () => {
        if (ws === picked || socks.every((s) => s.readyState > 1)) finish(null, null, ws === picked ? 'closed while signing in' : 'no answer');
      };
      ws.onerror = () => {};
    }
    if (!socks.length) return finish(null, null, 'no addresses');
    timer = setTimeout(() => finish(null, null, picked ? 'signing in timed out' : 'no answer'), 5000);
  }

  /** The route that won: from now on this is the link. */
  adopt(ws, local, early = []) {
    this.ws = ws;
    this.route = local ? 'local' : 'tailscale';
    clearInterval(this.probeTimer);
    if (!local) this.probeTimer = setInterval(() => this.tryLocal(), 30000);
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
    clearInterval(this.probeTimer);
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
