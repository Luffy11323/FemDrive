import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:femdrive/driver/driver_services.dart';
import 'package:femdrive/driver/driver_ride_details_page.dart';
import 'package:femdrive/shared/emergency_service.dart';
import 'package:femdrive/shared/notifications.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class EarningsSummary {
  final int totalRides;
  final double totalEarnings;
  const EarningsSummary({
    required this.totalRides,
    required this.totalEarnings,
  });
}

final LocationSettings locationSettings = LocationSettings(
  accuracy: LocationAccuracy.high, // This replaces desiredAccuracy
  distanceFilter:
      0, // Optional: minimum distance (in meters) for location updates
);

final driverOffersProvider = StreamProvider.autoDispose<List<PendingRequest>>((
  ref,
) {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return const Stream<List<PendingRequest>>.empty();

  final refBase = FirebaseDatabase.instance.ref('driver_notifications/$uid');

  return refBase.onValue.map((ev) {
    final v = ev.snapshot.value as Map?;
    if (v == null) return <PendingRequest>[];

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    const ttlMs = 15 * 1000; // 60s TTL - tweak as needed

    final list = <PendingRequest>[];
    v.forEach((rideId, payload) {
      if (payload is! Map) return;
      // TTL (if your rider wrote timestamp)
      final ts = (payload['timestamp'] as num?)?.toInt();
      if (ts != null && (nowMs - ts) > ttlMs) return;

      list.add(
        PendingRequest.fromMap(
          rideId.toString(),
          Map<String, dynamic>.from(payload),
        ),
      );
    });

    // Most recent first (if you have a timestamp)
    list.sort((a, b) {
      final at = (a.raw['timestamp'] as num?)?.toInt() ?? 0;
      final bt = (b.raw['timestamp'] as num?)?.toInt() ?? 0;
      return bt.compareTo(at);
    });
    return list;
  });
});

// === Ride status contract (match driver) ===
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

  static const terminalSet = <String>{completed, cancelled};
}

final _rtdb = FirebaseDatabase.instance.ref();

