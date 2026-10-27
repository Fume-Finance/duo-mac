// Keeps a copy of the app on the phone, so it opens even when the Mac's Tailscale address can't be
// reached (no internet, abroad): then it finds the Mac on the same Wi-Fi or hotspot (local mode,
// js/net.js). Always the network first, so an update is never held back; the copy only when
// that fails.
const CACHE = 'duo-mac-v1';
const SHELL = ['./', 'index.html', 'app.css', 'manifest.webmanifest', 'icon-180.png', 'icon-512.png',
  'js/main.js', 'js/net.js', 'js/screen.js', 'js/keyboard.js', 'js/trackpad.js', 'js/sheet.js', 'js/settings.js',
  'js/auth.js', 'js/sound.js', 'js/haptics.js', 'js/install.js', 'js/mic.js', 'js/mic-worklet.js',
  'js/speaker.js', 'js/speaker-worklet.js', 'js/cursor.js'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).catch(() => {}).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()));

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET' || new URL(req.url).origin !== location.origin || req.url.includes('/ws')) return;
  e.respondWith(fetch(req).then((res) => {
    if (res.ok) {
      const copy = res.clone();
      caches.open(CACHE).then((c) => c.put(req, copy)).catch(() => {});
    }
    return res;
  }).catch(() => caches.match(req, { ignoreSearch: true }).then((hit) => hit || caches.match('index.html'))));
});
