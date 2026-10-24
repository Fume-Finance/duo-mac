// The top half: draws the streamed Mac screen, handles local zoom, and (optionally) touch input on it.
import { settings } from './settings.js';

async function decode(bytes) {
  const blob = new Blob([bytes], { type: 'image/jpeg' });
  if (window.createImageBitmap) {
    try { return await createImageBitmap(blob); } catch {}
  }
  const url = URL.createObjectURL(blob);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    return img;
  } finally {
    URL.revokeObjectURL(url);
  }
}

export class Screen {
  constructor({ area, wrap, canvas, notch }) {
    this.area = area;
    this.wrap = wrap;
    this.canvas = canvas;
    this.notchEl = notch;
    this.ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
    this.streamW = 0;
    this.streamH = 0;
    this.displayPt = [1512, 982];
    this.notch = null;
    this.rect = { x: 0, y: 0, w: 0, h: 0 };
    this.zoom = { s: 1, x: 0, y: 0 };
    this.cursor = null;
    this.chain = Promise.resolve();
    this.frames = 0;
    this.bytes = 0;
    this.decodeMs = 0;
    this.gotFrame = false;
    this.onFirstFrame = null;
  }

  setDisplay(display) {
    if (display?.pt) this.displayPt = display.pt;
    this.notch = display?.notch || null;
    this.layout();
  }

  /** Size of the screen area in device pixels (the Mac picks the stream resolution from it). */
  boxPixels() {
    const dpr = window.devicePixelRatio || 1;
    return [Math.round(this.area.clientWidth * dpr), Math.round(this.area.clientHeight * dpr)];
  }

  layout() {
    const aw = this.area.clientWidth, ah = this.area.clientHeight;
    if (!aw || !ah) return;
    const aspect = this.streamW && this.streamH ? this.streamW / this.streamH : this.displayPt[0] / this.displayPt[1];
    let w = aw, h = aw / aspect;
    if (h > ah) { h = ah; w = ah * aspect; }
    const x = (aw - w) / 2, y = (ah - h) / 2;
    this.rect = { x, y, w, h };
    const s = this.canvas.style;
    s.left = `${x}px`;
    s.top = `${y}px`;
    s.width = `${w}px`;
    s.height = `${h}px`;

    const n = this.notchEl;
    if (settings.notch && this.notch) {
      const nw = w * this.notch[0], nh = Math.max(4, h * this.notch[1]);
      Object.assign(n.style, { width: `${nw}px`, height: `${nh}px`, left: `${x + (w - nw) / 2}px`, top: `${y}px` });
      n.classList.add('on');
    } else {
      n.classList.remove('on');
    }
    this.clampZoom();
    this.applyZoom();
  }

  // ───── Frames ─────

  /** Queues a frame; resolves with its id once drawn (frames are drawn strictly in order). */
  enqueue(buf) {
    const p = this.chain.then(() => this.draw(buf)).catch((e) => {
      console.error('frame error: ' + (e?.message || e));
      try { return new DataView(buf).getUint32(4, true); } catch { return 0; }
    });
    this.chain = p;
    return p;
  }

  async draw(buf) {
    const t0 = performance.now();
    const dv = new DataView(buf);
    if (dv.getUint8(0) !== 1) return 0;
    const full = (dv.getUint8(1) & 1) === 1;
    const n = dv.getUint16(2, true);
    const id = dv.getUint32(4, true);
    const w = dv.getUint16(8, true), h = dv.getUint16(10, true);
    const cx = dv.getUint16(12, true), cy = dv.getUint16(14, true);
    if (w !== this.streamW || h !== this.streamH) {
      if (!full) return id; // partial update for a size we no longer show
      this.streamW = w;
      this.streamH = h;
      this.canvas.width = w;
      this.canvas.height = h;
      this.layout();
    }
    let off = 16 + n * 12;
    const rects = [];
    for (let i = 0; i < n; i++) {
      const b = 16 + i * 12;
      const len = dv.getUint32(b + 8, true);
      rects.push({
        x: dv.getUint16(b, true), y: dv.getUint16(b + 2, true),
        data: new Uint8Array(buf, off, len),
      });
      off += len;
    }
    const images = await Promise.all(rects.map((r) => decode(r.data)));
    for (let i = 0; i < rects.length; i++) {
      const img = images[i];
      if (!img) continue;
      this.ctx.drawImage(img, rects[i].x, rects[i].y);
      img.close?.();
    }
    this.cursor = cx === 0xffff ? null : [cx, cy];
    this.frames++;
    this.bytes += buf.byteLength;
    this.decodeMs += performance.now() - t0;
    if (!this.gotFrame) {
      this.gotFrame = true;
      this.onFirstFrame?.();
    }
    if (this.zoom.s > 1.01) this.followCursor();
    return id;
  }