/// Driver’s live location — rider map marker
Stream<LatLng?> driverLocationStream(String driverId) {
  return _rtdb.child('driverLocations/$driverId').onValue.map((e) {
    final v = e.snapshot.value;
    if (v is! Map) return null;
    final m = Map<String, dynamic>.from(v.cast<String, dynamic>());
    final lat = (m['lat'] as num?)?.toDouble();
    final lng = (m['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  });
}

final _auth = FirebaseAuth.instance;
final _fire = FirebaseFirestore.instance;

String? universalUid;

Future<String?> getDriverUid() async {
  if (universalUid != null) return universalUid;
  final user = _auth.currentUser;
  if (user != null) {
    universalUid = user.uid;
    return universalUid;
  }
  return null;
}

final earningsProvider = FutureProvider.autoDispose<EarningsSummary>((
  ref,
) async {
  final uid = await getDriverUid();
  if (uid == null) {
    return const EarningsSummary(totalRides: 0, totalEarnings: 0);
  }
  final today = DateTime.now();
  final startOfDay = DateTime(today.year, today.month, today.day);
  final q = await _fire
      .collection(AppPaths.ridesCollection)
      .where(AppFields.driverId, isEqualTo: uid)
      .where(AppFields.status, isEqualTo: RideStatus.completed)
      .where(
        AppFields.completedAt,
        isGreaterThanOrEqualTo: Timestamp.fromDate(startOfDay),
      )
      .get();

  double total = 0;
  for (final d in q.docs) {
    total += (d.data()[AppFields.fare] as num?)?.toDouble() ?? 0.0;
  }
  return EarningsSummary(totalRides: q.docs.length, totalEarnings: total);
});

final totalEarningsProvider = FutureProvider.autoDispose<EarningsSummary>((
  ref,
) async {
  final uid = await getDriverUid();
  if (uid == null) {
    return const EarningsSummary(totalRides: 0, totalEarnings: 0);
  }
  final q = await _fire
      .collection(AppPaths.ridesCollection)
      .where(AppFields.driverId, isEqualTo: uid)
      .where(AppFields.status, isEqualTo: RideStatus.completed)
      .get();

  double total = 0;
  for (final d in q.docs) {
    total += (d.data()[AppFields.fare] as num?)?.toDouble() ?? 0.0;
  }
  return EarningsSummary(totalRides: q.docs.length, totalEarnings: total);
});

final weeklyEarningsProvider = FutureProvider.autoDispose<Map<String, double>>((
  ref,
) async {
  final uid = await getDriverUid();
  if (uid == null) return {};
  final now = DateTime.now();
  final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
  final q = await _fire
      .collection(AppPaths.ridesCollection)
      .where(AppFields.driverId, isEqualTo: uid)
      .where(AppFields.status, isEqualTo: RideStatus.completed)
      .where(
        AppFields.completedAt,
        isGreaterThanOrEqualTo: Timestamp.fromDate(startOfWeek),
      )
      .get();

  final weekly = <String, double>{};
  for (final d in q.docs) {
    final ts = d.data()[AppFields.completedAt] as Timestamp?;
    if (ts != null) {
      final date = ts.toDate().toString().split(' ')[0];
      weekly[date] =
          (weekly[date] ?? 0) + (d.data()[AppFields.fare] as num?)!.toDouble();
    }
  }
  return weekly;
});

final pastRidesProvider =
    StreamProvider.autoDispose<QuerySnapshot<Map<String, dynamic>>>((
      ref,
    ) async* {
      final uid = await getDriverUid();
      if (uid == null) return;

      yield* _fire
          .collection(AppPaths.ridesCollection)
          .where(AppFields.driverId, isEqualTo: uid)
          .orderBy(AppFields.completedAt, descending: true)
          .snapshots();
    });

final faresConfigProvider = FutureProvider<Map<String, double>>((ref) async {
  final snap = await _fire.collection('config').doc('fares').get();
  final data = snap.data();
  return {
    'base': data?['base']?.toDouble() ?? 5.0,
    'perKm': data?['perKm']?.toDouble() ?? 1.0,
  };
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
                    'Today\'s Rides: ${e.asData?.value.totalRides ?? 0}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Today\'s Earnings: \$${e.asData?.value.totalEarnings.toStringAsFixed(2) ?? '0.00'}',
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
            final fare = (raw[AppFields.fare] as num?)?.toDouble();
            final ts = raw[AppFields.completedAt] as Timestamp?;
            final dt = ts?.toDate();
            final fareStr = fare != null
                ? '\$${fare.toStringAsFixed(2)}'
                : '--';
            final dateStr = dt != null ? dt.toLocal().toString() : '-';
            final status = (raw[AppFields.status] ?? '')
                .toString()
                .toUpperCase();
            return Card(
              margin: const EdgeInsets.symmetric(vertical: 4),
              child: ListTile(
                dense: true,
                title: Text(
                  '${raw[AppFields.pickup] ?? '-'} → ${raw[AppFields.dropoff] ?? '-'}',
                ),
                subtitle: Text('Fare: $fareStr • $dateStr'),
                trailing: Chip(
                  label: Text(
                    status,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  backgroundColor: status == RideStatus.cancelled
                      ? Colors.red.shade100
                      : Colors.green.shade100,
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
        child: Text('Failed to load past rides: $e'),
      ).animate().fadeIn(duration: 400.ms),
    );
  }
}

class EarningsPage extends ConsumerWidget {
  const EarningsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totalEarnings = ref.watch(totalEarningsProvider);
    final weekly = ref.watch(weeklyEarningsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Earnings & Payouts')),
      body: totalEarnings.when(
        data: (summary) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total Rides: ${summary.totalRides}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Total Earnings: \$${summary.totalEarnings.toStringAsFixed(2)}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Weekly Breakdown',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              weekly.when(
                data: (map) => Table(
                  border: TableBorder.all(),
                  children: map.entries
                      .map(
                        (e) => TableRow(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(e.key),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text('\$${e.value.toStringAsFixed(2)}'),
                            ),
                          ],
                        ),
                      )
                      .toList(),
                ),
                loading: () => const CircularProgressIndicator(),
                error: (e, _) => Text('Failed to load weekly earnings: $e'),
              ),
              const SizedBox(height: 16),
              Expanded(child: const PastRidesListWidget()),
            ],
          ),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load earnings: $e')),
      ),
    );
  }
}

