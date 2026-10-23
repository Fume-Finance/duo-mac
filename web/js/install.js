// "Add to Home Screen", shown step by step for the browser the page was opened in. Every iPhone
// browser runs on WebKit, but each one names itself in the user agent, and they hide Add to Home
// Screen in different places.

const ua = navigator.userAgent;

/** safari | chrome | firefox | edge | google | inapp | other */
export const browser = !/iPhone|iPad|iPod/.test(ua) ? 'other'
  : /CriOS\//.test(ua) ? 'chrome'
  : /FxiOS\//.test(ua) ? 'firefox'
  : /EdgiOS\//.test(ua) ? 'edge'
  : /GSA\//.test(ua) ? 'google'
  : /Version\/[\d.]+.*Safari\//.test(ua) ? 'safari'
  : 'inapp';

export const browserName = {
  safari: 'Safari', chrome: 'Chrome', firefox: 'Firefox', edge: 'Edge', google: 'the Google app', inapp: 'this app', other: 'this browser',
}[browser];

const svg = (d, w = 1.7) => `<svg viewBox="0 0 20 20" aria-hidden="true"><path d="${d}" fill="none" stroke="currentColor" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
const ICON = {
  share: svg('M10 2.5v9.5M6.6 5.9 10 2.5l3.4 3.4M7 8.5H5v9h10v-9h-2'),
  menu: svg('M3.5 5.5h13M3.5 10h13M3.5 14.5h8'),
  back: svg('M16 10H4.5M9 5.5 4.5 10 9 14.5'),
  dots: svg('M4 10h.01M10 10h.01M16 10h.01', 3),
  reload: svg('M15.5 10a5.5 5.5 0 1 1-1.6-3.9M14.2 3v3.4h-3.4'),
  tabs: svg('M6.5 6.5V4h9.5v9.5h-2.5M4 6.5h9.5V16H4z'),
  more: svg('M5.5 8 10 12.5 14.5 8'),
  copy: svg('M7 7V3.5h9.5V13H13M3.5 7H13v9.5H3.5z'),
  plus: svg('M3.5 3.5h13v13h-13zM10 7v6M7 10h6'),
  close: svg('M5.5 5.5l9 9M14.5 5.5l-9 9'),
};

// ───── The miniature screens ─────
const page = '<div class="pg"><i class="pg-mac"></i><i class="pg-kb"></i><i class="pg-tp"></i></div>';
const acts = (last) => `<div class="sh-acts">
  <span><i>${ICON.copy}</i>Copy</span><span><i></i>Bookmark</span><span><i></i>Reading List</span>${last}</div>`;

const SCENES = {
  chromeBar: () => `<div class="sc">
    <div class="cbar"><span class="ic dim">${ICON.back}</span><span class="pill">…ts.net<span class="ic hl">${ICON.share}</span></span><span class="ic dim">${ICON.dots}</span></div>
    ${page}<div class="ctool"><i></i><i></i><i></i></div></div>`,
  safariBar: () => `<div class="sc">${page}
    <div class="sbar"><span class="circ">${ICON.back}</span><span class="pill"><span class="ic hl">${ICON.menu}</span>ts.net<span class="ic dim">${ICON.reload}</span></span><span class="circ">${ICON.tabs}</span></div></div>`,
  safariMenu: () => `<div class="sc dimmed">${page}
    <div class="menu"><p>Ask Siri</p><p>Translate…</p><hr><p class="hl">${ICON.share}Share</p><p>Add to Bookmarks</p><p>Find on Page</p></div></div>`,
  shareSheet: () => `<div class="sc dimmed">${page}
    <div class="sheet"><div class="sh-head"><img src="icon-180.png" alt=""><div><b>Duo Mac</b><small>…ts.net</small></div></div>
    <div class="sh-row ppl"><i></i><i></i><i></i><i></i></div>
    <div class="sh-row apps"><i style="background:#0a84ff"></i><i style="background:#30d158"></i><i style="background:#3a8dff"></i><i style="background:#ffd60a"></i></div>
    ${acts(`<span><i class="hl">${ICON.more}</i>View More</span>`)}</div></div>`,
  shareList: () => `<div class="sc dimmed">${page}
    <div class="sheet tall">${acts(`<span><i>${ICON.more}</i>View Less</span>`)}
    <div class="list"><p>Add to Bookmarks</p><p>Find on Page</p><p>Print</p></div>
    <div class="list"><p class="hl">${ICON.plus}Add to Home Screen</p></div></div></div>`,
  addDialog: () => `<div class="sc dimmed">${page}
    <div class="sheet tall dlg"><div class="dlg-top"><span class="circ">${ICON.close}</span><b>Add to Home Screen</b><span class="add hl">Add</span></div>
    <div class="dlg-row"><img src="icon-180.png" alt=""><div>Duo Mac<small>https://…ts.net</small></div></div>
    <div class="dlg-row"><span>Open as Web App</span><i class="sw"></i></div><div class="kb"></div></div></div>`,
  home: () => `<div class="sc home"><div class="grid">${'<i></i>'.repeat(9)}<span class="app"><span class="hl"><img src="icon-180.png" alt=""></span><small>Duo Mac</small></span>${'<i></i>'.repeat(6)}</div><div class="dock"><i></i><i></i><i></i><i></i></div></div>`,
};

const glyph = (name) => `<span class="gl">${ICON[name]}</span>`;
const STEPS = {
  safari: [
    ['safariBar', `Tap ${glyph('menu')} in the address bar`],
    ['safariMenu', 'Tap <b>Share</b>'],
    ['shareSheet', 'Tap <b>View More</b>'],
    ['shareList', 'Tap <b>Add to Home Screen</b>'],
    ['addDialog', 'Tap <b>Add</b>'],
    ['home', 'Open <b>Duo Mac</b> from your Home Screen'],
  ],
  chrome: [
    ['chromeBar', `Tap ${glyph('share')} in the address bar`],
    ['shareSheet', 'Tap <b>View More</b>'],
    ['shareList', 'Tap <b>Add to Home Screen</b>'],
    ['addDialog', 'Tap <b>Add</b>'],
    ['home', 'Open <b>Duo Mac</b> from your Home Screen'],
  ],
};

/** Whether there's a step-by-step guide for this browser (otherwise: open it in Safari). */
export const hasGuide = browser in STEPS;

/** The way out, kept quiet: in a browser tab the bars take room, so the Mac can't fill the screen. */
const anyway = (label) => `<div class="ig-alt">
  <button type="button" class="here">${label}</button>
  <span>⚠︎ Not recommended: the browser’s bars cover part of the screen, so the Mac won’t fit properly.</span>