  /** Client coordinates → normalised [0..1] position on the Mac screen. */
  normalized(clientX, clientY) {
    const r = this.canvas.getBoundingClientRect();
    if (!r.width || !r.height) return [0.5, 0.5];
    return [Math.min(1, Math.max(0, (clientX - r.left) / r.width)), Math.min(1, Math.max(0, (clientY - r.top) / r.height))];
  }

  // ───── Local zoom (the screen is tiny; pinch to read things) ─────

  setZoom(s, ax, ay) {
    const z = this.zoom;
    s = Math.max(1, Math.min(6, s));
    const px = (ax - z.x) / z.s, py = (ay - z.y) / z.s;
    z.s = s;
    z.x = ax - s * px;
    z.y = ay - s * py;
    this.clampZoom();
    this.applyZoom();
  }

  panBy(dx, dy) {
    this.zoom.x += dx;
    this.zoom.y += dy;
    this.clampZoom();
    this.applyZoom();
  }

  resetZoom() {
    this.zoom = { s: 1, x: 0, y: 0 };
    this.applyZoom();
  }

  clampZoom() {
    const z = this.zoom, r = this.rect;
    const aw = this.area.clientWidth, ah = this.area.clientHeight;
    if (z.s <= 1.001) { z.s = 1; z.x = 0; z.y = 0; return; }
    const cw = r.w * z.s, ch = r.h * z.s;
    z.x = cw <= aw ? (aw - cw) / 2 - r.x * z.s : Math.min(-r.x * z.s, Math.max(aw - (r.x + r.w) * z.s, z.x));
    z.y = ch <= ah ? (ah - ch) / 2 - r.y * z.s : Math.min(-r.y * z.s, Math.max(ah - (r.y + r.h) * z.s, z.y));
  }

  applyZoom() {
    const z = this.zoom;
    this.wrap.style.transform = z.s === 1 ? '' : `translate(${z.x}px, ${z.y}px) scale(${z.s})`;
  }

  /** Pointer position in screen-area coordinates (unzoomed), or the centre. */
  cursorAnchor() {
    const r = this.rect, z = this.zoom;
    if (!this.cursor || !this.streamW) return [this.area.clientWidth / 2, this.area.clientHeight / 2];
    const px = r.x + (this.cursor[0] / this.streamW) * r.w, py = r.y + (this.cursor[1] / this.streamH) * r.h;
    return [z.x + z.s * px, z.y + z.s * py];
  }

  followCursor() {
    if (!this.cursor) return;
    const [qx, qy] = this.cursorAnchor();
    const aw = this.area.clientWidth, ah = this.area.clientHeight;
    const m = Math.min(aw, ah) * 0.16;
    let dx = 0, dy = 0;
    if (qx < m) dx = m - qx; else if (qx > aw - m) dx = aw - m - qx;
    if (qy < m) dy = m - qy; else if (qy > ah - m) dy = ah - m - qy;
    if (dx || dy) this.panBy(dx, dy);
  }
}

const dist = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
const mid = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });

