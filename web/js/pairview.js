// The "Pair this iPhone" screen: a little Mac acting out where the code is (menu bar › Duo Mac ›
// Add iPhone…), and beside or below it, Scan QR Code (in the iPhone app) or the code typed in 8 boxes.
// Pairing codes are 8 characters from the Mac's alphabet (Config.swift: no 0/O, 1/I/L).

const QR_ICON = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
  <path d="M3 8V5a2 2 0 0 1 2-2h3M16 3h3a2 2 0 0 1 2 2v3M21 16v3a2 2 0 0 1-2 2h-3M8 21H5a2 2 0 0 1-2-2v-3"/>
  <rect x="7" y="7" width="4" height="4" rx=".6"/><rect x="13" y="7" width="4" height="4" rx=".6"/><rect x="7" y="13" width="4" height="4" rx=".6"/>
  <path d="M13 13h1.5v1.5M17 13v4h-4M15.5 15.5v1.5"/></svg>`;

/** A QR-looking pattern (decorative): finder squares in three corners, noise elsewhere. */
function qrPattern(x, y, size) {
  const n = 21, c = size / n;
  let seed = 7;
  const rnd = () => ((seed = (seed * 9301 + 49297) % 233280) / 233280);
  const finder = (i, j) => [[0, 0], [n - 7, 0], [0, n - 7]].some(([a, b]) => i >= a && i < a + 7 && j >= b && j < b + 7);
  let s = '';
  for (const [a, b] of [[0, 0], [n - 7, 0], [0, n - 7]]) {
    s += `<rect x="${x + a * c}" y="${y + b * c}" width="${7 * c}" height="${7 * c}" fill="#111"/>`
      + `<rect x="${x + (a + 1) * c}" y="${y + (b + 1) * c}" width="${5 * c}" height="${5 * c}" fill="#fff"/>`
      + `<rect x="${x + (a + 2) * c}" y="${y + (b + 2) * c}" width="${3 * c}" height="${3 * c}" fill="#111"/>`;
  }
  for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) {
    if (!finder(i, j) && rnd() < 0.48) s += `<rect x="${(x + i * c).toFixed(2)}" y="${(y + j * c).toFixed(2)}" width="${c.toFixed(2)}" height="${c.toFixed(2)}" fill="#111"/>`;
  }
  return s;
}

const MAC_SVG = `<svg class="pv-mac" viewBox="0 0 320 214" aria-hidden="true">
  <defs>
    <linearGradient id="pv-wall" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#2b3a67"/><stop offset=".55" stop-color="#5b3f7a"/><stop offset="1" stop-color="#b0567a"/>
    </linearGradient>
    <clipPath id="pv-screen"><rect x="12" y="10" width="296" height="176" rx="6"/></clipPath>
  </defs>
  <rect x="4" y="2" width="312" height="192" rx="12" fill="#0c0c0e" stroke="#3b3b42" stroke-width="1.5"/>
  <path d="M0 196h320l-6 10a6 6 0 0 1-5 3H11a6 6 0 0 1-5-3z" fill="#2c2c31"/>
  <g clip-path="url(#pv-screen)">
    <rect x="12" y="10" width="296" height="176" fill="url(#pv-wall)"/>
    <rect x="12" y="10" width="296" height="13" fill="rgba(20,20,26,.55)"/>
    <text x="20" y="20" font-size="8.5" fill="#fff" font-family="-apple-system, system-ui"></text>
    <rect x="32" y="14.5" width="18" height="4" rx="2" fill="rgba(255,255,255,.75)"/>
    <rect x="55" y="14.5" width="12" height="4" rx="2" fill="rgba(255,255,255,.5)"/>
    <rect x="71" y="14.5" width="12" height="4" rx="2" fill="rgba(255,255,255,.5)"/>
    <rect x="87" y="14.5" width="14" height="4" rx="2" fill="rgba(255,255,255,.5)"/>
    <rect x="222" y="14" width="9" height="5" rx="1.5" fill="none" stroke="rgba(255,255,255,.6)"/>
    <circle cx="240" cy="16.5" r="2.6" fill="none" stroke="rgba(255,255,255,.6)"/>
    <g class="pv-icon">
      <rect x="250" y="11.5" width="15" height="10" rx="2.5" fill="rgba(255,255,255,0)"/>
      <rect x="253" y="13.2" width="9" height="5.6" rx="1" fill="none" stroke="#fff" stroke-width="1.1"/>
      <path d="M251.5 19.8h12" stroke="#fff" stroke-width="1.1" stroke-linecap="round"/>
    </g>
    <text x="272" y="19.5" font-size="6.5" fill="#fff" font-family="-apple-system, system-ui">9:41</text>

    <g class="pv-menu">
      <rect x="196" y="25" width="104" height="74" rx="7" fill="rgba(44,44,50,.97)" stroke="rgba(255,255,255,.14)"/>
      <text x="205" y="38" font-size="7" font-weight="600" fill="#fff" font-family="-apple-system, system-ui">Duo Mac</text>
      <text x="205" y="48" font-size="5.6" fill="rgba(255,255,255,.55)" font-family="-apple-system, system-ui">Waiting for your iPhone</text>
      <rect x="203" y="53" width="90" height=".6" fill="rgba(255,255,255,.14)"/>
      <rect class="pv-hl" x="200" y="57" width="96" height="11" rx="3" fill="#0a84ff"/>
      <text x="206" y="64.8" font-size="6.4" fill="#fff" font-family="-apple-system, system-ui">＋ Add iPhone…</text>
      <text x="206" y="77" font-size="6.4" fill="rgba(255,255,255,.85)" font-family="-apple-system, system-ui">⚙︎ Settings…</text>
      <text x="206" y="89" font-size="6.4" fill="rgba(255,255,255,.85)" font-family="-apple-system, system-ui">⏻ Quit Duo Mac</text>
    </g>

    <g class="pv-win">
      <rect x="92" y="40" width="136" height="128" rx="9" fill="#242429" stroke="rgba(255,255,255,.14)"/>
      <circle cx="102" cy="49" r="2.2" fill="#ff5f57"/><circle cx="109" cy="49" r="2.2" fill="#febc2e"/><circle cx="116" cy="49" r="2.2" fill="#28c840"/>
      <text x="160" y="62" font-size="7.5" font-weight="600" fill="#fff" text-anchor="middle" font-family="-apple-system, system-ui">Add iPhone</text>
      <rect x="126" y="68" width="68" height="68" rx="5" fill="#fff"/>
      ${qrPattern(130, 72, 60)}
      <text x="160" y="152" font-size="9" font-weight="600" letter-spacing="1.2" fill="#fff" text-anchor="middle" font-family="ui-monospace, Menlo, monospace">ABCD-2345</text>
      <text x="160" y="161.5" font-size="5.4" fill="rgba(255,255,255,.5)" text-anchor="middle" font-family="-apple-system, system-ui">Scan with your iPhone</text>
    </g>
  </g>
  <g class="pv-cursor">
    <g class="pv-click"><path d="M0 0v13.5l3.3-3.1 2.4 5.4 2.3-1-2.4-5.3 4.6-.2z" fill="#fff" stroke="#000" stroke-width=".9" stroke-linejoin="round"/></g>
  </g>
