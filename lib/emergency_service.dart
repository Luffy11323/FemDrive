import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:logger/logger.dart';

class EmergencyService {
  static final _fire = FirebaseFirestore.instance;
  static final _rtdb = FirebaseDatabase.instance.ref();
  static final _logger = Logger();

  static Future<void> sendEmergency({
    required String rideId,
    required String currentUid,
    required String otherUid,
  }) async {
    try {
      // Update Firestore to mark other user as unverified and cancel ride
      await _fire.collection('users').doc(otherUid).update({'verified': false});
      await _fire.collection('rides').doc(rideId).update({
        'status': 'cancelled',
        'emergencyTriggered': true,
      });

      // Remove ride from RTDB pending queues
      await _rtdb.child('rides/$currentUid/$rideId').remove();
      await _rtdb.child('rides/pending/a/$rideId').remove();
      await _rtdb.child('rides/pending/b/$rideId').remove();

      // Notify admin via RTDB
      await _rtdb.child('notifications/admin').push().set({
        'type': 'emergency',
        'rideId': rideId,
        'reportedBy': currentUid,
        'otherUid': otherUid,
        'timestamp': ServerValue.timestamp,
      });
    } catch (e) {
      _logger.e('Failed to send emergency: $e');
      throw Exception('Failed to send emergency: $e');
    }
  }
}