final driverProfileProvider =
    StreamProvider<DocumentSnapshot<Map<String, dynamic>>>((ref) async* {
      final uid = await getDriverUid();
      if (uid == null) return;
      yield* _fire.collection('users').doc(uid).snapshots();
    });

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _phoneController;
  late TextEditingController _vehicleController;
  bool _isEditing = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _phoneController = TextEditingController();
    _vehicleController = TextEditingController();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _vehicleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(driverProfileProvider);
    return profile.when(
      data: (doc) {
        final data = doc.data() ?? {};
        if (!_isEditing) {
          _nameController.text = data[AppFields.username] ?? '';
          _phoneController.text = data[AppFields.phone] ?? '';
          _vehicleController.text = data['vehicle'] ?? '';
        }
        return Scaffold(
          appBar: AppBar(
            title: const Text('Profile'),
            actions: [
              IconButton(
                icon: Icon(_isEditing ? Icons.save : Icons.edit),
                onPressed: _isSaving
                    ? null
                    : () {
                        if (_isEditing) {
                          _saveProfile(doc.id);
                        } else {
                          setState(() => _isEditing = true);
                        }
                      },
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(labelText: 'Name'),
                    enabled: _isEditing,
                    validator: (value) =>
                        value?.isEmpty == true ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _phoneController,
                    decoration: const InputDecoration(labelText: 'Phone'),
                    enabled: _isEditing,
                    validator: (value) =>
                        value?.isEmpty == true ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _vehicleController,
                    decoration: const InputDecoration(
                      labelText: 'Vehicle Info',
                    ),
                    enabled: _isEditing,
                  ),
                  if (_isSaving) const CircularProgressIndicator(),
                ],
              ),
            ),
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Failed to load profile: $e')),
    );
  }

  Future<void> _saveProfile(String uid) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    try {
      await _fire.collection('users').doc(uid).update({
        AppFields.username: _nameController.text.trim(),
        AppFields.phone: _phoneController.text.trim(),
        'vehicle': _vehicleController.text.trim(),
      });
      setState(() => _isEditing = false);
      ScaffoldMessenger.of(
        // ignore: use_build_context_synchronously
        context,
      ).showSnackBar(const SnackBar(content: Text('Profile updated')));
    } catch (e) {
      ScaffoldMessenger.of(
        // ignore: use_build_context_synchronously
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to update: $e')));
    } finally {
      setState(() => _isSaving = false);
    }
  }
}

class EmergencyPage extends ConsumerWidget {
  const EmergencyPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeRide = ref.watch(driverDashboardProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Emergency')),
      body: activeRide.when(
        data: (doc) => doc != null
            ? Center(
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  onPressed: () async {
                    final rideId = doc.id;
                    final currentUid = await getDriverUid();
                    final riderId = doc.data()?[AppFields.riderId];
                    if (currentUid != null && riderId != null) {
                      try {
                        await EmergencyService.sendEmergency(
                          rideId: rideId,
                          currentUid: currentUid,
                          otherUid: riderId,
                        );
                        showEmergencyAlert(rideId: rideId);
                        // ignore: use_build_context_synchronously
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Emergency sent')),
                        );
                      } catch (e) {
                        ScaffoldMessenger.of(
                          // ignore: use_build_context_synchronously
                          context,
                        ).showSnackBar(SnackBar(content: Text('Failed: $e')));
                      }
                    }
                  },
                  child: const Text('Send Emergency Alert'),
                ),
              )
            : const Center(child: Text('No active ride for emergency')),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }
}

class DriverDashboard extends ConsumerStatefulWidget {
  const DriverDashboard({super.key});

  @override
  ConsumerState<DriverDashboard> createState() => _DriverDashboardState();
}

class _DriverDashboardState extends ConsumerState<DriverDashboard> {
  late final DriverLocationService _loc;
  StreamSubscription<Position>? _posSub;

