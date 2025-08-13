// ignore: unnecessary_library_name
library driver_services;

import 'dart:async';
import 'dart:convert';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:dart_geohash/dart_geohash.dart';
// ignore: unused_import
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:femdrive/location/directions_service.dart';
import 'package:femdrive/emergency_service.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:http/http.dart' as http;

/// DRIVER LOCATION SERVICE — writes to RTDB at `/drivers_online/$uid`
class DriverLocationService {
  StreamSubscription<Position>? _positionSub;
  final _rtdb = FirebaseDatabase.instance.ref();
  final _auth = FirebaseAuth.instance;

  Future<void> startOnlineMode() async {
    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('[Location] ERROR: No logged-in user');
      return;
    }
    final uid = user.uid;
    final geoHasher = GeoHasher();

    final bgEnabled = await FlutterBackground.initialize();
    if (bgEnabled) {
      await FlutterBackground.enableBackgroundExecution();
      debugPrint('[Location] Background execution enabled.');
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
              precision: 9,
            );
            await _rtdb.child('drivers_online/$uid').set({
              'uid': uid,
              'lat': pos.latitude,
              'lng': pos.longitude,
              'geohash': hash,
              'updatedAt': ServerValue.timestamp,
            });
          },
          onError: (err) async {
            debugPrint('[Location] Position error: $err — retrying...');
            await Future.delayed(const Duration(seconds: 3));
            startOnlineMode();
          },
        );
  }

  Future<void> goOffline() async {
    final user = _auth.currentUser;
    if (user == null) return;
    final uid = user.uid;

    await _positionSub?.cancel();
    _positionSub = null;

    await _rtdb.child('drivers_online/$uid').remove();

    if (FlutterBackground.isBackgroundExecutionEnabled) {
      await FlutterBackground.disableBackgroundExecution();
      debugPrint('[Location] Background execution disabled.');
    }
  }
}

/// DRIVER SERVICE — manages pending rides in RTDB `/rides_pending/$rideId`
class DriverService {
  final _fire = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _rtdb = FirebaseDatabase.instance.ref();

