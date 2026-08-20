// ============================================================
// newplus service worker
// Handles incoming Web Push messages: shows a notification and sets
// the app icon badge (Android/Chrome installed PWAs). Also caches
// already-downloaded chat photos, voice notes, and status/post photos
// (see below) so they open instantly instead of re-downloading every
// time you open a chat or view a status.
// ============================================================

const MEDIA_CACHE = "newplus-media-v2";

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    (async () => {
      // Remove any older, now-unused version of the media cache (e.g. the
      // one from before this fix) instead of leaving it taking up space
      // forever.
      const names = await caches.keys();
      await Promise.all(
        names.filter((n) => n.startsWith("newplus-media-") && n !== MEDIA_CACHE)
          .map((n) => caches.delete(n))
      );
      await self.clients.claim();
    })()
  );
});

// ------------------------------------------------------------
// Chat photos, voice notes, and status/post photos are private files,
// so the app has to ask Supabase for a fresh "signed" download link
// every time it shows them — that link includes a one-time security
// code that's different every time, even for the exact same file.
// Without help, the browser sees each new link as a brand-new file and
// re-downloads it from scratch, every single time you open a chat,
// view a status, or log back in.
//
// Profile pictures use a plain, unchanging link instead, so they don't
// have that same problem — but we cache them here too anyway, so they
// come from the saved copy instantly rather than depending on the
// browser's own, less predictable caching.
//
// This fixes both: it looks only at the FILE'S OWN PATH inside the
// link (ignoring the one-time security code part, for private media),
// and if it's already downloaded that exact file before, it hands back
// the saved copy instantly instead of downloading it again. A file
// you've never opened before still downloads normally the first time —
// only repeat opens of the same photo/voice note/status/profile
// picture are skipped, matching how WhatsApp only downloads what's
// actually new.
//
// Status photos can expire (24h) or get deleted by their owner — that's
// fine here, since caching only ever saves a copy of something this
// device already viewed while it was visible; it doesn't extend
// anyone's access beyond what they already had.
// ------------------------------------------------------------
self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);
  const isPrivateMedia =
    url.pathname.includes("/storage/v1/object/sign/chat-images/") ||
    url.pathname.includes("/storage/v1/object/sign/voice-notes/") ||
    url.pathname.includes("/storage/v1/object/sign/statuses/");
  const isAvatar = url.pathname.includes("/storage/v1/object/public/avatars/");
  if (!isPrivateMedia && !isAvatar) return;

  // Cache key = the file's own path, WITHOUT the one-time security code
  // (that's in the query string) — so the same photo is recognized as
  // "already have this" no matter how many different signed links
  // point to it over time. Profile pictures have no such code, but
  // stripping the query string is harmless and keeps this one rule
  // working the same way for both.
  //
  // A photo shown normally in the chat and the same photo being
  // explicitly downloaded via the "Save image" button ask for the file
  // in two technically different ways — one where the browser hides
  // the result from view, one where the app needs to actually read it.
  // They must never share a saved copy, or the save/download button can
  // end up handed a copy it can't read, which shows as "Failed to
  // fetch" even though the photo loaded and displayed just fine.
  const cacheKey = url.origin + url.pathname + "?__variant=" + (req.mode === "no-cors" ? "display" : "download");

  event.respondWith(
    (async () => {
      try {
        const cache = await caches.open(MEDIA_CACHE);
        const cached = await cache.match(cacheKey);
        if (cached) return cached;

        const response = await fetch(req);
        // Chat photos load through a plain <img> tag, which the browser
        // sends as a special cross-site request that deliberately hides
        // the real success/fail status from any code watching, including
        // this service worker ("opaque" response) — so photos need to be
        // cached even though we can't directly confirm they succeeded.
        // Voice notes use a normal fetch() instead, so those still only
        // get cached once we've confirmed they actually succeeded.
        try {
          if (response.ok || response.type === "opaque") {
            await cache.put(cacheKey, response.clone());
          }
        } catch (saveErr) {
          // Some phones/browsers (e.g. Private/Incognito mode, some
          // in-app browsers) don't allow saving files for later reuse.
          // That's fine — the photo/voice note still loaded just now,
          // it just won't be instant on the next visit. Never let a
          // saving problem take away a photo that already loaded fine.
        }
        return response;
      } catch (err) {
        // Something about the "remember this file" feature itself isn't
        // available on this phone/browser right now — fall back to a
        // completely plain, normal download instead, exactly as if this
        // feature didn't exist. This guarantees a hiccup in caching can
        // never turn into a "failed to load" error for a real photo.
        return fetch(req);
      }
    })()
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
