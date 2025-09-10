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
import 'package:async/async.dart';

import 'package:femdrive/location/directions_service.dart';
import 'package:femdrive/shared/emergency_service.dart';

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

class GeoCfg {
  static const driverHashPrecision = 9;
  static const popupProximityPrecision = 5;
}

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

  Stream<List<PendingRequest>> listenPendingRequestsMerged() {
    Stream<List<PendingRequest>> readNode(String node) {
      return _rtdb.child(node).onValue.map((event) {
        final v = event.snapshot.value;
        if (v == null || v is! Map) return <PendingRequest>[];
        final res = <PendingRequest>[];
        (v).forEach((k, val) {
          if (val is Map) {
            try {
              res.add(
                PendingRequest.fromMap(
                  k.toString(),
                  Map<String, dynamic>.from(val),
                ),
              );
            } catch (_) {}
          }
        });
        return res;
      });
    }

    final a = readNode(AppPaths.ridesPendingA);
    final b = readNode(AppPaths.ridesPendingB);

    return StreamZip<List<PendingRequest>>([a, b]).map((lists) {
      final merged = <String, PendingRequest>{};
      for (final lst in lists) {
        for (final r in lst) {
          merged[r.rideId] = r;
        }
      }
      return merged.values.toList();
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
    String status = '';

    // 1) Firestore txn: validate + persist counter fare
    await fire.runTransaction((txn) async {
      final snap = await txn.get(rideRef);
      if (!snap.exists) {
        throw Exception('Ride not found');
      }
      final data = snap.data() as Map<String, dynamic>;

      status = (data['status'] ?? '').toString();
      riderId = (data['riderId'] ?? '').toString();

      // Guard rails: don’t counter on finished rides
      if (status == 'cancelled' || status == 'completed') {
        throw Exception('Ride is no longer active');
      }

      txn.update(rideRef, {
        'counterFare': newFare,
        'counterProposedAt': FieldValue.serverTimestamp(),
        // (do NOT flip status here; rider may accept/reject)
      });
    });

    // 2) RTDB mirrors (live for rider UI)
    final now = ServerValue.timestamp;

    // 2a) Live broadcast node (optional, keeps parity with other live fields)
    await rtdb.child('ridesLive/$rideId').update({
      'counterFare': newFare,
      'updatedAt': now,
    });

    // 2b) Rider’s latest-ride stream node  ✅ required for popup
    if (riderId.isNotEmpty) {
      await rtdb.child('rides/$riderId/$rideId').update({
        'counterFare': newFare,
        'updatedAt': now,
      });
    }

    // 3) (Optional) Rider-side heads-up via RTDB notification fanout
    // This is optional; your modal shows without it. Keep if you want a chime:
    await rtdb.child('rider_notifications/$riderId/$rideId').set({
      'rideId': rideId,
      'action': 'COUNTER',
      'counterFare': newFare,
      'timestamp': now,
    });
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
    // Remove ride from pending queues (best-effort)
    try {
      await _rtdb.child('${AppPaths.ridesPendingA}/$rideId').remove();
      await _rtdb.child('${AppPaths.ridesPendingB}/$rideId').remove();
    } catch (e) {
      if (kDebugMode) {
        print(
          '[DriverService.declineRide] Failed to remove from pending queues: $e',
        );
      }
    }

    // Notify rider (best-effort)
    try {
      final riderDoc = await _fire
          .collection(AppPaths.ridesCollection)
          .doc(rideId)
          .get();
      final riderId = riderDoc.data()?[AppFields.riderId];
      if (riderId != null) {
        await _rtdb.child('${AppPaths.notifications}/$riderId').push().set({
          AppFields.type: 'ride_declined',
          AppFields.rideId: rideId,
          AppFields.timestamp: ServerValue.timestamp,
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('[DriverService.declineRide] Failed to notify rider: $e');
      }
    }

    // Fan-out delete the notification from all drivers (optional but recommended)
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
        print('[DriverService.declineRide] Fan-out delete failed: $e');
      }
    }
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

  const DriverMapWidget({
    super.key,
    required this.rideData,
    required this.onMapCreated,
    required this.onStatusChange,
    required this.onComplete,
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
  // --- live position subscription
  StreamSubscription<Position>? _posSub;

  // --- route state
  List<LatLng> _route = [];
  List<LatLng> _routeCovered = [];
  List<LatLng> _routeRemaining = [];
  Polyline? _polylineRemaining;
  Polyline? _polylineCovered;

  int _nearestIdx = 0;
  DateTime? _lastRerouteAt;
  int _offRouteStrikes = 0;

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
      final d = _distanceMeters(me, _route[_nearestIdx]);
      final tooFar = d > 30.0; // meters
      _offRouteStrikes = tooFar ? (_offRouteStrikes + 1) : 0;

      final now = DateTime.now();
      final canReroute =
          _lastRerouteAt == null ||
          now.difference(_lastRerouteAt!).inSeconds > 10;
      final needReroute = _offRouteStrikes >= 4;
      if (needReroute && canReroute) {
        _offRouteStrikes = 0;
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
      final pos = await Geolocator.getCurrentPosition();
      final start =
          (_status == RideStatus.inProgress || _status == RideStatus.onTrip)
          ? _pickup
          : LatLng(pos.latitude, pos.longitude);
      final end =
          (_status == RideStatus.inProgress || _status == RideStatus.onTrip)
          ? _dropoff
          : _pickup;

      final payload = await DirectionsService.getRoute(
        start,
        end,
        role: 'driver',
      );
      if (!mounted || payload == null) return;

      final points = _extractRoutePoints(payload);
      if (points.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No route points returned')),
          );
        }
        return;
      }

      _route = points;
      _nearestIdx = 0;
      _rebuildProgressPolylines(cutAt: 0);

      // optional: parse step list if your DirectionsService provides it
      final rawSteps = (payload['steps'] as List?) ?? const [];
      _steps = rawSteps.map((m) {
        final s = LatLng(
          ((m['start']?['lat'] as num?) ?? 0).toDouble(),
          ((m['start']?['lng'] as num?) ?? 0).toDouble(),
        );
        final e = LatLng(
          ((m['end']?['lat'] as num?) ?? 0).toDouble(),
          ((m['end']?['lng'] as num?) ?? 0).toDouble(),
        );
        final enc = (m['polyline'] as String? ?? '');
        final pts = enc.isNotEmpty ? _decodePolyline(enc) : <LatLng>[];
        return _StepInfo(
          start: s,
          end: e,
          html: (m['html'] as String? ?? ''),
          maneuver: (m['maneuver'] as String? ?? ''),
          distanceM: (m['distanceM'] as int? ?? 0),
          points: pts,
        );
      }).toList();
      _currentStep = 0;
      _turnBanner = _steps.isNotEmpty ? _stripHtml(_steps.first.html) : null;

      // ETA text (fallback to speed heuristic if not present)
      final etaSecs = (payload['etaSeconds'] as num?)?.toInt();
      String? etaText = payload['etaText']?.toString();
      final distanceKm = (payload['distanceKm'] as num?)?.toDouble();
      if ((etaText == null || etaText.isEmpty) && distanceKm != null) {
        etaText = '${(distanceKm / 30.0 * 60.0).round()} min';
      }

      setState(() {
        _eta = etaText;
        _loadingRoute = false;
      });

      // fit bounds (first<->last quick fit)
      if (_route.length >= 2) {
        final sw = LatLng(
          math.min(_route.first.latitude, _route.last.latitude),
          math.min(_route.first.longitude, _route.last.longitude),
        );
        final ne = LatLng(
          math.max(_route.first.latitude, _route.last.latitude),
          math.max(_route.first.longitude, _route.last.longitude),
        );
        await _mapController?.animateCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(southwest: sw, northeast: ne),
            60,
          ),
        );
      }

      // push ETA to RTDB for rider UI
      final rideId = widget.rideData['rideId'] as String?;
      if (rideId != null && etaSecs != null) {
        await FirebaseDatabase.instance
            .ref('${AppPaths.ridesLive}/$rideId')
            .update({AppFields.etaSecs: etaSecs});
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingRoute = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Route error: $e')));
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  Future<void> _refetchFromPos(LatLng from, LatLng to) async {
    setState(() => _loadingRoute = true);
    try {
      final payload = await DirectionsService.getRoute(
        from,
        to,
        role: 'driver',
      );
      if (!mounted || payload == null) return;

      final points = _extractRoutePoints(payload);
      if (points.isEmpty) return;

      _route = points;
      _nearestIdx = 0;
      _rebuildProgressPolylines(cutAt: 0);

      final rawSteps = (payload['steps'] as List?) ?? const [];
      _steps = rawSteps.map((m) {
        final s = LatLng(
          ((m['start']?['lat'] as num?) ?? 0).toDouble(),
          ((m['start']?['lng'] as num?) ?? 0).toDouble(),
        );
        final e = LatLng(
          ((m['end']?['lat'] as num?) ?? 0).toDouble(),
          ((m['end']?['lng'] as num?) ?? 0).toDouble(),
        );
        final enc = (m['polyline'] as String? ?? '');
        final pts = enc.isNotEmpty ? _decodePolyline(enc) : <LatLng>[];
        return _StepInfo(
          start: s,
          end: e,
          html: (m['html'] as String? ?? ''),
          maneuver: (m['maneuver'] as String? ?? ''),
          distanceM: (m['distanceM'] as int? ?? 0),
          points: pts,
        );
      }).toList();
      _currentStep = 0;
      _turnBanner = _steps.isNotEmpty ? _stripHtml(_steps.first.html) : null;
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

  List<LatLng> _extractRoutePoints(Map<String, dynamic> payload) {
    final p = payload['points'];
    if (p is List<LatLng>) return p;
    if (p is List) {
      final out = <LatLng>[];
      for (final e in p) {
        if (e is LatLng) {
          out.add(e);
        } else if (e is Map) {
          final lat = (e['lat'] as num?)?.toDouble();
          final lng = (e['lng'] as num?)?.toDouble();
          if (lat != null && lng != null) out.add(LatLng(lat, lng));
        }
      }
      if (out.isNotEmpty) return out;
    }
    final enc = payload['overview_polyline']?['points'];
    if (enc is String && enc.isNotEmpty) return _decodePolyline(enc);
    return const <LatLng>[];
  }

  List<LatLng> _decodePolyline(String encoded) {
    final points = <LatLng>[];
    int index = 0, lat = 0, lng = 0;
    while (index < encoded.length) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lng += dlng;

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return points;
  }

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
          onMapCreated: (controller) {
            _mapController = controller;
            widget.onMapCreated(controller);
          },
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

        // primary action
        Positioned(
          bottom: 96,
          left: 20,
          right: 20,
          child: ElevatedButton(
            onPressed: _statusBusy ? null : _progressStatus,
            child: _statusBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(),
                  )
                : Text(
                    _status == RideStatus.accepted
                        ? "I'm here"
                        : _status == RideStatus.driverArrived
                        ? 'Start Ride'
                        : 'Complete Ride',
                  ),
          ),
        ),

        // emergency
        Positioned(
          bottom: 24,
          left: 20,
          right: 20,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: _emergencyBusy ? null : _sendEmergency,
            child: _emergencyBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(),
                  )
                : const Text('Emergency'),
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

// config
const int kOfferExpiryMs = 60 * 1000; // 60s

Stream<List<DriverOffer>> listenDriverOffers(String driverId) {
  final ref = FirebaseDatabase.instance.ref(
    '${AppPaths.driverNotifications}/$driverId',
  );
  return ref.onValue.map((ev) {
    final v = ev.snapshot.value;
    if (v is! Map) return <DriverOffer>[];
    final now = DateTime.now().millisecondsSinceEpoch;

    final out = <DriverOffer>[];
    v.forEach((k, raw) {
      if (raw is Map) {
        final offer = DriverOffer.fromRTDB(k.toString(), raw);

        // 🔹 prune stale
        if (now - offer.createdAtMs <= kOfferExpiryMs) {
          out.add(offer);
        }
      }
    });

    // newest first
    out.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return out;
  });
}
