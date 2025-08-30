// nearby_drivers_service.dart
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:logger/logger.dart';

class NearbyDriversService {
  final _firestore = FirebaseFirestore.instance;
  final _logger = Logger();
  static const double _searchRadiusKm = 5.0;

  /// 🔹 Live stream of nearby drivers within radius
  Stream<List<Map<String, dynamic>>> streamNearbyDrivers(LatLng riderLocation) {
    return _firestore
        .collection('users')
        .where('role', isEqualTo: 'driver')
        .where('isOnline', isEqualTo: true)
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .where((doc) {
                final data = doc.data();
                final driverLocation = data['location'] as GeoPoint?;
                if (driverLocation == null) return false;

                final distance =
                    Geolocator.distanceBetween(
                      riderLocation.latitude,
                      riderLocation.longitude,
                      driverLocation.latitude,
                      driverLocation.longitude,
                    ) /
                    1000;
                return distance <= _searchRadiusKm;
              })
              .map((doc) {
                final data = doc.data();
                return {
                  'id': doc.id,
                  'username': data['username'] ?? 'Unknown Driver',
                  'location': data['location'],
                  'rideType': data['availableRideType'] ?? 'Economy',
                  'rating': data['rating'] ?? 0,
                };
              })
              .toList();
        });
  }

  /// 🔹 Assign driver atomically
  Future<void> assignDriver(String rideId, String driverId) async {
    final rideRef = _firestore.collection('rides').doc(rideId);
    final driverRef = _firestore.collection('users').doc(driverId);

    try {
      await _firestore.runTransaction((txn) async {
        final rideSnap = await txn.get(rideRef);
        if (!rideSnap.exists || rideSnap['status'] != 'pending') {
          throw Exception('Ride no longer available');
        }

        final driverSnap = await txn.get(driverRef);
        if (!driverSnap.exists || driverSnap['currentRideId'] != null) {
          throw Exception('Driver already busy');
        }

        txn.update(rideRef, {'driverId': driverId, 'status': 'accepted'});
        txn.update(driverRef, {'currentRideId': rideId});
      });
    } catch (e) {
      _logger.e('Failed to assign driver: $e');
      rethrow;
    }
  }
}
