// Keeps a copy of the app on the phone, and opens it from there at once: no waiting for the Mac or for
// Tailscale before anything shows (the connection comes up behind it). The Mac says which version it
// serves (js/main.js checkVersion); when it's newer, the page asks for an update here: the new files
// all come down into a fresh copy, which replaces the old one in one go, and the page reloads.
// Copies are named by version; the newest complete one is used.
const PREFIX = 'duo-mac-';
const DONE = '/__complete__';
// Never from the copy: the connection, the version list, and the files only an unlocked phone may get.
const LIVE = ['/ws', '/build.json', '/mac-picture.png', '/duo-mac-local.mobileconfig', '/downloads/', '/healthz'];

/** The copy in use: the newest complete one (by the time it was made). */
async function current() {
  let best = null, at = -1;
  for (const name of await caches.keys()) {
    if (!name.startsWith(PREFIX)) continue;
    const c = await caches.open(name);
    const done = await c.match(DONE);
    if (!done) continue;
    const t = +(await done.text()) || 0;
    if (t > at) { at = t; best = c; }
  }
  return best;
}

/** Downloads every file of the Mac's version into a new copy, then drops the others. */
async function update() {
  const res = await fetch('build.json', { cache: 'no-store' });
  if (!res.ok) throw new Error(`build.json: ${res.status}`);
  const { build, files } = await res.json();
  const name = PREFIX + build;
  const c = await caches.open(name);
  await Promise.all(['./', ...files].map(async (f) => {
    const r = await fetch(f, { cache: 'no-store' });
    if (!r.ok) throw new Error(`${f}: ${r.status}`);
    await c.put(f === './' ? './' : f, r);
  }));
  await c.put(DONE, new Response(String(Date.now())));
  for (const n of await caches.keys()) if (n.startsWith(PREFIX) && n !== name) await caches.delete(n);
  return build;
}

self.addEventListener('install', (e) => {
  e.waitUntil(update().catch(() => {}).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => e.waitUntil((async () => {
  await caches.delete('duo-mac-v1'); // the copy the earlier, network-first version kept
  await self.clients.claim();
})()));

// The page, each time it connects: "the Mac serves <build>". The copy is brought up to it if it isn't
// already (also the first time, when there's none yet), and the page hears back when it's ready.
self.addEventListener('message', (e) => {
  if (e.data?.t !== 'update') return;
  e.waitUntil((async () => {
    const want = e.data.build;
    if (want && (await caches.keys()).includes(PREFIX + want) && await (await caches.open(PREFIX + want)).match(DONE)) {
      return e.source?.postMessage({ t: 'updated', build: want });
    }
    const build = await update();
    e.source?.postMessage({ t: 'updated', build });
  })().catch((err) => e.source?.postMessage({ t: 'update-failed', msg: String(err?.message || err) })));
});

self.addEventListener('fetch', (e) => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== 'GET' || url.origin !== location.origin || LIVE.some((p) => url.pathname.startsWith(p))) return;
  e.respondWith((async () => {
    const c = await current();
    const hit = c && (await c.match(req, { ignoreSearch: true })
      || (req.mode === 'navigate' && await c.match('./')));
    if (hit) return hit;
    // Not in the copy (the first visit, or a file it doesn't have): the network, kept for next time.
    try {
      const res = await fetch(req);
      if (res.ok && c) c.put(req, res.clone()).catch(() => {});
      return res;
    } catch (err) {
      const any = c && await c.match('./');
      if (any && req.mode === 'navigate') return any;
      throw err;
    }
  })());
});
