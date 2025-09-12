import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:femdrive/shared/notifications.dart';
// keep if used elsewhere
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:dart_geohash/dart_geohash.dart';

import 'package:femdrive/location/directions_service.dart';
import 'package:femdrive/shared/emergency_service.dart';
// ignore: unused_import
import 'package:http/http.dart' as http; // (safe even if unused elsewhere)
import 'package:femdrive/location/directions_http.dart';

class AppPaths {
  static const driversOnline = 'drivers_online';
  static const ridesPendingA = 'rides_pending';
  static const ridesPendingB = 'rideRequests';
  static const ridesCollection = 'rides';
  static const ratingsCollection = 'ratings';
  static const locationsCollection = 'locations';
  static const driverLocations = 'driverLocations'; // RTDB live marker path
  static const notifications = 'notifications';
  static const messages = 'messages';
  static const driverNotifications = 'driver_notifications';
  static const ridesLive = 'ridesLive';
}

class AppFields {
  static const uid = 'uid';
  static const lat = 'lat';
  static const lng = 'lng';
  static const geohash = 'geohash';
  static const updatedAt = 'updatedAt';
  static const status = 'status';
  static const fare = 'fare';
  static const driverId = 'driverId';
  static const riderId = 'riderId';
  static const pickup = 'pickup';
  static const dropoff = 'dropoff';
  static const pickupLat = 'pickupLat';
  static const pickupLng = 'pickupLng';
  static const dropoffLat = 'dropoffLat';
  static const dropoffLng = 'dropoffLng';
  static const driverLat = 'driverLat';
  static const driverLng = 'driverLng';
  static const riderLat = 'riderLat';
  static const riderLng = 'riderLng';
  static const acceptedAt = 'acceptedAt';
  static const arrivingAt = 'arrivingAt';
  static const startedAt = 'startedAt';
  static const completedAt = 'completedAt';
  static const cancelledAt = 'cancelledAt';
  static const rating = 'rating';
  static const comment = 'comment';
  static const verified = 'verified';
  static const username = 'username';
  static const phone = 'phone';
  static const fcmToken = 'fcmToken';
  static const senderId = 'senderId';
  static const text = 'text';
  static const timestamp = 'timestamp';
  static const type = 'type';
  static const emergencyTriggered = 'emergencyTriggered';
  static const paymentStatus = 'paymentStatus';
  static const finalFare = 'finalFare';
  static const rideId = 'rideId';
  static const reportedBy = 'reportedBy';
  static const otherUid = 'otherUid';
  static const etaSecs = 'etaSecs';
}

/// Unified (matches DriverDashboard)
class RideStatus {
  static const pending = 'pending';
  static const searching = 'searching';
  static const accepted = 'accepted';
  static const driverArrived = 'driver_arrived';
  static const inProgress = 'in_progress';
  static const onTrip = 'onTrip';
  static const completed = 'completed';
  static const cancelled = 'cancelled';

  static const ongoingSet = <String>{
    accepted,
    driverArrived,
    inProgress,
    onTrip,
  };
}

class OfferType {
  static const rideAccepted = 'ride_accepted';
  static const counterFare = 'counter_fare';
  static const rideDeclined = 'ride_declined';
  static const statusUpdate = 'status_update';
  static const rideCompleted = 'ride_completed';
}

const _darkGuidanceStyle = '''
[
  // General map geometry background
  {
    "elementType": "geometry",
    "stylers": [
      { "color": "#f7f9fb" } // Light neutral tone for background
    ]
  },
  {
    "elementType": "labels.icon",
    "stylers": [
      { "visibility": "off" } // No icons for cleaner look
    ]
  },
  {
    "elementType": "labels.text.fill",
    "stylers": [
      { "color": "#3b4a5a" } // Dark gray-blue for good legibility
    ]
  },
  {
    "elementType": "labels.text.stroke",
    "stylers": [
      { "color": "#ffffff" } // White stroke improves contrast
    ]
  },

  // Roads
  {
    "featureType": "road",
    "elementType": "geometry",
    "stylers": [
      { "color": "#e0e4ea" } // Slightly more contrast than background
    ]
  },
  {
    "featureType": "road.arterial",
    "elementType": "geometry",
    "stylers": [
      { "color": "#d0d4dc" } // More prominent for arterial roads
    ]
  },
  {
    "featureType": "road.highway",
    "elementType": "geometry",
    "stylers": [
      { "color": "#c4c9d1" } // Clearly distinguish highways
    ]
  },
  {
    "featureType": "road.highway.controlled_access",
    "elementType": "geometry",
    "stylers": [
      { "color": "#babfc7" } // Highest priority roads — highest contrast
    ]
  },
  {
    "featureType": "road",
    "elementType": "labels.text.fill",
    "stylers": [
      { "color": "#5e6d7a" }
    ]
  },

  // Points of Interest
  {
    "featureType": "poi",
    "elementType": "geometry",
    "stylers": [
      { "color": "#eef2f7" } // Subtle but visible
    ]
  },
  {
    "featureType": "poi.park",
    "elementType": "geometry",
    "stylers": [
      { "color": "#e3f2e0" } // Soft green for parks
    ]
  },
  {
    "featureType": "poi.park",
    "elementType": "labels.text.fill",
    "stylers": [
      { "color": "#7cac7a" } // Green label text for parks
    ]
  },

  // Transit
  {
    "featureType": "transit.line",
    "elementType": "geometry",
    "stylers": [
      { "color": "#d6dbe4" } // Transit lines muted but visible
    ]
  },

  // Water
  {
    "featureType": "water",
    "elementType": "geometry",
    "stylers": [
      { "color": "#d0e6f8" } // Light blue for water
    ]
  }
]
''';

class GeoCfg {
  static const driverHashPrecision = 9;
  static const popupProximityPrecision = 5;
}

Future<String> getCarMarkerAsset() async {
  final uid = FirebaseAuth.instance.currentUser?.uid;

  if (uid == null) {
    throw Exception("User not logged in");
  }

  final userDoc = await FirebaseFirestore.instance
      .collection('users')
      .doc(uid)
      .get();

  if (!userDoc.exists) {
    throw Exception("User document not found");
  }

  final carType = userDoc.data()?['carType'] ?? 'car'; // default to 'car'

  final asset = (carType.toLowerCase() == 'bike')
      ? 'assets/images/bike_marker.png'
      : 'assets/images/car_marker.png';

  return asset;
}

