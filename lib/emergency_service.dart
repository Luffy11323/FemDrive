import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:logger/logger.dart';

class EmergencyService {
  static final _fire = FirebaseFirestore.instance;
  static final _rtdb = FirebaseDatabase.instance.ref();
  static final _logger = Logger();

  /// Trigger SOS during a ride
  static Future<void> sendEmergency({
    required String rideId,
    required String currentUid,
    required String otherUid,
  }) async {
    try {
      final batch = _fire.batch();

      // Mark other user suspicious
      batch.update(_fire.collection('users').doc(otherUid), {
        'verified': false,
      });

      // Cancel ride with SOS flag
      batch.update(_fire.collection('rides').doc(rideId), {
        'status': 'cancelled',
        'emergencyTriggered': true,
        'cancelledBy': currentUid,
        'cancelReason': 'emergency',
        'cancelledAt': FieldValue.serverTimestamp(),
      });

      await batch.commit();

      // Remove ride from RTDB
      final paths = [
        'rides/$currentUid/$rideId',
        'rides/pending/a/$rideId',
        'rides/pending/b/$rideId',
      ];
      for (final path in paths) {
        await _rtdb.child(path).remove();
      }

      // Notify admin
      await _rtdb.child('notifications/admin').push().set({
        'type': 'emergency',
        'rideId': rideId,
        'reportedBy': currentUid,
        'otherUid': otherUid,
        'timestamp': ServerValue.timestamp,
      });

      _logger.i('Emergency triggered for ride $rideId by $currentUid');
    } catch (e) {
      _logger.e('Failed to send emergency: $e');
      rethrow;
    }
  }
}