</div>`;

let el = null;
let timer = 0;

/** Show the guide over everything. `useHere` pairs in the browser instead. */
export function showInstall({ useHere }) {
  hideInstall();
  el = document.createElement('div');
  el.id = 'install';
  if (hasGuide) {
    const steps = STEPS[browser];
    el.innerHTML = `<div class="ig-wrap">
      <div class="ig-head"><b>Add Duo Mac to your Home Screen</b><span>It runs full screen there. You opened this in ${browserName}:</span></div>
      <div class="ig">
        <div class="ig-phone">${steps.map(([s], i) => `<div class="ig-scene" data-i="${i}">${SCENES[s]()}</div>`).join('')}</div>
        <ol class="ig-steps">${steps.map(([, t], i) => `<li><button type="button" data-i="${i}"><b>${i + 1}</b><span>${t}</span></button></li>`).join('')}</ol>
      </div>
      ${anyway(`Use it in ${browserName} anyway`)}
    </div>`;
  } else {
    el.innerHTML = `<div class="ig-wrap">
      <div class="ig-head"><b>Open this in Safari</b><span>Then add Duo Mac to your Home Screen from there. It runs full screen.</span></div>
      <div class="ig-acts"><button type="button" class="act primary safari">Open in Safari</button></div>
      ${anyway('Use it here anyway')}
    </div>`;
  }
  document.body.append(el);
  el.querySelector('.here').addEventListener('click', () => { hideInstall(); useHere(); });
  // iOS 17+ opens x-safari-https:// links in Safari.
  el.querySelector('.safari')?.addEventListener('click', () => { location.href = `x-safari-${location.href}`; });

  let cur = 0;
  const show = (i) => {
    cur = i;
    for (const n of el.querySelectorAll('[data-i]')) n.classList.toggle('on', +n.dataset.i === i);
  };
  const run = (delay) => {
    clearTimeout(timer);
    timer = setTimeout(() => { if (!el) return; show((cur + 1) % STEPS[browser].length); run(2600); }, delay);
  };
  if (hasGuide) {
    show(0);
    run(2600);
    el.querySelector('.ig-steps').addEventListener('click', (e) => {
      const b = e.target.closest('button[data-i]');
      if (!b) return;
      show(+b.dataset.i);
      run(6000); // give a tapped step time to be looked at
    });
  }
}

export function hideInstall() {
  clearTimeout(timer);
  el?.remove();
  el = null;
}