  String? _detailsPushedFor; // track last rideId for which we pushed details
  StreamSubscription? _liveRideSub; // <— NEW
  bool _detailsPushed = false; // <— NEW
  String? _liveWatchingRideId;
  bool _isOnline = false;
  late final StreamSubscription<List<ConnectivityResult>> _connSub;
  final Set<String> _shownRequestIds = {};
  GoogleMapController? _mapController;
  Position? _currentPosition;
  final bool _mapError = false;
  final String _mapErrorMessage = '';
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _loc = DriverLocationService();
    // 1. Internet status listener
    _connSub = Connectivity().onConnectivityChanged.listen((results) {
      final connected =
          results.contains(ConnectivityResult.mobile) ||
          results.contains(ConnectivityResult.wifi);
      if (kDebugMode) {
        debugPrint(connected ? 'Internet Connected' : 'No Internet');
      }
    });

    // 2. Driver verification listener
    getDriverUid().then((uid) {
      if (uid == null) return;
      _fire.collection('users').doc(uid).snapshots().listen((snap) async {
        if (!mounted) return;
        final data = snap.data();
        if (data == null) return;
        final isVerified = data[AppFields.verified] as bool? ?? true;
        if (!isVerified) {
          await _loc.goOffline();
          await _auth.signOut();
          if (!mounted) return;
          Navigator.of(context).popUntil((r) => r.isFirst);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('You have been logged out.')),
          );
        }
      });
    });
    _posSub = _loc.positionStream.listen((pos) {
      if (!mounted) return;
      setState(() {
        _currentPosition = pos;
      });
      _mapController?.animateCamera(
        CameraUpdate.newLatLng(LatLng(pos.latitude, pos.longitude)),
      );
    });
  }

  void _attachLiveRide(String rideId) {
    _liveRideSub?.cancel();
    _liveWatchingRideId = rideId;
    _loc.setActiveRide(
      rideId,
    ); // bind writer immediately when we start watching

    _detailsPushed = false;

    _liveRideSub = ridesLiveStream(rideId).listen((live) {
      if (!mounted) return;
      final status = (live?['status'] ?? '').toString();
      final driverId = (live?['driverId'] ?? '').toString();
      if (status == RideStatus.cancelled && _shownRequestIds.add(rideId)) {
        showCancelled(rideId: rideId);
      }
      if (RideStatus.ongoingSet.contains(status) &&
          _detailsPushedFor != rideId) {
        _detailsPushedFor = rideId;
        if (mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => DriverRideDetailsPage(rideId: rideId),
            ),
          );
        }
      }
      // Only respond when this ride is assigned to THIS driver (or driverId is not set yet)
      final me = _auth.currentUser?.uid;
      if (driverId.isNotEmpty && me != null && driverId != me) return;

      final isActive =
          status == RideStatus.accepted ||
          status == RideStatus.driverArrived ||
          status == RideStatus.inProgress ||
          status == RideStatus.onTrip;

      if (isActive && !_detailsPushed) {
        _detailsPushed = true;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DriverRideDetailsPage(rideId: rideId),
          ),
        );
      }

      // Optional: if completed/cancelled, close details and reset
      if (status == RideStatus.completed || status == RideStatus.cancelled) {
        _detailsPushed = false;
      }
      if (status == RideStatus.completed || status == RideStatus.cancelled) {
        _loc.setActiveRide(null);
      }
    });
  }

  @override
  void dispose() {
    _connSub.cancel();
    _mapController?.dispose();
    _liveRideSub?.cancel(); // <— NEW
    _loc.goOffline();
    _posSub?.cancel();
    super.dispose();
  }

  Future<void> _toggleOnline(bool v) async {
    setState(() => _isOnline = v);
    if (v) {
      await _loc.startOnlineMode(); // no ride yet
    } else {
      await _loc.goOffline();
      _shownRequestIds.clear();
    }
  }

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
  }

  bool _hasAttachedListeners = false; // Add this at the top of your class

  @override
  Widget build(BuildContext context) {
    // 🛡 Ensure ref.listen(...) is called only once
    if (!_hasAttachedListeners) {
      _hasAttachedListeners = true;

      // 2. Watch live ride document
      ref.listen<AsyncValue<DocumentSnapshot?>>(driverDashboardProvider, (
        prev,
        next,
      ) {
        final doc = next.asData?.value;
        final newRideId = doc?.id;

        if (newRideId == null) {
          _liveRideSub?.cancel();
          _liveRideSub = null;
          _liveWatchingRideId = null;
          _detailsPushed = false;
          _loc.setActiveRide(null);
          return;
        }

        if (_liveWatchingRideId == newRideId) return;
        _attachLiveRide(newRideId);

        _loc.setActiveRide(newRideId);
      });
    }

    final pages = [
      _buildHomePage(),
      const PastRidesListWidget(),
      const EarningsPage(),
      const ProfilePage(),
      const EmergencyPage(),
    ];

    return Theme(
      data: Theme.of(context),
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
                  activeThumbColor: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
          ],
        ),
        drawer: Drawer(child: _buildDrawer()),
        body: Stack(
          children: [
            pages[_selectedIndex],

            // 🔹 Offer Overlay only on Home tab + when Online
            if (_selectedIndex == 0 && _isOnline)
              Consumer(
                builder: (context, ref, _) {
                  final offersAsync = ref.watch(driverOffersProvider);

                  return offersAsync.when(
                    data: (offers) {
                      if (offers.isEmpty) return const SizedBox.shrink();

                      // Pick the most recent offer (your provider already sorts by timestamp desc)
                      final active = offers.first;
                      if (_shownRequestIds.add(active.rideId)) {
                        showIncomingRide(rideId: active.rideId);
                      }
                      return Align(
                        alignment: Alignment.bottomCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: _OfferCard(
                            offer: active,
                            onAccept: () async {
                              await ref
                                  .read(driverDashboardProvider.notifier)
                                  .acceptRide(active.rideId, context: active);

                              // 🔗 bind tracking to this ride
                              _loc.setActiveRide(active.rideId);
                              await _loc.startOnlineMode(rideId: active.rideId);

                              // remove only this popup for this driver
                              final uid =
                                  FirebaseAuth.instance.currentUser?.uid;
                              if (uid != null) {
                                await FirebaseDatabase.instance
                                    .ref(
                                      '${AppPaths.driverNotifications}/$uid/${active.rideId}',
                                    )
                                    .remove();
                              }

                              showAccepted(rideId: active.rideId);
                            },

                            onDecline: () async {
                              await ref
                                  .read(driverDashboardProvider.notifier)
                                  .declineRide(active.rideId);

                              final uid =
                                  FirebaseAuth.instance.currentUser?.uid;
                              if (uid != null) {
                                await FirebaseDatabase.instance
                                    .ref(
                                      '${AppPaths.driverNotifications}/$uid/${active.rideId}',
                                    )
                                    .remove();
                              }
                            },

                            onCounter: (newFare) async {
                              await ref
                                  .read(driverDashboardProvider.notifier)
                                  .proposeCounterFare(active.rideId, newFare);

                              final uid =
                                  FirebaseAuth.instance.currentUser?.uid;
                              if (uid != null) {
                                await FirebaseDatabase.instance
                                    .ref(
                                      '${AppPaths.driverNotifications}/$uid/${active.rideId}',
                                    )
                                    .remove();
                              }
                            },
                            onExpire: () async {
                              final uid =
                                  FirebaseAuth.instance.currentUser?.uid;
                              if (uid != null) {
                                await FirebaseDatabase.instance
                                    .ref(
                                      '${AppPaths.driverNotifications}/$uid/${active.rideId}',
                                    )
                                    .remove();
                              }
                            },
                          ),
                        ),
                      );
                    },
                    loading: () => const SizedBox.shrink(),
                    error: (_, _) => const SizedBox.shrink(),
                  );
                },
              ),
          ],
        ),

        bottomNavigationBar: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: _onItemTapped,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
            NavigationDestination(
              icon: Icon(Icons.history),
              label: 'Past Rides',
            ),
            NavigationDestination(
              icon: Icon(Icons.account_balance_wallet),
              label: 'Earnings',
            ),
            NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
            NavigationDestination(
              icon: Icon(Icons.emergency),
              label: 'Emergency',
            ),
          ],
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
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Logout'),
            onTap: () async {
              Navigator.pop(context);
              await _loc.goOffline();
              await _auth.signOut();
              if (!mounted) return;
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
        ],
      ),
    );
  }

  Widget _buildHomePage() {
    return ref
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
                Text('Error: $e'),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: () => ref.invalidate(driverDashboardProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ).animate().fadeIn(duration: 400.ms),
          data: (doc) =>
              doc == null ? _buildIdleHome() : _buildActiveRide(doc, doc.id),
        );
  }

  Widget _buildIdleHome() {
    return Column(
      children: [
        if (_isOnline)
          Expanded(
            child: _mapError
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.map, color: Colors.red, size: 48),
                        const SizedBox(height: 16),
                        Text(
                          _mapErrorMessage,
                          style: Theme.of(context).textTheme.bodyMedium,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  )
                : GoogleMap(
                    initialCameraPosition: CameraPosition(
                      target: _currentPosition != null
                          ? LatLng(
                              _currentPosition!.latitude,
                              _currentPosition!.longitude,
                            )
                          : const LatLng(0, 0),
                      zoom: 14,
                    ),
                    markers: {
                      if (_currentPosition != null)
                        Marker(
                          markerId: const MarkerId('driver'),
                          position: LatLng(
                            _currentPosition!.latitude,
                            _currentPosition!.longitude,
                          ),
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueRed,
                          ),
                        ),
                    },
                    myLocationEnabled: true,
                    myLocationButtonEnabled: true,
                    onMapCreated: (controller) {
                      _mapController = controller;
                      if (_currentPosition != null) {
                        controller.animateCamera(
                          CameraUpdate.newLatLng(
                            LatLng(
                              _currentPosition!.latitude,
                              _currentPosition!.longitude,
                            ),
                          ),
                        );
                      }
                    },
                  ),
          ),
        if (!_isOnline)
          const Expanded(
            child: Center(
              child: Text(
                'Go online to view your location and receive ride requests.',
              ),
            ),
          ),
        if (ref.watch(driverDashboardProvider).asData?.value == null)
          const EarningsSummaryWidget(),
      ],
    );
  }

  Widget _buildActiveRide(DocumentSnapshot doc, String rideId) {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) {
      return const Center(
        child: Text('Ride data unavailable.'),
      ).animate().fadeIn(duration: 400.ms);
    }

    return Stack(
      children: [
        _mapError
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.map, color: Colors.red, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      _mapErrorMessage,
                      style: Theme.of(context).textTheme.bodyMedium,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              )
            : GoogleMap(
                initialCameraPosition: CameraPosition(
                  target: LatLng(
                    (data[AppFields.pickupLat] as num).toDouble(),
                    (data[AppFields.pickupLng] as num).toDouble(),
                  ),
                  zoom: 14,
                ),
                markers: {
                  Marker(
                    markerId: const MarkerId('pickup'),
                    position: LatLng(
                      (data[AppFields.pickupLat] as num).toDouble(),
                      (data[AppFields.pickupLng] as num).toDouble(),
                    ),
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueAzure,
                    ),
                  ),
                  Marker(
                    markerId: const MarkerId('dropoff'),
                    position: LatLng(
                      (data[AppFields.dropoffLat] as num).toDouble(),
                      (data[AppFields.dropoffLng] as num).toDouble(),
                    ),
                    icon: BitmapDescriptor.defaultMarkerWithHue(
                      BitmapDescriptor.hueGreen,
                    ),
                  ),
                  if (_currentPosition != null)
                    Marker(
                      markerId: const MarkerId('driver'),
                      position: LatLng(
                        _currentPosition!.latitude,
                        _currentPosition!.longitude,
                      ),
                      icon: BitmapDescriptor.defaultMarkerWithHue(
                        BitmapDescriptor.hueRed,
                      ),
                    ),
                },
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
                onMapCreated: (controller) => _mapController = controller,
                onTap: (_) => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DriverRideDetailsPage(rideId: rideId),
                  ),
                ),
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
                          'Ride: ${data[AppFields.pickup] ?? '-'} → ${data[AppFields.dropoff] ?? '-'}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Fare: \$${data[AppFields.fare] is num ? (data[AppFields.fare] as num).toStringAsFixed(2) : '--'}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        StreamBuilder<Map<String, dynamic>?>(
                          stream: ridesLiveStream(rideId), // <-- RTDB live node
                          builder: (_, snap) {
                            final live = snap.data;
                            final liveStatus =
                                (live?['status'] ??
                                        data[AppFields.status] ??
                                        '-')
                                    .toString()
                                    .toUpperCase();
                            return Text(
                              'Status: $liveStatus',
                              style: Theme.of(context).textTheme.bodyMedium,
                            );
                          },
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

