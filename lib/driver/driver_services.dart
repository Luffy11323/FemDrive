// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:dart_geohash/dart_geohash.dart';
import 'package:http/http.dart' as http;
import 'package:async/async.dart';

import 'package:femdrive/location/directions_service.dart';
import 'package:femdrive/emergency_service.dart';

/// ------------------------------
/// Constants
/// ------------------------------
class AppPaths {
  static const driversOnline = 'drivers_online';
  static const ridesPendingA = 'rides_pending';
  static const ridesPendingB = 'rideRequests';
  static const ridesCollection = 'rides';
  static const ratingsCollection = 'ratings';
  static const locationsCollection = 'locations';
  static const driverLocations = 'driverLocations';
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

/// ------------------------------
/// Models
/// ------------------------------
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
      pickupLabel: map['pickup']?.toString(),
      dropoffLabel: map['dropoff']?.toString(),
      pickupLat: (map['pickupLat'] as num?)?.toDouble() ?? 0,
      pickupLng: (map['pickupLng'] as num?)?.toDouble() ?? 0,
      dropoffLat: (map['dropoffLat'] as num?)?.toDouble() ?? 0,
      dropoffLng: (map['dropoffLng'] as num?)?.toDouble() ?? 0,
      fare: (map['fare'] as num?),
      raw: Map<String, dynamic>.from(map),
    );
  }

  LatLng get pickupPos => LatLng(pickupLat, pickupLng);
  LatLng get dropoffPos => LatLng(dropoffLat, dropoffLng);
}

/// ------------------------------
/// Driver Location Service
/// ------------------------------
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
              // Update drivers_online for ride request matching
              await _rtdb.child('${AppPaths.driversOnline}/$uid').set({
                'uid': uid,
                'lat': pos.latitude,
                'lng': pos.longitude,
                'geohash': hash,
                'updatedAt': ServerValue.timestamp,
              });

              // Update driverLocations for rider dashboard
              await _firestore
                  .collection('users')
                  .doc(uid)
                  .collection(AppPaths.driverLocations)
                  .doc(DateTime.now().toIso8601String())
                  .set({
                    'latitude': pos.latitude,
                    'longitude': pos.longitude,
                    'timestamp': FieldValue.serverTimestamp(),
                    'status': 'available',
                  });

              // Update active ride with driver location
              if (_activeRideId != null) {
                await _firestore
                    .collection(AppPaths.ridesCollection)
                    .doc(_activeRideId)
                    .update({
                      'driverLat': pos.latitude,
                      'driverLng': pos.longitude,
                    });

                // Log historical location
                await _firestore
                    .collection(AppPaths.locationsCollection)
                    .doc(_activeRideId)
                    .collection('driver')
                    .doc(uid)
                    .collection('positions')
                    .doc(DateTime.now().toIso8601String())
                    .set({
                      'latitude': pos.latitude,
                      'longitude': pos.longitude,
                      'timestamp': FieldValue.serverTimestamp(),
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
            'latitude': 0.0,
            'longitude': 0.0,
            'timestamp': FieldValue.serverTimestamp(),
            'status': 'offline',
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

/// ------------------------------
/// Core Driver Service
/// ------------------------------
class DriverService {
  final _fire = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _rtdb = FirebaseDatabase.instance.ref();

  Stream<DocumentSnapshot<Map<String, dynamic>>?> listenActiveRide() {
    final user = _auth.currentUser;
    if (user == null) return const Stream.empty();

    final q = _fire
        .collection(AppPaths.ridesCollection)
        .where('driverId', isEqualTo: user.uid)
        .where('status', whereIn: RideStatus.ongoingSet.toList())
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
    final driverName = userDoc.data()?['username'] ?? 'Unknown Driver';

    await _fire.collection(AppPaths.ridesCollection).doc(rideId).set({
      'driverId': user.uid,
      'driverName': driverName,
      'status': RideStatus.accepted,
      'acceptedAt': FieldValue.serverTimestamp(),
      if (contextData != null) ...{
        'pickupLat': contextData.pickupLat,
        'pickupLng': contextData.pickupLng,
        'dropoffLat': contextData.dropoffLat,
        'dropoffLng': contextData.dropoffLng,
      },
    }, SetOptions(merge: true));

    try {
      final res = await http.post(
        Uri.parse('https://fem-drive.vercel.app/api/accept/driver'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'rideId': rideId, 'driverUid': user.uid}),
      );
      if (res.statusCode != 200) {
        debugPrint('[ACCEPT] backend reply: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      debugPrint('[ACCEPT] notify error: $e');
    }
  }

  Future<void> proposeCounterFare(String rideId, double newFare) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(code: 'no-user', message: 'Not logged in');
    }

    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      'fare': newFare,
      'status': 'pending_counter', // Custom status for rider to accept
    });

    try {
      final res = await http.post(
        Uri.parse('https://fem-drive.vercel.app/api/notify/status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'rideId': rideId,
          'status': 'counter_fare',
          'counterFare': newFare,
          'driverUid': user.uid,
        }),
      );
      if (res.statusCode != 200) {
        debugPrint('[COUNTER] backend reply: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      debugPrint('[COUNTER] notify error: $e');
    }
  }

  Future<void> updateRideStatus(String rideId, String newStatus) async {
    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      'status': newStatus,
      '${newStatus}At': FieldValue.serverTimestamp(),
    });

    try {
      final response = await http.post(
        Uri.parse('https://fem-drive.vercel.app/api/notify/status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'rideId': rideId, 'status': newStatus}),
      );
      if (response.statusCode != 200) {
        debugPrint('[FCM] status change failed: ${response.body}');
      }
    } catch (e) {
      debugPrint('[FCM] notify error: $e');
    }
  }

  Future<void> cancelRide(String rideId) async {
    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      'status': RideStatus.cancelled,
      'driverId': FieldValue.delete(),
      'driverName': FieldValue.delete(),
      'cancelledAt': FieldValue.serverTimestamp(),
    });

    try {
      final response = await http.post(
        Uri.parse('https://fem-drive.vercel.app/api/notify/status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'rideId': rideId, 'status': RideStatus.cancelled}),
      );
      if (response.statusCode != 200) {
        debugPrint('[FCM] cancel failed: ${response.body}');
      }
    } catch (e) {
      debugPrint('[FCM] notify error: $e');
    }
  }

  Future<void> completeRide(String rideId) async {
    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      'status': RideStatus.completed,
      'completedAt': FieldValue.serverTimestamp(),
    });

    try {
      final response = await http.post(
        Uri.parse('https://fem-drive.vercel.app/api/notify/status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'rideId': rideId, 'status': RideStatus.completed}),
      );
      if (response.statusCode != 200) {
        debugPrint('[FCM] complete failed: ${response.body}');
      }
    } catch (e) {
      debugPrint('[FCM] notify error: $e');
    }
  }
}

