// lib/driver/driver_dashboard.dart
// Dashboard: Riverpod-first, no duplicate Firebase listeners, clean pending popup.

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
import 'package:flutter_animate/flutter_animate.dart';
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

/// ---------- UID MECHANISM UPDATED ----------
String? universalUid; // will hold the driver UID globally

Future<String?> getDriverUid() async {
  if (universalUid != null) return universalUid;
  final user = _auth.currentUser;
  if (user != null) {
    universalUid = user.uid;
    return universalUid;
  }
  return null;
}

/// ---------- Providers using universal UID ----------
final earningsProvider = FutureProvider.autoDispose<EarningsSummary>((
  ref,
) async {
  final uid = await getDriverUid();
  if (uid == null) {
    return const EarningsSummary(totalRides: 0, totalEarnings: 0);
  }
  final q = await _fire
      .collection(AppPaths.ridesCollection)
      .where('driverId', isEqualTo: uid)
      .where('status', isEqualTo: RideStatus.completed)
      .get();

  double total = 0;
  for (final d in q.docs) {
    total += (d.data()['fare'] as num?)?.toDouble() ?? 0.0;
  }
  return EarningsSummary(totalRides: q.docs.length, totalEarnings: total);
});

final pastRidesProvider =
    StreamProvider.autoDispose<QuerySnapshot<Map<String, dynamic>>>((
      ref,
    ) async* {
      final uid = await getDriverUid();
      if (uid == null) return;

      yield* _fire
          .collection(AppPaths.ridesCollection)
          .where('driverId', isEqualTo: uid)
          .where('status', isEqualTo: RideStatus.completed)
          .orderBy('completedAt', descending: true)
          .snapshots();
    });

class EarningsSummaryWidget extends ConsumerWidget {
  const EarningsSummaryWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(earningsProvider);
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Total Rides: ${e.asData?.value.totalRides ?? 0}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Total Earnings: \$${e.asData?.value.totalEarnings.toStringAsFixed(2) ?? '0.00'}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.account_balance_wallet,
              color: Colors.green,
              size: 40,
            ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 400.ms);
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
          return const Center(
            child: Text('No past rides yet.'),
          ).animate().fadeIn(duration: 400.ms);
        }
        return ListView.separated(
          padding: const EdgeInsets.all(8),
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
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                dense: true,
                title: Text(
                  '${raw['pickup'] ?? '-'} → ${raw['dropoff'] ?? '-'}',
                ),
                subtitle: Text('Fare: $fareStr • $dateStr'),
                trailing: Chip(
                  label: Text(
                    (raw['status'] ?? '').toString().toUpperCase(),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  backgroundColor: Colors.green.shade100,
                ),
              ),
            ).animate().slideX(
              begin: 0.1 * (i % 2 == 0 ? 1 : -1),
              end: 0,
              duration: 400.ms,
              delay: (100 * i).ms,
            );
          },
        );
      },
      loading: () => const Center(
        child: CircularProgressIndicator(),
      ).animate().fadeIn(duration: 400.ms),
      error: (e, _) => Center(
        child: Text('Failed to load past rides'),
      ).animate().fadeIn(duration: 400.ms),
    );
  }
}

class IdleDashboard extends StatelessWidget {
  const IdleDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const EarningsSummaryWidget(),
        Expanded(child: const PastRidesListWidget()),
      ],
    );
  }
}

class RidePopupWidget extends ConsumerWidget {
  final PendingRequest request;

