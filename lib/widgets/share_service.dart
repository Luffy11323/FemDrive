import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:logger/logger.dart';
import 'package:share_plus/share_plus.dart';

class ShareService {
  final _firestore = FirebaseFirestore.instance;
  final _logger = Logger();

  Future<void> shareTripStatus({
    required String rideId,
    required String userId,
  }) async {
    try {
      final ride = await _firestore.collection('rides').doc(rideId).get();
      if (!ride.exists) {
        throw Exception('Ride not found');
      }

      final data = ride.data()!;
      final pickup = data['pickup'] ?? 'Unknown';
      final dropoff = data['dropoff'] ?? 'Unknown';
      final status = data['status'] ?? 'Unknown';
      final driverId = data['driverId'] as String?;
      String driverInfo = 'Not assigned';

      if (driverId != null) {
        final driverDoc = await _firestore
            .collection('users')
            .doc(driverId)
            .get();
        if (driverDoc.exists) {
          final driverData = driverDoc.data();
          driverInfo =
              '${driverData?['username'] ?? 'Unknown Driver'} '
              '(${driverData?['vehicle']?['make'] ?? 'Unknown'} '
              '${driverData?['vehicle']?['model'] ?? ''})';
        }
      }

      final message =
          'Trip Status:\n'
          'Pickup: $pickup\n'
          'Dropoff: $dropoff\n'
          'Status: $status\n'
          'Driver: $driverInfo\n'
          'Ride ID: $rideId\n'
          'Shared by: $userId';

      // ignore: deprecated_member_use
      await Share.share(message, subject: 'My Ride Trip Status');
    } catch (e) {
      _logger.e('Failed to share trip status: $e');
      throw Exception('Unable to share trip status: $e');
    }
  }
}
