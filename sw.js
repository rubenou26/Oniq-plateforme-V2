// ONIQ Hub — Service Worker
const CACHE = 'oniq-v1';
const STATIC = ['/'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(STATIC)));
  self.skipWaiting();
});

self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys =>
    Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))
  ));
  self.clients.claim();
});

self.addEventListener('fetch', e => {
  // Réseau en priorité, cache en fallback
  e.respondWith(
    fetch(e.request).catch(() => caches.match(e.request))
  );
});
