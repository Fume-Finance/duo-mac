// Trackpad gestures, modelled on a Mac trackpad with "tap to click" on.
//
//   1 finger move ........ pointer (with acceleration)
//   tap .................. click   (tap again quickly: double / triple click)
//   tap, then drag ....... drag (mouse button held until you lift)
//   2-finger tap ......... right-click
//   2-finger move ........ scroll (with momentum)
//   pinch ................ zoom the screen half (locally)
//   3-finger swipe ....... Mission Control / App Exposé / switch Spaces
//
// Real fingers rarely land or lift at the same instant, so:
//   • a second finger that lands while one finger is already moving the pointer is ignored (a brush);
//   • once fingers start lifting from a multi-finger gesture, the rest of it is ignored ("tail"),
//     but a two-finger tap still counts as a right-click;
//   • extra fingers never take over a pointer move or a drag.
import { settings } from './settings.js';

const TAP_MS = 260;          // max duration of a tap
const TWO_TAP_MS = 350;      // max duration of a two-finger tap
const TAP_SLOP = 7;          // px a finger may wander and still count as a tap
const MULTI_TAP_MS = 300;    // window for the next tap of a double-click / tap-drag
const MULTI_TAP_DIST = 45;

function accelerate(dx, dy, dt) {
  const d = Math.hypot(dx, dy);
  if (!d) return [0, 0];
  const v = d / Math.max(dt, 4); // px per ms
  const gain = 1.5 * settings.tracking * (1 + 1.9 * Math.pow(Math.min(v, 3), 1.25));
  return [dx * gain, dy * gain];
}

export class Trackpad {
  constructor(zone, surface, cb) {
    this.zone = zone;
    this.surface = surface;
    this.cb = cb;
    this.p = new Map();
    this.mode = 'none';
    this.g = null;
    this.lastTap = { t: 0, x: 0, y: 0, n: 0 };
    this.momentum = 0;
    zone.addEventListener('pointerdown', (e) => this.down(e));
    zone.addEventListener('pointermove', (e) => this.move(e));
    zone.addEventListener('pointerup', (e) => this.up(e, false));
    zone.addEventListener('pointercancel', (e) => this.up(e, true));
    zone.addEventListener('lostpointercapture', (e) => { if (this.p.has(e.pointerId)) this.up(e, true); });
  }

  /** Centroid / spread of the fingers that started a multi-finger gesture. */
  centroid(ids) {
    let x = 0, y = 0, n = 0;
    for (const id of ids) {
      const p = this.p.get(id);
      if (p) { x += p.x; y += p.y; n++; }
    }
    return n ? { x: x / n, y: y / n } : null;
  }

  spread(ids) {
    const a = this.p.get(ids[0]), b = this.p.get(ids[1]);
    return a && b ? Math.hypot(a.x - b.x, a.y - b.y) : 0;
  }

  down(e) {
    e.preventDefault();
    try { this.zone.setPointerCapture(e.pointerId); } catch {}
    const now = performance.now();
    // A primary pointer means no other touch is down: forget anything stale (a lost pointerup).
    if (e.isPrimary && this.p.size) this.reset();
    const stoppedMomentum = this.stopMomentum();
    this.p.set(e.pointerId, { x: e.clientX, y: e.clientY, sx: e.clientX, sy: e.clientY, lt: now });
    this.surface.classList.add('touching');
    this.cb.touched?.();

    if (this.p.size === 1) {
      const quick = now - this.lastTap.t < MULTI_TAP_MS &&
        Math.hypot(e.clientX - this.lastTap.x, e.clientY - this.lastTap.y) < MULTI_TAP_DIST;
      this.g = { start: now, moved: false, stopper: stoppedMomentum, followsTap: quick, primary: e.pointerId };
      this.g.probe = this.cb.probe?.() || 0; // a text field under the pointer?
      this.mode = 'one';
      return;
    }
    if (!this.g) return;
    // Extra fingers while moving the pointer or dragging are brushes: ignore them.
    if (this.mode === 'drag' || this.mode === 'tail' || (this.mode === 'one' && this.g.moved)) return;
    const ids = [...this.p.keys()];
    if (this.mode === 'one' && this.p.size === 2) {
      this.mode = 'two';
      this.g.followsTap = false;
      const c = this.centroid(ids);
      this.two = { ids, c, last: c, d: this.spread(ids), kind: null, moved: false, start: now, v: [] };
    } else if (this.mode === 'two' && !this.two.kind && !this.two.moved) {
      this.mode = 'three';
      this.three = { ids, c: this.centroid(ids), fired: false };
    }
    // A third finger joining a scroll or pinch that has already started is ignored.
  }

