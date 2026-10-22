// Wasla's desktop notifications (Web Push). Registered by the app with its
// own scope (push/), apart from the page, so the browser keeps it.
//
// The push function sends {title, body, tag, data, locale}, encrypted for
// this browser. While the app is open in front, it shows the news itself.

'use strict';

// Where the app is: the folder this file is served from.
const appUrl = new URL('./', self.location).href;

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

async function appWindows() {
  const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
  return all.filter((c) => c.url.startsWith(appUrl));
}

self.addEventListener('push', (event) => {
  let n = {};
  try {
    n = event.data ? event.data.json() : {};
  } catch (_) {
    // Not ours to read; say something rather than nothing.
  }
  event.waitUntil((async () => {
    const windows = await appWindows();
    if (windows.some((c) => c.focused && c.visibilityState === 'visible')) return;
    const ar = n.locale !== 'en';
    await self.registration.showNotification(n.title || (ar ? 'وصلة' : 'Wasla'), {
      body: n.body || '',
      tag: n.tag,
      // A new message in the same chat replaces the last one, and still rings.
      renotify: Boolean(n.tag),
      data: n.data || {},
      lang: ar ? 'ar' : 'en',
      dir: 'auto',
      icon: appUrl + 'icons/Icon-192.png',
      badge: appUrl + 'icons/Icon-192.png',
    });
  })());
});

// Opens what the notification is about: in the app's open window, or in a
// new one that opens it once it starts.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const data = event.notification.data || {};
  event.waitUntil((async () => {
    const windows = await appWindows();
    const app = windows.find((c) => c.focused) || windows[0];
    if (app) {
      await app.focus();
      app.postMessage({ waslaPush: data });
      return;
    }
    const url = new URL(appUrl);
    url.searchParams.set('push', JSON.stringify(data));
    await self.clients.openWindow(url.href);
  })());
});
