import express, { json } from 'express';
import {
  initializeApp,
  credential as _credential,
  firestore,
  database,
  messaging
} from 'firebase-admin';
import { encode, neighbors as _neighbors } from 'ngeohash';
import haversine from 'haversine-distance';

initializeApp({
  credential: _credential.cert(require('./serviceAccountKey.json')),
});

const db = firestore();
const realDb = database().ref();

const statuses = {
  accepted:   { title: 'Ride Accepted',     body: 'Your driver has accepted your ride.' },
  arriving:   { title: 'Driver Arriving',   body: 'Your driver is on the way to the pickup location.' },
  started:    { title: 'Ride Started',      body: 'Your ride has begun.' },
  completed:  { title: 'Ride Completed',    body: 'Thank you for riding with FemDrive!' },
  cancelled:  { title: 'Ride Cancelled',    body: 'The ride has been cancelled.' },
  no_drivers: { title: 'No Drivers Available', body: 'Sorry, no drivers are currently available.' },
};

const THRESHOLD = 12 * 60 * 60 * 1000; // 12 hrs

const app = express();
app.use(json());

// 🚨 1. Notify rider of status change
app.post('/notify/status', async (req, res) => {
  const { riderId, status, rideId } = req.body;
  if (!riderId || !statuses[status] || !rideId) {
    return res.status(400).json({ error: 'Missing or invalid parameters.' });
  }
  try {
    const snap = await db.collection('users').doc(riderId).get();
    const token = snap.data()?.fcmToken;
    if (!token) return res.status(404).json({ error: 'No FCM token for rider' });

    await messaging().send({
      token,
      notification: statuses[status],
      data: { status, rideId },
    });
    res.json({ success: true });
  } catch (e) {
    console.error('Status notification error:', e);
    res.status(500).json({ error: e.message });
  }
});

// 🚗 2. Pair driver to ride & notify nearby
app.post('/pair/ride', async (req, res) => {
  const { rideId, pickupLat, pickupLng } = req.body;
  if (!rideId || !pickupLat || !pickupLng) {
    return res.status(400).json({ error: 'Missing ride or coordinates.' });
  }
  try {
    const rideSnap = await db.collection('rides').doc(rideId).get();
    if (rideSnap.data()?.driverId) return res.json({ message: 'Already assigned' });

    const pHash = encode(pickupLat, pickupLng, 9);
    const neigh = [..._neighbors(pHash), pHash];
    const drivers = [];

    for (const h of neigh) {
      const q = await realDb
        .child('drivers_online')
        .orderByChild('geohash')
        .startAt(h)
        .endAt(h + '\uf8ff')
        .once('value');
      q.forEach(c => drivers.push(c.val()));
    }

    if (!drivers.length) {
      await db.collection('rides').doc(rideId).update({ status: 'no_drivers' });
      return res.json({ message: 'No drivers found' });
    }

    drivers.sort((a, b) =>
      haversine(a, { lat: pickupLat, lon: pickupLng }) -
      haversine(b, { lat: pickupLat, lon: pickupLng })
    );

    const tokens = [];
    for (const d of drivers) {
      const snap = await db.collection('users').doc(d.uid).get();
      const token = snap.data()?.fcmToken;
      if (!token) continue;
      tokens.push(token);
      await messaging().send({
        token,
        notification: {
          title: 'Ride Request Nearby',
          body: `Pickup near lat:${pickupLat.toFixed(4)}, lng:${pickupLng.toFixed(4)}`,
        },
        data: { rideId, action: 'NEW_REQUEST' },
      });
      await new Promise(r => setTimeout(r, 20000)); // 20 sec spacing
    }

    res.json({ success: true, targeted: tokens.length });
  } catch (e) {
    console.error('Pairing error:', e);
    res.status(500).json({ error: e.message });
  }
});

// 🚨 3. Emergency handler
app.post('/emergency', async (req, res) => {
  const { rideId, reportedBy, otherUid } = req.body;
  if (!rideId || !reportedBy || !otherUid) {
    return res.status(400).json({ error: 'Missing parameters.' });
  }
  try {
    await db.collection('emergencies').add({
      rideId,
      reportedBy,
      otherUid,
      timestamp: firestore.FieldValue.serverTimestamp(),
    });
    await db.collection('users').doc(otherUid).update({ verified: false });
    await db.collection('rides').doc(rideId).update({ status: 'cancelled' });
    await db.collection('mail').add({
      to: 'franklnwrldd@gmail.com',
      subject: '🚨 Emergency Triggered',
      text: `User ${reportedBy} triggered emergency on ride ${rideId}, affected: ${otherUid}`,
    });
    res.json({ success: true });
  } catch (e) {
    console.error('Emergency error:', e);
    res.status(500).json({ error: e.message });
  }
});

// ✅ 4. Driver accept with race protection
app.post('/accept/driver', async (req, res) => {
  const { rideId, driverUid } = req.body;
  if (!rideId || !driverUid) {
    return res.status(400).json({ error: 'Missing params.' });
  }
  try {
    const rideRef = db.collection('rides').doc(rideId);
    const result = await db.runTransaction(async t => {
      const snap = await t.get(rideRef);
      if (snap.data()?.driverId) return { assigned: false };
      t.update(rideRef, { driverId: driverUid, status: 'accepted' });
      return { assigned: true };
    });
    res.json(result);
  } catch (e) {
    console.error('Accept error:', e);
    res.status(500).json({ error: e.message });
  }
});

// Clean up stale drivers every 15 minutes
setInterval(async () => {
  const snap = await realDb.child('drivers_online').once('value');
  const now = Date.now();
  const updates = {};
  snap.forEach(c => {
    if (now - c.val().updatedAt > THRESHOLD) {
      updates[c.key] = null;
    }
  });
  if (Object.keys(updates).length) {
    await realDb.child('drivers_online').update(updates);
    console.log('Removed stale drivers:', Object.keys(updates));
  }
}, 15 * 60 * 1000);

// Export for serverless (if using Vercel), or listen locally:
export default app;