  const RidePopupWidget({super.key, required this.request});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('New Ride Request'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (request.pickupLabel != null)
            Text(
              'From: ${request.pickupLabel}',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          if (request.dropoffLabel != null)
            Text(
              'To: ${request.dropoffLabel}',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          Text(
            'Pickup: ${request.pickupLat.toStringAsFixed(4)}, ${request.pickupLng.toStringAsFixed(4)}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            'Dropoff: ${request.dropoffLat.toStringAsFixed(4)}, ${request.dropoffLng.toStringAsFixed(4)}',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (request.fare != null)
            Text(
              'Fare: \$${(request.fare as num).toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
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
                  builder: (_) => DriverRideDetailsPage(rideId: request.rideId),
                ),
              );
            }
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: const Text('Accept'),
        ),
      ],
    ).animate().scale(duration: 300.ms);
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
  String? _driverGeoHashPrefix;
  final Set<String> _shownRequestIds = {};

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

    getDriverUid().then((uid) {
      if (uid == null) return;
      _fire.collection('users').doc(uid).snapshots().listen((snap) async {
        if (!mounted) return;
        final data = snap.data();
        if (data == null) return;
        final isVerified = data['verified'] as bool? ?? true;
        if (!isVerified) {
          await DriverLocationService().goOffline();
          await _auth.signOut();
          if (!mounted) return;
          Navigator.of(context).popUntil((r) => r.isFirst);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('You have been logged out.')),
          );
        }
      });
    });
  }

  Future<void> _ensureDriverHashPrefix() async {
    if (_driverGeoHashPrefix != null) return;
    final uid = await getDriverUid();
    if (uid == null) return;

    try {
      final snap = await _rtdb
          .child(AppPaths.driversOnline)
          .child(uid)
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
            // ignore: use_build_context_synchronously
            context: context,
            builder: (_) => RidePopupWidget(request: req),
          );
          break;
        }
      }
    });

    return Theme(
      data: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Theme.of(context).brightness,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ),
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Driver Dashboard',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          actions: [
            Row(
              children: [
                Text(
                  _isOnline ? 'Online' : 'Offline',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(width: 8),
                Switch(
                  value: _isOnline,
                  onChanged: _toggleOnline,
                  activeThumbColor: Colors.green,
                ),
              ],
            ),
          ],
        ),
        drawer: Drawer(child: _buildDrawer()),
        body: ref
            .watch(driverDashboardProvider)
            .when(
              loading: () => const Center(
                child: CircularProgressIndicator(),
              ).animate().fadeIn(duration: 400.ms),
              error: (e, _) => Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error, color: Colors.red, size: 48),
                    const SizedBox(height: 16),
                    Text('Error: ${e.toString()}'),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: () => ref.invalidate(driverDashboardProvider),
                      child: const Text('Retry'),
                    ),
                  ],
                ).animate().fadeIn(duration: 400.ms),
              ),
              data: (doc) => AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: doc == null
                    ? const IdleDashboard(key: ValueKey('idle'))
                    : _buildMapView(doc, doc.id),
              ),
            ),
        floatingActionButton: ref
            .watch(driverDashboardProvider)
            .when(
              data: (doc) => doc == null
                  ? FloatingActionButton(
                      onPressed: () => Scaffold.of(context).openDrawer(),
                      tooltip: 'Menu',
                      child: const Icon(Icons.menu),
                    )
                  : null,
              loading: () => null,
              error: (_, _) => null,
            ),
      ),
    );
  }

  Widget _buildDrawer() {
    return SafeArea(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          UserAccountsDrawerHeader(
            accountName: Text(_auth.currentUser?.displayName ?? 'Driver'),
            accountEmail: Text(_auth.currentUser?.email ?? 'No email'),
            currentAccountPicture: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: const Icon(Icons.person, color: Colors.white),
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
            ),
          ).animate().slideY(begin: -0.2, end: 0, duration: 400.ms),
          const ListTile(
            leading: Icon(Icons.account_balance_wallet),
            title: Text('Earnings Summary'),
            enabled: false,
          ).animate().fadeIn(duration: 400.ms, delay: 100.ms),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Logout'),
            onTap: () async {
              Navigator.pop(context); // Close drawer
              await DriverLocationService().goOffline();
              await _auth.signOut();
              if (!mounted) return;
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
        ],
      ),
    );
  }

  Widget _buildMapView(DocumentSnapshot doc, String rideId) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      return const Center(
        child: Text('Ride data unavailable.'),
      ).animate().fadeIn(duration: 400.ms);
    }

    return Stack(
      children: [
        GoogleMap(
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
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => DriverRideDetailsPage(rideId: rideId),
              ),
            );
          },
        ),
        Positioned(
          bottom: 16,
          left: 16,
          right: 16,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ride: ${data['pickup'] ?? '-'} → ${data['dropoff'] ?? '-'}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Fare: \$${data['fare'] is num ? (data['fare'] as num).toStringAsFixed(2) : '--'}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DriverRideDetailsPage(rideId: rideId),
                      ),
                    ),
                    child: const Text('View Details'),
                  ),
                ],
              ),
            ),
          ).animate().slideY(begin: 0.2, end: 0, duration: 400.ms),
        ),
      ],
    );
  }
}