/** Touch on the screen half: tap = click there, drag = drag, two fingers = zoom/pan (local). */
export class LidTouch {
  // Touching the screen itself: tap to click there, drag to drag; two fingers scroll the Mac (or
  // pinch to zoom the picture), a two-finger tap right-clicks; three or four fingers swipe for
  // Mission Control, App Exposé and Spaces, like on the trackpad.
  constructor(el, screen, cb) {
    this.el = el;
    this.screen = screen;
    this.cb = cb;
    this.p = new Map();
    this.mode = 'none';
    this.lastTap = { t: 0, x: 0, y: 0, n: 0 };
    this.momentum = 0;
    el.addEventListener('pointerdown', (e) => this.down(e));
    el.addEventListener('pointermove', (e) => this.move(e));
    el.addEventListener('pointerup', (e) => this.up(e, false));
    el.addEventListener('pointercancel', (e) => this.up(e, true));
  }

  centroid() {
    let x = 0, y = 0;
    for (const q of this.p.values()) { x += q.x; y += q.y; }
    return { x: x / this.p.size, y: y / this.p.size };
  }

  /** Taps click where they land: always in Screen only, else when the setting says so. */
  get taps() { return settings.touchscreen || settings.layout === 'screen'; }

  down(e) {
    if (e.target.closest('button, #overlay:not(.hidden)')) return;
    if (this.cb.enabled && !this.cb.enabled()) return; // Screen only, as a trackpad: trackpad.js has it
    e.preventDefault();
    try { this.el.setPointerCapture(e.pointerId); } catch {}
    const now = performance.now();
    if (e.isPrimary && this.p.size) this.reset(); // no other touch is down: drop stale ones
    cancelAnimationFrame(this.momentum);
    this.cb.touched?.();
    this.p.set(e.pointerId, { x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY });
    if (this.p.size === 1) {
      const near = now - this.lastTap.t < 350 && Math.hypot(e.clientX - this.lastTap.x, e.clientY - this.lastTap.y) < 30;
      this.g = { start: now, moved: false, count: near ? Math.min(3, this.lastTap.n + 1) : 1, primary: e.pointerId };
      this.g.probe = this.cb.probe?.(...this.screen.normalized(e.clientX, e.clientY)) || 0; // a text field there?
      this.mode = 'one';
    } else if (this.p.size === 2 && (this.mode === 'one' || this.mode === 'pan') && !this.g.moved) {
      const [a, b] = [...this.p.values()];
      this.mode = 'two';
      this.two = { d: Math.max(1, dist(a, b)), c: mid(a, b), lc: mid(a, b), s: this.screen.zoom.s, kind: null, moved: false, start: now, v: [] };
    } else if (this.p.size >= 3 && this.mode === 'two' && !this.two.kind) {
      this.mode = 'swipe';
      this.swipe = { c: this.centroid(), fired: false };
    }
  }

  move(e) {
    const pt = this.p.get(e.pointerId);
    if (!pt) return;
    e.preventDefault();
    pt.x = e.clientX;
    pt.y = e.clientY;
    if ((this.mode === 'one' || this.mode === 'drag' || this.mode === 'pan') && e.pointerId !== this.g.primary) return;
    if (this.mode === 'one' && !this.g.moved && Math.hypot(pt.x - pt.sx, pt.y - pt.sy) > 8) {
      this.g.moved = true;
      if (this.taps) {
        this.cb.abs(...this.screen.normalized(pt.sx, pt.sy));
        this.cb.button(0, true, 1);
        this.mode = 'drag';
      } else if (this.screen.zoom.s > 1) {
        this.mode = 'pan';
        this.last = { x: pt.x, y: pt.y };
      }
    }
    if (this.mode === 'drag') {
      this.cb.abs(...this.screen.normalized(pt.x, pt.y));
    } else if (this.mode === 'pan') {
      this.screen.panBy(pt.x - this.last.x, pt.y - this.last.y);
      this.last = { x: pt.x, y: pt.y };
    } else if (this.mode === 'two' && this.p.size >= 2) {
      const [a, b] = [...this.p.values()];
      const t = this.two, d = dist(a, b), c = mid(a, b);
      const cm = Math.hypot(c.x - t.c.x, c.y - t.c.y), dd = Math.abs(d - t.d);
      if (cm > 6 || dd > 8) t.moved = true;
      if (!t.kind) {
        // Fingers spreading: zoom the picture. Moving together: scroll the Mac under them.
        // A real pinch's midpoint drifts too: neither wins until it clearly outweighs the other.
        if ((dd > 16 && dd > cm * 1.2) || dd > 40) t.kind = 'pinch';
        else if ((cm > 8 && cm > dd * 1.5) || cm > 30) {
          t.kind = 'scroll';
          this.cb.abs(...this.screen.normalized(t.c.x, t.c.y));
        }
      }
      if (t.kind === 'scroll') {
        const sx = c.x - t.lc.x, sy = c.y - t.lc.y;
        if (sx || sy) {
          this.cb.scroll?.(sx, sy);
          const now = performance.now();
          t.v.push({ t: now, x: sx, y: sy });
          while (t.v.length && now - t.v[0].t > 100) t.v.shift();
        }
      } else if (t.kind === 'pinch') {
        const ar = this.screen.area.getBoundingClientRect();
        this.screen.setZoom(t.s * (d / t.d), c.x - ar.left, c.y - ar.top);
        this.screen.panBy(c.x - t.lc.x, c.y - t.lc.y);
      }
      t.lc = c;
    } else if (this.mode === 'swipe' && !this.swipe.fired) {
      const c = this.centroid(), mx = c.x - this.swipe.c.x, my = c.y - this.swipe.c.y;
      if (Math.hypot(mx, my) > 50) {
        this.swipe.fired = true;
        this.cb.swipe3?.(Math.abs(mx) > Math.abs(my) ? (mx > 0 ? 'right' : 'left') : (my > 0 ? 'down' : 'up'));
      }
    }
  }