  /// Listen to the active ride document for the current driver.
  Stream<DocumentSnapshot<Map<String, dynamic>>> listenActiveRide() {
    final user = _auth.currentUser;
    if (user == null) {
      // Return an empty stream if not logged in
      return const Stream.empty();
    }
    // Listen for rides where driverId == current user and status is not completed/cancelled
    return _fire
        .collection('rides')
        .where('driverId', isEqualTo: user.uid)
        .where('status', whereIn: ['accepted', 'arriving', 'started'])
        .limit(1)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs.isNotEmpty ? snapshot.docs.first : null,
        )
        .where((doc) => doc != null)
        .cast<DocumentSnapshot<Map<String, dynamic>>>();
  }

  /// Convert pending rides from RTDB into Firestore assignments.
  Stream<DatabaseEvent> listenPendingRides() {
    return _rtdb.child('rides_pending').onValue;
  }

  Future<void> acceptRide(String rideId) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw FirebaseAuthException(code: 'no-user', message: 'Not logged in');
    }

    // Remove matching RTDB pending ride
    await _rtdb.child('rides_pending/$rideId').remove();

    // Update Firestore
    await _fire.collection('rides').doc(rideId).update({
      'driverId': user.uid,
      'status': 'accepted',
      'acceptedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateRideStatus(String rideId, String newStatus) async {
    await _fire.collection('rides').doc(rideId).update({
      'status': newStatus,
      '${newStatus}At': FieldValue.serverTimestamp(),
    });

    // 🔔 Trigger notification
    try {
      final response = await http.post(
        Uri.parse('https://fem-drive.vercel.app/api/notify/status'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'rideId': rideId, 'status': newStatus}),
      );

      if (response.statusCode != 200) {
        debugPrint('[FCM] Failed to notify status change: ${response.body}');
      }
    } catch (e) {
      debugPrint('[FCM] Notification error: $e');
    }
  }

  Future<void> cancelRide(String rideId) {
    return _fire.collection('rides').doc(rideId).update({
      'status': 'cancelled',
      'driverId': FieldValue.delete(),
      'cancelledAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> completeRide(String rideId) {
    return _fire.collection('rides').doc(rideId).update({
      'status': 'completed',
      'completedAt': FieldValue.serverTimestamp(),
    });
  }
}

/// DRIVER MAP WIDGET
class DriverMapWidget extends StatefulWidget {
  final Map<String, dynamic> rideData;
  final Function(String newStatus) onStatusChange;
  final VoidCallback onComplete;
  final void Function(GoogleMapController) onMapCreated;

  const DriverMapWidget({
    super.key,
    required this.rideData,
    required this.onStatusChange,
    required this.onComplete,
    required this.onMapCreated,
  });

  @override
  State<DriverMapWidget> createState() => _DriverMapWidgetState();
}

class _DriverMapWidgetState extends State<DriverMapWidget> {
  late LatLng pickup;
  late LatLng dropoff;
  String status = 'accepted';
  Set<Marker> _markers = {};
  Polyline? _polyline;
  String? _eta;
  bool _isStatusChanging = false;
  bool _isSendingEmergency = false;
  bool _loadingRoute = true;

  @override
  void initState() {
    super.initState();
    pickup = LatLng(widget.rideData['pickupLat'], widget.rideData['pickupLng']);
    dropoff = LatLng(
      widget.rideData['dropoffLat'],
      widget.rideData['dropoffLng'],
    );
    status = widget.rideData['status'] ?? 'accepted';
    _markers = {
      Marker(markerId: const MarkerId('pickup'), position: pickup),
      Marker(markerId: const MarkerId('dropoff'), position: dropoff),
    };
    _fetchRoute();
  }

  Future<void> _fetchRoute() async {
    try {
      final routeData = await DirectionsService.getRoute(
        pickup,
        dropoff,
      ).timeout(const Duration(seconds: 10));
      if (routeData == null) throw 'No route returned';
      setState(() {
        _eta = routeData['eta'];
        _polyline = Polyline(
          polylineId: const PolylineId('route'),
          color: Colors.blue,
          width: 5,
          points: routeData['polyline'],
        );
      });
    } catch (e) {
      debugPrint('[Map] fetchRoute error: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to fetch route: $e')));
      }
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  void _changeStatus() async {
    if (_isStatusChanging) return;
    setState(() => _isStatusChanging = true);

    String next;
    if (status == 'accepted') {
      next = 'arriving';
    } else if (status == 'arriving') {
      next = 'started';
    } else if (status == 'started') {
      next = 'completed';
    } else {
      setState(() => _isStatusChanging = false);
      return;
    }

    try {
      await DriverService().updateRideStatus(widget.rideData['rideId'], next);
      widget.onStatusChange(next);
      setState(() => status = next);
      if (next == 'completed') widget.onComplete();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Status update failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _isStatusChanging = false);
    }
  }

  void _sendEmergency() async {
    if (_isSendingEmergency) return;

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

    setState(() => _isSendingEmergency = true);
    try {
      final currentUid = FirebaseAuth.instance.currentUser!.uid;
      final isDriver = widget.rideData['driverId'] == currentUid;
      final otherUid = isDriver
          ? widget.rideData['riderId']
          : widget.rideData['driverId'];

      if (otherUid == null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Unable to identify other user.')),
        );
        return;
      }

      await EmergencyService.sendEmergency(
        rideId: widget.rideData['rideId'],
        currentUid: currentUid,
        otherUid: otherUid,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Emergency sent')));
      }
    } catch (e) {
      debugPrint('[Map] emergency failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Emergency failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSendingEmergency = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(target: pickup, zoom: 15),
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
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white70,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('ETA: $_eta'),
            ),
          ),
        Positioned(
          bottom: 100,
          left: 20,
          right: 20,
          child: ElevatedButton(
            onPressed: _isStatusChanging ? null : _changeStatus,
            child: _isStatusChanging
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    status == 'accepted'
                        ? 'Arriving'
                        : status == 'arriving'
                        ? 'Start Ride'
                        : 'Complete Ride',
                  ),
          ),
        ),
        Positioned(
          bottom: 30,
          left: 20,
          right: 20,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: _isSendingEmergency ? null : _sendEmergency,
            child: _isSendingEmergency
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Emergency'),
          ),
        ),
      ],
    );
  }
}

/// DRIVER RIDE DETAILS PAGE
class DriverRideDetailsPage extends StatelessWidget {
  final String rideId;

  const DriverRideDetailsPage({super.key, required this.rideId});

  @override
  Widget build(BuildContext context) {
    // Recommend keeping the async logic separate to avoid overloading this method
    // If needed, refactor into StatefulWidget again
    return Scaffold(
      appBar: AppBar(title: const Text('Ride Request')),
      body: Center(
        child: Text('Implement async UI logic or call showModal here.'),
      ),
    );
  }
}

/// RIDE POPUP WIDGET
class RidePopupWidget extends ConsumerWidget {
  const RidePopupWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final service = DriverService();
    return StreamBuilder(
      stream: service.listenPendingRides(),
      builder: (ctx, snapshot) {
        if (!snapshot.hasData || snapshot.data!.snapshot.children.isEmpty) {
          return const Center(child: Text('Waiting for ride requests...'));
        }
        final rideSnapshot = snapshot.data!.snapshot.children.first;
        final data = rideSnapshot.value as Map<String, dynamic>;
        return AlertDialog(
          title: const Text('New Ride Request'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('From: ${data['pickup']}'),
              Text('To: ${data['dropoff']}'),
              Text('fare: \$${data['fare']}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                ref
                    .read(driverDashboardProvider.notifier)
                    .acceptRide(rideSnapshot.key as String);
                Navigator.of(context).pop();
              },
              child: const Text('Accept'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Dismiss'),
            ),
          ],
        );
      },
    );
  }
}

