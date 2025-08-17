// lib/driver/driver_services.dart
// Single source of truth: models, constants, services, providers, shared widgets.

library;

import 'dart:async';
import 'dart:convert';

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
// ignore: depend_on_referenced_packages
import 'package:async/async.dart';

import 'package:femdrive/location/directions_service.dart';
import 'package:femdrive/emergency_service.dart';

/// ------------------------------
/// Constants
/// ------------------------------
class AppPaths {
  static const driversOnline = 'drivers_online';
  static const ridesPendingA = 'rides_pending';
  static const ridesPendingB = 'rideRequests'; // legacy/alt node
  static const ridesCollection = 'rides';
  static const ratingsCollection = 'ratings';
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
  final _auth = FirebaseAuth.instance;

  Future<void> startOnlineMode() async {
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('[Location] No logged-in user');
      return;
    }
    final uid = user.uid;
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
                'uid': uid,
                'lat': pos.latitude,
                'lng': pos.longitude,
                'geohash': hash,
                'updatedAt': ServerValue.timestamp,
              });
            } catch (e) {
              debugPrint('[Location] RTDB write failed: $e');
            }
          },
          onError: (err) async {
            debugPrint('[Location] stream error: $err — retrying');
            await Future.delayed(const Duration(seconds: 3));
            await _positionSub?.cancel();
            _positionSub = null;
            await startOnlineMode();
          },
        );
  }

  Future<void> goOffline() async {
    final user = _auth.currentUser;
    if (user == null) return;
    final uid = user.uid;

    await _positionSub?.cancel();
    _positionSub = null;

    try {
      await _rtdb.child('${AppPaths.driversOnline}/$uid').remove();
    } catch (e) {
      debugPrint('[Location] RTDB remove failed: $e');
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
/// Core Driver Service (backend calls)
/// ------------------------------
class DriverService {
  final _fire = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _rtdb = FirebaseDatabase.instance.ref();

  /// Stream the current driver's active ride (accepted/arriving/started)
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

  /// Merge both pending-ride RTDB nodes into a single stream.
  Stream<List<PendingRequest>> listenPendingRequestsMerged() {
    Stream<List<PendingRequest>> readNode(String node) {
      return _rtdb.child(node).onValue.map((event) {
        final v = event.snapshot.value;
        if (v == null || v is! Map) return <PendingRequest>[];
        final res = <PendingRequest>[];
        // ignore: unnecessary_cast
        (v as Map).forEach((k, val) {
          if (val is Map) {
            try {
              res.add(
                PendingRequest.fromMap(
                  k.toString(),
                  // ignore: unnecessary_cast
                  Map<String, dynamic>.from(val as Map),
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

    // Combine latest lists from both streams.
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

    // Remove from both nodes (best effort)
    try {
      await _rtdb.child('${AppPaths.ridesPendingA}/$rideId').remove();
    } catch (_) {}
    try {
      await _rtdb.child('${AppPaths.ridesPendingB}/$rideId').remove();
    } catch (_) {}

    // Update Firestore ride
    await _fire.collection(AppPaths.ridesCollection).doc(rideId).set({
      'driverId': user.uid,
      'status': RideStatus.accepted,
      'acceptedAt': FieldValue.serverTimestamp(),
      if (contextData != null) ...{
        'pickupLat': contextData.pickupLat,
        'pickupLng': contextData.pickupLng,
        'dropoffLat': contextData.dropoffLat,
        'dropoffLng': contextData.dropoffLng,
      },
    }, SetOptions(merge: true));

    // Optional backend notify
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

  Future<void> updateRideStatus(String rideId, String newStatus) async {
    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      'status': newStatus,
      '${newStatus}At': FieldValue.serverTimestamp(),
    });

    // Optional backend notify
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
      'cancelledAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> completeRide(String rideId) async {
    await _fire.collection(AppPaths.ridesCollection).doc(rideId).update({
      'status': RideStatus.completed,
      'completedAt': FieldValue.serverTimestamp(),
    });
  }
}

/// ------------------------------
/// Riverpod: Single dashboard controller (keeps your current API)
/// ------------------------------
final driverDashboardProvider =
    StateNotifierProvider<
      DriverDashboardController,
      AsyncValue<DocumentSnapshot<Map<String, dynamic>>?>
    >((ref) {
      return DriverDashboardController(ref);
    });

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

  // Keep existing API that UI calls
  Future<void> acceptRide(String rideId, {PendingRequest? context}) =>
      _service.acceptRide(rideId, context);

  Future<void> updateStatus(String rideId, String newStatus) =>
      _service.updateRideStatus(rideId, newStatus);

  Future<void> cancelRide(String rideId) => _service.cancelRide(rideId);

  Future<void> completeRide(String rideId) => _service.completeRide(rideId);
}

/// ------------------------------
/// Riverpod: Pending requests provider (merged nodes)
/// ------------------------------
final pendingRequestsProvider =
    StreamProvider.autoDispose<List<PendingRequest>>((ref) {
      return DriverService().listenPendingRequestsMerged();
    });

/// ------------------------------
/// Shared Widgets (Map + Feedback)
/// ------------------------------
class DriverMapWidget extends StatefulWidget {
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
  State<DriverMapWidget> createState() => _DriverMapWidgetState();
}

class _DriverMapWidgetState extends State<DriverMapWidget> {
  late final LatLng _pickup;
  late final LatLng _dropoff;
  String _status = RideStatus.accepted;
  Set<Marker> _markers = {};
  Polyline? _polyline;
  String? _eta;
  bool _loadingRoute = true;
  bool _statusBusy = false;
  bool _emergencyBusy = false;

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
      Marker(markerId: const MarkerId('pickup'), position: _pickup),
      Marker(markerId: const MarkerId('dropoff'), position: _dropoff),
    };

    _fetchRoute();
  }

  Future<void> _fetchRoute() async {
    try {
      final route = await DirectionsService.getRoute(
        _pickup,
        _dropoff,
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
      // ignore: curly_braces_in_flow_control_structures
    } else if (_status == RideStatus.arriving)
      // ignore: curly_braces_in_flow_control_structures
      next = RideStatus.started;
    // ignore: curly_braces_in_flow_control_structures
    else if (_status == RideStatus.started)
      // ignore: curly_braces_in_flow_control_structures
      next = RideStatus.completed;
    // ignore: curly_braces_in_flow_control_structures
    else {
      return;
    }

    setState(() => _statusBusy = true);
    try {
      await DriverService().updateRideStatus(
        widget.rideData['rideId'] as String,
        next,
      );
      _status = next;
      widget.onStatusChange(next);
      if (next == RideStatus.completed) widget.onComplete();
      if (mounted) setState(() {});
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
      final isDriver = widget.rideData['driverId'] == currentUid;
      final otherUid = isDriver
          ? widget.rideData['riderId']
          : widget.rideData['driverId'];
      if (otherUid == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Unable to identify other user.')),
          );
        }
        return;
      }

      await EmergencyService.sendEmergency(
        rideId: widget.rideData['rideId'] as String,
        currentUid: currentUid,
        otherUid: otherUid as String,
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
          onMapCreated: widget.onMapCreated,
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

/// Simple reusable dialog for rating
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
                          'rating': rating,
                          'comment': comment.text.trim(),
                          'createdAt': FieldValue.serverTimestamp(),
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
