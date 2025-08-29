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
        final driver = await _firestore.collection('users').doc(driverId).get();
        if (driver.exists) {
          final driverData = driver.data()!;
          driverInfo =
              '${driverData['username']} (${driverData['vehicle']?['make']} ${driverData['vehicle']?['model']}, Plate: ${driverData['vehicle']?['plateNumber']})';
        }
      }

      final shareText =
          '''
Ride Status: $status
From: $pickup
To: $dropoff
Driver: $driverInfo
Track: https://yourapp.com/track/$rideId
''';

      // ignore: deprecated_member_use
      await Share.share(shareText, subject: 'My Ride Status');
    } catch (e) {
      _logger.e('Failed to share trip status: $e');
      throw Exception('Failed to share trip status: $e');
    }
  }
}