</svg>`;

export class PairView {
  /** cb: { scan() (or null outside the iPhone app), code(code) } */
  constructor(root, cb) {
    this.root = root;
    this.cb = cb;
    root.innerHTML = `
      <div class="pv-anim">
        ${MAC_SVG}
        <ol class="pv-steps">
          <li class="pv-s1"><b>1</b>Click <span class="pv-chip">${'<svg viewBox="0 0 16 12"><rect x="3" y="1.5" width="10" height="6.5" rx="1.2" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M1 10.3h14" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>'}</span> Duo Mac in the Mac’s menu bar</li>
          <li class="pv-s2"><b>2</b>Choose <em>Add iPhone…</em></li>
          <li class="pv-s3"><b>3</b>Scan the QR code, or type the code below</li>
        </ol>
      </div>
      <div class="pv-form">
        <h2>Pair this iPhone</h2>
        <p class="pv-note" hidden></p>
        ${cb.scan ? `<button type="button" class="pv-scan">${QR_ICON}<span>Scan QR Code</span></button>
        <div class="pv-or"><span>or type the code</span></div>`
          : '<p class="pv-hint">Scan the QR code with the iPhone’s Camera, or type the code:</p>'}
        <label class="pv-code" aria-label="Pairing code">
          <input type="text" inputmode="text" autocomplete="off" autocorrect="off" autocapitalize="characters"
            spellcheck="false" enterkeyhint="go" maxlength="9">
          <span class="pv-cells">${'<i></i>'.repeat(4)}<span class="pv-dash">–</span>${'<i></i>'.repeat(4)}</span>
        </label>
      </div>`;
    this.input = root.querySelector('.pv-code input');
    this.cells = [...root.querySelectorAll('.pv-cells i')];
    this.note = root.querySelector('.pv-note');
    root.querySelector('.pv-scan')?.addEventListener('click', () => this.cb.scan());
    this.input.addEventListener('input', () => this.typed());
    this.input.addEventListener('focus', () => this.render());
    this.input.addEventListener('blur', () => this.render());
    this.input.addEventListener('keydown', (e) => { if (e.key === 'Enter') this.submit(); });
    new ResizeObserver(() => this.fit()).observe(root);
  }

  show(note = '') {
    this.note.textContent = note;
    this.note.hidden = !note;
    this.input.value = '';
    this.render();
    this.fit();
  }

  /** Side by side when the space is wide, the Mac above the form when it's tall. */
  fit() {
    const r = this.root.getBoundingClientRect();
    if (r.width && r.height) this.root.classList.toggle('wide', r.width > r.height * 1.15);
  }

  typed() {
    // Only the Mac's alphabet; a pasted "ABCD-EFGH" or a whole pairing link works too.
    let v = this.input.value.toUpperCase();
    const m = v.match(/PAIR=([0-9A-Z-]+)/);
    if (m) v = m[1];
    v = v.replace(/[^0-9A-Z]/g, '').slice(0, 8);
    this.input.value = v;
    this.render();
    if (v.length === 8) this.submit();
  }

  submit() {
    const v = this.input.value;
    if (v.length !== 8) return;
    this.input.blur();
    this.cb.code(v);
  }

  render() {
    const v = this.input.value, focused = document.activeElement === this.input;
    this.cells.forEach((c, i) => {
      c.textContent = v[i] || '';
      c.classList.toggle('filled', i < v.length);
      c.classList.toggle('cur', focused && i === Math.min(v.length, 7));
    });
    this.root.querySelector('.pv-code').classList.toggle('done', v.length === 8);
  }
}
