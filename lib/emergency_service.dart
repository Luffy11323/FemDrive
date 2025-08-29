import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'driver/driver_services.dart';

class EmergencyService {
  static final _fire = FirebaseFirestore.instance;
  static final _rtdb = FirebaseDatabase.instance.ref();

  static Future<void> sendEmergency({
    required String rideId,
    required String currentUid,
    required String otherUid,
  }) async {
    try {
      await _fire.collection('users').doc(otherUid).update({
        AppFields.verified: false,
      });
      await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
        AppFields.status: RideStatus.cancelled,
        AppFields.emergencyTriggered: true,
      });
      await _rtdb.child('${AppPaths.ridesPendingA}/$rideId').remove();
      await _rtdb.child('${AppPaths.ridesPendingB}/$rideId').remove();

      // Notify admin via RTDB
      await _rtdb.child('${AppPaths.notifications}/admin').push().set({
        AppFields.type: 'emergency',
        AppFields.rideId: rideId,
        AppFields.reportedBy: currentUid,
        AppFields.otherUid: otherUid,
        AppFields.timestamp: ServerValue.timestamp,
      });
    } catch (e) {
      throw Exception('Failed to send emergency: $e');
    }
  }
}