  move(e) {
    const pt = this.p.get(e.pointerId);
    if (!pt) return;
    e.preventDefault();
    const now = performance.now();
    const dx = e.clientX - pt.x, dy = e.clientY - pt.y, dt = now - pt.lt;
    pt.x = e.clientX;
    pt.y = e.clientY;
    pt.lt = now;

    if (this.mode === 'one' || this.mode === 'drag') {
      if (e.pointerId !== this.g.primary) return;
      if (!this.g.moved && Math.hypot(pt.x - pt.sx, pt.y - pt.sy) > TAP_SLOP) {
        this.g.moved = true;
        if (this.mode === 'one' && this.g.followsTap) {
          this.mode = 'drag';
          this.surface.classList.add('dragging');
          this.cb.button(0, true, 1);
        }
      }
      if (this.g.moved) {
        const [ax, ay] = accelerate(dx, dy, dt);
        this.cb.move(ax, ay);
      }
    } else if (this.mode === 'two') {
      const t = this.two;
      if (!t.ids.includes(e.pointerId)) return;
      const c = this.centroid(t.ids), d = this.spread(t.ids);
      if (!c || !d) return;
      if (!t.kind) {
        const cm = Math.hypot(c.x - t.c.x, c.y - t.c.y), dd = Math.abs(d - t.d);
        if (cm > 5 || dd > 8) t.moved = true;
        if (dd > 26 && dd > cm * 1.3 && t.d > 0) {
          t.kind = 'pinch';
          t.d0 = t.d;
          this.cb.zoom?.('start');
        } else if (cm > 6) {
          t.kind = 'scroll';
          t.last = c;
        }
      }
      if (t.kind === 'scroll') {
        const sx = c.x - t.last.x, sy = c.y - t.last.y;
        t.last = c;
        if (sx || sy) {
          this.cb.scroll(sx, sy);
          t.v.push({ t: now, x: sx, y: sy });
          while (t.v.length && now - t.v[0].t > 100) t.v.shift();
        }
      } else if (t.kind === 'pinch' && t.d0 > 0) {
        this.cb.zoom?.('change', d / t.d0);
      }
    } else if (this.mode === 'three') {
      const t = this.three, c = this.centroid(t.ids);
      if (!c || t.fired) return;
      const mx = c.x - t.c.x, my = c.y - t.c.y;
      if (Math.hypot(mx, my) > 40) {
        t.fired = true;
        const dir = Math.abs(mx) > Math.abs(my) ? (mx > 0 ? 'right' : 'left') : (my > 0 ? 'down' : 'up');
        this.cb.swipe3?.(dir);
      }
    }
    // 'tail': fingers lifting from a multi-finger gesture — nothing to do until all are up.
  }

  up(e, cancelled) {
    const pt = this.p.get(e.pointerId);
    if (!pt) return;
    this.p.delete(e.pointerId);
    const now = performance.now();

    if (this.mode === 'one') {
      if (e.pointerId === this.g.primary) {
        const tap = !cancelled && !this.g.moved && now - this.g.start < TAP_MS && !this.g.stopper;
        if (tap) {
          const n = this.g.followsTap ? Math.min(3, this.lastTap.n + 1) : 1;
          this.cb.click(0, n);
          this.lastTap = { t: now, x: pt.x, y: pt.y, n };
          this.cb.tapped?.(this.g.probe);
        } else {
          this.lastTap.t = 0;
        }
        if (this.p.size) this.mode = 'tail'; // a brushing finger is still down
      }
    } else if (this.mode === 'drag') {
      if (e.pointerId === this.g.primary) {
        this.cb.button(0, false, 1);
        this.surface.classList.remove('dragging');
        this.lastTap.t = 0;
        if (this.p.size) this.mode = 'tail';
      }
    } else if (this.mode === 'two') {
      const t = this.two;
      // The gesture ends when the first of its fingers lifts.
      t.tap = !cancelled && !t.moved && !t.kind && now - t.start < TWO_TAP_MS;
      if (t.kind === 'scroll' && !cancelled) this.startMomentum(t.v, now);
      else if (t.kind === 'pinch') this.cb.zoom?.('end');
      this.lastTap.t = 0;
      this.mode = this.p.size ? 'tail' : 'none';
      if (!this.p.size && t.tap) this.cb.click(1, 1);
    } else if (this.mode === 'three') {
      this.lastTap.t = 0;
      this.mode = this.p.size ? 'tail' : 'none';
    } else if (this.mode === 'tail' && !this.p.size) {
      const t = this.two;
      const still = Math.hypot(pt.x - pt.sx, pt.y - pt.sy) < TAP_SLOP * 2;
      if (t?.tap && still && !cancelled && now - t.start < TWO_TAP_MS + 150) this.cb.click(1, 1);
    }

    if (this.p.size === 0) {
      this.mode = 'none';
      this.two = null;
      this.surface.classList.remove('touching');
    }
  }

  startMomentum(samples, now) {
    const recent = samples.filter((s) => now - s.t < 90);
    if (recent.length < 2) return;
    const span = Math.max(16, now - recent[0].t);
    let vx = recent.reduce((a, s) => a + s.x, 0) / span;
    let vy = recent.reduce((a, s) => a + s.y, 0) / span;
    if (Math.hypot(vx, vy) < 0.3) return;
    let last = performance.now();
    const step = () => {
      const t = performance.now();
      const dt = Math.min(50, t - last);
      last = t;
      const decay = Math.pow(0.9963, dt);
      vx *= decay;
      vy *= decay;
      this.cb.scroll(vx * dt, vy * dt, true);
      if (Math.hypot(vx, vy) < 0.03) {
        this.momentum = 0;
        return;
      }
      this.momentum = requestAnimationFrame(step);
    };
    this.momentum = requestAnimationFrame(step);
  }

  stopMomentum() {
    if (!this.momentum) return false;
    cancelAnimationFrame(this.momentum);
    this.momentum = 0;
    return true;
  }

  /** Lift everything (app went to the background, connection lost, stale touches). */
  reset() {
    if (this.mode === 'drag') {
      this.cb.button(0, false, 1);
      this.surface.classList.remove('dragging');
    }
    this.stopMomentum();
    this.p.clear();
    this.mode = 'none';
    this.two = null;
    this.surface.classList.remove('touching');
  }
}
