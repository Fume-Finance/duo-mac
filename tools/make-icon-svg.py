# Duo Mac icon: an iPhone Duo opened like a laptop, modelled in 3D (mm) and projected to SVG.
import math, sys

W_MM, D_MM, T = 118.0, 82.0, 6.0     # each half: 118 x 82 mm, thickness (a bit exaggerated)
R = 11.0                              # outer corner radius
TILT = math.radians(18)               # lid leans back from vertical
YAW, PITCH, DIST, FOV = math.radians(34), math.radians(31), 420.0, 900.0

# ── geometry helpers ─────────────────────────────────────────────────────────
def deck_pt(x, z, y=T):               # deck: x along the hinge, z toward the front
    return (x, y, z)

def lid_pt(x, s, w=0.0):              # lid: s up from the hinge, w into the lid (thickness)
    c, si = math.cos(TILT), math.sin(TILT)
    # front (screen) surface through the hinge line at (y=T, z=0); w goes back along the normal
    return (x, T + s * c - w * si, -s * si - w * c)

def outline(w, d, r, steps=10):
    """Slab outline in (u, v): v=0 at the hinge (square corners), v=d at the outer edge (rounded)."""
    pts = [(0.0, 0.0), (w, 0.0)]
    for i in range(steps + 1):                     # right outer corner
        a = -math.pi / 2 + (math.pi / 2) * i / steps
        pts.append((w - r + r * math.cos(a + math.pi / 2 * 0) * 0 + r * math.sin(a + math.pi / 2), d - r + r * math.cos(a + math.pi / 2) * -1 * -1))
    return pts

def rounded_outline(w, d, r, steps=10):
    pts = [(0.0, 0.0), (w, 0.0), (w, d - r)]
    for i in range(1, steps + 1):                  # right outer corner
        a = (math.pi / 2) * i / steps
        pts.append((w - r + r * math.cos(a), d - r + r * math.sin(a)))
    pts.append((r, d))
    for i in range(1, steps + 1):                  # left outer corner
        a = math.pi / 2 + (math.pi / 2) * i / steps
        pts.append((r + r * math.cos(a), d - r + r * math.sin(a)))
    return pts

def rot(p):
    x, y, z = p[0] - W_MM / 2, p[1] - 30, p[2] - 20
    x, z = x * math.cos(YAW) + z * math.sin(YAW), -x * math.sin(YAW) + z * math.cos(YAW)
    y, z = y * math.cos(PITCH) - z * math.sin(PITCH), y * math.sin(PITCH) + z * math.cos(PITCH)
    return (x, y, z)

def proj(p):
    x, y, z = rot(p)
    k = FOV / (DIST - z)
    return (x * k, -y * k, z)

def normal(a, b, c):
    a, b, c = rot(a), rot(b), rot(c)
    u = [b[i] - a[i] for i in range(3)]; v = [c[i] - a[i] for i in range(3)]
    n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
    l = math.sqrt(sum(q * q for q in n)) or 1
    return tuple(q / l for q in n)

# ── shapes ───────────────────────────────────────────────────────────────────
polys = []   # (depth, svg)
def path(pts3, **attrs):
    pp = [proj(p) for p in pts3]
    d = "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y, _ in pp) + " Z"
    a = " ".join(f'{k.replace("_", "-")}="{v}"' for k, v in attrs.items())
    return f'<path d="{d}" {a}/>', sum(z for *_, z in pp) / len(pp)

LIGHT = (-0.3, 0.75, 0.6)
def shade(n, base=(58, 62, 72), hi=(190, 196, 206)):
    l = max(0.0, sum(n[i] * LIGHT[i] for i in range(3)) / math.sqrt(sum(q * q for q in LIGHT)))
    l = l ** 1.6
    return "#%02x%02x%02x" % tuple(int(base[i] + (hi[i] - base[i]) * l) for i in range(3))

