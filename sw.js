// ============================================================
// newplus service worker
// Handles incoming Web Push messages: shows a notification and sets
// the app icon badge (Android/Chrome installed PWAs). No offline
// caching is done here — this only exists for push + badge support.
// ============================================================

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
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
