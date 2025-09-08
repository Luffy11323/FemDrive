// api/index.js
const fs = require('fs');
const path = require('path');
const express = require('express');
const cors = require('cors');
const admin = require('firebase-admin');
const { encode: geohashEncode, neighbors: geohashNeighbors } = require('ngeohash');
const haversine = require('haversine-distance');

//
// ──────────────────────────────────────────────────────────────────────────
//  Firebase Admin initialization (supports env base64, ADC, or local file)
// ──────────────────────────────────────────────────────────────────────────
let adminCred;
if (process.env.SERVICE_ACCOUNT_BASE64) {
  try {
    const json = Buffer.from(process.env.SERVICE_ACCOUNT_BASE64, 'base64').toString('utf8');
    adminCred = admin.credential.cert(JSON.parse(json));
    console.log('Using service account from SERVICE_ACCOUNT_BASE64');
  } catch (err) {
    console.error('Failed to parse SERVICE_ACCOUNT_BASE64:', err);
    adminCred = admin.credential.applicationDefault();
  }
} else if (process.env.GOOGLE_APPLICATION_CREDENTIALS) {
  // Use ADC (recommended on GCP)
  adminCred = admin.credential.applicationDefault();
  console.log('Using application default credentials (GOOGLE_APPLICATION_CREDENTIALS)');
} else {
  // Fallback to local file (dev); do NOT commit this file
  const localPath = path.join(__dirname, 'serviceAccountKey.json');
  if (fs.existsSync(localPath)) {
    adminCred = admin.credential.cert(require(localPath));
    console.log('Using local serviceAccountKey.json (dev)');
  } else {
    console.warn('No service account found. Falling back to applicationDefault()');
    adminCred = admin.credential.applicationDefault();
  }
}

// ensure you set a DB url via env in production
const databaseURL = process.env.FIREBASE_DATABASE_URL || 'https://<PROJECT_ID>.firebaseio.com';

admin.initializeApp({
  credential: adminCred,
  databaseURL,
});

const db = admin.firestore();
const rtdb = admin.database().ref();
const fcm = admin.messaging();

//
// ──────────────────────────────────────────────────────────────────────────
//  Shared Paths & Fields
// ──────────────────────────────────────────────────────────────────────────
const AppPaths = {
  driversOnline: 'drivers_online',
  ridesPendingA: 'rides_pending',
  ridesPendingB: 'rideRequests',
  ridesCollection: 'rides',
  ratingsCollection: 'ratings',
  locationsCollection: 'locations',
  driverLocations: 'driverLocations',
  notifications: 'notifications',
  messages: 'messages',
  driverNotifications: 'driver_notifications',
  ridesLive: 'ridesLive',
  adminAlerts: 'admin_alerts',
};

const AppFields = {
  uid: 'uid',
  lat: 'lat',
  lng: 'lng',
  geohash: 'geohash',
  updatedAt: 'updatedAt',
  status: 'status',
  fare: 'fare',
  driverId: 'driverId',
  riderId: 'riderId',
  pickup: 'pickup',
  dropoff: 'dropoff',
  pickupLat: 'pickupLat',
  pickupLng: 'pickupLng',
  dropoffLat: 'dropoffLat',
  dropoffLng: 'dropoffLng',
  driverLat: 'driverLat',
  driverLng: 'driverLng',
  riderLat: 'riderLat',
  riderLng: 'riderLng',
  acceptedAt: 'acceptedAt',
  arrivingAt: 'arrivingAt',
  startedAt: 'startedAt',
  completedAt: 'completedAt',
  cancelledAt: 'cancelledAt',
  rating: 'rating',
  comment: 'comment',
  verified: 'verified',
  username: 'username',
  phone: 'phone',
  fcmToken: 'fcmToken',
  senderId: 'senderId',
  text: 'text',
  timestamp: 'timestamp',
  type: 'type',
  emergencyTriggered: 'emergencyTriggered',
  paymentStatus: 'paymentStatus',
  finalFare: 'finalFare',
  rideId: 'rideId',
  reportedBy: 'reportedBy',
  otherUid: 'otherUid',
  etaSecs: 'etaSecs',
};

