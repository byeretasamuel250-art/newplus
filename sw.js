// ============================================================
// newplus service worker — handles incoming Web Push notifications
// and opens/focuses the app when one is tapped. Nothing else: this
// app doesn't do offline caching, so there's no fetch handler here.
// ============================================================

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("push", (event) => {
  if (!event.data) return;
  let payload;
  try {
    payload = event.data.json();
  } catch (e) {
    payload = { title: "newplus", body: event.data.text() };
  }

  const title = payload.title || "newplus";
  const options = {
    body: payload.body || "",
    icon: payload.icon || "/icon-192.png",
    badge: payload.badge || "/icon-192.png",
    tag: payload.tag || undefined, // same tag replaces a still-visible notification instead of stacking
    data: { url: payload.url || "/" }
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const targetUrl = event.notification.data?.url || "/";

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        // Reuse an already-open tab rather than opening a new one, and
        // bring it to the front — that's the whole point of tapping a
        // notification instead of just reading it.
        if ("focus" in client) return client.focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
    })
  );
});