def slab(to3, outline_pts, thick, skip_hinge=True):
    """Visible walls of a slab (front surface at w=0, back at w=thick), lit by their outward normal."""
    out = []
    n = len(outline_pts)
    cu = sum(u for u, _ in outline_pts) / n; cv = sum(v for _, v in outline_pts) / n
    center = rot(to3(cu, cv, thick / 2))
    for i in range(n):
        (u0, v0), (u1, v1) = outline_pts[i], outline_pts[(i + 1) % n]
        if skip_hinge and v0 == 0 and v1 == 0:
            continue
        q = [to3(u0, v0, 0), to3(u1, v1, 0), to3(u1, v1, thick), to3(u0, v0, thick)]
        nn = normal(q[0], q[1], q[2])
        mid = rot(to3((u0 + u1) / 2, (v0 + v1) / 2, thick / 2))
        if sum((mid[k] - center[k]) * nn[k] for k in range(3)) < 0:
            nn = tuple(-c for c in nn)                 # make it point outward
        if nn[2] <= 0.02:
            continue
        svg, z = path(q, fill=shade(nn), stroke=shade(nn), stroke_width="0.6")
        out.append((z, svg))
    return out

deck3 = lambda u, v, w: deck_pt(u, v, T - w)        # w=0 top surface, w=T bottom
lid3 = lambda u, v, w: lid_pt(u, v, w)
ol = rounded_outline(W_MM, D_MM, R)

def surface(to3, pts, **attrs):
    return path([to3(u, v, 0) for u, v in pts], **attrs)[0]

def rrect(u0, v0, u1, v1, r, steps=5):
    pts = []
    for cx, cy, a0 in ((u1 - r, v0 + r, -90), (u1 - r, v1 - r, 0), (u0 + r, v1 - r, 90), (u0 + r, v0 + r, 180)):
        for i in range(steps + 1):
            a = math.radians(a0 + 90 * i / steps)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts

def inset_outline(i, top_round=True):
    """Screen area: inset i from the edges; the fold side stays open (the screen bends there)."""
    pts = rounded_outline(W_MM - 2 * i, D_MM - i, R - i, 12)
    return [(u + i, v) for u, v in pts]

# ── lid (drawn first: it's behind) ───────────────────────────────────────────
body = []
lid_walls = slab(lid3, ol, T)
# buttons on the lid's left edge (volume) and top edge (top button)
def bump(to3, a, b, along, out=1.4, w0=1.6, w1=4.4):
    # a..b along an edge parameter; along(t) -> (u, v) on the outline; extruded outward
    return None

parts = []
parts += lid_walls
lid_face = surface(lid3, ol, fill="url(#ti)")
lid_screen_pts = inset_outline(2.2)
screen_clip = surface(lid3, lid_screen_pts)

# wallpaper waves on the lid screen (u across, v up from the fold)
def wave(base, amp, phase, top=True):
    pts = [(2.2 + (W_MM - 4.4) * i / 40, base + amp * math.sin(i / 40 * math.pi * 1.6 + phase)) for i in range(41)]
    return pts + [(W_MM - 2.2, 0), (2.2, 0)]
waves = [
    ('url(#w1)', wave(48, 9, 0.4)),
    ('url(#w2)', wave(34, 7, 1.6)),
    ('url(#w3)', wave(20, 5, 2.6)),
]
lid_content = [surface(lid3, lid_screen_pts, fill="url(#sky)")]
lid_content += [surface(lid3, p, fill=f) for f, p in waves]
lid_content.append(surface(lid3, [(2.2 + R, 75.2), (W_MM - 2.2 - R, 75.2), (W_MM - 2.2 - R + 4, 79.8), (2.2 + R - 4, 79.8)], fill="#ffffff", opacity="0.25"))
# dock
lid_content.append(surface(lid3, rrect(30, 3.5, 88, 11.5, 2.6), fill="#ffffff", opacity="0.3"))
cols = ["#3fa7ff", "#34c759", "#ff9f0a", "#ff375f", "#bf5af2", "#ffd60a", "#8e8e93"]
for i, c in enumerate(cols):
    u = 32.6 + i * 7.9
    lid_content.append(surface(lid3, rrect(u, 4.6, u + 5.8, 10.4, 1.4), fill=c))
