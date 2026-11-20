/* ÁXIS: funciona sem internet depois da primeira abertura */
const VERSION = 'axis-v10';
const ASSETS = [
  './',
  './index.html',
  './manifest.webmanifest',
  './vendor/jspdf.umd.min.js',
  './vendor/supabase-2.118.0.js',
  './config.js',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon-maskable-512.png',
  './icons/apple-touch-icon.png',
  './icons/favicon-32.png',
  './fonts/cormorant-garamond-latin-500-normal.woff2',
  './fonts/cormorant-garamond-latin-600-normal.woff2',
  './fonts/jost-latin-400-normal.woff2',
  './fonts/jost-latin-500-normal.woff2',
  './fonts/jost-latin-600-normal.woff2'
];

self.addEventListener('install', event => {
  event.waitUntil(caches.open(VERSION).then(cache => cache.addAll(ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

const timeout = ms => new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), ms));

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // Página: tenta a versão nova (até 3 s, sinal fraco na academia) e cai para a guardada.
  if (req.mode === 'navigate') {
    event.respondWith(
      Promise.race([fetch(req), timeout(3000)])
        .then(res => {
          if (res && res.ok) { const copy = res.clone(); caches.open(VERSION).then(c => c.put('./index.html', copy)); }
          return res;
        })
        .catch(() => caches.match('./index.html').then(hit => hit || fetch(req)))
    );
    return;
  }

  // Arquivos fixos: do cache primeiro.
  event.respondWith(
    caches.match(req).then(hit => hit || fetch(req).then(res => {
      if (res && res.ok) { const copy = res.clone(); caches.open(VERSION).then(c => c.put(req, copy)); }
      return res;
    }))
  );
});

/* Aviso do descanso com o app em segundo plano */
let restGen = 0;
const ICON = './icons/icon-192.png';
async function closeTag(tag) {
  const list = await self.registration.getNotifications({ tag });
  list.forEach(n => n.close());
}
async function appVisible() {
  const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  return wins.some(w => w.visibilityState === 'visible');
}
self.addEventListener('message', event => {
  const d = event.data || {};
  if (d.type === 'rest-start') {
    const gen = ++restGen;
    const wait = Math.max(0, Math.min((d.end || 0) - Date.now(), 270000));
    event.waitUntil(new Promise(r => setTimeout(r, wait)).then(async () => {
      if (gen !== restGen || await appVisible()) return;
      await closeTag('rest-live');
      await self.registration.showNotification('Descanso acabou', {
        body: 'Hora da próxima série.', tag: 'rest-end', renotify: true,
        vibrate: [300, 120, 300, 120, 500], icon: ICON, badge: ICON, data: { url: './#treino' }
      });
    }));
  } else if (d.type === 'rest-cancel') {
    restGen++;
    event.waitUntil(closeTag('rest-live'));
  } else if (d.type === 'rest-bg') {
    event.waitUntil(self.registration.showNotification('Descanso em andamento', {
      body: d.body || 'Toque para voltar ao treino.', tag: 'rest-live', silent: true, icon: ICON, badge: ICON,
      timestamp: d.end || Date.now(), data: { url: './#treino' }
    }));
  } else if (d.type === 'rest-fg') {
    event.waitUntil(closeTag('rest-live').then(() => closeTag('rest-end')).then(() => closeTag('descanso')));
  }
});
/* Notificação enviada pelo servidor (fim do descanso, teste) */
self.addEventListener('push', event => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch (e) { d = { corpo: event.data ? event.data.text() : '' }; }
  event.waitUntil(closeTag('rest-live').then(() => self.registration.showNotification(d.titulo || 'ÁXIS', {
    body: d.corpo || '', tag: d.tag || 'descanso', renotify: true,
    vibrate: [300, 120, 300, 120, 500], icon: ICON, badge: ICON, data: { url: d.url || './#treino' }
  })));
});
self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const w of wins) { if ('focus' in w) return w.focus(); }
    return self.clients.openWindow((event.notification.data && event.notification.data.url) || './');
  })());
});
