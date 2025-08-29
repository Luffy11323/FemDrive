import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:logger/logger.dart';

class NearbyDriversService {
  final _firestore = FirebaseFirestore.instance;
  final _logger = Logger();
  static const double _searchRadiusKm = 5.0; // 5 km radius

  Future<List<Map<String, dynamic>>> getNearbyDrivers(
    LatLng riderLocation,
    LatLng latLng,
  ) async {
    try {
      final drivers = await _firestore
          .collection('users')
          .where('role', isEqualTo: 'driver')
          .where('isOnline', isEqualTo: true)
          .get();

      final nearbyDrivers = <Map<String, dynamic>>[];
      for (var doc in drivers.docs) {
        final data = doc.data();
        final driverLocation = data['location'] as GeoPoint?;
        if (driverLocation == null) continue;

        final distance =
            Geolocator.distanceBetween(
              riderLocation.latitude,
              riderLocation.longitude,
              driverLocation.latitude,
              driverLocation.longitude,
            ) /
            1000; // Convert to km

        if (distance <= _searchRadiusKm) {
          nearbyDrivers.add({
            'uid': doc.id,
            'username': data['username'] ?? 'Unknown Driver',
            'location': driverLocation,
            'rideType': data['availableRideType'] ?? 'Economy',
          });
        }
      }
      return nearbyDrivers;
    } catch (e) {
      _logger.e('Failed to fetch nearby drivers: $e');
      return [];
    }
  }

  Future<void> assignDriver(String rideId, String driverId) async {
    try {
      await _firestore.collection('rides').doc(rideId).update({
        'driverId': driverId,
        'status': 'accepted',
      });
      await _firestore.collection('users').doc(driverId).update({
        'currentRideId': rideId,
      });
    } catch (e) {
      _logger.e('Failed to assign driver: $e');
      throw Exception('Unable to assign driver: $e');
    }
  }
}