  up(e, cancelled) {
    const pt = this.p.get(e.pointerId);
    if (!pt) return;
    this.p.delete(e.pointerId);
    const now = performance.now();
    if (this.mode === 'one' && e.pointerId === this.g.primary) {
      if (!cancelled && !this.g.moved && now - this.g.start < 350 && this.taps) {
        this.cb.abs(...this.screen.normalized(pt.x, pt.y));
        this.cb.click(0, this.g.count);
        this.lastTap = { t: now, x: pt.x, y: pt.y, n: this.g.count };
        this.cb.tapped?.(this.g.probe); // still inside the tap, so iOS lets its keyboard come up
      }
      this.mode = this.p.size ? 'tail' : 'none';
    } else if (this.mode === 'drag' && e.pointerId === this.g.primary) {
      if (!cancelled) this.cb.abs(...this.screen.normalized(pt.x, pt.y));
      this.cb.button(0, false, 1);
      this.mode = this.p.size ? 'tail' : 'none';
    } else if (this.mode === 'two') {
      const t = this.two;
      if (!cancelled && !t.moved && now - t.start < 300 && this.taps && this.p.size === 0) {
        this.cb.abs(...this.screen.normalized(t.c.x, t.c.y));
        this.cb.click(1, 1);
      }
      if (t.kind === 'scroll' && !cancelled) this.glide(t.v, now);
      this.mode = this.p.size ? 'tail' : 'none';
    }
    if (this.p.size === 0) this.mode = 'none';
  }

  /** Keep scrolling after the fingers lift, slowing down, like iOS. */
  glide(samples, now) {
    const recent = samples.filter((s) => now - s.t < 90);
    if (recent.length < 2 || !this.cb.scroll) return;
    const span = Math.max(16, now - recent[0].t);
    let vx = recent.reduce((a, s) => a + s.x, 0) / span;
    let vy = recent.reduce((a, s) => a + s.y, 0) / span;
    if (Math.hypot(vx, vy) < 0.3) return;
    let last = performance.now();
    const step = () => {
      const t = performance.now(), dt = Math.min(50, t - last);
      last = t;
      const decay = Math.pow(0.9963, dt);
      vx *= decay;
      vy *= decay;
      this.cb.scroll(vx * dt, vy * dt, true);
      this.momentum = Math.hypot(vx, vy) < 0.03 ? 0 : requestAnimationFrame(step);
    };
    this.momentum = requestAnimationFrame(step);
  }

  /** Forget all touches (app backgrounded, connection lost); lets go of a drag in progress. */
  reset() {
    if (this.mode === 'drag') this.cb.button(0, false, 1);
    this.p.clear();
    this.mode = 'none';
  }
}
