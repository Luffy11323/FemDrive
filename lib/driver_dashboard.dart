// lib/driver/driver_dashboard.dart
// Dashboard: Riverpod-first, no duplicate Firebase listeners, clean pending popup.

// ignore: unnecessary_library_name
library driver_dashboard;

import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dart_geohash/dart_geohash.dart';
import 'package:femdrive/driver/driver_services.dart';
import 'package:femdrive/driver/driver_ride_details_page.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Earnings + past rides (kept here as they are dashboard-only)
class EarningsSummary {
  final int totalRides;
  final double totalEarnings;
  const EarningsSummary({
    required this.totalRides,
    required this.totalEarnings,
  });
}

final _auth = FirebaseAuth.instance;
final _fire = FirebaseFirestore.instance;
final _rtdb = FirebaseDatabase.instance.ref();

final earningsProvider = FutureProvider.autoDispose<EarningsSummary>((
  ref,
) async {
  final user = _auth.currentUser;
  if (user == null) {
    return const EarningsSummary(totalRides: 0, totalEarnings: 0);
  }
  final q = await _fire
      .collection(AppPaths.ridesCollection)
      .where('driverId', isEqualTo: user.uid)
      .where('status', isEqualTo: RideStatus.completed)
      .get();

  double total = 0;
  for (final d in q.docs) {
    total += (d.data()['fare'] as num?)?.toDouble() ?? 0.0;
  }
  return EarningsSummary(totalRides: q.docs.length, totalEarnings: total);
});

final pastRidesProvider =
    StreamProvider.autoDispose<QuerySnapshot<Map<String, dynamic>>>((ref) {
      final user = _auth.currentUser;
      if (user == null) return const Stream.empty();
      return _fire
          .collection(AppPaths.ridesCollection)
          .where('driverId', isEqualTo: user.uid)
          .where('status', isEqualTo: RideStatus.completed)
          .orderBy('completedAt', descending: true)
          .snapshots();
    });

class EarningsSummaryWidget extends ConsumerWidget {
  const EarningsSummaryWidget({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(earningsProvider);
    return e.when(
      data: (s) => Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Total Rides: ${s.totalRides}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Expanded(
              child: Text(
                'Total Earnings: \$${s.totalEarnings.toStringAsFixed(2)}',
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
      ),
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: LinearProgressIndicator(),
      ),
      error: (e, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Earnings unavailable'),
      ),
    );
  }
}

class PastRidesListWidget extends ConsumerWidget {
  const PastRidesListWidget({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(pastRidesProvider);
    return snap.when(
      data: (qSnap) {
        if (qSnap.docs.isEmpty) {
          return const Center(child: Text('No past rides yet.'));
        }
        return ListView.separated(
          itemCount: qSnap.docs.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (ctx, i) {
            final raw = qSnap.docs[i].data();
            final fare = (raw['fare'] as num?)?.toDouble();
            final ts = raw['completedAt'] as Timestamp?;
            final dt = ts?.toDate();
            final fareStr = fare != null
                ? '\$${fare.toStringAsFixed(2)}'
                : '--';
            final dateStr = dt != null ? dt.toLocal().toString() : '-';
            return ListTile(
              dense: true,
              title: Text('${raw['pickup'] ?? '-'} → ${raw['dropoff'] ?? '-'}'),
              subtitle: Text('Fare: $fareStr • $dateStr'),
              trailing: Text(
                (raw['status'] ?? '').toString().toUpperCase(),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load past rides')),
    );
  }
}

class IdleDashboard extends StatelessWidget {
  const IdleDashboard({super.key});
  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        EarningsSummaryWidget(),
        Expanded(child: PastRidesListWidget()),
      ],
    );
  }
}

/// Ride request popup (Riverpod-only; no duplicate listeners)
class RidePopupWidget extends ConsumerWidget {
  final PendingRequest request;
  const RidePopupWidget({super.key, required this.request});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      title: const Text('New Ride Request'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (request.pickupLabel != null) Text('From: ${request.pickupLabel}'),
          if (request.dropoffLabel != null) Text('To: ${request.dropoffLabel}'),
          Text(
            'Pickup: ${request.pickupLat.toStringAsFixed(4)}, ${request.pickupLng.toStringAsFixed(4)}',
          ),
          Text(
            'Dropoff: ${request.dropoffLat.toStringAsFixed(4)}, ${request.dropoffLng.toStringAsFixed(4)}',
          ),
          if (request.fare != null)
            Text('Fare: \$${(request.fare as num).toStringAsFixed(2)}'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Decline'),
        ),
        ElevatedButton(
          onPressed: () async {
            try {
              await ref
                  .read(driverDashboardProvider.notifier)
                  .acceptRide(request.rideId, context: request);
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Accept failed: $e')));
              }
              return;
            }
            if (context.mounted) {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      DriverRideDetailsPage(rideId: request.rideId), // ✅ fix
                ),
              );
            }
          },
          child: const Text('Accept'),
        ),
      ],
    );
  }
}

