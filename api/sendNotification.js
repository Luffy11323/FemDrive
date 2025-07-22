import admin from 'firebase-admin';

const serviceAccount = JSON.parse(process.env.FIREBASE_ADMIN_KEY);

if (!admin.apps.length) {
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
  });
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).end('Method Not Allowed');
  }

  const { token, title, body, data } = req.body;

  if (!token || !title || !body) {
    return res.status(400).json({ error: 'Missing required fields' });
  }

  try {
    await admin.messaging().send({
      token,
      notification: { title, body },
      data: data || {},
    });

    return res.status(200).json({ success: true });
  } catch (err) {
    console.error('FCM Error:', err);
    return res.status(500).json({ error: 'Failed to send notification' });
  }
}
