// ============================================================
// newplus service worker
// Handles incoming Web Push messages: shows a notification and sets
// the app icon badge (Android/Chrome installed PWAs). Also caches chat
// photos and voice notes locally so they don't re-download every time
// the app is reopened — see MEDIA CACHE section below.
// ============================================================

const MEDIA_CACHE = "newplus-media-v1";

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    Promise.all([
      self.clients.claim(),
      // Drop any older/renamed media cache versions from a previous
      // deploy — keeps device storage from growing unbounded across
      // updates to the caching logic itself.
      caches.keys().then((keys) =>
        Promise.all(keys.filter((k) => k.startsWith("newplus-media-") && k !== MEDIA_CACHE).map((k) => caches.delete(k)))
      ),
    ])
  );
});

// ============================================================
// MEDIA CACHE: chat photos and voice notes are fetched through
// short-lived *signed* Supabase Storage URLs — a fresh, random token is
// appended every time one is requested, so the same file gets a
// different URL string on every login. That defeats the browser's
// normal HTTP cache, which keys on the full URL including the query
// string, so the same photo/voice note ends up re-downloaded every
// time the app is reopened.
//
// This intercepts those storage requests, strips the rotating token to
// get a stable key (the file's path), and caches the actual bytes under
// that key instead. A file already downloaded once is then served from
// the device from then on — only genuinely new messages hit the network.
//
// Caching forever is safe here: every upload in the app writes to a
// brand-new, timestamped path each time (see index.html), so a given
// path's content never changes after it's written — there's no "the
// file at this path was replaced" case to invalidate against. Avatars
// use stable public URLs (no token) and are matched/cached the same way
// for consistency, though the browser's own HTTP cache already covers
// those reasonably well on its own.
// ============================================================
const CACHEABLE_STORAGE = /\/storage\/v1\/object\/(public|sign)\/(chat-images|voice-notes|avatars|statuses)\//;

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  let url;
  try { url = new URL(req.url); } catch (e) { return; }
  if (!CACHEABLE_STORAGE.test(url.pathname)) return;

  // Cache key omits the query string (the rotating ?token=...) so a
  // freshly re-signed URL for a file we already have still hits cache.
  const cacheKey = new Request(url.origin + url.pathname, { method: "GET" });

  event.respondWith(
    caches.open(MEDIA_CACHE).then(async (cache) => {
      const cached = await cache.match(cacheKey);
      if (cached) return cached;
      const response = await fetch(req);
      // Photos load via `<img>`/`new Image()` without a crossOrigin flag,
      // which makes this a no-cors request — the response comes back
      // "opaque" (status always reads as 0/not-ok even on success, by
      // design, since JS isn't allowed to inspect a cross-origin no-cors
      // response). Cache it anyway: this is the standard pattern for
      // caching cross-origin images behind a service worker, and the
      // browser would have shown the image successfully either way — we
      // just don't get to distinguish success from failure from here.
      // Voice notes go through an explicit fetch() (cors mode) instead,
      // so those get a normal readable status and only cache on a real
      // 2xx via response.ok.
      if (response && (response.ok || response.type === "opaque")) cache.put(cacheKey, response.clone());
      return response;
    }).catch(() => fetch(req)) // cache API unavailable for some reason — fall back to a normal network fetch rather than breaking the request
  );
});

self.addEventListener("push", (event) => {
  let data = { title: "newplus", body: "You have a new notification", badge: 0, url: "/" };
  try {
    if (event.data) data = { ...data, ...event.data.json() };
  } catch (e) {
    // If the payload isn't JSON for some reason, fall back to the defaults above.
  }

  // Set (or clear) the badge count on the app icon. Supported on
  // Android/Chrome for installed PWAs; silently does nothing where
  // unsupported (e.g. iOS), which is fine — it just won't show there.
  const badgePromise = (async () => {
    try {
      if (data.badge > 0 && "setAppBadge" in self.registration) {
        await self.registration.setAppBadge(data.badge);
      } else if ("clearAppBadge" in self.registration) {
        await self.registration.clearAppBadge();
      }
    } catch (e) {
      // Badging API not supported on this platform — ignore.
    }
  })();

  const notifyPromise = self.registration.showNotification(data.title, {
    body: data.body,
    icon: "/icon-192.png",
    badge: "/icon-192.png",
    data: { url: data.url || "/" },
  });

  event.waitUntil(Promise.all([badgePromise, notifyPromise]));
});

// Tapping the notification opens (or focuses) the app.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const targetUrl = event.notification.data?.url || "/";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if ("focus" in client) return client.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
    })
  );
});
