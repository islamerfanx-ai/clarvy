// The Decision Rooms app in the browser: pages still open without a connection (the last copy), and phone
// notifications arrive even when the app is closed. Pages always come from the network first, so a deploy
// shows straight away; nothing from /api/ or Supabase is ever stored here.
const CACHE = "dr-app-v1";
const SHELL = ["/dashboard.html", "/room.html", "/rooms/rooms.js", "/rooms/rooms.css", "/i18n/en.json", "/i18n/ar.json", "/app/icon-192.png"];

self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).catch(() => {}));
  self.skipWaiting();
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", e => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== location.origin || url.pathname.startsWith("/api/")) return;
  e.respondWith(fetch(req).then(res => {
    if (res.ok && res.type === "basic") { const copy = res.clone(); caches.open(CACHE).then(c => c.put(req, copy)).catch(() => {}); }
    return res;
  }).catch(async () => (await caches.match(req)) || (req.mode === "navigate" && await caches.match(url.pathname, { ignoreSearch: true })) || Response.error()));
});

self.addEventListener("push", e => {
  let m = {};
  try { m = e.data ? e.data.json() : {}; } catch { m = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(m.title || "Decision Rooms", {
    body: m.body || "", tag: m.tag || undefined, renotify: !!m.tag, lang: m.lang || "en", dir: m.lang === "ar" ? "rtl" : "ltr",
    icon: "/app/icon-192.png", badge: "/app/badge-96.png", data: { url: m.url || "/dashboard.html" }
  }));
});
self.addEventListener("notificationclick", e => {
  e.notification.close();
  const url = new URL(e.notification.data?.url || "/dashboard.html", location.origin).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(async list => {
    const open = list.find(c => new URL(c.url).origin === location.origin);
    if (open) { await open.focus(); return open.navigate(url).catch(() => self.clients.openWindow(url)); }
    return self.clients.openWindow(url);
  }));
});