/// FEEDBACK DIALOG
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
                  if (comment.text.isEmpty) {
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

                    await FirebaseFirestore.instance.collection('ratings').add({
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
                    // ignore: use_build_context_synchronously
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Thank you for your feedback!'),
                      ),
                    );
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
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Submit'),
        ),
      ],
    );
  }
}

/// RIDE POPUP WIDGET
final driverDashboardProvider =
    StateNotifierProvider<
      DriverDashboardController,
      AsyncValue<DocumentSnapshot?>
    >((ref) {
      return DriverDashboardController(ref);
    });

class DriverDashboardController
    extends StateNotifier<AsyncValue<DocumentSnapshot?>> {
  final Ref ref;
  final _service = DriverService();
  final _auth = FirebaseAuth.instance;
  final _rtdb = FirebaseDatabase.instance.ref();

  DriverDashboardController(this.ref) : super(const AsyncLoading()) {
    _loadRide();
  }

  void _loadRide() {
    _service.listenActiveRide().listen((doc) {
      state = AsyncValue.data(doc);
    });
  }

  Future<void> acceptRide(String rideId) async {
    final user = _auth.currentUser;
    if (user == null) throw FirebaseAuthException(code: 'no-user');

    await _rtdb.child('rides_pending/$rideId').remove();

    try {
      final response = await http.post(
        Uri.parse('https://fem-drive.vercel.app/api/accept/driver'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'rideId': rideId, 'driverUid': user.uid}),
      );

      if (response.statusCode != 200) {
        debugPrint('[ACCEPT] Backend error: ${response.body}');
      }
    } catch (e) {
      debugPrint('[ACCEPT] Exception: $e');
    }
  }

  Future<void> updateStatus(String rideId, String newStatus) async {
    try {
      await _service.updateRideStatus(rideId, newStatus);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> cancelRide(String rideId) async {
    try {
      await _service.cancelRide(rideId);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> completeRide(String rideId) async {
    try {
      await _service.completeRide(rideId);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}

class RiderMapWidget extends StatefulWidget {
  final Map<String, dynamic> rideData;

  const RiderMapWidget({super.key, required this.rideData});

  @override
  State<RiderMapWidget> createState() => _RiderMapWidgetState();
}

class _RiderMapWidgetState extends State<RiderMapWidget> {
  Set<Marker> _markers = {};
  Polyline? _polyline;
  String? _eta;

  @override
  void initState() {
    super.initState();
    _markers = {
      Marker(
        markerId: const MarkerId('pickup'),
        position: LatLng(
          widget.rideData['pickupLat'],
          widget.rideData['pickupLng'],
        ),
      ),
      Marker(
        markerId: const MarkerId('dropoff'),
        position: LatLng(
          widget.rideData['dropoffLat'],
          widget.rideData['dropoffLng'],
        ),
      ),
    };
    _fetchRoute();
  }

  Future<void> _fetchRoute() async {
    final pickup = LatLng(
      widget.rideData['pickupLat'],
      widget.rideData['pickupLng'],
    );
    final dropoff = LatLng(
      widget.rideData['dropoffLat'],
      widget.rideData['dropoffLng'],
    );
    final routeData = await DirectionsService.getRoute(pickup, dropoff);
    if (routeData != null) {
      setState(() {
        _eta = routeData['eta'];
        _polyline = Polyline(
          polylineId: const PolylineId('route'),
          color: Colors.blue,
          width: 5,
          points: routeData['polyline'],
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(
            target: _markers.first.position,
            zoom: 14,
          ),
          markers: _markers,
          polylines: _polyline == null ? {} : {_polyline!},
          myLocationEnabled: true,
        ),
        if (_eta != null)
          Positioned(
            top: 20,
            left: 20,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white70,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('ETA: $_eta'),
            ),
          ),
        Positioned(
          bottom: 20,
          left: 20,
          right: 20,
          child: ElevatedButton.icon(
            onPressed: () async {
              final data = widget.rideData;
              await EmergencyService.sendEmergency(
                rideId: data['rideId'],
                currentUid: FirebaseAuth.instance.currentUser!.uid,
                otherUid: data['driverId']!,
              );
              if (mounted) {
                // ignore: use_build_context_synchronously
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Emergency reported')),
                );
              }
            },
            icon: const Icon(Icons.warning),
            label: const Text('Emergency'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
          ),
        ),
      ],
    );
  }
}

class DriverMapPage extends StatelessWidget {
  final Map<String, dynamic> rideData;
  const DriverMapPage({super.key, required this.rideData});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Active Ride Map')),
      body: DriverMapWidget(
        rideData: rideData,
        onMapCreated: (mapController) => {},
        onStatusChange: (newStatus) {
          FirebaseFirestore.instance
              .collection('rides')
              .doc(rideData['rideId'])
              .update({'status': newStatus});
        },
        onComplete: () {
          Navigator.of(context).popUntil((r) => r.isFirst);
        },
      ),
    );
  }
}