const RideStatus = {
  pending: 'pending',
  searching: 'searching',
  accepted: 'accepted',
  driverArrived: 'driver_arrived',
  inProgress: 'in_progress',
  onTrip: 'onTrip',
  completed: 'completed',
  cancelled: 'cancelled',
};

const StatusTitles = {
  accepted: { title: 'Ride Accepted', body: 'Your driver has accepted your ride.' },
  driver_arrived: { title: 'Driver Arrived', body: 'Your driver has arrived.' },
  in_progress: { title: 'Ride Started', body: 'Your ride has begun.' },
  completed: { title: 'Ride Completed', body: 'Thanks for riding with FemDrive!' },
  cancelled: { title: 'Ride Cancelled', body: 'This ride has been cancelled.' },
  no_drivers: { title: 'No Drivers Available', body: 'Sorry, no drivers are currently available.' },
};

const OFFER_TTL_MS = 60 * 1000;
const DRIVER_STALE_MS = 12 * 60 * 60 * 1000;

//
// ──────────────────────────────────────────────────────────────────────────
//  Express app
// ──────────────────────────────────────────────────────────────────────────
const app = express();
app.use(cors());
app.use(express.json());

// Health
app.get('/health', (_req, res) => res.json({ ok: true }));

//
// ──────────────────────────────────────────────────────────────────────────
//  Helpers
// ──────────────────────────────────────────────────────────────────────────
async function getAdminTokens() {
  const tokens = [];
  try {
    const qs = await db.collection('users').where('role', '==', 'admin').get();
    qs.forEach(d => {
      const tok = d.data()?.[AppFields.fcmToken];
      if (tok) tokens.push(tok);
    });
  } catch (err) {
    console.error('getAdminTokens error', err);
  }
  return tokens;
}

/**
 * Send FCM to a single user token pulled from Firestore users/{uid}.fcmToken
 * androidSound - raw resource name (without extension) e.g. 'ride_incoming_15s'
 * iosSound - bundle filename e.g. 'ride_incoming_15s.wav'
 */
async function fcmToUser(uid, payload = {}, { androidSound, iosSound, androidChannelId } = {}) {
  try {
    const snap = await db.collection('users').doc(uid).get();
    const token = snap.data()?.[AppFields.fcmToken];
    if (!token) return false;

    const message = {
      token,
      notification: payload.notification || undefined,
      data: payload.data || undefined,
      android: {
        priority: 'high',
        notification: {
          channelId: androidChannelId || 'ride_incoming_ch',
          sound: androidSound || undefined,
        },
      },
      apns: {
        payload: {
          aps: {
            sound: iosSound || undefined,
            contentAvailable: 1,
          },
        },
        headers: { 'apns-priority': '10' },
      },
    };

    // Remove undefined nested fields to avoid API warnings
    if (!message.notification) delete message.notification;
    if (!message.data) delete message.data;
    if (!androidSound && !androidChannelId) delete message.android.notification.sound;
    await fcm.send(message);
    return true;
  } catch (err) {
    console.error('fcmToUser error', err);
    return false;
  }
}

async function seedRidesLiveIfMissing(rideId) {
  const node = rtdb.child(`${AppPaths.ridesLive}/${rideId}`);
  const snap = await node.get();
  if (!snap.exists()) {
    await node.set({
      [AppFields.status]: RideStatus.pending,
      updatedAt: admin.database.ServerValue.TIMESTAMP,
    });
  }
}

