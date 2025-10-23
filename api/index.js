const fs = require('fs');
const path = require('path');
const express = require('express');
const cors = require('cors');
const admin = require('firebase-admin');
const { encode: geohashEncode, neighbors: geohashNeighbors } = require('ngeohash');
const haversine = require('haversine-distance');
/// ──────────────────────────────────────────────────────────────────────────
///  Firebase Admin initialization
/// ──────────────────────────────────────────────────────────────────────────
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
  adminCred = admin.credential.applicationDefault();
  console.log('Using application default credentials (GOOGLE_APPLICATION_CREDENTIALS)');
} else {
  const localPath = path.join(__dirname, 'serviceAccountKey.json');
  if (fs.existsSync(localPath)) {
    adminCred = admin.credential.cert(require(localPath));
    console.log('Using local serviceAccountKey.json (dev)');
  } else {
    console.warn('No service account found. Falling back to applicationDefault()');
    adminCred = admin.credential.applicationDefault();
  }
}

const databaseURL = 'https://ridesharefyp-0022-default-rtdb.firebaseio.com';

admin.initializeApp({ credential: adminCred, databaseURL });

const db = admin.firestore();
const rtdb = admin.database().ref();
const fcm = admin.messaging();

/// ──────────────────────────────────────────────────────────────────────────
///  Shared Paths & Fields
/// ──────────────────────────────────────────────────────────────────────────
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
  trip_shares: 'trip_shares',
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
  createdAt: 'createdAt',
  role: 'role',
  trustScore: 'trustScore',
  requiresManualReview: 'requiresManualReview',
  cnicNumber: 'cnicNumber',
  cnicBase64: 'cnicBase64',
  verifiedCnic: 'verifiedCnic',
  documentsUploaded: 'documentsUploaded',
  uploadTimestamp: 'uploadTimestamp',
  carType: 'carType',
  carModel: 'carModel',
  altContact: 'altContact',
  licenseBase64: 'licenseBase64',
  verifiedLicense: 'verifiedLicense',
  awaitingVerification: 'awaitingVerification',
  paymentMethod: 'paymentMethod',
  amount: 'amount',
  paymentTimestamp: 'paymentTimestamp',
  earnings: 'earnings',
  cancelledBy: 'cancelledBy',
  cancelReason: 'cancelReason',
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
  noDrivers: 'no_drivers',
};

const StatusTitles = {
  accepted:       { title: 'Ride Accepted',    body: 'Your driver has accepted your ride.' },
  driver_arrived: { title: 'Driver Arrived',   body: 'Your driver has arrived.' },
  in_progress:    { title: 'Ride Started',     body: 'Your ride has begun.' },
  onTrip:         { title: 'Ride Started',     body: 'Your ride has begun.' }, // alias
  completed:      { title: 'Ride Completed',   body: 'Thanks for riding with FemDrive!' },
  cancelled:      { title: 'Ride Cancelled',   body: 'This ride has been cancelled.' },
  no_drivers:     { title: 'No Drivers Available', body: 'Sorry, no drivers are currently available.' },
};

const OFFER_TTL_MS = 60 * 1000;
const DRIVER_STALE_MS = 12 * 60 * 60 * 1000;

const app = express();
app.use(cors());
app.use(express.json());

// Create a router for all /api/* routes
const apiRouter = express.Router();

/// Health
apiRouter.get('/health', (_req, res) => res.json({ ok: true }));

/// ──────────────────────────────────────────────────────────────────────────
/// Helpers
/// ──────────────────────────────────────────────────────────────────────────
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

/** Send FCM to a user by uid; supports optional sound/channel hints. */
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

async function validatePhone(phone) {
  const digitsOnly = phone.replace(/\D/g, '');
  const snap = await db.collection('phones').doc(digitsOnly).get();
  return snap.exists;
}

async function validateCnic(cnicNumber) {
  const qs = await db.collection('users').where('cnicNumber', '==', cnicNumber).limit(1).get();
  return !qs.empty;
}

/// ──────────────────────────────────────────────────────────────────────────
/// Routes
/// ──────────────────────────────────────────────────────────────────────────

