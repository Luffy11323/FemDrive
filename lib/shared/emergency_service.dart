import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:logger/logger.dart';

// Import these from your driver_services.dart or define accordingly
import '../driver/driver_services.dart' show AppPaths, AppFields, RideStatus;

class EmergencyService {
  static final _fire = FirebaseFirestore.instance;
  static final _rtdb = FirebaseDatabase.instance.ref();
  static final _logger = Logger();

  /// Trigger emergency during a ride: cancel ride, unverify rider, log full report,
  /// notify rider and admin, and cleanup notifications.
  static Future<void> sendEmergency({
    required String rideId,
    required String currentUid, // driver
    required String otherUid, // rider
  }) async {
    try {
      // 1) Snapshot the current ride for admin report
      final rideRef = _fire.collection(AppPaths.ridesCollection).doc(rideId);
      final rideSnap = await rideRef.get();
      final rideData = rideSnap.data() ?? <String, dynamic>{};

      // 2) Firestore batch: unverify rider + cancel ride (with SOS metadata)
      final batch = _fire.batch();

      final riderRef = _fire.collection('users').doc(otherUid);
      batch.update(riderRef, {AppFields.verified: false});

      batch.update(rideRef, {
        AppFields.status: RideStatus.cancelled,
        'emergencyTriggered': true,
        'cancelledBy': currentUid,
        'cancelReason': 'emergency',
        AppFields.cancelledAt: FieldValue.serverTimestamp(),
      });

      // 3) Admin emergency report in Firestore
      final adminReportRef = _fire.collection('emergencies').doc();
      batch.set(adminReportRef, {
        'type': 'driver_emergency',
        AppFields.rideId: rideId,
        AppFields.reportedBy: currentUid,
        AppFields.otherUid: otherUid,
        'createdAt': FieldValue.serverTimestamp(),
        'rideSnapshot': {
          ...rideData,
          // Explicit fields for easier filtering
          AppFields.pickup: rideData[AppFields.pickup],
          AppFields.dropoff: rideData[AppFields.dropoff],
          AppFields.pickupLat: rideData[AppFields.pickupLat],
          AppFields.pickupLng: rideData[AppFields.pickupLng],
          AppFields.dropoffLat: rideData[AppFields.dropoffLat],
          AppFields.dropoffLng: rideData[AppFields.dropoffLng],
          AppFields.fare: rideData[AppFields.fare],
          'rideType': rideData['rideType'],
          AppFields.riderId: rideData[AppFields.riderId],
          AppFields.driverId: rideData[AppFields.driverId],
        },
      });

      await batch.commit();

      // 4) RTDB live node: mark ride as cancelled (do not delete)
      await _rtdb.child('${AppPaths.ridesLive}/$rideId').update({
        AppFields.status: RideStatus.cancelled,
        'emergencyTriggered': true,
        'updatedAt': ServerValue.timestamp,
      });

      // 5) Remove ride from pending queues (if applicable)
      try {
        await _rtdb.child('${AppPaths.ridesPendingA}/$rideId').remove();
        await _rtdb.child('${AppPaths.ridesPendingB}/$rideId').remove();
      } catch (_) {
        // Ignore cleanup errors
      }

      // 6) Fan-out delete driver notifications related to this ride
      try {
        final notifsSnap = await _rtdb
            .child(AppPaths.driverNotifications)
            .get();
        if (notifsSnap.exists && notifsSnap.value is Map) {
          final updates = <String, Object?>{};
          final map = notifsSnap.value as Map;
          map.forEach((driverKey, ridesMap) {
            if (ridesMap is Map && ridesMap.containsKey(rideId)) {
              updates['${AppPaths.driverNotifications}/$driverKey/$rideId'] =
                  null;
            }
          });
          if (updates.isNotEmpty) await _rtdb.update(updates);
        }
      } catch (e) {
        _logger.w('[Emergency] driver notifications cleanup failed: $e');
      }

      // 7) Notify rider of cancellation in RTDB
      await _rtdb.child('${AppPaths.notifications}/$otherUid').push().set({
        AppFields.type: 'ride_cancelled',
        AppFields.rideId: rideId,
        'reason': 'emergency',
        AppFields.timestamp: ServerValue.timestamp,
      });

      // 8) Notify admin channel in RTDB
      await _rtdb.child('notifications/admin').push().set({
        AppFields.type: 'emergency',
        AppFields.rideId: rideId,
        AppFields.reportedBy: currentUid,
        AppFields.otherUid: otherUid,
        AppFields.timestamp: ServerValue.timestamp,
      });

      _logger.i('Emergency triggered for ride $rideId by $currentUid');
    } catch (e, st) {
      _logger.e('Failed to send emergency: $e', error: e, stackTrace: st);
      rethrow;
    }
  }
}