/// ------------------------------
/// Riverpod Providers
/// ------------------------------
final driverDashboardProvider =
    StateNotifierProvider<
      DriverDashboardController,
      AsyncValue<DocumentSnapshot<Map<String, dynamic>>?>
    >((ref) => DriverDashboardController(ref));

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

  Future<void> updateStatus(String rideId, String newStatus) =>
      _service.updateRideStatus(rideId, newStatus);

  Future<void> cancelRide(String rideId) => _service.cancelRide(rideId);

  Future<void> completeRide(String rideId) => _service.completeRide(rideId);
}

final pendingRequestsProvider =
    StreamProvider.autoDispose<List<PendingRequest>>((ref) {
      return DriverService().listenPendingRequestsMerged();
    });

/// ------------------------------
/// Shared Widgets (Map + Feedback)
/// ------------------------------
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

  @override
  void initState() {
    super.initState();
    _pickup = LatLng(
      (widget.rideData['pickupLat'] as num).toDouble(),
      (widget.rideData['pickupLng'] as num).toDouble(),
    );
    _dropoff = LatLng(
      (widget.rideData['dropoffLat'] as num).toDouble(),
      (widget.rideData['dropoffLng'] as num).toDouble(),
    );
    _status = (widget.rideData['status'] as String?) ?? RideStatus.accepted;

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

  Future<void> _progressStatus() async {
    if (_statusBusy) return;
    String next = _status;
    if (_status == RideStatus.accepted) {
      next = RideStatus.arriving;
    } else if (_status == RideStatus.arriving) {
      next = RideStatus.started;
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
      if (next == RideStatus.completed) widget.onComplete();
      if (mounted) {
        setState(() {});
        _fetchRoute(); // Update route for new status
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
      final otherUid = widget.rideData['riderId'] as String?;
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
      ],
    );
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
                          'toUid': widget.rideId, // Rider ID needed
                          'rating': rating,
                          'comment': comment.text.trim(),
                          'createdAt': FieldValue.serverTimestamp(),
                        });

                    if (!mounted) return;
                    Navigator.of(context).pop();
                    widget.onSubmitted();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Thank you for your feedback!'),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
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
