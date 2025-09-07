// nearby_drivers_service.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:logger/logger.dart';

class NearbyDriversService {
  final _firestore = FirebaseFirestore.instance;
  final _rtdb = FirebaseDatabase.instance.ref();
  final _logger = Logger();

  // === Config ===
  static const double _searchRadiusKm = 5.0;
  static const int _freshMs =
      60 * 1000; // consider driver "online" if updated within last 60s

  /// --------------------------------------------------------------------------
  /// A) CURRENT (Firestore) – unchanged behavior
  ///    Reads driver docs (role=driver, isOnline=true) and filters by GeoPoint.
  ///    NOTE: If you don't have an 'isOnline' bool, prefer using streamNearbyDriversFast().
  /// --------------------------------------------------------------------------
  Stream<List<Map<String, dynamic>>> streamNearbyDrivers(LatLng riderLocation) {
    return _firestore
        .collection('users')
        .where('role', isEqualTo: 'driver')
        .where('isOnline', isEqualTo: true) // keep for backward compat
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
  ///     1) Watches Firestore for driver metadata (name, rating, type, etc.).
  ///     2) Watches RTDB /drivers_online for {lat,lng,updatedAt[,geohash]} live.
  ///     3) Merges both and filters by freshness + Haversine radius (<= 5 km),
  ///        using a progressive sweep from 2km → 5km until drivers are found.
  ///
  /// Usage in UI: NearbyDriversService().streamNearbyDriversFast(center)
  /// ----------------------------------------------------------------------------
  Stream<List<Map<String, dynamic>>> streamNearbyDriversFast(
    LatLng riderLocation,
  ) {
    final controller = StreamController<List<Map<String, dynamic>>>.broadcast();

    QuerySnapshot<Map<String, dynamic>>? latestFs; // driver metadata
    DatabaseEvent? latestRtdb; // live locations: drivers_online

    void emitIfReady() {
      if (latestFs == null || latestRtdb == null) return;

      // --- Build metadata map by driverId from Firestore ---
      final metaById = <String, Map<String, dynamic>>{};
      for (final doc in latestFs!.docs) {
        metaById[doc.id] = doc.data();
      }

      // --- Read RTDB drivers_online snapshot ---
      final raw = latestRtdb!.snapshot.value;
      final locMap = (raw is Map ? raw.cast<dynamic, dynamic>() : const {})
          .map<String, Map<String, dynamic>>(
            (k, v) =>
                MapEntry(k.toString(), (v as Map).cast<String, dynamic>()),
          );

      final nowMs = DateTime.now().millisecondsSinceEpoch;

      // Progressive radius: 2km → 5km
      double currentRadius = 2.0;
      List<Map<String, dynamic>> candidates = [];

      // These counters are for logging insight
      int staleSkipped = 0;
      int metaMissing = 0;

      while (currentRadius <= _searchRadiusKm && candidates.isEmpty) {
        final temp = <Map<String, dynamic>>[];

        locMap.forEach((driverId, m) {
          final lat = (m['lat'] as num?)?.toDouble();
          final lng = (m['lng'] as num?)?.toDouble();
          final updatedAt = (m['updatedAt'] as num?)?.toInt() ?? 0;
          if (lat == null || lng == null) return;

          // Freshness gate
          if ((nowMs - updatedAt) > _freshMs) {
            staleSkipped++;
            return;
          }

          final meta = metaById[driverId];
          if (meta == null) {
            metaMissing++;
            // Could still show, but we’ll skip to keep labels consistent
            return;
          }

          // Distance check with Haversine
          final distanceKm = _haversineKm(
            riderLocation.latitude,
            riderLocation.longitude,
            lat,
            lng,
          );

          if (distanceKm <= currentRadius) {
            temp.add({
              'id': driverId,
              'username': meta['username'] ?? 'Unknown Driver',
              'location': LatLng(lat, lng),
              'rideType': meta['availableRideType'] ?? 'Economy',
              'rating': meta['rating'] ?? 0,
              'distanceKm': distanceKm,
              'updatedAt': updatedAt,
            });
          }
        });

        if (temp.isNotEmpty) {
          candidates = temp;
        } else {
          currentRadius += 1.0; // expand search window
        }
      }

      // Sort nearest first (stable UI)
      candidates.sort(
        (a, b) =>
            (a['distanceKm'] as double).compareTo(b['distanceKm'] as double),
      );

      // Final summary log
      if (kDebugMode) {
        print(
          '[NearbyDriversService] (FAST) RTDB /drivers_online total=${locMap.length} '
          'emitting=${candidates.length} within<=${currentRadius.clamp(2.0, _searchRadiusKm)}km '
          '(fresh<=${_freshMs}ms, staleSkipped=$staleSkipped, metaMissing=$metaMissing)',
        );
      }

      controller.add(candidates);
    }

    // Firestore: driver metadata (no isOnline filter; freshness comes from RTDB)
    final subA = _firestore
        .collection('users')
        .where('role', isEqualTo: 'driver')
        .snapshots()
        .listen((snap) {
          latestFs = snap;
          emitIfReady();
        });

    // RTDB: live presence & location for drivers
    final subB = _rtdb.child('drivers_online').onValue.listen((evt) {
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

// --- Haversine helper (used by FAST stream) ---
double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const R = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180.0;
  final dLon = (lon2 - lon1) * math.pi / 180.0;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) *
          math.cos(lat2 * math.pi / 180.0) *
          math.sin(dLon / 2) *
          math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return R * c;
}
