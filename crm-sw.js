/* ONIQ Pilotage — service worker.
   Deux rôles seulement : permettre l'installation sur l'écran d'accueil,
   et afficher les notifications poussées de l'espace partenaire. Aucun
   cache des données : le CRM lit toujours la base en direct. */
self.addEventListener('install', function(e){ self.skipWaiting(); });
self.addEventListener('activate', function(e){ e.waitUntil(self.clients.claim()); });
self.addEventListener('fetch', function(){ /* réseau direct */ });

self.addEventListener('push', function(e){
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { corps: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.titre || 'ONIQ Pilotage', {
    body: d.corps || '',
    icon: 'crm-icone-192.png',
    badge: 'crm-icone-192.png',
    tag: d.tag || 'oniq',
    data: { url: d.url || '/crm' }
  }));
});

self.addEventListener('notificationclick', function(e){
  e.notification.close();
  var url = (e.notification.data && e.notification.data.url) || '/crm';
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(l){
    for (var i = 0; i < l.length; i++) { if ('focus' in l[i]) { l[i].navigate(url); return l[i].focus(); } }
    return self.clients.openWindow(url);
  }));
});
