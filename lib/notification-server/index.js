const express = require('express');
const admin = require('firebase-admin');
const ngeohash = require('ngeohash');
const haversine = require('haversine-distance');

admin.initializeApp({
  credential: admin.credential.cert(require('./serviceAccountKey.json')),
});

const db = admin.firestore();
const realDb = admin.database().ref();

const statuses = {
  accepted:   { title: 'Ride Accepted',     body: 'Your driver has accepted your ride.' },
  arriving:   { title: 'Driver Arriving',   body: 'Your driver is on the way to the pickup location.' },
  started:    { title: 'Ride Started',      body: 'Your ride has begun.' },
  completed:  { title: 'Ride Completed',    body: 'Thank you for riding with FemDrive!' },
  cancelled:  { title: 'Ride Cancelled',    body: 'The ride has been cancelled.' },
  no_drivers: { title: 'No Drivers Available', body: 'Sorry, no drivers are currently available.' },
};

const THRESHOLD = 12 * 60 * 60 * 1000; // 12 hours

const app = express();
app.use(express.json());

// --- Notify Rider Status Update ---
app.post('/notify/status', async (req, res) => {
  const { riderId, status, rideId } = req.body;
  if (!riderId || !status || !rideId || !statuses[status]) {
    return res.status(400).json({ error: 'Missing or invalid parameters.' });
  }

  try {
    const userDoc = await db.collection('users').doc(riderId).get();
    const token = userDoc.data()?.fcmToken;
    if (!token) return res.status(404).json({ error: 'No FCM token for rider' });

    await admin.messaging().send({
      token,
      notification: statuses[status],
      data: { status, rideId },
    });

    res.json({ success: true });
  } catch (err) {
    console.error('Status notification failed:', err);
    res.status(500).json({ error: err.message });
  }
});

// --- Pair Driver to Ride & Notify ---
app.post('/pair/ride', async (req, res) => {
  const { rideId, pickupLat, pickupLng } = req.body;
  if (!rideId || !pickupLat || !pickupLng) {
    return res.status(400).json({ error: 'Missing ride or coordinates.' });
  }

  try {
    const rideSnap = await db.collection('rides').doc(rideId).get();
    const ride = rideSnap.data();
    if (ride?.driverId) return res.json({ message: 'Already assigned' });

    const pickupHash = ngeohash.encode(pickupLat, pickupLng, 9);
    const neighbors = [...ngeohash.neighbors(pickupHash), pickupHash];
    let drivers = [];

    for (const h of neighbors) {
      const q = await realDb
        .child('drivers_online')
        .orderByChild('geohash')
        .startAt(h)
        .endAt(h + '\uf8ff')
        .once('value');

      q.forEach(c => drivers.push(c.val()));
    }

    if (drivers.length === 0) {
      await db.collection('rides').doc(rideId).update({ status: 'no_drivers' });
      return res.json({ message: 'No drivers found' });
    }

    drivers.sort((a, b) => {
      const da = haversine({ lat: a.lat, lon: a.lng }, { lat: pickupLat, lon: pickupLng });
      const dbDist = haversine({ lat: b.lat, lon: b.lng }, { lat: pickupLat, lon: pickupLng });
      return da - dbDist;
    });

    const tokens = [];
    for (const driver of drivers) {
      const userDoc = await db.collection('users').doc(driver.uid).get();
      const token = userDoc.data()?.fcmToken;
      if (!token) continue;

      tokens.push(token);
      await admin.messaging().send({
        token,
        notification: {
          title: 'Ride Request Nearby',
          body: `Pickup near lat:${pickupLat.toFixed(4)}, lng:${pickupLng.toFixed(4)}`,
        },
        data: { rideId, action: 'NEW_REQUEST' },
      });
      await new Promise(r => setTimeout(r, 20000));
    }

    res.json({ success: true, tokens });
  } catch (err) {
    console.error('Pairing failed:', err);
    res.status(500).json({ error: err.message });
  }
});

// --- Emergency Handler ---
app.post('/emergency', async (req, res) => {
  const { rideId, reportedBy, otherUid } = req.body;
  if (!rideId || !reportedBy || !otherUid) {
    return res.status(400).json({ error: 'Missing params.' });
  }

  try {
    await db.collection('emergencies').add({
      rideId, reportedBy, otherUid, timestamp: admin.firestore.FieldValue.serverTimestamp()
    });
    await db.collection('users').doc(otherUid).update({ verified: false });
    await db.collection('rides').doc(rideId).update({ status: 'cancelled' });
    await db.collection('mail').add({
      to: 'franklnwrldd@gmail.com',
      subject: '🚨 Emergency Triggered',
      text: `User ${reportedBy} triggered emergency on ride ${rideId}. Affected: ${otherUid}`
    });
    res.json({ success: true });
  } catch (err) {
    console.error('Emergency failed:', err);
    res.status(500).json({ error: err.message });
  }
});

// --- Driver Accept Race Protection ---
app.post('/accept/driver', async (req, res) => {
  const { rideId, driverUid } = req.body;
  if (!rideId || !driverUid) {
    return res.status(400).json({ error: 'Missing params.' });
  }

  const rideRef = db.collection('rides').doc(rideId);
  try {
    const result = await db.runTransaction(async t => {
      const d = await t.get(rideRef);
      if (d.exists && d.data().driverId) return { assigned: false };

      t.update(rideRef, { driverId: driverUid, status: 'accepted' });
      return { assigned: true };
    });

    res.json(result);
  } catch (err) {
    console.error('Accept driver failed:', err);
    res.status(500).json({ error: err.message });
  }
});

// --- Cleanup Stale Drivers ---
async function cleanupOldDrivers() {
  const snap = await realDb.child('drivers_online').once('value');
  const now = Date.now();
  const updates = {};
  snap.forEach(c => {
    const data = c.val();
    const last = data.updatedAt;
    if (now - last > THRESHOLD) updates[c.key] = null;
  });
  if (Object.keys(updates).length) {
    await realDb.child('drivers_online').update(updates);
    console.log('Cleaned stale drivers:', Object.keys(updates));
  }
}

// schedule cleanup every 15min
setInterval(cleanupOldDrivers, 15 * 60 * 1000);

// --- Start Server ---
const PORT = process.env.PORT || 5001;
app.listen(PORT, () => console.log(`Notification server listening on :${PORT}`));
