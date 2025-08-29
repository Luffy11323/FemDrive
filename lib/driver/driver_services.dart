import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:femdrive/driver_dashboard.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
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
  static const driverLocations = 'driverLocations';
  static const notifications = 'notifications';
  static const messages = 'messages';
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
  static const rideId = 'rideId'; // Added to resolve the error
  static const reportedBy = 'reportedBy'; // Added to resolve the error
  static const otherUid = 'otherUid';
}

class RideStatus {
  static const accepted = 'accepted';
  static const arriving = 'arriving';
  static const started = 'started';
  static const completed = 'completed';
  static const cancelled = 'cancelled';
  static const ongoingSet = <String>{accepted, arriving, started};
}

class GeoCfg {
  static const driverHashPrecision = 9;
  static const popupProximityPrecision = 5;
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
              await _rtdb.child('${AppPaths.driversOnline}/$uid').set({
                AppFields.uid: uid,
                AppFields.lat: pos.latitude,
                AppFields.lng: pos.longitude,
                AppFields.geohash: hash,
                AppFields.updatedAt: ServerValue.timestamp,
              });

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

  Future<void> acceptRide(String rideId, PendingRequest? contextData) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(code: 'no-user', message: 'Not logged in');
    }

    try {
      await _rtdb.child('${AppPaths.ridesPendingA}/$rideId').remove();
      await _rtdb.child('${AppPaths.ridesPendingB}/$rideId').remove();
    } catch (_) {}

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

    // Notify rider via RTDB
    final riderId =
        contextData?.raw[AppFields.riderId] ??
        (await _fire.collection(AppPaths.ridesCollection).doc(rideId).get())
            .data()?[AppFields.riderId];
    if (riderId != null) {
      await _rtdb.child('${AppPaths.notifications}/$riderId').push().set({
        AppFields.type: 'ride_accepted',
        AppFields.rideId: rideId,
        AppFields.timestamp: ServerValue.timestamp,
      });
    }
  }

  Future<void> proposeCounterFare(String rideId, double newFare) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(code: 'no-user', message: 'Not logged in');
    }

    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      AppFields.fare: newFare,
      AppFields.status: 'pending_counter',
    });

    // Notify rider via RTDB
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

  Future<void> declineRide(String rideId) async {
    await _rtdb.child('${AppPaths.ridesPendingA}/$rideId').remove();
    await _rtdb.child('${AppPaths.ridesPendingB}/$rideId').remove();

    // Notify rider via RTDB
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

  Future<void> updateRideStatus(String rideId, String newStatus) async {
    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      AppFields.status: newStatus,
      '${newStatus}At': FieldValue.serverTimestamp(),
    });

    // Notify rider via RTDB
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

  Future<void> cancelRide(String rideId) async {
    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      AppFields.status: RideStatus.cancelled,
      AppFields.driverId: FieldValue.delete(),
      'driverName': FieldValue.delete(),
      AppFields.cancelledAt: FieldValue.serverTimestamp(),
    });

    // Notify rider via RTDB
    final riderId =
        (await _fire.collection(AppPaths.ridesCollection).doc(rideId).get())
            .data()?[AppFields.riderId];
    if (riderId != null) {
      await _rtdb.child('${AppPaths.notifications}/$riderId').push().set({
        AppFields.type: 'ride_cancelled',
        AppFields.rideId: rideId,
        AppFields.timestamp: ServerValue.timestamp,
      });
    }
  }

  Future<void> completeRide(String rideId, double finalFare) async {
    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      AppFields.status: RideStatus.completed,
      AppFields.completedAt: FieldValue.serverTimestamp(),
      AppFields.finalFare: finalFare,
      AppFields.paymentStatus: 'processed',
    });

    // Notify rider via RTDB
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

final driverDashboardProvider =
    StateNotifierProvider<
      DriverDashboardController,
      AsyncValue<DocumentSnapshot<Map<String, dynamic>>?>
    >((ref) => DriverDashboardController(ref));
final _auth = FirebaseAuth.instance;

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
    final uid = _auth.currentUser?.uid;
    if (uid != null) await _service.sendMessage(rideId, message, uid);
  }
}

final pendingRequestsProvider =
    StreamProvider.autoDispose<List<PendingRequest>>((ref) {
      return DriverService().listenPendingRequestsMerged();
    });

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

  Future<void> _fetchRoute() async {
    try {
      LatLng start;
      if (_status == RideStatus.accepted || _status == RideStatus.arriving) {
        final pos = await Geolocator.getCurrentPosition();
        start = LatLng(pos.latitude, pos.longitude);
      } else {
        start = _pickup;
      }

      final LatLng end = _status == RideStatus.started ? _dropoff : _pickup;

      final route = await DirectionsService.getRoute(
        start,
        end,
        role: '',
      ).timeout(const Duration(seconds: 12));
      if (!mounted || route == null) return;

      setState(() {
        _eta = route['eta'];
        _polyline = Polyline(
          polylineId: const PolylineId('route'),
          width: 5,
          points: List<LatLng>.from(route['polyline']),
          color: Colors.blueAccent,
        );
        _mapController?.animateCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(
                min(start.latitude, end.latitude),
                min(start.longitude, end.longitude),
              ),
              northeast: LatLng(
                max(start.latitude, end.latitude),
                max(start.longitude, end.longitude),
              ),
            ),
            50,
          ),
        );
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to fetch route: $e')));
      }
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

  Future<void> _progressStatus() async {
    if (_statusBusy) return;
    String next = _status;
    if (_status == RideStatus.accepted) {
      next = RideStatus.arriving;
      _startPickupTimer();
    } else if (_status == RideStatus.arriving) {
      next = RideStatus.started;
      _pickupTimer?.cancel();
    } else if (_status == RideStatus.started) {
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
                        ? 'Arriving'
                        : _status == RideStatus.arriving
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
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: const Text('Pickup timer expired!'),
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

class FeedbackDialog extends StatefulWidget {
  final String rideId;
  final VoidCallback onSubmitted;

  const FeedbackDialog({
    super.key,
    required this.rideId,
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
                          'toUid': widget.rideId, // Fix: use riderId
                          AppFields.rating: rating,
                          AppFields.comment: comment.text.trim(),
                          AppFields.timestamp: FieldValue.serverTimestamp(),
                        });

                    // Update rider's average rating
                    // Logic to calculate average and update user doc

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
