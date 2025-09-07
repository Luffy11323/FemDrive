// nearby_drivers_service.dart
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:logger/logger.dart';

class NearbyDriversService {
  final _firestore = FirebaseFirestore.instance;
  final _rtdb = FirebaseDatabase.instance.ref();
  final _logger = Logger();
  static const double _searchRadiusKm = 5.0;

  /// --------------------------------------------------------------------------
  /// A) CURRENT (Firestore) – unchanged behavior
  ///    Reads driver docs (role=driver, isOnline=true) and filters by GeoPoint.
  /// --------------------------------------------------------------------------
  Stream<List<Map<String, dynamic>>> streamNearbyDrivers(LatLng riderLocation) {
    print(
      '[NearbyDriversService] Streaming nearby drivers from Firestore for location: $riderLocation',
    );

    return _firestore
        .collection('users')
        .where('role', isEqualTo: 'driver')
        .where('isOnline', isEqualTo: true)
        .snapshots()
        .map((snapshot) {
          final filtered = snapshot.docs.where((doc) {
            final data = doc.data();
            final location = data['location'] as GeoPoint?;
            if (location == null) return false;

            final distanceKm =
                Geolocator.distanceBetween(
                  riderLocation.latitude,
                  riderLocation.longitude,
                  location.latitude,
                  location.longitude,
                ) /
                1000.0;

            return distanceKm <= _searchRadiusKm;
          }).toList();

          print(
            '[NearbyDriversService] Firestore nearby drivers in radius: ${filtered.length}',
          );

          return filtered.map((doc) {
            final data = doc.data();
            return {
              'id': doc.id,
              'username': data['username'] ?? 'Unknown Driver',
              'location': data['location'],
              'rideType': data['availableRideType'] ?? 'Economy',
              'rating': data['rating'] ?? 0,
            };
          }).toList();
        });
  }

  /// ----------------------------------------------------------------------------
  /// B) FAST (RTDB) – recommended for live markers
  ///     1) Watches Firestore for online drivers (metadata).
  ///     2) Watches RTDB /driverLocations for {lat,lng} in real time.
  ///     3) Merges both and filters by radius using the RTDB location.
  ///
  /// Usage: replace the call site to use this method for faster updates:
  ///   NearbyDriversService().streamNearbyDriversFast(center)
  /// ----------------------------------------------------------------------------
  Stream<List<Map<String, dynamic>>> streamNearbyDriversFast(
    LatLng riderLocation,
  ) {
    print(
      '[NearbyDriversService] Entering streamNearbyDriversFast with location: $riderLocation',
    );

    final controller = StreamController<List<Map<String, dynamic>>>.broadcast();

    QuerySnapshot<Map<String, dynamic>>? latestFs;
    DatabaseEvent? latestRtdb;

    void emitIfReady() {
      if (latestFs == null || latestRtdb == null) return;

      final metaById = <String, Map<String, dynamic>>{};
      for (final doc in latestFs!.docs) {
        metaById[doc.id] = doc.data();
      }

      final raw = latestRtdb!.snapshot.value;
      final locMap = (raw is Map ? raw.cast<dynamic, dynamic>() : const {}).map(
        (k, v) => MapEntry(k.toString(), (v as Map).cast<String, dynamic>()),
      );

      final out = <Map<String, dynamic>>[];

      locMap.forEach((driverId, m) {
        final lat = (m['lat'] as num?)?.toDouble();
        final lng = (m['lng'] as num?)?.toDouble();
        if (lat == null || lng == null) return;

        final meta = metaById[driverId];
        if (meta == null) return;

        final distanceKm =
            Geolocator.distanceBetween(
              riderLocation.latitude,
              riderLocation.longitude,
              lat,
              lng,
            ) /
            1000.0;

        if (distanceKm <= _searchRadiusKm) {
          out.add({
            'id': driverId,
            'username': meta['username'] ?? 'Unknown Driver',
            'location': LatLng(lat, lng),
            'rideType': meta['availableRideType'] ?? 'Economy',
            'rating': meta['rating'] ?? 0,
            'distanceKm': distanceKm,
          });
        }
      });

      print(
        '[NearbyDriversService] Nearby drivers in RTDB after merge: ${out.length}',
      );
      controller.add(out);
    }

    final subA = _firestore
        .collection('users')
        .where('role', isEqualTo: 'driver')
        .where('isOnline', isEqualTo: true)
        .snapshots()
        .listen((snap) {
          latestFs = snap;
          emitIfReady();
        });

    final subB = _rtdb.child('driverLocations').onValue.listen((evt) {
      latestRtdb = evt;
      emitIfReady();
    });

    controller.onCancel = () {
      subA.cancel();
      subB.cancel();
    };

    return controller.stream;
  }

  /// 🔹 Assign driver atomically (Firestore transactional ownership)
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
    } catch (e, st) {
      _logger.e('Failed to assign driver: $e', stackTrace: st);
      rethrow;
    }
  }
}