final googleMapsApiKey = 'AIzaSyCRpuf1w49Ri0gNiiTPOJcSY7iyhyC-2c4';
// Fares config (exported so UI can import it)
final faresConfigProvider = FutureProvider<Map<String, double>>((ref) async {
  final snap = await FirebaseFirestore.instance
      .collection('config')
      .doc('fares')
      .get();
  final data = snap.data();
  return {
    'base': (data?['base'] as num?)?.toDouble() ?? 5.0,
    'perKm': (data?['perKm'] as num?)?.toDouble() ?? 1.0,
  };
});

// RTDB live ride node (shared by rider & driver)
Stream<Map<String, dynamic>?> ridesLiveStream(String rideId) {
  final ref = FirebaseDatabase.instance.ref('${AppPaths.ridesLive}/$rideId');
  return ref.onValue.map((e) {
    final v = e.snapshot.value;
    if (v is Map) return Map<String, dynamic>.from(v.cast<String, dynamic>());
    return null;
  });
}

class PendingRequest {
  final String rideId;
  final String? pickupLabel;
  final String? dropoffLabel;
  final double pickupLat;
  final double pickupLng;
  final double dropoffLat;
  final double dropoffLng;
  final num? fare;
  final Map<String, dynamic> raw;

  PendingRequest({
    required this.rideId,
    required this.pickupLat,
    required this.pickupLng,
    required this.dropoffLat,
    required this.dropoffLng,
    required this.raw,
    this.pickupLabel,
    this.dropoffLabel,
    this.fare,
  });

  factory PendingRequest.fromMap(String id, Map<String, dynamic> map) {
    return PendingRequest(
      rideId: id,
      pickupLabel: map[AppFields.pickup]?.toString(),
      dropoffLabel: map[AppFields.dropoff]?.toString(),
      pickupLat: (map[AppFields.pickupLat] as num?)?.toDouble() ?? 0,
      pickupLng: (map[AppFields.pickupLng] as num?)?.toDouble() ?? 0,
      dropoffLat: (map[AppFields.dropoffLat] as num?)?.toDouble() ?? 0,
      dropoffLng: (map[AppFields.dropoffLng] as num?)?.toDouble() ?? 0,
      fare: (map[AppFields.fare] as num?),
      raw: Map<String, dynamic>.from(map),
    );
  }

  LatLng get pickupPos => LatLng(pickupLat, pickupLng);
  LatLng get dropoffPos => LatLng(dropoffLat, dropoffLng);
}

class DriverLocationService {
  final DatabaseReference _rtdb = FirebaseDatabase.instance.ref();
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  StreamSubscription<Position>? _positionSub;
  final GeoHasher _geoHasher = GeoHasher();

  LocationSettings locationSettings;

  String? _activeRideId;
  bool _isPaused = false;

  // Stream controller for position updates to notify UI (e.g., map camera)
  final StreamController<Position> _positionController =
      StreamController<Position>.broadcast();

  Stream<Position> get positionStream => _positionController.stream;

