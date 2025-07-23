// ignore: unnecessary_library_name
library driver_dashboard;

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
import 'package:femdrive/location/directions_service.dart';

/// Earnings summary widget
class EarningsSummaryWidget extends StatelessWidget {
  const EarningsSummaryWidget({super.key});
  @override
  Widget build(BuildContext ctx) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    return FutureBuilder<QuerySnapshot>(
      future: FirebaseFirestore.instance
          .collection('rides')
          .where('driverId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'completed')
          .get(),
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final docs = snap.data?.docs ?? [];
        final total = docs.fold<double>(
          0,
          // ignore: avoid_types_as_parameter_names
          (sum, d) => sum + (d['fare'] as num).toDouble(),
        );
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Total Rides: ${docs.length}'),
              const SizedBox(height: 4),
              Text('Total Earnings: \$${total.toStringAsFixed(2)}'),
            ],
          ),
        );
      },
    );
  }
}

/// Past rides list widget
class PastRidesListWidget extends StatelessWidget {
  const PastRidesListWidget({super.key});
  @override
  Widget build(BuildContext ctx) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('rides')
          .where('driverId', isEqualTo: user.uid)
          .where('status', isEqualTo: 'completed')
          .orderBy('completedAt', descending: true)
          .snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.data!.docs.isEmpty) {
          return const Center(child: Text('No past rides yet.'));
        }
        return ListView.builder(
          itemCount: snap.data!.docs.length,
          itemBuilder: (ctx, i) {
            final d = snap.data!.docs[i].data()! as Map<String, dynamic>;
            final ts = d['completedAt'] as Timestamp?;
            final dt = ts?.toDate();
            return ListTile(
              title: Text('${d['pickup']} → ${d['dropoff']}'),
              subtitle: Text('Fare: \$${d['fare']} • ${dt?.toLocal() ?? '-'}'),
              trailing: Text(d['status'].toString().toUpperCase()),
            );
          },
        );
      },
    );
  }
}

/// Idle dashboard view (no active ride)
class IdleDashboard extends StatelessWidget {
  const IdleDashboard({super.key});
  @override
  Widget build(BuildContext ctx) {
    return Column(
      children: const [
        EarningsSummaryWidget(),
        Expanded(child: PastRidesListWidget()),
      ],
    );
  }
}

/// Main Driver Dashboard
class DriverDashboard extends ConsumerStatefulWidget {
  const DriverDashboard({super.key});
  @override
  ConsumerState<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends ConsumerState<DriverDashboard> {
  bool _isOnline = false;
  bool _trackingStarted = false;
  bool _mapReady = false;

  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};
  Polyline? _pickupPolyline;
  Polyline? _dropoffPolyline;

  late StreamSubscription _connSub;
  final _geo = GeoHasher();
  final _rtdb = FirebaseDatabase.instance.ref();
  StreamSubscription<DatabaseEvent>? _rideReqSub;
  String? _pickupHash;

