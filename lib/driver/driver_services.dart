import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
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
import 'package:femdrive/emergency_service.dart';

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
  StreamSubscription<Position>? _positionSub;
  final _rtdb = FirebaseDatabase.instance.ref();
  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  String? _activeRideId;

  Future<void> startOnlineMode({String? rideId}) async {
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('[Location] No logged-in user');
      return;
    }
    final uid = user.uid;
    _activeRideId = rideId;
    final geoHasher = GeoHasher();

    try {
      final ok = await FlutterBackground.initialize();
      if (ok) {
        await FlutterBackground.enableBackgroundExecution();
        debugPrint('[Location] Background enabled');
      }
    } catch (e) {
      debugPrint('[Location] BG init failed: $e');
    }

    _positionSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          ),
        ).listen(
          (pos) async {
            final hash = geoHasher.encode(
              pos.latitude,
              pos.longitude,
              precision: GeoCfg.driverHashPrecision,
            );
            try {
              // Canonical online presence
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
                  .doc(DateTime.now().toIso8601String())
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
                    .doc(DateTime.now().toIso8601String())
                    .set({
                      AppFields.lat: pos.latitude,
                      AppFields.lng: pos.longitude,
                      AppFields.timestamp: FieldValue.serverTimestamp(),
                    });
              }
            } catch (e) {
              debugPrint('[Location] Write failed: $e');
            }
          },
          onError: (err) async {
            debugPrint('[Location] Stream error: $err — retrying');
            await Future.delayed(const Duration(seconds: 3));
            await _positionSub?.cancel();
            _positionSub = null;
            await startOnlineMode(rideId: _activeRideId);
          },
        );
  }

  Future<void> goOffline() async {
    final user = _auth.currentUser;
    if (user == null) return;
    final uid = user.uid;
    _activeRideId = null;

    await _positionSub?.cancel();
    _positionSub = null;

    try {
      await _rtdb.child('${AppPaths.driversOnline}/$uid').remove();
      await _rtdb.child('${AppPaths.driverLocations}/$uid').remove();

      // optional breadcrumb in Firestore
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
      debugPrint('[Location] Remove failed: $e');
    }

    try {
      if (FlutterBackground.isBackgroundExecutionEnabled) {
        await FlutterBackground.disableBackgroundExecution();
        debugPrint('[Location] Background disabled');
      }
    } catch (e) {
      debugPrint('[Location] BG disable failed: $e');
    }
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

    try {
      await _rtdb.child('${AppPaths.ridesPendingA}/$rideId').remove();
      await _rtdb.child('${AppPaths.ridesPendingB}/$rideId').remove();
    } catch (_) {}
    final driverId = user.uid;
    final userDoc = await _fire.collection('users').doc(user.uid).get();
    final driverName = userDoc.data()?[AppFields.username] ?? 'Unknown Driver';

    await _fire.collection(AppPaths.ridesCollection).doc(rideId).set({
      AppFields.driverId: user.uid,
      'driverName': driverName,
      AppFields.status: RideStatus.accepted,
      AppFields.acceptedAt: FieldValue.serverTimestamp(),
      if (contextData != null) ...{
        AppFields.pickupLat: contextData.pickupLat,
        AppFields.pickupLng: contextData.pickupLng,
        AppFields.dropoffLat: contextData.dropoffLat,
        AppFields.dropoffLng: contextData.dropoffLng,
      },
    }, SetOptions(merge: true));

    await _rtdb.child('ridesLive/$rideId').update({
      AppFields.status: RideStatus.accepted,
      'driverId': user.uid,
      'updatedAt': ServerValue.timestamp,
    });
    await _fire.runTransaction((tx) async {
      final docRef = _fire.collection('rides').doc(rideId);
      final snap = await tx.get(docRef);
      final currentStatus = snap.data()?['status'];
      if (currentStatus != 'pending') {
        throw Exception('Ride already taken');
      }

      tx.update(docRef, {
        'driverId': driverId,
        'status': 'accepted',
        'acceptedAt': FieldValue.serverTimestamp(),
      });
    });
    // --- NEW: fan-out delete this rideId from ALL driver_notifications ---
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
      } else {
        if (kDebugMode) {
          print(
            '[DriverService.acceptRide] No other pending notifications found for ride=$rideId',
          );
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('[DriverService.acceptRide] ⚠️ Fan-out delete failed: $e');
      }
    }

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
      await _rtdb.child('driver_notifications/${user.uid}/$rideId').remove();
    } catch (_) {}
  }

  // COUNTER
  Future<void> proposeCounterFare(String rideId, double newFare) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(code: 'no-user', message: 'Not logged in');
    }
    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      'counterFare': newFare,
      AppFields.status: 'pending_counter',
    });

    await _rtdb.child('ridesLive/$rideId').update({
      AppFields.status: 'pending_counter',
      'updatedAt': ServerValue.timestamp,
    });

    final riderId =
        (await _fire.collection(AppPaths.ridesCollection).doc(rideId).get())
            .data()?[AppFields.riderId];
    if (riderId != null) {
      await _rtdb.child('${AppPaths.notifications}/$riderId').push().set({
        AppFields.type: 'counter_fare',
        'counterFare': newFare,
        AppFields.rideId: rideId,
        AppFields.timestamp: ServerValue.timestamp,
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
    await _rtdb.child('${AppPaths.ridesPendingA}/$rideId').remove();
    await _rtdb.child('${AppPaths.ridesPendingB}/$rideId').remove();

    final riderId =
        (await _fire.collection(AppPaths.ridesCollection).doc(rideId).get())
            .data()?[AppFields.riderId];
    if (riderId != null) {
      await _rtdb.child('${AppPaths.notifications}/$riderId').push().set({
        AppFields.type: 'ride_declined',
        AppFields.rideId: rideId,
        AppFields.timestamp: ServerValue.timestamp,
      });
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

class _DriverMapWidgetState extends ConsumerState<DriverMapWidget> {
  late final LatLng _pickup;
  late final LatLng _dropoff;
  String _status = RideStatus.accepted;
  Set<Marker> _markers = {};
  Polyline? _polyline;
  String? _eta;
  bool _loadingRoute = true;
  bool _statusBusy = false;
  bool _emergencyBusy = false;
  GoogleMapController? _mapController;
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

    _fetchRoute();
  }

  // --- Polyline adapter: accepts Map or List or encoded string -------------
  List<LatLng> _extractRoutePoints(dynamic route) {
    if (route is List<LatLng>) return route;

    // e.g. list of {lat: , lng: }
    if (route is List) {
      final out = <LatLng>[];
      for (final p in route) {
        if (p is LatLng) {
          out.add(p);
        } else if (p is Map) {
          final lat = (p['lat'] as num?)?.toDouble();
          final lng = (p['lng'] as num?)?.toDouble();
          if (lat != null && lng != null) out.add(LatLng(lat, lng));
        }
      }
      return out;
    }

    // map payload from a directions API
    if (route is Map) {
      // 1) common Google shape
      final enc =
          route['overview_polyline']?['points'] ??
          route['polyline'] ??
          route['encoded'] ??
          route['points'];
      if (enc is String) return _decodePolyline(enc);

      // 2) sometimes 'points' is already a list
      final pts = route['points'];
      if (pts is List) return _extractRoutePoints(pts);
    }

    return const <LatLng>[];
  }

  // Standard encoded polyline decoder
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

  Future<void> _fetchRoute() async {
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

      // Use the same DirectionsService used elsewhere (may return a Map)
      final routePayload = await DirectionsService.getRoute(
        start,
        end,
        role: 'driver',
      );
      final points = _extractRoutePoints(routePayload);
      if (points.isEmpty || !mounted) return;

      // ETA estimation via distance (fallback if you don't have direct ETA)
      final distanceKm = await DirectionsService.getDistance(start, end);
      // ignore: unnecessary_null_comparison
      final etaMins = (distanceKm != null)
          ? (distanceKm / 30.0 * 60.0).round()
          : null;

      setState(() {
        _eta = etaMins != null ? '$etaMins min' : null;
        _polyline = Polyline(
          polylineId: const PolylineId('driver_route'),
          points: points,
          color: Colors.blueAccent,
          width: 6,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
        );
      });

      // fit bounds
      final sw = LatLng(
        [
          points.first.latitude,
          points.last.latitude,
        ].reduce((a, b) => a < b ? a : b),
        [
          points.first.longitude,
          points.last.longitude,
        ].reduce((a, b) => a < b ? a : b),
      );
      final ne = LatLng(
        [
          points.first.latitude,
          points.last.latitude,
        ].reduce((a, b) => a > b ? a : b),
        [
          points.first.longitude,
          points.last.longitude,
        ].reduce((a, b) => a > b ? a : b),
      );
      await _mapController?.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(southwest: sw, northeast: ne),
          60,
        ),
      );

      // push ETA to ridesLive for rider UI
      final rideId = widget.rideData['rideId'] as String?;
      if (rideId != null && etaMins != null) {
        await FirebaseDatabase.instance
            .ref('${AppPaths.ridesLive}/$rideId')
            .update({AppFields.etaSecs: etaMins * 60});
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Route error: $e')));
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  void _startPickupTimer() {
    _pickupTimer = Timer(const Duration(minutes: 5), () {
      setState(() => _timerExpired = true);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pickup time expired. Consider cancelling the ride.'),
        ),
      );
    });
  }

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
      if (mounted) {
        setState(() {});
        _fetchRoute();
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

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(target: _pickup, zoom: 15),
          markers: _markers,
          polylines: _polyline != null ? {_polyline!} : <Polyline>{},
          onMapCreated: (controller) {
            _mapController = controller;
            widget.onMapCreated(controller);
          },
          myLocationEnabled: true,
          myLocationButtonEnabled: true,
        ),
        if (_loadingRoute) const Center(child: CircularProgressIndicator()),
        if (_eta != null && !_loadingRoute)
          Positioned(
            top: 20,
            left: 20,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white70,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text('ETA: $_eta'),
              ),
            ),
          ),
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