  DriverLocationService({LocationSettings? locationSettings})
    : locationSettings =
          locationSettings ??
          const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          );

  // Exponential backoff variables
  int _retryAttempt = 0;
  Timer? _retryTimer;

  Future<bool> _checkAndRequestPermissions() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (kDebugMode) {
          debugPrint('[Location] Location permission denied');
        }
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      if (kDebugMode) {
        debugPrint(
          '[Location] Location permission denied forever. Cannot request.',
        );
      }
      return false;
    }
    return true;
  }

  /// Starts listening to location updates and writes them to RTDB and Firestore.
  Future<void> startOnlineMode({String? rideId}) async {
    final user = _auth.currentUser;
    if (user == null) {
      if (kDebugMode) debugPrint('[Location] No logged-in user');
      return;
    }
    final uid = user.uid;
    _activeRideId = rideId;
    _isPaused = false;

    bool permissionGranted = await _checkAndRequestPermissions();
    if (!permissionGranted) return;

    // Initialize background execution
    try {
      final ok = await FlutterBackground.initialize();
      if (ok) {
        await FlutterBackground.enableBackgroundExecution();
        if (kDebugMode) debugPrint('[Location] Background execution enabled');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Location] Background init failed: $e');
    }

    // Cancel existing subscription if any
    await _positionSub?.cancel();

    _positionSub =
        Geolocator.getPositionStream(locationSettings: locationSettings).listen(
          (pos) async {
            if (_isPaused) return;

            _retryAttempt = 0; // reset retry counter on success

            _positionController.add(pos);

            final String hash = _geoHasher.encode(
              pos.latitude,
              pos.longitude,
              precision: GeoCfg.driverHashPrecision,
            );

            try {
              // Debounce writes to every ~3 seconds (adjust as needed)
              _debouncedWrite(uid, pos, hash);
            } catch (e) {
              if (kDebugMode) debugPrint('[Location] Write failed: $e');
            }
          },
          onError: (err) async {
            if (kDebugMode) debugPrint('[Location] Stream error: $err');

            // Retry with exponential backoff
            _retryAttempt++;
            final delaySeconds = _calculateBackoffSeconds(_retryAttempt);
            if (kDebugMode) {
              debugPrint('[Location] Retry in $delaySeconds seconds');
            }

            _retryTimer?.cancel();
            _retryTimer = Timer(Duration(seconds: delaySeconds), () async {
              await _positionSub?.cancel();
              _positionSub = null;
              if (!_isPaused) {
                await startOnlineMode(rideId: _activeRideId);
              }
            });
          },
        );
  }

  // Helper: exponential backoff with max delay cap at 32 seconds
  int _calculateBackoffSeconds(int attempt) {
    return attempt > 5 ? 32 : (1 << attempt);
  }

  // Debounce timer & last write cache to reduce frequent writes
  Timer? _debounceTimer;
  Position? _lastPosition;
  String? _lastGeoHash;
  DateTime? _lastWriteTime;

  void _debouncedWrite(String uid, Position pos, String hash) {
    final now = DateTime.now();

    // If last write < 3 seconds ago and position/geohash didn't change significantly, skip
    if (_lastWriteTime != null &&
        now.difference(_lastWriteTime!).inSeconds < 3 &&
        _lastPosition != null &&
        _isPositionClose(_lastPosition!, pos) &&
        _lastGeoHash == hash) {
      // Skip update
      return;
    }

    // Cancel previous timer, if any
    _debounceTimer?.cancel();

    // Schedule write in 1 second
    _debounceTimer = Timer(const Duration(seconds: 1), () async {
      try {
        // Canonical online presence (RTDB)
        await _rtdb.child('${AppPaths.driversOnline}/$uid').set({
          AppFields.uid: uid,
          AppFields.lat: pos.latitude,
          AppFields.lng: pos.longitude,
          AppFields.geohash: hash,
          AppFields.updatedAt: ServerValue.timestamp,
        });

        // Rider-facing live location marker (RTDB)
        await _rtdb.child('${AppPaths.driverLocations}/$uid').update({
          AppFields.lat: pos.latitude,
          AppFields.lng: pos.longitude,
          AppFields.updatedAt: ServerValue.timestamp,
        });

        // Optional: historical breadcrumbs in Firestore
        await _firestore
            .collection('users')
            .doc(uid)
            .collection(AppPaths.driverLocations)
            .doc(now.toIso8601String())
            .set({
              AppFields.lat: pos.latitude,
              AppFields.lng: pos.longitude,
              AppFields.timestamp: FieldValue.serverTimestamp(),
              AppFields.status: 'available',
            });

        // If in a ride, mirror location to ride doc & path
        if (_activeRideId != null) {
          await _firestore
              .collection(AppPaths.ridesCollection)
              .doc(_activeRideId)
              .update({
                AppFields.driverLat: pos.latitude,
                AppFields.driverLng: pos.longitude,
              });

          await _firestore
              .collection(AppPaths.locationsCollection)
              .doc(_activeRideId)
              .collection('driver')
              .doc(uid)
              .collection('positions')
              .doc(now.toIso8601String())
              .set({
                AppFields.lat: pos.latitude,
                AppFields.lng: pos.longitude,
                AppFields.timestamp: FieldValue.serverTimestamp(),
              });
        }

        // Cache last written state
        _lastPosition = pos;
        _lastGeoHash = hash;
        _lastWriteTime = now;
      } catch (e) {
        if (kDebugMode) debugPrint('[Location] Debounced write failed: $e');
      }
    });
  }

  // Simple distance check to avoid updates when driver barely moved (~5 meters)
  bool _isPositionClose(Position a, Position b, [double thresholdMeters = 5]) {
    final distance = Geolocator.distanceBetween(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
    return distance < thresholdMeters;
  }

  /// Pause location updates without canceling subscription (useful on temporary offline states)
  void pause() {
    _isPaused = true;
  }

  /// Resume location updates if paused
  void resume() {
    _isPaused = false;
  }

  /// Set or clear the active ride ID to start/stop mirroring location to ride documents
  void setActiveRide(String? rideId) {
    _activeRideId = rideId;
  }

  /// Stops location updates, removes RTDB presence, disables background execution
  Future<void> goOffline() async {
    final user = _auth.currentUser;
    if (user == null) return;
    final uid = user.uid;
    _activeRideId = null;
    _isPaused = true;

    // Cancel position subscription & timers
    await _positionSub?.cancel();
    _positionSub = null;
    _retryTimer?.cancel();
    _debounceTimer?.cancel();

    // Clear position broadcast stream?
    // _positionController.add(null); // Optionally notify listeners of offline?

    try {
      await _rtdb.child('${AppPaths.driversOnline}/$uid').remove();
      await _rtdb.child('${AppPaths.driverLocations}/$uid').remove();

      // Optional breadcrumb in Firestore marking offline
      await _firestore
          .collection('users')
          .doc(uid)
          .collection(AppPaths.driverLocations)
          .doc(DateTime.now().toIso8601String())
          .set({
            AppFields.lat: 0.0,
            AppFields.lng: 0.0,
            AppFields.timestamp: FieldValue.serverTimestamp(),
            AppFields.status: 'offline',
          });
    } catch (e) {
      if (kDebugMode) debugPrint('[Location] Remove failed: $e');
    }

    try {
      if (FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.disableBackgroundExecution();
        if (kDebugMode) debugPrint('[Location] Background execution disabled');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Location] Background disable failed: $e');
    }
  }

  /// Dispose method for cleaning up streams and timers
  Future<void> dispose() async {
    await _positionSub?.cancel();
    await _positionController.close();
    _retryTimer?.cancel();
    _debounceTimer?.cancel();
    await goOffline();
  }
}

class DriverService {
  final _fire = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _rtdb = FirebaseDatabase.instance.ref();

  Stream<DocumentSnapshot<Map<String, dynamic>>?> listenActiveRide() {
    final user = _auth.currentUser;
    if (user == null) return const Stream.empty();

    final q = _fire
        .collection(AppPaths.ridesCollection)
        .where(AppFields.driverId, isEqualTo: user.uid)
        .where(AppFields.status, whereIn: RideStatus.ongoingSet.toList())
        .limit(1);

    return q.snapshots().map((snap) {
      if (snap.docs.isEmpty) return null;
      return snap.docs.first;
    });
  }