class _OfferCard extends StatefulWidget {
  final PendingRequest offer;
  final Future<void> Function() onAccept;
  final Future<void> Function() onDecline;
  final Future<void> Function(double newFare) onCounter;
  final Future<void> Function()? onExpire;
  const _OfferCard({
    required this.offer,
    required this.onAccept,
    required this.onDecline,
    required this.onCounter,
    this.onExpire,
  });

  @override
  State<_OfferCard> createState() => _OfferCardState();
}

class _OfferCardState extends State<_OfferCard> {
  static const int _ttlMs = 15 * 1000;
  late int _secondsLeft;
  Timer? _ticker;
  final _counterCtrl = TextEditingController();
  bool _expiredHandled = false;

  @override
  void initState() {
    super.initState();
    final ts = (widget.offer.raw['timestamp'] as num?)?.toInt();
    _secondsLeft = _computeLeft(ts);

    _ticker = Timer.periodic(const Duration(seconds: 1), (_) async {
      final left = _computeLeft(ts);
      if (!mounted) return;
      setState(() => _secondsLeft = left);
      if (left <= 0 && !_expiredHandled) {
        _expiredHandled = true;
        _ticker?.cancel();
        if (widget.onExpire != null) {
          await widget.onExpire!(); // <-- remove notif -> overlay disappears
        }
      }
    });
  }

