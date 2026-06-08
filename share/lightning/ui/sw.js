// Lightning wallet PWA service worker (FEAT-346 offline app shell +
// FEAT-347 web-push wake).  Same-origin only — like app.js it carries no
// absolute http(s):// URL; everything is relative to the SW scope so the
// "if you loaded the PWA you trust the origin behind it" stance holds.
//
// Strategy:
//   • app shell (html/js/css/manifest/icon)  → cache-first, refreshed in
//     the background (stale-while-revalidate) so updates land next load.
//   • config.json                            → network-first (operator
//     edits must propagate) falling back to cache when offline.
//   • the account API (/.well-known/…)        → network-only, NEVER cached:
//     balances and auth must always be fresh and must not linger on disk.
//   • navigations                            → network-first, falling back
//     to the cached app shell so deep links work offline.

const CACHE = "lightning-shell-v1";

// Relative to the SW scope (e.g. /lightning/).  index.html doubles as the
// offline navigation fallback (the SPA shell).
const SHELL = [
  "./",
  "index.html",
  "app.js",
  "style.css",
  "manifest.webmanifest",
  "icon.svg",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
      )
      .then(() => self.clients.claim())
  );
});

// Is this request for the account API?  Such responses are per-account,
// bearer-authed and money-sensitive: never serve them from or write them
// to the cache.
function isApi(url) {
  return url.pathname.includes("/.well-known/");
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return; // only GETs are cacheable
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return; // same-origin only
  if (isApi(url)) return; // network-only; let it hit the network untouched

  // Navigations: try the network, fall back to the cached shell offline.
  if (req.mode === "navigate") {
    event.respondWith(
      fetch(req).catch(() => caches.match("index.html", { ignoreSearch: true }))
    );
    return;
  }

  // config.json: network-first so operator edits take effect.
  if (url.pathname.endsWith("/config.json") || url.pathname.endsWith("config.json")) {
    event.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copy));
          return res;
        })
        .catch(() => caches.match(req))
    );
    return;
  }

  // Everything else (shell assets): cache-first, refresh in the background.
  event.respondWith(
    caches.match(req).then((hit) => {
      const network = fetch(req)
        .then((res) => {
          if (res && res.ok) {
            const copy = res.clone();
            caches.open(CACHE).then((c) => c.put(req, copy));
          }
          return res;
        })
        .catch(() => hit);
      return hit || network;
    })
  );
});

// ---- web push (FEAT-347) ------------------------------------------------
// Groundwork for a push-to-sign wake: the configured API server can
// nudge the device to come fetch a pending signing request.  The payload
// is advisory only — the app re-authenticates and fetches the real
// request when opened; nothing sensitive rides in the notification.

self.addEventListener("push", (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (_) {
    data = { body: event.data ? event.data.text() : "" };
  }
  const title = data.title || "Lightning";
  const options = {
    body: data.body || "You have a pending request.",
    icon: "icon.svg",
    badge: "icon.svg",
    tag: data.tag || "lightning-push",
    data: { url: data.url || "./" },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || "./";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((wins) => {
      for (const w of wins) {
        if ("focus" in w) return w.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow(target);
    })
  );
});
