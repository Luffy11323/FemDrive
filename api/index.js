// api/index.js
const express = require('express');
const cors = require('cors');
const {
  initializeApp,
  credential,
  firestore,
  database,
  messaging,
} = require('firebase-admin');
const { encode: geohashEncode, neighbors: geohashNeighbors } = require('ngeohash');
const haversine = require('haversine-distance');

//
// ──────────────────────────────────────────────────────────────────────────
//  Firebase Admin
// ──────────────────────────────────────────────────────────────────────────
initializeApp({
  // For Vercel/Cloud Functions prefer:
  // credential: credential.applicationDefault(),
  // For local:
  credential: credential.cert(require('./serviceAccountKey.json')),
});
const db = firestore();
const rtdb = database().ref();
const fcm = messaging();

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
    // Option A: users with role: 'admin'
    const qs = await db.collection('users').where('role', '==', 'admin').get();
    qs.forEach(d => {
      const tok = d.data()?.[AppFields.fcmToken];
      if (tok) tokens.push(tok);
    });

    // Option B (alternative): a 'admins' collection with { fcmToken }
    // const qs2 = await db.collection('admins').get();
    // qs2.forEach(d => { const tok = d.data()?.fcmToken; if (tok) tokens.push(tok); });

  } catch (_) {}
  return tokens;
}

async function fcmToUser(uid, payload, { androidSound, iosSound } = {}) {
  const snap = await db.collection('users').doc(uid).get();
  const token = snap.data()?.[AppFields.fcmToken];
  if (!token) return false;
  await fcm.send({
    token,
    ...payload,
    android: androidSound ? { notification: { sound: androidSound } } : undefined,
    apns: iosSound ? { payload: { aps: { sound: iosSound } } } : undefined,
  });
  return true;
}

async function seedRidesLiveIfMissing(rideId) {
  const node = rtdb.child(`${AppPaths.ridesLive}/${rideId}`);
  const snap = await node.get();
  if (!snap.exists()) {
    await node.set({
      [AppFields.status]: RideStatus.pending,
      updatedAt: database.ServerValue.TIMESTAMP,
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
    });
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
        updatedAt: database.ServerValue.TIMESTAMP,
      });
      return res.json({ ok: true, targeted: 0 });
    }

    candidates.sort(
      (a, b) =>
        haversine({ lat: a.lat, lon: a.lng }, { lat: pLat, lon: pLng }) -
        haversine({ lat: b.lat, lon: b.lng }, { lat: pLat, lon: pLng }),
    );

    const nowTS = database.ServerValue.TIMESTAMP;
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

    // 🔊 Play incoming ride sound for top N drivers
    const topN = Math.min(10, candidates.length);
    let fcmCount = 0;
    for (let i = 0; i < topN; i++) {
      const ok = await fcmToUser(candidates[i].uid, {
        notification: {
          title: 'Ride Request Nearby',
          body: `Pickup near ${pLat.toFixed(4)}, ${pLng.toFixed(4)}`,
        },
        data: { rideId, action: 'NEW_REQUEST' },
      }, { androidSound: 'ride_incoming_15s', iosSound: 'ride_incoming_15s.wav' });
      if (ok) fcmCount++;
    }

    res.json({ ok: true, targeted: candidates.length, fcm: fcmCount });
  } catch (e) {
    console.error('pair/ride error', e);
    res.status(500).json({ error: e.message });
  }
});

// 3) Driver accept
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
          [AppFields.acceptedAt]: firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return { assigned: true };
    });

    if (result.assigned) {
      await rtdb.child(`${AppPaths.ridesLive}/${rideId}`).update({
        [AppFields.status]: RideStatus.accepted,
        driverId: driverUid,
        updatedAt: database.ServerValue.TIMESTAMP,
      });

      const all = await rtdb.child(AppPaths.driverNotifications).get();
      const del = {};
      all.forEach((driverSnap) => {
        if (driverSnap.hasChild(rideId)) {
          del[`${AppPaths.driverNotifications}/${driverSnap.key}/${rideId}`] = null;
        }
      });
      if (Object.keys(del).length) await rtdb.update(del);
      await Promise.all([
        rtdb.child(`${AppPaths.ridesPendingA}/${rideId}`).remove().catch(() => {}),
        rtdb.child(`${AppPaths.ridesPendingB}/${rideId}`).remove().catch(() => {}),
      ]);

      // 🔊 Notify rider with accept sound
      const snap = await rideRef.get();
      const riderId = snap.data()?.[AppFields.riderId];
      if (riderId) {
        await fcmToUser(riderId, {
          notification: StatusTitles.accepted,
          data: { status: 'accepted', rideId },
        }, { androidSound: 'ride_accept_3s', iosSound: 'ride_accept_3s.wav' });
      }
    }

    res.json(result);
  } catch (e) {
    console.error('accept/driver error', e);
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
        [AppFields.driverId]: firestore.FieldValue.delete(),
        driverName: firestore.FieldValue.delete(),
        [AppFields.cancelledAt]: firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );

    await rtdb.child(`${AppPaths.ridesLive}/${rideId}`).update({
      [AppFields.status]: RideStatus.cancelled,
      updatedAt: database.ServerValue.TIMESTAMP,
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
      }, { androidSound: 'ride_cancel_2s', iosSound: 'ride_cancel_2s.wav' });
    }

    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.post('/emergency', async (req, res) => {
  const { rideId, reportedBy, otherUid } = req.body;
  if (!rideId || !reportedBy || !otherUid) {
    return res.status(400).json({ error: 'Missing rideId/reportedBy/otherUid' });
  }

  try {
    // 1) Persist emergency (Firestore)
    await db.collection('emergencies').add({
      [AppFields.rideId]: rideId,
      [AppFields.reportedBy]: reportedBy,
      [AppFields.otherUid]: otherUid,
      [AppFields.timestamp]: firestore.FieldValue.serverTimestamp(),
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
      [AppFields.timestamp]: database.ServerValue.TIMESTAMP,
      severity: 'emergency',
      acknowledged: false,
    });

    // 4) Optional: FCM push to admins
    const adminTokens = await getAdminTokens(); // see helper above
    if (adminTokens.length) {
      await fcm.sendEachForMulticast({
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
        android: { priority: 'high' },
        apns: { headers: { 'apns-priority': '10' } },
      });
    }

    // ✅ 4b) NEW: Direct FCM to adminUid
    const adminUid = 'ADMIN_UID_HERE'; // Replace this with your actual logic
    await fcmToUser(adminUid, {
      notification: {
        title: '🚨 Emergency Triggered',
        body: `Ride ${rideId} reported by ${reportedBy}`,
      },
      data: { action: 'EMERGENCY', rideId },
    }, {
      androidSound: 'ride_incoming_15s',
      iosSound: 'ride_incoming_15s.wav',
    });

    // 5) Mail
    await db.collection('mail').add({
      to: 'frnklnwrld@gmail.com',
      subject: '🚨 Emergency Triggered',
      text: `User ${reportedBy} triggered emergency on ride ${rideId}, affected: ${otherUid}`,
    });

    res.json({ ok: true });
  } catch (e) {
    console.error('Emergency error:', e);
    res.status(500).json({ error: e.message });
  }
});


// ──────────────────────────────────────────────────────────────────────────
//  Export
// ──────────────────────────────────────────────────────────────────────────
module.exports = app;