  int _computeLeft(int? tsMs) {
    if (tsMs == null) return (_ttlMs / 1000).floor(); // 15;
    final now = DateTime.now().millisecondsSinceEpoch;
    final leftMs = _ttlMs - (now - tsMs);
    return leftMs <= 0 ? 0 : (leftMs / 1000).floor();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _counterCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'New Ride Request',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (widget.offer.pickupLabel != null)
              Text('From: ${widget.offer.pickupLabel}'),
            if (widget.offer.dropoffLabel != null)
              Text('To: ${widget.offer.dropoffLabel}'),
            Text(
              'Pickup: ${widget.offer.pickupLat.toStringAsFixed(4)}, '
              '${widget.offer.pickupLng.toStringAsFixed(4)}',
            ),
            Text(
              'Dropoff: ${widget.offer.dropoffLat.toStringAsFixed(4)}, '
              '${widget.offer.dropoffLng.toStringAsFixed(4)}',
            ),
            if (widget.offer.fare != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Suggested Fare: \$${widget.offer.fare!.toStringAsFixed(2)}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _counterCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Counter Fare (optional)',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _secondsLeft > 0 ? '$_secondsLeft s' : 'expired',
                  style: TextStyle(
                    color: _secondsLeft > 10 ? Colors.black54 : Colors.red,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _secondsLeft == 0 ? null : widget.onDecline,
                    child: const Text('Decline'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _secondsLeft == 0 ? null : widget.onAccept,
                    child: const Text('Accept'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: _secondsLeft == 0
                    ? null
                    : () async {
                        final v = double.tryParse(_counterCtrl.text.trim());
                        if (v == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Enter a valid counter fare'),
                            ),
                          );
                          return;
                        }
                        await widget.onCounter(v);
                      },
                child: const Text('Send Counter Fare'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