  // ACCEPT
  Future<void> acceptRide(String rideId, PendingRequest? contextData) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(code: 'no-user', message: 'Not logged in');
    }
    final driverId = user.uid;

    // read driver name once
    final userDoc = await _fire.collection('users').doc(driverId).get();
    final driverName = userDoc.data()?[AppFields.username] ?? 'Unknown Driver';

    // 1) Atomic accept in Firestore
    await _fire.runTransaction((tx) async {
      final docRef = _fire.collection(AppPaths.ridesCollection).doc(rideId);
      final snap = await tx.get(docRef);
      final currentStatus = snap.data()?['status'];

      if (currentStatus != 'pending') {
        throw Exception('Ride already taken');
      }

      tx.update(docRef, {
        AppFields.driverId: driverId,
        AppFields.status: RideStatus.accepted,
        AppFields.acceptedAt: FieldValue.serverTimestamp(),
        'driverName': driverName,
        if (contextData != null) ...{
          AppFields.pickupLat: contextData.pickupLat,
          AppFields.pickupLng: contextData.pickupLng,
          AppFields.dropoffLat: contextData.dropoffLat,
          AppFields.dropoffLng: contextData.dropoffLng,
        },
      });
    });

    // 2) Mirror to RTDB live node
    await _rtdb.child('${AppPaths.ridesLive}/$rideId').update({
      AppFields.status: RideStatus.accepted,
      'driverId': driverId,
      'updatedAt': ServerValue.timestamp,
    });

    // 3) Remove this ride from pending queues (best-effort)
    try {
      await _rtdb.child('${AppPaths.ridesPendingA}/$rideId').remove();
      await _rtdb.child('${AppPaths.ridesPendingB}/$rideId').remove();
    } catch (_) {}

    // 4) Fan-out delete the notification from ALL drivers (optional but recommended)
    try {
      final notifsSnap = await _rtdb.child(AppPaths.driverNotifications).get();
      final updates = <String, Object?>{};
      if (notifsSnap.exists && notifsSnap.value is Map) {
        final map = notifsSnap.value as Map;
        map.forEach((driverKey, ridesMap) {
          if (ridesMap is Map && ridesMap.containsKey(rideId)) {
            updates['${AppPaths.driverNotifications}/$driverKey/$rideId'] =
                null;
          }
        });
      }
      if (updates.isNotEmpty) {
        await _rtdb.update(updates);
      }
    } catch (e) {
      if (kDebugMode) {
        print('[DriverService.acceptRide] Fan-out delete failed: $e');
      }
    }

    // 5) Notify rider (best-effort)
    final riderId =
        (await _fire.collection(AppPaths.ridesCollection).doc(rideId).get())
            .data()?[AppFields.riderId];
    if (riderId != null) {
      await _rtdb.child('${AppPaths.notifications}/$riderId').push().set({
        AppFields.type: 'ride_accepted',
        AppFields.rideId: rideId,
        AppFields.timestamp: ServerValue.timestamp,
      });
    }
    try {
      await _rtdb
          .child('${AppPaths.driverNotifications}/$driverId/$rideId')
          .remove();
    } catch (_) {}
  }

  // COUNTER
  Future<void> proposeCounterFare(String rideId, double newFare) async {
    final fire = FirebaseFirestore.instance;
    final rtdb = FirebaseDatabase.instance.ref();
    final rideRef = fire.collection('rides').doc(rideId);

    String riderId = '';

    await fire.runTransaction((txn) async {
      final snap = await txn.get(rideRef);
      if (!snap.exists) throw Exception('Ride not found');
      final data = snap.data() as Map<String, dynamic>;

      final status = (data['status'] ?? '').toString();
      riderId = (data['riderId'] ?? '').toString();
      if (status == 'cancelled' || status == 'completed') {
        throw Exception('Ride is no longer active');
      }

      final me = FirebaseAuth.instance.currentUser!.uid;
      txn.update(rideRef, {
        'counterFare': newFare,
        'counterProposedAt': FieldValue.serverTimestamp(),
        'counterDriverId': me,
      });
    });

    final now = ServerValue.timestamp;

    await rtdb.child('ridesLive/$rideId').update({
      'counterFare': newFare,
      'updatedAt': now,
    });

    if (riderId.isNotEmpty) {
      await rtdb.child('rides/$riderId/$rideId').update({
        'counterFare': newFare,
        'updatedAt': now,
      });

      await rtdb.child('rider_notifications/$riderId/$rideId').set({
        'rideId': rideId,
        'action': 'COUNTER',
        'counterFare': newFare,
        'timestamp': now,
      });
    }
  }

  // STATUS (accepted -> driver_arrived -> in_progress -> completed)
  Future<void> updateRideStatus(String rideId, String newStatus) async {
    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      AppFields.status: newStatus,
      '${newStatus}At': FieldValue.serverTimestamp(),
    });

    await _rtdb.child('ridesLive/$rideId').update({
      AppFields.status: newStatus,
      'updatedAt': ServerValue.timestamp,
    });

    final riderId =
        (await _fire.collection(AppPaths.ridesCollection).doc(rideId).get())
            .data()?[AppFields.riderId];
    if (riderId != null) {
      await _rtdb.child('${AppPaths.notifications}/$riderId').push().set({
        AppFields.type: 'status_update',
        AppFields.status: newStatus,
        AppFields.rideId: rideId,
        AppFields.timestamp: ServerValue.timestamp,
      });
    }
  }

  // CANCEL
  Future<void> cancelRide(String rideId) async {
    final doc = await _fire
        .collection(AppPaths.ridesCollection)
        .doc(rideId)
        .get();
    final riderId = doc.data()?[AppFields.riderId];

    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      AppFields.status: RideStatus.cancelled,
      AppFields.driverId: FieldValue.delete(),
      'driverName': FieldValue.delete(),
      AppFields.cancelledAt: FieldValue.serverTimestamp(),
    });

    await _rtdb.child('ridesLive/$rideId').update({
      AppFields.status: RideStatus.cancelled,
      'updatedAt': ServerValue.timestamp,
    });

    if (riderId != null) {
      await _rtdb.child('${AppPaths.notifications}/$riderId').push().set({
        AppFields.type: 'ride_cancelled',
        AppFields.rideId: rideId,
        AppFields.timestamp: ServerValue.timestamp,
      });
    }
  }

  // COMPLETE
  Future<void> completeRide(String rideId, double finalFare) async {
    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      AppFields.status: RideStatus.completed,
      AppFields.completedAt: FieldValue.serverTimestamp(),
      AppFields.finalFare: finalFare,
      AppFields.paymentStatus: 'processed',
    });

    await _rtdb.child('ridesLive/$rideId').update({
      AppFields.status: RideStatus.completed,
      'updatedAt': ServerValue.timestamp,
    });

    final riderId =
        (await _fire.collection(AppPaths.ridesCollection).doc(rideId).get())
            .data()?[AppFields.riderId];
    if (riderId != null) {
      await _rtdb.child('${AppPaths.notifications}/$riderId').push().set({
        AppFields.type: 'ride_completed',
        AppFields.rideId: rideId,
        AppFields.timestamp: ServerValue.timestamp,
      });
    }
  }

  Future<void> declineRide(String rideId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(code: 'no-user', message: 'Not logged in');
    }
    final driverId = user.uid;

    // 1) Remove ONLY this driver's local popup
    try {
      await _rtdb
          .child('${AppPaths.driverNotifications}/$driverId/$rideId')
          .remove();
    } catch (e) {
      if (kDebugMode) {
        print('[DriverService.declineRide] Remove my notif failed: $e');
      }
    }

    // 2) Optional rider heads-up (no status change)
    try {
      final rideSnap = await _fire
          .collection(AppPaths.ridesCollection)
          .doc(rideId)
          .get();
      final riderId = rideSnap.data()?[AppFields.riderId];
      if (riderId != null) {
        await _rtdb.child('${AppPaths.notifications}/$riderId').push().set({
          AppFields.type: 'ride_declined',
          AppFields.rideId: rideId,
          AppFields.timestamp: ServerValue.timestamp,
          'by': driverId, // optional attribution
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('[DriverService.declineRide] Rider notify failed: $e');
      }
    }

    // 3) DO NOT modify rides/{rideId} or ridesLive/{rideId}
    // 4) DO NOT remove from global pending queues or other drivers’ notifications
  }

  // RTDB chat under /rides/{rideId}/messages
  Future<void> sendMessage(
    String rideId,
    String message,
    String senderId,
  ) async {
    await _rtdb
        .child('${AppPaths.ridesCollection}/$rideId/${AppPaths.messages}')
        .push()
        .set({
          AppFields.senderId: senderId,
          AppFields.text: message,
          AppFields.timestamp: ServerValue.timestamp,
        });
  }

  Stream<List<Map<String, dynamic>>> listenMessages(String rideId) {
    return _rtdb
        .child('${AppPaths.ridesCollection}/$rideId/${AppPaths.messages}')
        .onValue
        .map((event) {
          final v = event.snapshot.value as Map?;
          if (v == null) return [];
          return v.entries
              .map(
                (e) =>
                    Map<String, dynamic>.from(e.value as Map)..['id'] = e.key,
              )
              .toList();
        });
  }
}