// 0) Hook to seed ridesLive
apiRouter.post('/rides/init', async (req, res) => {
  const { rideId } = req.body;
  if (!rideId) return res.status(400).json({ error: 'rideId required' });
  try {
    await seedRidesLiveIfMissing(rideId);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 1) Generic rider status notifier (server-side)
apiRouter.post('/notify/status', async (req, res) => {
  const { riderId, status, rideId } = req.body;
  if (!riderId || !status || !rideId || !StatusTitles[status]) {
    return res.status(400).json({ error: 'Invalid params' });
  }
  try {
    await fcmToUser(riderId, {
      notification: StatusTitles[status],
      data: { status, rideId },
    }, { androidSound: undefined, iosSound: undefined, androidChannelId: 'ride_progress_ch' });
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 2) Pair / broadcast offers to nearby drivers
apiRouter.post('/pair/ride', async (req, res) => {
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
      [AppFields.pickup]:     r[AppFields.pickup] ?? '',
      [AppFields.dropoff]:    r[AppFields.dropoff] ?? '',
      [AppFields.dropoffLat]: r[AppFields.dropoffLat] ?? 0,
      [AppFields.dropoffLng]: r[AppFields.dropoffLng] ?? 0,
      [AppFields.fare]:       r[AppFields.fare] ?? 0,
    };

    const hash = geohashEncode(pLat, pLng, 9);
    const hashes = [...geohashNeighbors(hash), hash];

    const candidates = [];
    for (const h of hashes) {
      const snap = await rtdb
        .child(AppPaths.driversOnline)
        .orderByChild(AppFields.geohash)
        .startAt(h).endAt(`${h}\uf8ff`)
        .get();

      snap.forEach((c) => {
        const v = c.val() || {};
        if (v?.uid && typeof v.lat === 'number' && typeof v.lng === 'number') {
          candidates.push({ uid: v.uid, lat: v.lat, lng: v.lng });
        }
      });
    }

    if (!candidates.length) {
      await db.collection(AppPaths.ridesCollection).doc(rideId)
        .set({ [AppFields.status]: RideStatus.noDrivers }, { merge: true });
      await rtdb.child(`${AppPaths.ridesLive}/${rideId}`).update({
        [AppFields.status]: RideStatus.noDrivers,
        updatedAt: admin.database.ServerValue.TIMESTAMP,
      });

      // Notify rider (no drivers)
      const riderId = r[AppFields.riderId];
      if (riderId) {
        await fcmToUser(riderId, {
          notification: StatusTitles.no_drivers,
          data: { status: RideStatus.noDrivers, rideId },
        }, { androidChannelId: 'ride_progress_ch' });
      }

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
        rideId,
      };
    }
    await rtdb.update(updates);

    // Push FCM to top N drivers with ring
    const topN = Math.min(10, candidates.length);
    let fcmCount = 0;
    for (let i = 0; i < topN; i++) {
      const ok = await fcmToUser(candidates[i].uid, {
        notification: {
          title: 'Ride Request Nearby',
          body:  `Pickup near ${pLat.toFixed(4)}, ${pLng.toFixed(4)}`,
        },
        data: { rideId, action: 'NEW_REQUEST' },
      }, {
        androidSound: 'ride_incoming_15s',
        iosSound:     'ride_incoming_15s.wav',
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

// 3) Driver accept (race-protected) → notify rider
apiRouter.post('/accept/driver', async (req, res) => {
  const { rideId, driverUid } = req.body;
  if (!rideId || !driverUid) return res.status(400).json({ error: 'Missing rideId/driverUid' });

  try {
    const rideRef = db.collection(AppPaths.ridesCollection).doc(rideId);
    const result = await db.runTransaction(async (t) => {
      const snap = await t.get(rideRef);
      const cur = snap.data() || {};
      if (cur[AppFields.driverId]) return { assigned: false }; // already won elsewhere
      t.set(rideRef, {
        [AppFields.driverId]: driverUid,
        [AppFields.status]: RideStatus.accepted,
        [AppFields.acceptedAt]: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
      return { assigned: true };
    });

    if (result.assigned) {
      await rtdb.child(`${AppPaths.ridesLive}/${rideId}`).update({
        [AppFields.status]: RideStatus.accepted,
        driverId: driverUid,
        updatedAt: admin.database.ServerValue.TIMESTAMP,
      });

      // Clean driver notifications for this ride
      const all = await rtdb.child(AppPaths.driverNotifications).get();
      const del = {};
      all.forEach((driverSnap) => {
        if (driverSnap.hasChild(rideId)) {
          del[`${AppPaths.driverNotifications}/${driverSnap.key}/${rideId}`] = null;
        }
      });
      if (Object.keys(del).length) await rtdb.update(del);

      // Remove legacy queues
      await Promise.all([
        rtdb.child(`${AppPaths.ridesPendingA}/${rideId}`).remove().catch(() => {}),
        rtdb.child(`${AppPaths.ridesPendingB}/${rideId}`).remove().catch(() => {}),
      ]);

      // Notify rider (accepted)
      const snap = await rideRef.get();
      const riderId = snap.data()?.[AppFields.riderId];
      if (riderId) {
        await fcmToUser(riderId, {
          notification: StatusTitles.accepted,
          data: { status: 'accepted', rideId },
        }, {
          androidSound: 'ride_accept_3s',
          iosSound:     'ride_accept_3s.wav',
          androidChannelId: 'ride_accept_ch',
        });
      }
    }

    res.json(result);
  } catch (e) {
    console.error('accept/driver error', e);
    res.status(500).json({ error: e.message });
  }
});

// 4) Counter fare (driver → rider)
apiRouter.post('/ride/counter-fare', async (req, res) => {
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
      }, {
        androidSound: 'ride_accept_3s',
        iosSound:     'ride_accept_3s.wav',
        androidChannelId: 'ride_accept_ch',
      });
    }
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 4b) Counter fare resolution (rider → driver)
apiRouter.post('/ride/counter-fare/resolve', async (req, res) => {
  const { rideId, riderUid, accepted } = req.body;
  if (!rideId || typeof accepted !== 'boolean') {
    return res.status(400).json({ error: 'Missing rideId/accepted' });
  }
  try {
    const ref = db.collection(AppPaths.ridesCollection).doc(rideId);
    const snap = await ref.get();
    const data = snap.data() || {};
    const driverId = data[AppFields.driverId];
    if (!driverId) return res.json({ ok: true, skipped: 'no_driver' });

    // Push to driver
    await fcmToUser(driverId, {
      notification: {
        title: accepted ? 'Counter Fare Accepted' : 'Counter Fare Rejected',
        body:   accepted ? 'Rider accepted your counter offer.'
                         : 'Rider rejected your counter offer.',
      },
      data: { rideId, action: accepted ? 'COUNTER_FARE_ACCEPTED' : 'COUNTER_FARE_REJECTED' },
    }, {
      androidChannelId: accepted ? 'ride_accept_ch' : 'ride_cancel_ch',
      androidSound: accepted ? 'ride_accept_3s' : 'ride_cancel_2s',
      iosSound:     accepted ? 'ride_accept_3s.wav' : 'ride_cancel_2s.wav',
    });

    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 5) Status progression → notify rider for known titles
apiRouter.post('/ride/status', async (req, res) => {
  const { rideId, newStatus } = req.body;
  if (!rideId || !newStatus) return res.status(400).json({ error: 'Missing rideId/newStatus' });
  const valid = new Set(Object.values(RideStatus));
  if (!valid.has(newStatus)) return res.status(400).json({ error: 'Invalid status' });

  try {
    const ref = db.collection(AppPaths.ridesCollection).doc(rideId);
    await ref.set(
      { [AppFields.status]: newStatus, [`${newStatus}At`]: admin.firestore.FieldValue.serverTimestamp() },
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
      }, { androidChannelId: 'ride_progress_ch' });
    }
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 6) Cancel ride → notify BOTH parties with role-aware wording
apiRouter.post('/ride/cancel', async (req, res) => {
  const { rideId, byUid } = req.body;
  if (!rideId) return res.status(400).json({ error: 'Missing rideId' });

  try {
    const ref = db.collection(AppPaths.ridesCollection).doc(rideId);
    const snap = await ref.get();
    const ride = snap.data() || {};
    const riderId  = ride[AppFields.riderId];
    const driverId = ride[AppFields.driverId];

    await ref.set({
      [AppFields.status]: RideStatus.cancelled,
      [AppFields.driverId]: admin.firestore.FieldValue.delete(),
      driverName: admin.firestore.FieldValue.delete(),
      [AppFields.cancelledAt]: admin.firestore.FieldValue.serverTimestamp(),
    }, { merge: true });

    await rtdb.child(`${AppPaths.ridesLive}/${rideId}`).update({
      [AppFields.status]: RideStatus.cancelled,
      updatedAt: admin.database.ServerValue.TIMESTAMP,
    });

    // Remove pending notifications
    const all = await rtdb.child(AppPaths.driverNotifications).get();
    const del = {};
    all.forEach((driverSnap) => {
      if (driverSnap.hasChild(rideId)) {
        del[`${AppPaths.driverNotifications}/${driverSnap.key}/${rideId}`] = null;
      }
    });
    if (Object.keys(del).length) await rtdb.update(del);

    // Role-aware pushes
    const byIsRider  = byUid && riderId && byUid === riderId;
    const byIsDriver = byUid && driverId && byUid === driverId;

    if (riderId) {
      await fcmToUser(riderId, {
        notification: { title: 'Ride Cancelled', body: byIsDriver ? 'Driver cancelled this ride.' : 'Ride cancelled.' },
        data: { status: 'cancelled', rideId, byUid: byUid ?? '' },
      }, {
        androidChannelId: 'ride_cancel_ch',
        androidSound: 'ride_cancel_2s', iosSound: 'ride_cancel_2s.wav',
      });
      await rtdb.child(`${AppPaths.notifications}/${riderId}`).push().set({
        [AppFields.type]: 'ride_cancelled',
        [AppFields.rideId]: rideId,
        [AppFields.timestamp]: admin.database.ServerValue.TIMESTAMP,
      });
    }

    if (driverId) {
      await fcmToUser(driverId, {
        notification: { title: 'Ride Cancelled', body: byIsRider ? 'Rider cancelled this ride.' : 'Ride cancelled.' },
        data: { action: byIsRider ? 'CANCELLED_BY_RIDER' : 'CANCELLED_BY_DRIVER', rideId, byUid: byUid ?? '' },
      }, {
        androidChannelId: byIsRider ? 'ride_cancel_ch' : 'ride_cancel_ch',
        androidSound: 'ride_cancel_2s', iosSound: 'ride_cancel_2s.wav',
      });
    }

    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// 7) Emergency endpoint (also notifies reported user)
apiRouter.post('/emergency', async (req, res) => {
  const { rideId, reportedBy, otherUid } = req.body;
  if (!rideId || !reportedBy || !otherUid) {
    return res.status(400).json({ error: 'Missing rideId/reportedBy/otherUid' });
  }

  try {
    const rideRef = db.collection(AppPaths.ridesCollection).doc(rideId);
    const rideSnap = await rideRef.get();
    const rideData = rideSnap.data() || {};

    const batch = db.batch();
    batch.update(db.collection('users').doc(otherUid), { [AppFields.verified]: false });
    batch.update(rideRef, {
      [AppFields.status]: RideStatus.cancelled,
      [AppFields.emergencyTriggered]: true,
      [AppFields.cancelledBy]: reportedBy,
      [AppFields.cancelReason]: 'emergency',
      [AppFields.cancelledAt]: admin.firestore.FieldValue.serverTimestamp(),
    });

    const emergencyRef = db.collection('emergencies').doc();
    batch.set(emergencyRef, {
      type: 'driver_emergency',
      [AppFields.rideId]: rideId,
      [AppFields.reportedBy]: reportedBy,
      [AppFields.otherUid]: otherUid,
      emergencyTriggered: true,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      rideSnapshot: {
        [AppFields.pickup]: rideData[AppFields.pickup],
        [AppFields.dropoff]: rideData[AppFields.dropoff],
        [AppFields.pickupLat]: rideData[AppFields.pickupLat],
        [AppFields.pickupLng]: rideData[AppFields.pickupLng],
        [AppFields.dropoffLat]: rideData[AppFields.dropoffLat],
        [AppFields.dropoffLng]: rideData[AppFields.dropoffLng],
        [AppFields.fare]: rideData[AppFields.fare],
        rideType: rideData.rideType,
        [AppFields.riderId]: rideData[AppFields.riderId],
        [AppFields.driverId]: rideData[AppFields.driverId],
      },
    });

    await batch.commit();

    // RTDB updates
    await rtdb.child(`${AppPaths.ridesLive}/${rideId}`).update({
      [AppFields.status]: RideStatus.cancelled,
      [AppFields.emergencyTriggered]: true,
      updatedAt: admin.database.ServerValue.TIMESTAMP,
    });

    await Promise.all([
      rtdb.child(`${AppPaths.ridesPendingA}/${rideId}`).remove(),
      rtdb.child(`${AppPaths.ridesPendingB}/${rideId}`).remove(),
    ]);

    // Clean driver notifications
    const notifsSnap = await rtdb.child(AppPaths.driverNotifications).get();
    if (notifsSnap.exists() && typeof notifsSnap.val() === 'object') {
      const updates = {};
      const map = notifsSnap.val();
      Object.entries(map).forEach(([driverKey, ridesMap]) => {
        if (ridesMap && rideId in ridesMap) {
          updates[`${AppPaths.driverNotifications}/${driverKey}/${rideId}`] = null;
        }
      });
      if (Object.keys(updates).length) await rtdb.update(updates);
    }

    // Notify rider
    await rtdb.child(`${AppPaths.notifications}/${otherUid}`).push().set({
      [AppFields.type]: 'ride_cancelled',
      [AppFields.rideId]: rideId,
      reason: 'emergency',
      [AppFields.timestamp]: admin.database.ServerValue.TIMESTAMP,
    });

    // Notify admin
    await rtdb.child('notifications/admin').push().set({
      [AppFields.type]: 'emergency',
      [AppFields.rideId]: rideId,
      [AppFields.reportedBy]: reportedBy,
      [AppFields.otherUid]: otherUid,
      [AppFields.timestamp]: admin.database.ServerValue.TIMESTAMP,
    });

    // FCM to admins
    const adminTokens = await getAdminTokens();
    if (adminTokens.length) {
      await fcm.sendMulticast({
        tokens: adminTokens,
        notification: {
          title: '🚨 Emergency Triggered',
          body: `Ride ${rideId} — reported by ${reportedBy}`,
        },
        data: { action: 'EMERGENCY', rideId, reportedBy, otherUid },
        android: { priority: 'high', notification: { channelId: 'ride_incoming_ch', sound: 'ride_incoming_15s' } },
        apns: { payload: { aps: { sound: 'ride_incoming_15s.wav', contentAvailable: 1 } },
                headers: { 'apns-priority': '10' } },
      });
    }

    // Notify the reported user
    await fcmToUser(otherUid, {
      notification: { title: 'Safety Report Filed', body: `A report was filed against you for ride ${rideId}.` },
      data: { action: 'REPORTED_AGAINST_YOU', rideId, reportedBy },
    }, { androidChannelId: 'ride_reports_ch' });

    // Notify the reporter
    await fcmToUser(reportedBy, {
      notification: { title: 'Emergency Sent', body: `We’ve notified support and the other party for ride ${rideId}.` },
      data: { action: 'EMERGENCY', rideId },
    }, {
      androidChannelId: 'ride_incoming_ch',
      androidSound: 'ride_incoming_15s',
      iosSound: 'ride_incoming_15s.wav',
    });

    // Optional mail
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

// 8) Payments (optional hooks you can call from your PaymentService)
apiRouter.post('/notify/payment', async (req, res) => {
  const { rideId, toUid, ok } = req.body; // ok=true/false
  if (!rideId || !toUid || typeof ok !== 'boolean') {
    return res.status(400).json({ error: 'Missing rideId/toUid/ok' });
  }
  try {
    await fcmToUser(toUid, {
      notification: {
        title: ok ? 'Payment Confirmed' : 'Payment Failed',
        body:  ok ? 'Your payment was successful.' : 'Please update your payment method.',
      },
      data: { rideId, action: ok ? 'PAYMENT_CONFIRMED' : 'PAYMENT_FAILED' },
    }, { androidChannelId: 'ride_payments_ch' });
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// New: User Signup (from signup_page.dart)
apiRouter.post('/signup', async (req, res) => {
  const {
    uid,
    phone,
    username,
    role,
    cnicNumber,
    cnicBase64,
    verifiedCnic,
    documentsUploaded,
    carType,
    carModel,
    altContact,
    licenseBase64,
    verifiedLicense,
    awaitingVerification,
  } = req.body;

  if (!uid || !phone || !username || !role || !cnicNumber) {
    return res.status(400).json({ error: 'Missing required fields' });
  }

  try {
    // Validate phone
    if (await validatePhone(phone)) {
      return res.status(400).json({ error: 'Phone number already registered' });
    }

    // Validate CNIC
    if (await validateCnic(cnicNumber)) {
      return res.status(400).json({ error: 'CNIC already registered' });
    }

    // Calculate trust score (placeholder; integrate ML if needed)
    const trustScore = 0.7; // From document verification
    const verified = trustScore >= 0.6;
    const requiresManualReview = trustScore < 0.6;

    // User document
    const userDoc = {
      [AppFields.uid]: uid,
      [AppFields.phone]: phone,
      [AppFields.username]: username,
      [AppFields.role]: role,
      [AppFields.createdAt]: admin.firestore.FieldValue.serverTimestamp(),
      [AppFields.verified]: verified,
      [AppFields.trustScore]: trustScore,
      [AppFields.requiresManualReview]: requiresManualReview,
      [AppFields.cnicNumber]: cnicNumber,
      [AppFields.cnicBase64]: cnicBase64,
      [AppFields.verifiedCnic]: verifiedCnic,
      [AppFields.documentsUploaded]: documentsUploaded,
      [AppFields.uploadTimestamp]: admin.firestore.FieldValue.serverTimestamp(),
    };

    if (role === 'driver') {
      userDoc[AppFields.carType] = carType;
      userDoc[AppFields.carModel] = carModel;
      userDoc[AppFields.altContact] = altContact;
      userDoc[AppFields.licenseBase64] = licenseBase64;
      userDoc[AppFields.verifiedLicense] = verifiedLicense;
      userDoc[AppFields.awaitingVerification] = awaitingVerification;
    }

    // Batch write
    const batch = db.batch();
    batch.set(db.collection('users').doc(uid), userDoc);
    batch.set(db.collection('phones').doc(phone.replace(/\D/g, '')), { uid, type: 'primary' });
    if (role === 'driver' && altContact) {
      batch.set(db.collection('phones').doc(altContact.replace(/\D/g, '')), { uid, type: 'alt' });
    }
    await batch.commit();

    res.json({ ok: true });
  } catch (e) {
    // Cleanup phones on failure
    await db.collection('phones').doc(phone.replace(/\D/g, '')).delete().catch(() => {});
    if (role === 'driver' && altContact) {
      await db.collection('phones').doc(altContact.replace(/\D/g, '')).delete().catch(() => {});
    }
    console.error('Signup error:', e);
    res.status(500).json({ error: e.message });
  }
});

// New: Process Payment (from payment_services.dart)
apiRouter.post('/processPayment', async (req, res) => {
  const { rideId, amount, paymentMethod, userId } = req.body;
  if (!rideId || !amount || !paymentMethod || !userId) {
    return res.status(400).json({ error: 'Missing required fields' });
  }

  try {
    // Validate payment method (placeholder; integrate real gateway)
    const validMethods = ['EasyPaisa', 'JazzCash', 'Card', 'Cash'];
    if (!validMethods.includes(paymentMethod)) {
      return res.status(400).json({ error: 'Invalid payment method' });
    }

    const rideRef = db.collection(AppPaths.ridesCollection).doc(rideId);
    const snap = await rideRef.get();
    const rideData = snap.data() || {};
    const driverId = rideData[AppFields.driverId];

    const batch = db.batch();
    batch.update(rideRef, {
      [AppFields.paymentStatus]: paymentMethod === 'Cash' ? 'pending_driver_confirmation' : 'completed',
      [AppFields.paymentMethod]: paymentMethod,
      [AppFields.amount]: amount,
      [AppFields.paymentTimestamp]: admin.firestore.FieldValue.serverTimestamp(),
    });

    if (paymentMethod !== 'Cash' && driverId) {
      const driverRef = db.collection('users').doc(driverId);
      batch.update(driverRef, {
        [AppFields.earnings]: admin.firestore.FieldValue.increment(amount * 0.8),
      });
    }

    const receiptRef = db.collection('receipts').doc(rideId);
    batch.set(receiptRef, {
      [AppFields.rideId]: rideId,
      userId,
      driverId,
      [AppFields.amount]: amount,
      method: paymentMethod,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
    });

    await batch.commit();

    // Notify user
    await fcmToUser(userId, {
      notification: {
        title: 'Payment Processed',
        body: `Your payment of $${amount.toFixed(2)} via ${paymentMethod} was successful.`,
      },
      data: { rideId, action: 'PAYMENT_CONFIRMED' },
    }, { androidChannelId: 'ride_payments_ch' });

    res.json({ ok: true });
  } catch (e) {
    console.error('Process payment error:', e);
    res.status(500).json({ error: e.message });
  }
});

// 9) Send Message → Store and notify recipient
apiRouter.post('/rides/:rideId/messages', async (req, res) => {
  const rideId = req.params.rideId;
  const { senderId, text } = req.body;
  
  if (!rideId || !senderId || !text) {
    return res.status(400).json({ error: 'Missing rideId/senderId/text' });
  }
  
  try {
    // 1. Store message in Realtime Database
    const messageRef = await rtdb.child(`rides/${rideId}/messages`).push();
    await messageRef.set({
      [AppFields.senderId]: senderId,
      [AppFields.text]: text,
      [AppFields.timestamp]: admin.database.ServerValue.TIMESTAMP,
    });

    // 2. Determine recipient (rider or driver)
    const rideSnap = await db.collection(AppPaths.ridesCollection).doc(rideId).get();
    const rideData = rideSnap.data() || {};
    const recipientId = senderId === rideData[AppFields.driverId] ? rideData[AppFields.riderId] : rideData[AppFields.driverId];
    
    if (!recipientId) {
      return res.status(400).json({ error: 'Recipient not found' });
    }

    // 3. Fetch sender's username for notification
    const senderSnap = await db.collection('users').doc(senderId).get();
    const senderName = senderSnap.data()?.[AppFields.username] || 'User';

    // 4. Send FCM notification with formatted message
    const notificationBody = `${senderName}: ${text.length > 50 ? `${text.substring(0, 47)}...` : text}`;
    const ok = await fcmToUser(recipientId, {
      notification: {
        title: 'New Message',
        body: notificationBody,
      },
      data: { 
        rideId, 
        action: 'NEW_MESSAGE', 
        message: text 
      },
    }, {
      androidChannelId: 'ride_progress_ch',
      androidSound: 'ride_cancel_2s',
      iosSound: 'ride_cancel_2s.wav',
    });

    res.json({ ok: ok, messageId: messageRef.key });
  } catch (e) {
    console.error('message/send error', e);
    res.status(500).json({ error: e.message });
  }
});

// NEW: Handle counter fare proposal
apiRouter.post('/ride/counter-fare', async (req, res) => {
  const { rideId, driverUid, counterFare, riderId } = req.body;

  if (!rideId || !driverUid || !counterFare || !riderId) {
    return res.status(400).json({ error: 'Missing required fields' });
  }

  try {
    const rideRef = db.collection('rides').doc(rideId);
    const rideSnap = await rideRef.get();
    if (!rideSnap.exists) {
      return res.status(404).json({ error: 'Ride not found' });
    }

    const rideData = rideSnap.data();
    if (rideData.status === 'cancelled' || rideData.status === 'completed') {
      return res.status(400).json({ error: 'Ride is no longer active' });
    }

    // Update ride with counter offer
    await rideRef.update({
      counterFare: counterFare,
      counterProposedAt: admin.firestore.FieldValue.serverTimestamp(),
      counterDriverId: driverUid,
    });

    // Notify rider via FCM
    const userRef = db.collection('users').doc(riderId);
    const userSnap = await userRef.get();
    const fcmToken = userSnap.data()?.fcmToken;

    if (fcmToken) {
      await fcm.send({
        token: fcmToken,
        notification: {
          title: 'Counter Offer Received',
          body: `Driver proposed $${counterFare} for ride ${rideId}`,
          sound: 'ride_cancel_2s',
        },
        data: { action: 'COUNTER_OFFER', rideId, counterFare },
        android: { priority: 'high', notification: { channelId: 'ride_progress_ch' } },
        apns: { payload: { aps: { sound: 'ride_cancel_2s.wav', contentAvailable: 1 } }, headers: { 'apns-priority': '10' } },
      });
    }

    res.json({ ok: true, counterFare });
  } catch (e) {
    console.error('Error processing counter fare:', e);
    res.status(500).json({ error: 'Failed to process counter fare' });
  }
});

// New: Update Location (from location_service.dart)
apiRouter.post('/updateLocation', async (req, res) => {
  const { role, rideId, lat, lng, driverId } = req.body;
  if (!role || !lat || !lng) {
    return res.status(400).json({ error: 'Missing role/lat/lng' });
  }

  try {
    const updates = {};
    if (rideId) {
      updates[`rides/${rideId}/driverLat`] = lat;
      updates[`rides/${rideId}/driverLng`] = lng;
      updates[`rides/${rideId}/driverTs`] = admin.database.ServerValue.TIMESTAMP;
      updates[`${AppPaths.ridesLive}/${rideId}/driverLat`] = lat;
      updates[`${AppPaths.ridesLive}/${rideId}/driverLng`] = lng;
      updates[`${AppPaths.ridesLive}/${rideId}/driverTs`] = admin.database.ServerValue.TIMESTAMP;
    }
    if (driverId) {
      updates[`${AppPaths.driversOnline}/${driverId}/lat`] = lat;
      updates[`${AppPaths.driversOnline}/${driverId}/lng`] = lng;
      updates[`${AppPaths.driversOnline}/${driverId}/updatedAt`] = admin.database.ServerValue.TIMESTAMP;
    }

    await rtdb.update(updates);

    // Log to Firestore (background locations)
    if (driverId) {
      await db.collection('drivers').doc(driverId).collection('bg_locations').add({
        lat,
        lng,
        timestamp: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    res.json({ ok: true });
  } catch (e) {
    console.error('Update location error:', e);
    res.status(500).json({ error: e.message });
  }
});

// Housekeeping
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

apiRouter.post('/housekeep/run', async (_req, res) => {
  try {
    await Promise.all([pruneStaleDrivers(), pruneExpiredOffers()]);
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// New: Create a shareable trip link
apiRouter.post('/trip/share', async (req, res) => {
  const { rideId, userId } = req.body;
  if (!rideId || !userId) {
    return res.status(400).json({ error: 'Missing rideId/userId' });
  }

  try {
    // Generate a unique shareId
    const shareId = Math.random().toString(36).substring(2, 15);
    
    // Validate ride exists
    const rideRef = db.collection(AppPaths.ridesCollection).doc(rideId);
    const rideSnap = await rideRef.get();
    if (!rideSnap.exists) {
      return res.status(404).json({ error: 'Ride not found' });
    }

    // Initialize share node in RTDB
    await rtdb.child(`${AppPaths.trip_shares}/${shareId}`).set({
      rideId,
      userId,
      createdAt: admin.database.ServerValue.TIMESTAMP,
    });

    // Return shareable URL
    const shareUrl = `https://fem-drive.vercel.app/trip/${shareId}`; // Update with your Vercel domain
    res.json({ ok: true, shareId, shareUrl });
  } catch (e) {
    console.error('Trip share error:', e);
    res.status(500).json({ error: e.message });
  }
});

// New: Update location for a shared trip
apiRouter.post('/trip/:shareId/location', async (req, res) => {
  const { shareId } = req.params;
  const { lat, lng, userId } = req.body;
  if (!shareId || !lat || !lng || !userId) {
    return res.status(400).json({ error: 'Missing shareId/lat/lng/userId' });
  }

  try {
    // Verify the share exists and belongs to the user
    const shareSnap = await rtdb.child(`${AppPaths.trip_shares}/${shareId}`).get();
    if (!shareSnap.exists() || shareSnap.val().userId !== userId) {
      return res.status(403).json({ error: 'Invalid or unauthorized shareId' });
    }

    // Update location
    await rtdb.child(`${AppPaths.trip_shares}/${shareId}`).update({
      lat,
      lng,
      updatedAt: admin.database.ServerValue.TIMESTAMP,
    });

    res.json({ ok: true });
  } catch (e) {
    console.error('Trip location update error:', e);
    res.status(500).json({ error: e.message });
  }
});

// New: Stop sharing a trip
apiRouter.post('/trip/:shareId/stop', async (req, res) => {
  const { shareId } = req.params;
  const { userId } = req.body;
  if (!shareId || !userId) {
    return res.status(400).json({ error: 'Missing shareId/userId' });
  }

  try {
    // Verify the share exists and belongs to the user
    const shareSnap = await rtdb.child(`${AppPaths.trip_shares}/${shareId}`).get();
    if (!shareSnap.exists() || shareSnap.val().userId !== userId) {
      return res.status(403).json({ error: 'Invalid or unauthorized shareId' });
    }

    // Remove the share node
    await rtdb.child(`${AppPaths.trip_shares}/${shareId}`).remove();
    res.json({ ok: true });
  } catch (e) {
    console.error('Stop trip share error:', e);
    res.status(500).json({ error: e.message });
  }
});

// Mount the API router at /api
app.use('/api', apiRouter);

module.exports = app;