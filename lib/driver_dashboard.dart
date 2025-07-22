import 'dart:async';
import 'package:femdrive/location/location_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../driver/driver_services.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:dart_geohash/dart_geohash.dart';

class DriverDashboard extends ConsumerStatefulWidget {
  const DriverDashboard({super.key});
  @override
  ConsumerState<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends ConsumerState<DriverDashboard> {
  bool _trackingStarted = false;
  GoogleMapController? _mapController;
  late StreamSubscription _connectionSub;
  final _rtdb = FirebaseDatabase.instance.ref();
  final _geo = GeoHasher();
  StreamSubscription<DatabaseEvent>? _rideRequestSub;
  String? _currentPickupHash;

  @override
  void initState() {
    super.initState();

    _connectionSub = Connectivity().onConnectivityChanged.listen((status) {
      // ignore: unrelated_type_equality_checks
      if (status == ConnectivityResult.none && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No internet. Working offline...'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    });

    _subscribeToRequests();
  }

  void _subscribeToRequests() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Listener on RTDB rides_pending
    final sub = _rtdb.child('rides_pending').onChildAdded;
    _rideRequestSub = sub.listen((evt) {
      final data = Map<String, dynamic>.from(evt.snapshot.value as Map);
      final lat = data['pickupLat'] as double;
      final lng = data['pickupLng'] as double;
      // Compare geohash with driver's current location hash (subscribe only if driver's tracking)
      if (_currentPickupHash != null) {
        final reqHash = _geo.encode(lat, lng, precision: 5);
        if (reqHash.startsWith(_currentPickupHash!) && mounted) {
          // Show popup for new ride
          showDialog(context: context, builder: (_) => RidePopupWidget());
        }
      }
    });
  }

  @override
  void dispose() {
    _connectionSub.cancel();
    _rideRequestSub?.cancel();
    super.dispose();
  }

  final Set<Marker> _markers = {};

  void _addOrUpdateMarker(String id, LatLng position) {
    final existing = _markers.firstWhere(
      (m) => m.markerId.value == id,
      orElse: () => Marker(markerId: MarkerId(id)),
    );
    final updated = existing.copyWith(positionParam: position);
    setState(() {
      _markers.removeWhere((m) => m.markerId.value == id);
      _markers.add(updated);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(driverDashboardProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Driver Dashboard'),
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
      ),
      drawer: Drawer(
        child: ListView(
          children: [
            UserAccountsDrawerHeader(
              accountName: Text(
                FirebaseAuth.instance.currentUser?.displayName ?? 'Driver',
              ),
              accountEmail: Text(
                FirebaseAuth.instance.currentUser?.email ?? '',
              ),
              currentAccountPicture: const CircleAvatar(
                child: Icon(Icons.person),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Logout'),
              onTap: () async {
                await DriverLocationService().goOffline(); // RTDB offline
                await FirebaseAuth.instance.signOut();
                if (mounted) {
                  // ignore: use_build_context_synchronously
                  Navigator.popUntil(context, (r) => r.isFirst);
                }
              },
            ),
          ],
        ),
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text(
            e is FirebaseException
                ? 'Firebase error: ${e.message}'
                : 'Something went wrong',
          ),
        ),
        data: (rideDoc) {
          if (rideDoc == null) return const RidePopupWidget();

          final rideId = rideDoc.id;
          return StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('rides')
                .doc(rideId)
                .snapshots(),
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = snap.data!.data()! as Map<String, dynamic>;

              if (data['status'] == 'accepted' && !_trackingStarted) {
                _trackingStarted = true;
                final currentUser = FirebaseAuth.instance.currentUser;
                if (currentUser != null) {
                  LocationService().startTracking(currentUser.uid, 'driver');
                }
                // capture driver's current geohash prefix for filtering requests
                Geolocator.getCurrentPosition().then((pos) {
                  final prefix = _geo.encode(
                    pos.latitude,
                    pos.longitude,
                    precision: 5,
                  );
                  _currentPickupHash = prefix;
                });
              }

              final lat = data['driverLat'] as double?;
              final lng = data['driverLng'] as double?;
              if (lat != null && lng != null) {
                final pos = LatLng(lat, lng);
                _mapController?.animateCamera(CameraUpdate.newLatLng(pos));
                _addOrUpdateMarker('driver', pos);
              }

              return DriverMapWidget(
                rideData: data,
                onMapCreated: (ctrl) => _mapController = ctrl,
                onStatusChange: (ns) => ref
                    .read(driverDashboardProvider.notifier)
                    .updateStatus(rideId, ns),
                onComplete: () async {
                  await ref
                      .read(driverDashboardProvider.notifier)
                      .completeRide(rideId);
                  if (mounted) {
                    showDialog(
                      // ignore: use_build_context_synchronously
                      context: context,
                      builder: (_) => FeedbackDialog(
                        rideId: rideId,
                        onSubmitted: () =>
                            ref.invalidate(driverDashboardProvider),
                      ),
                    );
                  }
                },
              );
            },
          );
        },
      ),
    );
  }
}
