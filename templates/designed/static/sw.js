// Service Worker for Rocket Blog PWA
const CACHE_NAME = 'rocket-blog-pwa-v1';
const urlsToCache = [
  '/',
  '/static/style.css',
  '/static/worktime.css',
  '/static/manifest.json',
  '/static/icon-192x192.png',
  '/static/icon-512x512.png',
  '/static/icon-96x96.png',
  '/static/icon-180x180.png',
  // Add offline fallback page
  '/offline'
];

// Install event - cache resources
self.addEventListener('install', event => {
  console.log('Service Worker: Installing...');
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => {
        console.log('Service Worker: Caching files');
        return cache.addAll(urlsToCache);
      })
      .catch(err => console.log('Service Worker: Cache failed', err))
  );
});

// Activate event - clean up old caches
self.addEventListener('activate', event => {
  console.log('Service Worker: Activating...');
  event.waitUntil(
    caches.keys().then(cacheNames => {
      return Promise.all(
        cacheNames.map(cacheName => {
          if (cacheName !== CACHE_NAME) {
            console.log('Service Worker: Deleting old cache', cacheName);
            return caches.delete(cacheName);
          }
        })
      );
    })
  );
});

// Fetch event - serve from cache when offline
self.addEventListener('fetch', event => {
  // Skip non-GET requests
  if (event.request.method !== 'GET') {
    return;
  }

  // Skip Chrome extension requests
  if (event.request.url.startsWith('chrome-extension://')) {
    return;
  }

  event.respondWith(
    caches.match(event.request)
      .then(response => {
        // Return cached version or fetch from network
        if (response) {
          console.log('Service Worker: Serving from cache', event.request.url);
          return response;
        }

        console.log('Service Worker: Fetching from network', event.request.url);
        return fetch(event.request).then(response => {
          // Check if response is valid
          if (!response || response.status !== 200 || response.type !== 'basic') {
            return response;
          }

          // Clone the response for caching
          const responseToCache = response.clone();

          // Cache the response for future use (for worktime app URLs)
          if (event.request.url.includes('/entries') || 
              event.request.url.includes('/roles') ||
              event.request.url.includes('/settings') ||
              event.request.url.includes('/static/')) {
            caches.open(CACHE_NAME)
              .then(cache => {
                cache.put(event.request, responseToCache);
              });
          }

          return response;
        }).catch(() => {
          // If network fails, try to serve offline page
          if (event.request.destination === 'document') {
            return caches.match('/offline');
          }
        });
      })
  );
});

// Background sync for when connectivity returns
self.addEventListener('sync', event => {
  console.log('Service Worker: Background sync', event.tag);
  
  if (event.tag === 'time-tracking-sync') {
    event.waitUntil(syncTimeEntries());
  }
});

// Sync pending time entries when connectivity returns
async function syncTimeEntries() {
  try {
    // Get pending entries from IndexedDB (would need to implement this)
    console.log('Service Worker: Syncing time entries...');
    
    // This would sync any offline time entries when connection is restored
    // Implementation would depend on storing entries locally in IndexedDB
    
  } catch (error) {
    console.error('Service Worker: Sync failed', error);
  }
}

// Push notification support (for time tracking reminders)
self.addEventListener('push', event => {
  const options = {
    body: event.data ? event.data.text() : 'Time tracking reminder',
    icon: '/static/icon-192x192.png',
    badge: '/static/icon-96x96.png',
    vibrate: [100, 50, 100],
    data: {
      dateOfArrival: Date.now(),
      primaryKey: 1
    },
    actions: [
      {
        action: 'start-timer',
        title: 'Start Timer',
        icon: '/static/icon-play.png'
      },
      {
        action: 'view-dashboard',
        title: 'View Dashboard',
        icon: '/static/icon-dashboard.png'
      }
    ]
  };

  event.waitUntil(
    self.registration.showNotification('Work Time Tracker', options)
  );
});

// Handle notification clicks
self.addEventListener('notificationclick', event => {
  event.notification.close();

  const action = event.action;
  
  if (action === 'start-timer') {
    event.waitUntil(
      clients.openWindow('/?action=start')
    );
  } else if (action === 'view-dashboard') {
    event.waitUntil(
      clients.openWindow('/')
    );
  } else {
    // Default action - open the app
    event.waitUntil(
      clients.openWindow('/')
    );
  }
});

// Handle messages from the main app
self.addEventListener('message', event => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
});