lid_content.append(surface(lid3, lid_screen_pts, fill="url(#shine)"))

# side buttons: volume (left edge of the lid) and the top button (top edge, left part)
def edge_button(to3, u_fixed, v0, v1, out):
    q = [to3(u_fixed - out, v0, 1.5), to3(u_fixed - out, v1, 1.5), to3(u_fixed - out, v1, T - 1.5), to3(u_fixed - out, v0, T - 1.5)]
    nn = normal(q[0], q[1], q[2])
    return path(q, fill=shade(nn, (40, 44, 52), (210, 214, 222)))[0]
buttons = [edge_button(lid3, 0, 44, 56, 1.3), edge_button(lid3, 0, 59, 71, 1.3)]
def top_button(u0, u1):
    h = 1.6
    top = [lid3(u0, D_MM + h, 1.4), lid3(u1, D_MM + h, 1.4), lid3(u1, D_MM + h, T - 1.4), lid3(u0, D_MM + h, T - 1.4)]
    front = [lid3(u0, D_MM - 0.2, 1.4), lid3(u1, D_MM - 0.2, 1.4), lid3(u1, D_MM + h, 1.4), lid3(u0, D_MM + h, 1.4)]
    return path(top, fill="#cfd4dc")[0] + path(front, fill="#7d838e")[0]
buttons.append(top_button(16, 34))

# ── deck ─────────────────────────────────────────────────────────────────────
deck_walls = slab(deck3, ol, T)
deck_face = surface(deck3, ol, fill="url(#ti)")
deck_screen_pts = inset_outline(2.2)
deck_content = [surface(deck3, deck_screen_pts, fill="url(#glass)")]
# keyboard fills the half toward the fold; trackpad below it (v from the fold toward the front)
m, gap = 7.0, 1.2
rows = [(4.5, 12.0, 10), (13.4, 20.9, 10), (22.3, 29.8, 9), (31.2, 38.7, 0)]
span = W_MM - 2 * m
kw = (span - gap * 9) / 10
for v0, v1, n in rows[:3]:
    sn = n * kw + (n - 1) * gap
    u = m + (span - sn) / 2
    for i in range(n):
        deck_content.append(surface(deck3, rrect(u, v0, u + kw, v1, 1.3), fill="url(#key)"))
        u += kw + gap
v0, v1 = rows[3][0], rows[3][1]
deck_content.append(surface(deck3, rrect(m, v0, m + kw * 1.6, v1, 1.3), fill="url(#key)"))
deck_content.append(surface(deck3, rrect(m + kw * 1.6 + gap, v0, W_MM - m - kw * 1.6 - gap, v1, 1.3), fill="url(#key)"))
deck_content.append(surface(deck3, rrect(W_MM - m - kw * 1.6, v0, W_MM - m, v1, 1.3), fill="url(#key)"))
deck_content.append(surface(deck3, rrect(32, 43.5, 86, 75.5, 2.6), fill="url(#pad)", stroke="#4a4e59", stroke_width="1.2"))
deck_content.append(surface(deck3, deck_screen_pts, fill="url(#shine2)"))
# USB-C on the deck's left edge
def usbc():
    v0, v1, u = 36.0, 46.0, -0.05
    q = [deck3(u, v0, 2.0), deck3(u, v1, 2.0), deck3(u, v1, T - 2.0), deck3(u, v0, T - 2.0)]
    return path(q, fill="#050506")[0]

# hinge: a dark band where the screen bends, plus titanium knuckles at the ends
hinge_band = path([deck3(2.2, 0, 0), deck3(W_MM - 2.2, 0, 0), lid3(W_MM - 2.2, 0.0, 0), lid3(W_MM - 2.2, 3.0, 0), lid3(2.2, 3.0, 0)], fill="#06070a")[0]

