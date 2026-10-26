// The Mac's pointer, drawn here rather than in the video, so it moves the moment your finger does
// instead of a network round trip later. Every move is applied here at once (a prediction) and
// sent to the Mac numbered; ~30 times a second the Mac says where the pointer really is and which
// move it has applied last (helper MacPointer.swift). The pointer is drawn at that position plus
// the moves still on their way, so it never jumps back. Its look (arrow, I-beam, hand…) comes from
// the Mac as a picture whenever it changes.

const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));

export class MacCursor {
  constructor(screen, el) {
    this.screen = screen;
    this.el = el;
    this.size = [1512, 982]; // the Mac display, in points
    this.base = null;        // where the Mac last said it was (0…1)
    this.pending = [];       // moves not yet applied there: { q, dx, dy } (points) or { q, abs: [x, y] }
    this.pos = null;
    this.shape = null;
  }

  /** The pointer's look: { img: PNG base64, w, h, hx, hy } in points. */
  setShape(m) {
    this.shape = { w: m.w, h: m.h, hx: m.hx, hy: m.hy };
    this.el.style.backgroundImage = `url(data:image/png;base64,${m.img})`;
    this.render();
  }

  /** A relative move (points), part of the batch the Mac will know as `q`. */
  moved(dx, dy, q) {
    const last = this.pending[this.pending.length - 1];
    if (last && last.q === q && !last.abs) { last.dx += dx; last.dy += dy; } else this.pending.push({ q, dx, dy });
    this.update();
  }

  /** A jump to a spot on the screen (0…1): a tap on the screen itself. */
  jumped(x, y, q) {
    this.pending.push({ q, abs: [x, y] });
    this.update();
  }

  /** The Mac's word: position (0…1), last move applied, display size in points. */
  server(m) {
    this.base = [m.x, m.y];
    if (m.w && m.h) this.size = [m.w, m.h];
    this.pending = this.pending.filter((p) => p.q > m.q);
    this.update();
  }

  update() {
    if (!this.base) return;
    const [W, H] = this.size;
    let [x, y] = this.base;
    for (const p of this.pending) {
      if (p.abs) [x, y] = p.abs;
      else { x = clamp(x + p.dx / W, 0, 1 - 1 / W); y = clamp(y + p.dy / H, 0, 1 - 1 / H); }
    }
    this.pos = [x, y];
    this.render();
  }

  render() {
    const s = this.screen, r = s.rect, sh = this.shape;
    if (!this.pos || !sh || !r.w || !s.gotFrame) { this.el.hidden = true; return; }
    const k = r.w / this.size[0]; // CSS pixels per Mac point
    const left = r.x + this.pos[0] * r.w - sh.hx * k, top = r.y + this.pos[1] * r.h - sh.hy * k;
    this.el.hidden = false;
    this.el.style.width = `${sh.w * k}px`;
    this.el.style.height = `${sh.h * k}px`;
    this.el.style.transform = `translate(${left}px, ${top}px)`;
    // Zoomed in, the view follows the pointer: this one, not the one in the last frame.
    if (s.streamW) {
      s.cursor = [this.pos[0] * s.streamW, this.pos[1] * s.streamH];
      if (s.zoom.s > 1.01) s.followCursor();
    }
  }
}