function asNum(v) {
  if (typeof v === 'number') return v;
  if (typeof v === 'string') {
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

//
// ──────────────────────────────────────────────────────────────────────────
//  Routes
// ──────────────────────────────────────────────────────────────────────────

// 0) Ride creation hook
app.post('/rides/init', async (req, res) => {
  const { rideId } = req.body;
  if (!rideId) return res.status(400).json({ error: 'rideId required' });
  try {
    await seedRidesLiveIfMissing(rideId);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 1) Notify rider of a status change
app.post('/notify/status', async (req, res) => {
  const { riderId, status, rideId } = req.body;
  if (!riderId || !status || !rideId || !StatusTitles[status]) {
    return res.status(400).json({ error: 'Invalid params' });
  }
  try {
    await fcmToUser(riderId, {
      notification: StatusTitles[status],
      data: { status, rideId },
    }, { androidSound: undefined, iosSound: undefined });
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 2) Pair / broadcast offers to nearby drivers
app.post('/pair/ride', async (req, res) => {
  const { rideId, pickupLat, pickupLng } = req.body;
  const pLat = asNum(pickupLat), pLng = asNum(pickupLng);
  if (!rideId || pLat == null || pLng == null) {
    return res.status(400).json({ error: 'Missing rideId/pickupLat/pickupLng' });
  }

  try {
    await seedRidesLiveIfMissing(rideId);

    const rideDoc = await db.collection(AppPaths.ridesCollection).doc(rideId).get();
    const r = rideDoc.data() || {};
    const payloadBase = {
      [AppFields.pickup]: r[AppFields.pickup] ?? '',
      [AppFields.dropoff]: r[AppFields.dropoff] ?? '',
      [AppFields.dropoffLat]: r[AppFields.dropoffLat] ?? 0,
      [AppFields.dropoffLng]: r[AppFields.dropoffLng] ?? 0,
      [AppFields.fare]: r[AppFields.fare] ?? 0,
    };

    const hash = geohashEncode(pLat, pLng, 9);
    const hashes = [...geohashNeighbors(hash), hash];

    const candidates = [];
    for (const h of hashes) {
      const snap = await rtdb
        .child(AppPaths.driversOnline)
        .orderByChild(AppFields.geohash)
        .startAt(h)
        .endAt(`${h}\uf8ff`)
        .get();

      snap.forEach((c) => {
        const v = c.val() || {};
        if (v?.uid && typeof v.lat === 'number' && typeof v.lng === 'number') {
          candidates.push({ uid: v.uid, lat: v.lat, lng: v.lng });
        }
      });
    }

    if (!candidates.length) {
      await db.collection(AppPaths.ridesCollection).doc(rideId).set(
        { [AppFields.status]: 'no_drivers' },
        { merge: true },
      );
      await rtdb.child(`${AppPaths.ridesLive}/${rideId}`).update({
        [AppFields.status]: 'no_drivers',
        updatedAt: admin.database.ServerValue.TIMESTAMP,
      });
      return res.json({ ok: true, targeted: 0 });
    }

    candidates.sort(
      (a, b) =>
        haversine({ lat: a.lat, lon: a.lng }, { lat: pLat, lon: pLng }) -
        haversine({ lat: b.lat, lon: b.lng }, { lat: pLat, lon: pLng }),
    );

    const nowTS = admin.database.ServerValue.TIMESTAMP;
    const updates = {};
    for (const d of candidates) {
      updates[`${AppPaths.driverNotifications}/${d.uid}/${rideId}`] = {
        ...payloadBase,
        [AppFields.pickupLat]: pLat,
        [AppFields.pickupLng]: pLng,
        [AppFields.timestamp]: nowTS,
      };
    }
    await rtdb.update(updates);

    // 🔊 Send FCM (with sound) to top N drivers
    const topN = Math.min(10, candidates.length);
    let fcmCount = 0;
    for (let i = 0; i < topN; i++) {
      const lat = pLat.toFixed(4);
      const lng = pLng.toFixed(4);
      const ok = await fcmToUser(candidates[i].uid, {
        notification: {
          title: 'Ride Request Nearby',
          body: `Pickup near ${lat}, ${lng}`,
        },
        data: { rideId, action: 'NEW_REQUEST' },
      }, {
        androidSound: 'ride_incoming_15s',
        iosSound: 'ride_incoming_15s.wav',
        androidChannelId: 'ride_incoming_ch',
      });
      if (ok) fcmCount++;
    }

    res.json({ ok: true, targeted: candidates.length, fcm: fcmCount });
  } catch (e) {
    console.error('pair/ride error', e);
    res.status(500).json({ error: e.message });
  }
});

// 3) Driver accept (race-protected)
app.post('/accept/driver', async (req, res) => {
  const { rideId, driverUid } = req.body;
  if (!rideId || !driverUid) return res.status(400).json({ error: 'Missing rideId/driverUid' });

  try {
    const rideRef = db.collection(AppPaths.ridesCollection).doc(rideId);
    const result = await db.runTransaction(async (t) => {
      const snap = await t.get(rideRef);
      const cur = snap.data() || {};
      if (cur[AppFields.driverId]) return { assigned: false };

      t.set(
        rideRef,
        {
          [AppFields.driverId]: driverUid,
          [AppFields.status]: RideStatus.accepted,
          [AppFields.acceptedAt]: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return { assigned: true };
    });

    if (result.assigned) {
      await rtdb.child(`${AppPaths.ridesLive}/${rideId}`).update({
        [AppFields.status]: RideStatus.accepted,
        driverId: driverUid,
        updatedAt: admin.database.ServerValue.TIMESTAMP,
      });

      // remove driver_notifications for this ride from all drivers
      const all = await rtdb.child(AppPaths.driverNotifications).get();
      const del = {};
      all.forEach((driverSnap) => {
        if (driverSnap.hasChild(rideId)) {
          del[`${AppPaths.driverNotifications}/${driverSnap.key}/${rideId}`] = null;
        }
      });
      if (Object.keys(del).length) await rtdb.update(del);

      // remove legacy pending nodes
      await Promise.all([
        rtdb.child(`${AppPaths.ridesPendingA}/${rideId}`).remove().catch(() => {}),
        rtdb.child(`${AppPaths.ridesPendingB}/${rideId}`).remove().catch(() => {}),
      ]);

      // Notify rider (with accept sound)
      const snap = await rideRef.get();
      const riderId = snap.data()?.[AppFields.riderId];
      if (riderId) {
        await fcmToUser(riderId, {
          notification: StatusTitles.accepted,
          data: { status: 'accepted', rideId },
        }, { androidSound: 'ride_accept_3s', iosSound: 'ride_accept_3s.wav', androidChannelId: 'ride_accept_ch' });
      }
    }

    res.json(result);
  } catch (e) {
    console.error('accept/driver error', e);
    res.status(500).json({ error: e.message });
  }
});

// 4) Counter fare (driver -> rider)
app.post('/ride/counter-fare', async (req, res) => {
  const { rideId, driverUid, counterFare } = req.body;
  if (!rideId || !driverUid || typeof counterFare !== 'number') {
    return res.status(400).json({ error: 'Missing rideId/driverUid/counterFare' });
  }
  try {
    const ref = db.collection(AppPaths.ridesCollection).doc(rideId);
    await ref.set(
      { counterFare, [AppFields.status]: 'pending_counter' },
      { merge: true },
    );
    await rtdb.child(`${AppPaths.ridesLive}/${rideId}`).update({
      [AppFields.status]: 'pending_counter',
      updatedAt: admin.database.ServerValue.TIMESTAMP,
    });

    const riderId = (await ref.get()).data()?.[AppFields.riderId];
    if (riderId) {
      await rtdb.child(`${AppPaths.notifications}/${riderId}`).push().set({
        [AppFields.type]: 'counter_fare',
        counterFare,
        [AppFields.rideId]: rideId,
        [AppFields.timestamp]: admin.database.ServerValue.TIMESTAMP,
      });
      await fcmToUser(riderId, {
        notification: { title: 'Counter Fare', body: `Driver offered $${counterFare.toFixed(2)}` },
        data: { rideId, action: 'COUNTER_FARE' },
      }, { androidSound: 'ride_accept_3s', iosSound: 'ride_accept_3s.wav', androidChannelId: 'ride_accept_ch' });
    }
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 5) Status progression
app.post('/ride/status', async (req, res) => {
  const { rideId, newStatus } = req.body;
  if (!rideId || !newStatus) return res.status(400).json({ error: 'Missing rideId/newStatus' });
  const valid = new Set(Object.values(RideStatus));
  if (!valid.has(newStatus)) return res.status(400).json({ error: 'Invalid status' });

  try {
    const ref = db.collection(AppPaths.ridesCollection).doc(rideId);
    await ref.set(
      {
        [AppFields.status]: newStatus,
        [`${newStatus}At`]: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    await rtdb.child(`${AppPaths.ridesLive}/${rideId}`).update({
      [AppFields.status]: newStatus,
      updatedAt: admin.database.ServerValue.TIMESTAMP,
    });

    const riderId = (await ref.get()).data()?.[AppFields.riderId];
    if (riderId && StatusTitles[newStatus]) {
      await rtdb.child(`${AppPaths.notifications}/${riderId}`).push().set({
        [AppFields.type]: 'status_update',
        [AppFields.status]: newStatus,
        [AppFields.rideId]: rideId,
        [AppFields.timestamp]: admin.database.ServerValue.TIMESTAMP,
      });
      await fcmToUser(riderId, {
        notification: StatusTitles[newStatus],
        data: { rideId, status: newStatus },
      }, { androidSound: undefined, iosSound: undefined });
    }
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 6) Cancel ride
app.post('/ride/cancel', async (req, res) => {
  const { rideId, byUid } = req.body;
  if (!rideId) return res.status(400).json({ error: 'Missing rideId' });

  try {
    const ref = db.collection(AppPaths.ridesCollection).doc(rideId);
    const snap = await ref.get();
    const riderId = snap.data()?.[AppFields.riderId];

    await ref.set(
      {
        [AppFields.status]: RideStatus.cancelled,
        [AppFields.driverId]: admin.firestore.FieldValue.delete(),
        driverName: admin.firestore.FieldValue.delete(),
        [AppFields.cancelledAt]: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    await rtdb.child(`${AppPaths.ridesLive}/${rideId}`).update({
      [AppFields.status]: RideStatus.cancelled,
      updatedAt: admin.database.ServerValue.TIMESTAMP,
    });

    const all = await rtdb.child(AppPaths.driverNotifications).get();
    const del = {};
    all.forEach((driverSnap) => {
      if (driverSnap.hasChild(rideId)) {
        del[`${AppPaths.driverNotifications}/${driverSnap.key}/${rideId}`] = null;
      }
    });
    if (Object.keys(del).length) await rtdb.update(del);

    if (riderId) {
      await fcmToUser(riderId, {
        notification: StatusTitles.cancelled,
        data: { status: 'cancelled', rideId, byUid: byUid ?? '' },
      }, { androidSound: 'ride_cancel_2s', iosSound: 'ride_cancel_2s.wav', androidChannelId: 'ride_cancel_ch' });
      await rtdb.child(`${AppPaths.notifications}/${riderId}`).push().set({
        [AppFields.type]: 'ride_cancelled',
        [AppFields.rideId]: rideId,
        [AppFields.timestamp]: admin.database.ServerValue.TIMESTAMP,
      });
    }

    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// Emergency endpoint
app.post('/emergency', async (req, res) => {
  const { rideId, reportedBy, otherUid } = req.body;
  if (!rideId || !reportedBy || !otherUid) {
    return res.status(400).json({ error: 'Missing rideId/reportedBy/otherUid' });
  }

  try {
    // 1) Persist emergency
    await db.collection('emergencies').add({
      [AppFields.rideId]: rideId,
      [AppFields.reportedBy]: reportedBy,
      [AppFields.otherUid]: otherUid,
      [AppFields.timestamp]: admin.firestore.FieldValue.serverTimestamp(),
    });

    // 2) Soft action on involved account/ride
    await db.collection('users').doc(otherUid).set({ [AppFields.verified]: false }, { merge: true });
    await db.collection(AppPaths.ridesCollection).doc(rideId).set(
      { [AppFields.status]: RideStatus.cancelled },
      { merge: true },
    );

    // 3) RTDB admin alert
    const alertRef = rtdb.child(AppPaths.adminAlerts).push();
    await alertRef.set({
      [AppFields.rideId]: rideId,
      [AppFields.reportedBy]: reportedBy,
      [AppFields.otherUid]: otherUid,
      [AppFields.timestamp]: admin.database.ServerValue.TIMESTAMP,
      severity: 'emergency',
      acknowledged: false,
    });

    // 4) Optional: FCM push to admins (multicast)
    const adminTokens = await getAdminTokens();
    if (adminTokens.length) {
      await fcm.sendMulticast({
        tokens: adminTokens,
        notification: {
          title: '🚨 Emergency Triggered',
          body: `Ride ${rideId} — reported by ${reportedBy}`,
        },
        data: {
          action: 'EMERGENCY',
          rideId,
          reportedBy,
          otherUid,
        },
        android: {
          priority: 'high',
          notification: {
            channelId: 'ride_incoming_ch',
            sound: 'ride_incoming_15s',
          },
        },
        apns: {
          payload: {
            aps: {
              sound: 'ride_incoming_15s.wav',
              contentAvailable: 1,
            },
          },
          headers: { 'apns-priority': '10' },
        },
      });
    }

    // 4b) Also notify a specific admin user (if you have a main admin UID)
    const adminUid = process.env.MAIN_ADMIN_UID || null;
    if (adminUid) {
      await fcmToUser(adminUid, {
        notification: {
          title: '🚨 Emergency Triggered',
          body: `Ride ${rideId} reported by ${reportedBy}`,
        },
        data: { action: 'EMERGENCY', rideId },
      }, {
        androidSound: 'ride_incoming_15s',
        iosSound: 'ride_incoming_15s.wav',
        androidChannelId: 'ride_incoming_ch',
      });
    }

    // 5) Mail (optional)
    await db.collection('mail').add({
      to: 'ops@example.com',
      subject: '🚨 Emergency Triggered',
      text: `User ${reportedBy} triggered emergency on ride ${rideId}, affected: ${otherUid}`,
    });

    res.json({ ok: true });
  } catch (e) {
    console.error('Emergency error:', e);
    res.status(500).json({ error: e.message });
  }
});

// Housekeeping helpers: prune stale drivers and expired offers
async function pruneStaleDrivers() {
  const now = Date.now();
  const snap = await rtdb.child(AppPaths.driversOnline).get();
  const updates = {};
  snap.forEach((c) => {
    const v = c.val() || {};
    if (typeof v.updatedAt === 'number' && now - v.updatedAt > DRIVER_STALE_MS) {
      updates[`${AppPaths.driversOnline}/${c.key}`] = null;
    }
  });
  if (Object.keys(updates).length) await rtdb.update(updates);
}

async function pruneExpiredOffers() {
  const now = Date.now();
  const root = await rtdb.child(AppPaths.driverNotifications).get();
  const updates = {};
  root.forEach((driverNode) => {
    driverNode.forEach((rideNode) => {
      const ts = rideNode.child(AppFields.timestamp).val();
      if (!ts || now - ts > OFFER_TTL_MS) {
        updates[`${AppPaths.driverNotifications}/${driverNode.key}/${rideNode.key}`] = null;
      }
    });
  });
  if (Object.keys(updates).length) await rtdb.update(updates);
}

app.post('/housekeep/run', async (_req, res) => {
  try {
    await Promise.all([pruneStaleDrivers(), pruneExpiredOffers()]);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

module.exports = app;