def knuckle(x):
    c, si = math.cos(TILT), math.sin(TILT)
    cy, cz, r = T * 0.55, -T * 0.45, T * 0.85
    pts = [(x, cy + r * math.sin(a), cz + r * math.cos(a)) for a in (math.tau * i / 24 for i in range(24))]
    return path(pts, fill="#8a919c", stroke="#5b616c", stroke_width="0.5")[0]

# ── assemble ─────────────────────────────────────────────────────────────────
allpts = [proj(deck3(u, v, w)) for u, v in ol for w in (0, T)] + [proj(lid3(u, v, w)) for u, v in ol for w in (0, T)]
minx = min(p[0] for p in allpts); maxx = max(p[0] for p in allpts)
miny = min(p[1] for p in allpts); maxy = max(p[1] for p in allpts)
S = 780 / max(maxx - minx, maxy - miny)
tx = 512 - (minx + maxx) / 2 * S
ty = 520 - (miny + maxy) / 2 * S

def layer(items):
    return "\n".join(s for _, s in sorted(items, key=lambda t: t[0]))

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs>
  <radialGradient id="bg" cx="50%" cy="42%" r="70%">
    <stop offset="0" stop-color="#1f56e0"/><stop offset="0.5" stop-color="#0a1c5c"/><stop offset="1" stop-color="#030712"/>
  </radialGradient>
  <linearGradient id="ti" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2a2d34"/><stop offset="1" stop-color="#15171b"/></linearGradient>
  <linearGradient id="sky" x1="0" y1="1" x2="0" y2="0" gradientUnits="objectBoundingBox"><stop offset="0" stop-color="#2a2fd6"/><stop offset="1" stop-color="#6b9bff"/></linearGradient>
  <linearGradient id="w1" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#7b2ff7"/><stop offset="0.55" stop-color="#ff3d8b"/><stop offset="1" stop-color="#ffb347"/></linearGradient>
  <linearGradient id="w2" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#3b5bff"/><stop offset="0.6" stop-color="#b03cff"/><stop offset="1" stop-color="#ff5e62"/></linearGradient>
  <linearGradient id="w3" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2140ff"/><stop offset="1" stop-color="#121c8f"/></linearGradient>
  <linearGradient id="glass" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1a1c23"/><stop offset="1" stop-color="#0b0c10"/></linearGradient>
  <linearGradient id="key" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5f636c"/><stop offset="1" stop-color="#4a4d56"/></linearGradient>
  <linearGradient id="pad" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#30333c"/><stop offset="1" stop-color="#26282f"/></linearGradient>
  <linearGradient id="shine" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.16"/><stop offset="0.5" stop-color="#fff" stop-opacity="0"/></linearGradient>
  <linearGradient id="shine2" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.07"/><stop offset="0.6" stop-color="#fff" stop-opacity="0"/></linearGradient>
  <filter id="glow" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="46"/></filter>
  <filter id="soft" x="-30%" y="-60%" width="160%" height="220%"><feGaussianBlur stdDeviation="18"/></filter>
</defs>
<rect width="1024" height="1024" fill="url(#bg)"/>
<g transform="translate({tx:.1f} {ty:.1f}) scale({S:.4f})">
  {surface(lid3, ol, fill="#4f7dff", opacity="0.6", filter="url(#glow)")}
  {path([deck3(u, v, T) for u, v in ol], fill="#000", opacity="0.6", filter="url(#soft)")[0]}
  {layer(lid_walls)}
  {lid_face}
  {"".join(buttons)}
  {"".join(lid_content)}
  {hinge_band}
  {knuckle(-0.3)}
  {layer(deck_walls)}
  {usbc()}
  {deck_face}
  {"".join(deck_content)}
</g>
</svg>
'''
open(sys.argv[1], "w").write(svg)