class DriverDashboard extends ConsumerStatefulWidget {
  const DriverDashboard({super.key});
  @override
  ConsumerState<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends ConsumerState<DriverDashboard> {
  bool _isOnline = false;
  late final StreamSubscription<List<ConnectivityResult>> _connSub;
  final _geoHasher = GeoHasher();
  String? _driverGeoHashPrefix; // for proximity filtering
  final Set<String> _shownRequestIds =
      {}; // prevent duplicate dialogs in session

  @override
  void initState() {
    super.initState();
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final connected =
          results.contains(ConnectivityResult.mobile) ||
          results.contains(ConnectivityResult.wifi);
      if (kDebugMode) {
        debugPrint(connected ? 'Internet Connected' : 'No Internet');
      }
    });

    // Listen to pending requests once; show dialog for first nearby request not shown yet
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listen<AsyncValue<List<PendingRequest>>>(pendingRequestsProvider, (
        prev,
        next,
      ) async {
        final list = next.asData?.value ?? const <PendingRequest>[];
        if (list.isEmpty) return;

        await _ensureDriverHashPrefix();

        for (final req in list) {
          if (_shownRequestIds.contains(req.rideId)) continue;
          final prefix = _driverGeoHashPrefix;
          bool isNearby = true;
          if (prefix != null && prefix.isNotEmpty) {
            try {
              final ph = _geoHasher.encode(
                req.pickupLat,
                req.pickupLng,
                precision: GeoCfg.popupProximityPrecision,
              );
              final checkLen = min(prefix.length, 4);
              isNearby = ph.startsWith(prefix.substring(0, checkLen));
            } catch (_) {}
          }

          if (isNearby && mounted) {
            _shownRequestIds.add(req.rideId);
            showDialog(
              context: context,
              builder: (_) => RidePopupWidget(request: req),
            );
            break;
          }
        }
      });
    });
  }

  Future<void> _ensureDriverHashPrefix() async {
    if (_driverGeoHashPrefix != null) return;
    final user = _auth.currentUser;
    if (user == null) return;
    try {
      final snap = await _rtdb
          .child(AppPaths.driversOnline)
          .child(user.uid)
          .child('geohash')
          .get();
      if (snap.exists && snap.value is String) {
        _driverGeoHashPrefix = (snap.value as String).substring(0, 5);
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      _driverGeoHashPrefix = _geoHasher.encode(
        pos.latitude,
        pos.longitude,
        precision: 5,
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _connSub.cancel();
    super.dispose();
  }

  Future<void> _toggleOnline(bool v) async {
    setState(() => _isOnline = v);
    if (v) {
      await DriverLocationService().startOnlineMode();
      await _ensureDriverHashPrefix();
    } else {
      await DriverLocationService().goOffline();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ride = ref.watch(driverDashboardProvider);

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
        child: SafeArea(
          child: Column(
            children: [
              UserAccountsDrawerHeader(
                accountName: Text(_auth.currentUser?.displayName ?? ''),
                accountEmail: Text(_auth.currentUser?.email ?? ''),
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
                  await _auth.signOut();
                  if (!mounted) return;
                  // ignore: use_build_context_synchronously
                  Navigator.of(context).popUntil((r) => r.isFirst);
                },
              ),
            ],
          ),
        ),
      ),
      body: ride.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: ${e.toString()}')),
        data: (doc) {
          if (doc == null) return const IdleDashboard();

          // Live ride doc -> render embedded map here for quick glance
          final data = doc.data();
          if (data == null) {
            return const Center(child: Text('Ride data unavailable.'));
          }
          final rideId = doc.id;

          return GoogleMap(
            initialCameraPosition: CameraPosition(
              target: data['pickupLat'] is num && data['pickupLng'] is num
                  ? LatLng(
                      (data['pickupLat'] as num).toDouble(),
                      (data['pickupLng'] as num).toDouble(),
                    )
                  : const LatLng(0, 0),
              zoom: 14,
            ),
            markers: {
              if (data['pickupLat'] is num && data['pickupLng'] is num)
                Marker(
                  markerId: const MarkerId('pickup'),
                  position: LatLng(
                    (data['pickupLat'] as num).toDouble(),
                    (data['pickupLng'] as num).toDouble(),
                  ),
                  icon: BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueAzure,
                  ),
                ),
              if (data['dropoffLat'] is num && data['dropoffLng'] is num)
                Marker(
                  markerId: const MarkerId('dropoff'),
                  position: LatLng(
                    (data['dropoffLat'] as num).toDouble(),
                    (data['dropoffLng'] as num).toDouble(),
                  ),
                  icon: BitmapDescriptor.defaultMarkerWithHue(
                    BitmapDescriptor.hueGreen,
                  ),
                ),
            },
            myLocationEnabled: true,
            myLocationButtonEnabled: true,
            onTap: (_) {
              // Navigate to full ride details
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DriverRideDetailsPage(rideId: rideId),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