// State / providers
final driverDashboardProvider =
    StateNotifierProvider<
      DriverDashboardController,
      AsyncValue<DocumentSnapshot<Map<String, dynamic>>?>
    >((ref) => DriverDashboardController(ref));

final _authGlobal = FirebaseAuth.instance;

class DriverDashboardController
    extends StateNotifier<AsyncValue<DocumentSnapshot<Map<String, dynamic>>?>> {
  final Ref ref;
  final _service = DriverService();
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>?>? _sub;

  DriverDashboardController(this.ref) : super(const AsyncLoading()) {
    _subscribe();
  }

  void _subscribe() {
    _sub?.cancel();
    state = const AsyncLoading();
    _sub = _service.listenActiveRide().listen(
      (doc) {
        state = AsyncValue.data(doc);
      },
      onError: (e, st) {
        state = AsyncValue.error(e, st);
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> acceptRide(String rideId, {PendingRequest? context}) =>
      _service.acceptRide(rideId, context);

  Future<void> proposeCounterFare(String rideId, double newFare) =>
      _service.proposeCounterFare(rideId, newFare);

  Future<void> declineRide(String rideId) => _service.declineRide(rideId);

  Future<void> updateStatus(String rideId, String newStatus) =>
      _service.updateRideStatus(rideId, newStatus);

  Future<void> cancelRide(String rideId) => _service.cancelRide(rideId);

  Future<void> completeRide(String rideId, double finalFare) =>
      _service.completeRide(rideId, finalFare);

  Future<void> sendMessage(String rideId, String message) async {
    final uid = _authGlobal.currentUser?.uid;
    if (uid != null) await _service.sendMessage(rideId, message, uid);
  }
}

// ---------------- Driver Map widget (polyline adapter added) -----------------
class DriverMapWidget extends ConsumerStatefulWidget {
  final Map<String, dynamic> rideData;
  final void Function(GoogleMapController) onMapCreated;
  final Function(String newStatus) onStatusChange;
  final VoidCallback onComplete;
  final VoidCallback onContactRider; // NEW

  const DriverMapWidget({
    super.key,
    required this.rideData,
    required this.onMapCreated,
    required this.onStatusChange,
    required this.onComplete,
    required this.onContactRider,
  });

  @override
  ConsumerState<DriverMapWidget> createState() => _DriverMapWidgetState();
}

class _StepInfo {
  final LatLng start, end;
  final String html, maneuver;
  final int distanceM;
  final List<LatLng> points;
  _StepInfo({
    required this.start,
    required this.end,
    required this.html,
    required this.maneuver,
    required this.distanceM,
    required this.points,
  });
}

class _DriverMapWidgetState extends ConsumerState<DriverMapWidget> {
  double _distanceFromPolyline(
    LatLng p,
    List<LatLng> line, {
    int startIndex = 0,
  }) {
    if (line.length < 2) return double.infinity;
    double best = double.infinity;
    for (int i = startIndex; i < line.length - 1; i++) {
      best = math.min(best, _distanceToSegment(p, line[i], line[i + 1]));
      if (i - startIndex > 200 && best < 10) break; // perf window
    }
    return best;
  }

  double _distanceToSegment(LatLng p, LatLng v, LatLng w) {
    final px = p.latitude, py = p.longitude;
    final vx = v.latitude, vy = v.longitude;
    final wx = w.latitude, wy = w.longitude;

    final dx = wx - vx, dy = wy - vy;
    if (dx == 0 && dy == 0) return _distanceMeters(p, v);

    double t = ((px - vx) * dx + (py - vy) * dy) / (dx * dx + dy * dy);
    t = t.clamp(0.0, 1.0);
    final proj = LatLng(vx + t * dx, vy + t * dy);
    return _distanceMeters(p, proj);
  }

  static const double _offRouteMeters = 35.0;
  static const int _rerouteCooldownSec = 8;

  DateTime? _lastRerouteAt;
  // Add this helper near the top of the class
  bool get _showRideActions =>
      _status == RideStatus.accepted ||
      _status == RideStatus.driverArrived ||
      _status == RideStatus.inProgress ||
      _status == RideStatus.onTrip;

  String _primaryLabel() {
    if (_status == RideStatus.accepted) return "I'm here";
    if (_status == RideStatus.driverArrived) return 'Start Ride';
    return 'Complete Ride';
  }

  bool _nearPickup([double meters = 150]) {
    if (_currentPosition == null) return false;
    final d = Geolocator.distanceBetween(
      _currentPosition!.latitude,
      _currentPosition!.longitude,
      _pickup.latitude,
      _pickup.longitude,
    );
    return d <= meters;
  }

  bool _primaryEnabled() {
    if (_statusBusy) return false;
    if (_status == RideStatus.accepted) return _nearPickup();
    return true;
  }

  // --- live position subscription
  StreamSubscription<Position>? _posSub;

  // --- route state
  List<LatLng> _route = [];
  List<LatLng> _routeCovered = [];
  List<LatLng> _routeRemaining = [];
  Polyline? _polylineRemaining;
  Polyline? _polylineCovered;

  int _nearestIdx = 0;

  List<_StepInfo> _steps = [];
  int _currentStep = 0;
  String? _turnBanner;

  // --- endpoints & status
  late final LatLng _pickup;
  late final LatLng _dropoff;
  String _status = RideStatus.accepted;

  // --- map / ui state
  GoogleMapController? _mapController;
  Set<Marker> _markers = {};
  // ignore: unused_field
  Position? _currentPosition;
  String? _eta;
  bool _loadingRoute = true;
  bool _statusBusy = false;
  bool _emergencyBusy = false;
  Timer? _pickupTimer;
  bool _timerExpired = false;

  @override
  void initState() {
    super.initState();

    _pickup = LatLng(
      (widget.rideData[AppFields.pickupLat] as num).toDouble(),
      (widget.rideData[AppFields.pickupLng] as num).toDouble(),
    );
    _dropoff = LatLng(
      (widget.rideData[AppFields.dropoffLat] as num).toDouble(),
      (widget.rideData[AppFields.dropoffLng] as num).toDouble(),
    );
    _status =
        (widget.rideData[AppFields.status] as String?) ?? RideStatus.accepted;

    _markers = {
      Marker(
        markerId: const MarkerId('pickup'),
        position: _pickup,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      ),
      Marker(
        markerId: const MarkerId('dropoff'),
        position: _dropoff,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
      ),
    };

    // live position → follow, progress, light reroute
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
      ),
    ).listen(_onPosition);

    _fetchRoute(); // initial route for current leg
  }

  // === live position handler =================================================
  void _onPosition(Position pos) async {
    if (!mounted) return;
    _currentPosition = pos;
    final me = LatLng(pos.latitude, pos.longitude);

    // update driver marker + bearing toward next remaining point
    final bearing = _bearingFromRouteOrLast(me);
    setState(() {
      _markers = {
        ..._markers.where((m) => m.markerId.value != 'driver'),
        Marker(
          markerId: const MarkerId('driver'),
          position: me,
          rotation: bearing,
          anchor: const Offset(0.5, 0.5),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ),
      };
    });

    // camera: behind-the-car, tilted, smooth
    _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: me, zoom: 17.0, tilt: 45.0, bearing: bearing),
      ),
    );

    // progress: trim covered / keep remaining
    if (_route.isNotEmpty) {
      final idx = _nearestRouteIndex(me, startFrom: _nearestIdx);
      if (idx >= _nearestIdx) {
        _nearestIdx = idx;
        _rebuildProgressPolylines(cutAt: _nearestIdx);
      }
    }

    // light off-route detection + cooldowned reroute
    if (_route.isNotEmpty) {
      final d = _distanceFromPolyline(me, _route, startIndex: _nearestIdx);
      final now = DateTime.now();
      final cool =
          _lastRerouteAt == null ||
          now.difference(_lastRerouteAt!).inSeconds > _rerouteCooldownSec;

      if (d > _offRouteMeters && cool) {
        _lastRerouteAt = now;
        final target =
            (_status == RideStatus.inProgress || _status == RideStatus.onTrip)
            ? _dropoff
            : _pickup;
        await _refetchFromPos(me, target);
      }
    }

    // lite turn-by-turn banner (optional if steps available)
    _updateStepBanner(me);
  }

  // === route building for current leg =======================================
  Future<void> _fetchRoute() async {
    setState(() => _loadingRoute = true);
    try {
      // Determine leg
      final pos = await Geolocator.getCurrentPosition();
      final isTrip =
          (_status == RideStatus.inProgress || _status == RideStatus.onTrip);
      final origin = isTrip
          ? _pickup /* already at pickup when trip starts */
          : LatLng(pos.latitude, pos.longitude);
      final dest = isTrip ? _dropoff : _pickup;

      final dir = DirectionsHttp(googleMapsApiKey);
      final payload = await dir.fetchRoute(origin, dest);

      final points = (payload['points'] as List<LatLng>);
      final rawSteps = (payload['steps'] as List);

      if (points.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No route points returned')),
          );
        }
        return;
      }

      // Map into your structures
      _route = points;
      _nearestIdx = 0;
      _rebuildProgressPolylines(cutAt: 0);

      _steps = rawSteps.map<_StepInfo>((m) {
        final s = LatLng(
          ((m['end']?['lat'] as num?) ?? 0).toDouble(),
          ((m['end']?['lng'] as num?) ?? 0).toDouble(),
        );
        return _StepInfo(
          start: _route.first,
          end: s,
          html: (m['primaryText'] as String?) ?? '',
          maneuver: (m['maneuver'] as String?) ?? '',
          distanceM: (m['distanceM'] as num?)?.toInt() ?? 0,
          points: const <LatLng>[], // optional per-step polyline
        );
      }).toList();

      // ETA text from totalSeconds
      final totalSeconds = (payload['totalSeconds'] as int?) ?? 0;
      String? etaText;
      if (totalSeconds > 0) {
        final mins = (totalSeconds / 60).round();
        etaText = mins >= 60 ? '${mins ~/ 60}h ${mins % 60}m' : '$mins min';
      }
      setState(() {
        _eta = etaText;
        _loadingRoute = false;
        _turnBanner = _steps.isNotEmpty ? _stripHtml(_steps.first.html) : null;
      });

      // Push ETA to RTDB (unchanged)
      final rideId = widget.rideData['rideId'] as String?;
      final etaSecs = totalSeconds;
      if (rideId != null && etaSecs > 0) {
        await FirebaseDatabase.instance
            .ref('${AppPaths.ridesLive}/$rideId')
            .update({AppFields.etaSecs: etaSecs});
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Route error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  Future<void> _refetchFromPos(LatLng from, LatLng to) async {
    setState(() => _loadingRoute = true);
    try {
      final dir = DirectionsHttp(googleMapsApiKey);
      final payload = await dir.fetchRoute(from, to);

      final points = (payload['points'] as List<LatLng>);
      if (points.isEmpty) return;

      _route = points;
      _nearestIdx = 0;
      _rebuildProgressPolylines(cutAt: 0);

      final rawSteps = (payload['steps'] as List);
      _steps = rawSteps.map<_StepInfo>((m) {
        final s = LatLng(
          ((m['end']?['lat'] as num?) ?? 0).toDouble(),
          ((m['end']?['lng'] as num?) ?? 0).toDouble(),
        );
        return _StepInfo(
          start: _route.first,
          end: s,
          html: (m['primaryText'] as String?) ?? '',
          maneuver: (m['maneuver'] as String?) ?? '',
          distanceM: (m['distanceM'] as num?)?.toInt() ?? 0,
          points: const <LatLng>[],
        );
      }).toList();

      setState(() {
        _turnBanner = _steps.isNotEmpty ? _stripHtml(_steps.first.html) : null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Reroute failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  // === helpers ==============================================================

  int _nearestRouteIndex(LatLng p, {int startFrom = 0}) {
    if (_route.isEmpty) return 0;
    double best = double.infinity;
    int bestIdx = startFrom.clamp(0, _route.length - 1);
    final end = _route.length;
    for (int i = startFrom; i < end; i++) {
      final d = _distanceMeters(p, _route[i]);
      if (d < best) {
        best = d;
        bestIdx = i;
      }
      if (i - startFrom > 200) break; // small window for perf
    }
    return bestIdx;
  }

  double _distanceMeters(LatLng a, LatLng b) {
    return Geolocator.distanceBetween(
      a.latitude,
      a.longitude,
      b.latitude,
      b.longitude,
    );
  }

  double _bearingBetween(LatLng a, LatLng b) {
    double toRad(double deg) => deg * (3.141592653589793 / 180.0);
    double toDeg(double rad) => rad * (180.0 / 3.141592653589793);
    final lat1 = toRad(a.latitude), lat2 = toRad(b.latitude);
    final dLon = toRad(b.longitude - a.longitude);
    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    final brng = toDeg(math.atan2(y, x));
    return (brng + 360.0) % 360.0;
  }

  double _bearingFromRouteOrLast(LatLng now) {
    if (_routeRemaining.length >= 2) {
      return _bearingBetween(_routeRemaining[0], _routeRemaining[1]);
    }
    if (_route.length >= 2) {
      final idx = _nearestRouteIndex(now, startFrom: _nearestIdx);
      final nextIdx = (idx + 1).clamp(0, _route.length - 1);
      if (idx != nextIdx) {
        return _bearingBetween(_route[idx], _route[nextIdx]);
      }
    }
    return 0.0;
  }

  void _rebuildProgressPolylines({required int cutAt}) {
    if (_route.isEmpty) return;
    final safeCut = cutAt.clamp(0, _route.length - 1);
    _routeCovered = _route.sublist(0, safeCut + 1);
    _routeRemaining = _route.sublist(safeCut);

    _polylineCovered = Polyline(
      polylineId: const PolylineId('covered'),
      points: _routeCovered,
      color: Colors.grey,
      width: 6,
      startCap: Cap.roundCap,
      endCap: Cap.roundCap,
      jointType: JointType.round,
    );
    _polylineRemaining = Polyline(
      polylineId: const PolylineId('remaining'),
      points: _routeRemaining,
      color: Colors.blueAccent,
      width: 6,
      startCap: Cap.roundCap,
      endCap: Cap.roundCap,
      jointType: JointType.round,
    );
    setState(() {}); // trigger repaint
  }

  String _stripHtml(String s) {
    return s
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .trim();
  }

  void _updateStepBanner(LatLng me) {
    if (_steps.isEmpty) {
      _turnBanner = null;
      return;
    }
    final end = _steps[_currentStep].end;
    final dEnd = _distanceMeters(me, end);
    if (dEnd < 25 && _currentStep < _steps.length - 1) {
      _currentStep++;
    }
    _turnBanner = _stripHtml(_steps[_currentStep].html);
  }

  // === status progression ====================================================
  // accepted -> driver_arrived -> in_progress -> completed
  Future<void> _progressStatus() async {
    if (_statusBusy) return;

    String next = _status;
    if (_status == RideStatus.accepted) {
      next = RideStatus.driverArrived;
      _startPickupTimer();
    } else if (_status == RideStatus.driverArrived) {
      next = RideStatus.inProgress;
      _pickupTimer?.cancel();
    } else if (_status == RideStatus.inProgress) {
      next = RideStatus.completed;
    } else {
      return;
    }

    setState(() => _statusBusy = true);
    try {
      await ref
          .read(driverDashboardProvider.notifier)
          .updateStatus(widget.rideData['rideId'] as String, next);

      _status = next;
      widget.onStatusChange(next);

      if (next == RideStatus.driverArrived) {
        showDriverArrived(rideId: widget.rideData['rideId'] as String);
      }
      if (next == RideStatus.inProgress) {
        showRideStarted(rideId: widget.rideData['rideId'] as String);
      }
      if (next == RideStatus.completed) {
        showRideCompleted(rideId: widget.rideData['rideId'] as String);
      }

      // rebuild route when switching leg (current→pickup or pickup→dropoff)
      await _fetchRoute();

      if (next == RideStatus.completed) {
        final distance = await DirectionsService.getDistance(_pickup, _dropoff);
        final fares =
            ref.read(faresConfigProvider).asData?.value ??
            {'base': 5.0, 'perKm': 1.0};
        final finalFare = fares['base']! + distance * fares['perKm']!;
        await ref
            .read(driverDashboardProvider.notifier)
            .completeRide(widget.rideData['rideId'] as String, finalFare);
        widget.onComplete();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Status update failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _statusBusy = false);
    }
  }

  // === pickup timer ==========================================================
  void _startPickupTimer() {
    _pickupTimer?.cancel();
    _pickupTimer = Timer(const Duration(minutes: 5), () {
      if (!mounted) return;
      setState(() => _timerExpired = true);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Pickup time expired.')));
    });
  }

  // === emergency =============================================================
  Future<void> _sendEmergency() async {
    if (_emergencyBusy) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Confirm Emergency'),
        content: const Text(
          'Are you sure you want to send an emergency alert?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _emergencyBusy = true);
    try {
      final currentUid = FirebaseAuth.instance.currentUser!.uid;
      final otherUid = widget.rideData[AppFields.riderId] as String?;
      if (otherUid == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to identify rider.')),
          );
        }
        return;
      }

      await EmergencyService.sendEmergency(
        rideId: widget.rideData['rideId'] as String,
        currentUid: currentUid,
        otherUid: otherUid,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Emergency sent')));
        showEmergencyAlert(rideId: widget.rideData['rideId'] as String);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Emergency failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _emergencyBusy = false);
    }
  }

  // === build ================================================================
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(target: _pickup, zoom: 15),
          markers: _markers,
          polylines: {
            if (_polylineRemaining != null) _polylineRemaining!,
            if (_polylineCovered != null) _polylineCovered!,
          },
          style: _darkGuidanceStyle,
          onMapCreated: (controller) async {
            _mapController = controller;
            widget.onMapCreated(controller);
          },
          buildingsEnabled: true,
          trafficEnabled: false,
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
        ),

        if (_loadingRoute) const Center(child: CircularProgressIndicator()),

        // ETA + turn banner
        if (!_loadingRoute)
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white70,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_turnBanner != null)
                      Text(
                        _turnBanner!,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    if (_eta != null)
                      Text(
                        'ETA: $_eta',
                        style: const TextStyle(color: Colors.black54),
                      ),
                  ],
                ),
              ),
            ),
          ),

        // ---- Modern 4-button overlay: Primary + (Emergency | Cancel | Contact rider)
        if (_showRideActions)
          Positioned(
            bottom: 16,
            left: 16,
            right: 16,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _primaryEnabled() ? _progressStatus : null,
                      child: _statusBusy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_primaryLabel()),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      // Emergency
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.red,
                            side: const BorderSide(color: Colors.red),
                          ),
                          onPressed: _emergencyBusy ? null : _sendEmergency,
                          child: _emergencyBusy
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Emergency'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Cancel
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('Cancel Ride'),
                                content: const Text(
                                  'Are you sure you want to cancel this ride?',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('No'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('Yes'),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              await ref
                                  .read(driverDashboardProvider.notifier)
                                  .cancelRide(
                                    widget.rideData['rideId'] as String,
                                  );
                              // ignore: use_build_context_synchronously
                              if (mounted) Navigator.of(context).maybePop();
                            }
                          },
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Contact rider
                      Expanded(
                        child: ElevatedButton(
                          onPressed: widget.onContactRider,
                          child: const Text('Info'),
                        ),
                      ),
                    ],
                  ),
                  if (_status == RideStatus.accepted && !_nearPickup())
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Move closer to pickup to continue',
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: Colors.black54),
                      ),
                    ),
                ],
              ),
            ),
          ),

        if (_timerExpired)
          Positioned(
            top: 60,
            left: 20,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.yellow.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Pickup timer expired!'),
              ),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _pickupTimer?.cancel();
    _mapController?.dispose();
    _posSub?.cancel();
    super.dispose();
  }
}