  @override
  void initState() {
    super.initState();
    _connSub = Connectivity().onConnectivityChanged.listen((status) {
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
    _subscribeRequests();
  }

  @override
  void dispose() {
    _connSub.cancel();
    _rideReqSub?.cancel();
    super.dispose();
  }

  void _subscribeRequests() {
    _rideReqSub?.cancel();
    if (!_isOnline) return;

    _rideReqSub = _rtdb.child('rides_pending').onChildAdded.listen((evt) {
      final d = Map<String, dynamic>.from(evt.snapshot.value as Map);
      final hash = _geo.encode(d['pickupLat'], d['pickupLng'], precision: 5);
      if (_pickupHash != null && hash.startsWith(_pickupHash!)) {
        if (mounted) {
          showDialog(context: context, builder: (_) => const RidePopupWidget());
        }
      }
    });
  }

  void _toggleOnline(bool v) async {
    setState(() => _isOnline = v);
    if (v) {
      await DriverLocationService().startOnlineMode();
      _subscribeRequests();

      if (!_trackingStarted && mounted) {
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          _trackingStarted = true;
          LocationService().startTracking(user.uid, 'driver');
          final pos = await Geolocator.getCurrentPosition();
          _pickupHash = _geo.encode(pos.latitude, pos.longitude, precision: 5);
        }
      }
    } else {
      await DriverLocationService().goOffline();
      _rideReqSub?.cancel();
    }
  }

  void _addMarker(String id, LatLng p) {
    final old = _markers.firstWhere(
      (m) => m.markerId.value == id,
      orElse: () => Marker(markerId: MarkerId(id)),
    );
    final updated = old.copyWith(positionParam: p);
    setState(() {
      _markers.removeWhere((m) => m.markerId.value == id);
      _markers.add(updated);
    });
  }

  Future<void> _syncPolyline(Map<String, dynamic> data) async {
    final p = LatLng(data['pickupLat'], data['pickupLng']);
    final d = LatLng(data['dropoffLat'], data['dropoffLng']);
    final route = await DirectionsService.getRoute(p, d);
    if (mounted && route != null) {
      final pts = List<LatLng>.from(route['polyline']);
      setState(() {
        _pickupPolyline = Polyline(
          polylineId: const PolylineId('pickup'),
          color: Colors.green,
          width: 5,
          points: pts,
        );
        _dropoffPolyline = Polyline(
          polylineId: const PolylineId('dropoff'),
          color: Colors.blue,
          width: 5,
          points: pts,
        );
      });
    }
  }

  @override
  Widget build(BuildContext ctx) {
    final state = ref.watch(driverDashboardProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Driver Dashboard'),
        actions: [
          Row(
            children: [
              Text(_isOnline ? 'Online' : 'Offline'),
              Switch(value: _isOnline, onChanged: _toggleOnline),
            ],
          ),
        ],
      ),
      drawer: Drawer(
        child: Column(
          children: [
            UserAccountsDrawerHeader(
              accountName: Text(
                FirebaseAuth.instance.currentUser?.displayName ?? '',
              ),
              accountEmail: Text(
                FirebaseAuth.instance.currentUser?.email ?? '',
              ),
              currentAccountPicture: const CircleAvatar(
                child: Icon(Icons.person),
              ),
            ),
            const ListTile(
              leading: Icon(Icons.account_balance_wallet),
              title: Text('Earnings Summary'),
            ),
            const Divider(height: 1),
            const Expanded(child: PastRidesListWidget()),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Logout'),
              onTap: () async {
                await DriverLocationService().goOffline();
                await FirebaseAuth.instance.signOut();
                // ignore: use_build_context_synchronously
                if (mounted) Navigator.popUntil(ctx, (r) => r.isFirst);
              },
            ),
          ],
        ),
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: ${e.toString()}')),
        data: (rideDoc) {
          if (rideDoc == null) return const IdleDashboard();

          return StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('rides')
                .doc(rideDoc.id)
                .snapshots(),
            builder: (ctx, snap) {
              if (!snap.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final data = snap.data!.data() as Map<String, dynamic>;

              final lat = data['driverLat'] as double?;
              final lng = data['driverLng'] as double?;
              if (_mapReady && lat != null && lng != null) {
                final p = LatLng(lat, lng);
                _mapController?.animateCamera(CameraUpdate.newLatLng(p));
                _addMarker('driver', p);
              }

              _syncPolyline(data);

              return GoogleMap(
                initialCameraPosition: CameraPosition(
                  target: LatLng(data['pickupLat'], data['pickupLng']),
                  zoom: 14,
                ),
                markers: {
                  ..._markers,
                  Marker(
                    markerId: const MarkerId('pickup'),
                    position: LatLng(data['pickupLat'], data['pickupLng']),
                  ),
                  Marker(
                    markerId: const MarkerId('dropoff'),
                    position: LatLng(data['dropoffLat'], data['dropoffLng']),
                  ),
                },
                polylines: {
                  if (_pickupPolyline != null) _pickupPolyline!,
                  if (_dropoffPolyline != null) _dropoffPolyline!,
                },
                onMapCreated: (ctrl) {
                  _mapController = ctrl;
                  _mapReady = true;
                },
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
              );
            },
          );
        },
      ),
    );
  }
}
