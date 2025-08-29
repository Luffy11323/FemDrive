import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';

class NearbyDriversService {
  final _fire = FirebaseFirestore.instance;

  Future<List<Map<String, dynamic>>> fetchNearbyDrivers(
    LatLng center,
    double radiusKm,
  ) async {
    try {
      final snapshot = await _fire
          .collection('users')
          .where('role', isEqualTo: 'driver')
          .where('verified', isEqualTo: true)
          .where('lastLocation', isNotEqualTo: null)
          .get();

      final drivers = <Map<String, dynamic>>[];
      for (var doc in snapshot.docs) {
        final data = doc.data();
        final geoPoint = data['lastLocation'] as GeoPoint?;
        if (geoPoint == null) continue;

        final driverPos = LatLng(geoPoint.latitude, geoPoint.longitude);
        final distance =
            Geolocator.distanceBetween(
              center.latitude,
              center.longitude,
              driverPos.latitude,
              driverPos.longitude,
            ) /
            1000;

        if (distance <= radiusKm) {
          drivers.add({
            'uid': doc.id,
            'position': driverPos,
            'name': data['username'] ?? 'Unknown Driver',
          });
        }
      }
      return drivers;
    } catch (e) {
      if (kDebugMode) {
        print('Error fetching nearby drivers: $e');
      }
      return [];
    }
  }
}