// -------------------- Feedback dialog & offers helpers (unchanged here) -----
class FeedbackDialog extends StatefulWidget {
  final String rideId;
  final String riderId;
  final VoidCallback onSubmitted;

  const FeedbackDialog({
    super.key,
    required this.rideId,
    required this.riderId,
    required this.onSubmitted,
  });

  @override
  State<FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<FeedbackDialog> {
  final TextEditingController comment = TextEditingController();
  double rating = 4;
  bool isSubmitting = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rate This Ride'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Slider(
            min: 1,
            max: 5,
            divisions: 4,
            value: rating,
            onChanged: (v) => setState(() => rating = v),
            label: rating.toString(),
          ),
          TextField(
            controller: comment,
            decoration: const InputDecoration(labelText: 'Comments'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: isSubmitting
              ? null
              : () async {
                  if (comment.text.trim().isEmpty) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter a comment')),
                      );
                    }
                    return;
                  }

                  setState(() => isSubmitting = true);
                  try {
                    final user = FirebaseAuth.instance.currentUser;
                    if (user == null) {
                      throw FirebaseAuthException(
                        code: 'no-user',
                        message: 'No authenticated user.',
                      );
                    }
                    await FirebaseFirestore.instance
                        .collection(AppPaths.ratingsCollection)
                        .add({
                          'rideId': widget.rideId,
                          'fromUid': user.uid,
                          'toUid': widget.riderId,
                          AppFields.rating: rating,
                          AppFields.comment: comment.text.trim(),
                          AppFields.timestamp: FieldValue.serverTimestamp(),
                        });

                    if (!mounted) return;
                    // ignore: use_build_context_synchronously
                    Navigator.of(context).pop();
                    widget.onSubmitted();
                    if (mounted) {
                      // ignore: use_build_context_synchronously
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Thank you for your feedback!'),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      // ignore: use_build_context_synchronously
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Failed to submit feedback: $e'),
                        ),
                      );
                    }
                  } finally {
                    if (mounted) setState(() => isSubmitting = false);
                  }
                },
          child: isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(),
                )
              : const Text('Submit'),
        ),
      ],
    );
  }
}

class DriverOffer {
  final String rideId;
  final String? pickup;
  final String? dropoff;
  final double? pickupLat, pickupLng, dropoffLat, dropoffLng;
  final double? fare;
  final int createdAtMs;

  DriverOffer({
    required this.rideId,
    this.pickup,
    this.dropoff,
    this.pickupLat,
    this.pickupLng,
    this.dropoffLat,
    this.dropoffLng,
    this.fare,
    required this.createdAtMs,
  });

  factory DriverOffer.fromRTDB(String rideId, Map data) {
    double? d(v) => (v is num) ? v.toDouble() : null;
    return DriverOffer(
      rideId: rideId,
      pickup: data[AppFields.pickup]?.toString(),
      dropoff: data[AppFields.dropoff]?.toString(),
      pickupLat: d(data[AppFields.pickupLat]),
      pickupLng: d(data[AppFields.pickupLng]),
      dropoffLat: d(data[AppFields.dropoffLat]),
      dropoffLng: d(data[AppFields.dropoffLng]),
      fare: d(data[AppFields.fare]),
      createdAtMs:
          (data[AppFields.timestamp] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
  }
}
