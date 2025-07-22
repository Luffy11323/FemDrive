import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

class EmergencyService {
  static final _fire = FirebaseFirestore.instance;
  static final _fn = FirebaseFunctions.instance;

  /// Sends an emergency alert to backend:
  /// - Marks the reported user as unverified
  /// - Cancels the ride
  /// - Triggers the Cloud Function (`handleEmergency`)
  static Future<void> sendEmergency({
    required String rideId,
    required String currentUid,
    required String otherUid,
  }) async {
    try {
      // 🔒 Mark the reported user as unverified
      await _fire.collection('users').doc(otherUid).update({'verified': false});

      // 🚫 Cancel the ride
      await _fire.collection('rides').doc(rideId).update({
        'status': 'cancelled',
      });

      // 📡 Trigger backend Cloud Function to log & notify
      final result = await _fn.httpsCallable('handleEmergency').call({
        'rideId': rideId,
        'reportedBy': currentUid,
        'otherUid': otherUid,
      });

      if (!(result.data['success'] as bool)) {
        throw Exception('Emergency function returned failure');
      }
    } catch (e) {
      // You can log this to Sentry or Firebase Crashlytics
      throw Exception('Failed to report emergency: $e');
    }
  }
}
