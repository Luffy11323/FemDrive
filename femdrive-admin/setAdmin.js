const admin = require('firebase-admin');
const serviceAccount = require('./serviceAccountKey.json');

admin.initializeApp({
  credential: admin.credential.cert(serviceAccount),
});

const uid = 'Cjpo9BdhsehHZSL7bmDogeOJk6I2'; // <-- Replace with your actual UID

admin.auth().setCustomUserClaims(uid, { admin: true })
  .then(() => {
    console.log(`✅ Admin claim set for UID: ${uid}`);
  })
  .catch((error) => {
    console.error('❌ Failed to set admin claim:', error);
  });
