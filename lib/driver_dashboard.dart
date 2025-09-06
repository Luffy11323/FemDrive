import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dart_geohash/dart_geohash.dart';
import 'package:femdrive/driver/driver_services.dart';
import 'package:femdrive/driver/driver_ride_details_page.dart';
import 'package:femdrive/emergency_service.dart';
import 'package:femdrive/location/directions_service.dart';
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
    const ttlMs = 60 * 1000; // 60s TTL - tweak as needed

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

/// Live ride snapshot used by both rider & driver UIs
Stream<Map<String, dynamic>?> ridesLiveStream(String rideId) {
  return _rtdb.child('ridesLive/$rideId').onValue.map((e) {
    final v = e.snapshot.value;
    if (v is Map) return Map<String, dynamic>.from(v.cast<String, dynamic>());
    return null;
  });
}

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

class RidePopupWidget extends ConsumerStatefulWidget {
  final PendingRequest request;

  const RidePopupWidget({super.key, required this.request});

  @override
  ConsumerState<RidePopupWidget> createState() => _RidePopupWidgetState();
}

class _RidePopupWidgetState extends ConsumerState<RidePopupWidget> {
  late TextEditingController fareController;
  bool isSubmitting = false;
  double? estimatedDistance;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    fareController = TextEditingController(
      text: widget.request.fare?.toStringAsFixed(2) ?? '',
    );
    _fetchEstimatedDistance();
  }

  Future<void> _fetchEstimatedDistance() async {
    try {
      estimatedDistance = await DirectionsService.getDistance(
        LatLng(widget.request.pickupLat, widget.request.pickupLng),
        LatLng(widget.request.dropoffLat, widget.request.dropoffLng),
      );
      setState(() {});
    } catch (e) {
      setState(() => errorMessage = 'Failed to calculate distance: $e');
    }
  }

  @override
  void dispose() {
    fareController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('New Ride Request'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.request.pickupLabel != null)
            Text('From: ${widget.request.pickupLabel}'),
          if (widget.request.dropoffLabel != null)
            Text('To: ${widget.request.dropoffLabel}'),
          Text(
            'Pickup: ${widget.request.pickupLat.toStringAsFixed(4)}, ${widget.request.pickupLng.toStringAsFixed(4)}',
          ),
          Text(
            'Dropoff: ${widget.request.dropoffLat.toStringAsFixed(4)}, ${widget.request.dropoffLng.toStringAsFixed(4)}',
          ),
          if (estimatedDistance != null)
            Text('Distance: ${estimatedDistance!.toStringAsFixed(2)} km'),
          if (widget.request.fare != null)
            Text(
              'Suggested Fare: \$${widget.request.fare!.toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          TextField(
            controller: fareController,
            decoration: const InputDecoration(
              labelText: 'Counter Fare (optional)',
            ),
            keyboardType: TextInputType.number,
          ),
          if (errorMessage != null)
            Text(errorMessage!, style: const TextStyle(color: Colors.red)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            try {
              await ref
                  .read(driverDashboardProvider.notifier)
                  .declineRide(widget.request.rideId);
            } catch (e) {
              ScaffoldMessenger.of(
                // ignore: use_build_context_synchronously
                context,
              ).showSnackBar(SnackBar(content: Text('Failed to decline: $e')));
            }
            // ignore: use_build_context_synchronously
            Navigator.of(context).pop();
          },
          child: const Text('Decline'),
        ),
        ElevatedButton(
          onPressed: isSubmitting
              ? null
              : () async {
                  setState(() => isSubmitting = true);
                  try {
                    final newFare = double.tryParse(fareController.text);
                    if (newFare != null && newFare != widget.request.fare) {
                      await ref
                          .read(driverDashboardProvider.notifier)
                          .proposeCounterFare(widget.request.rideId, newFare);
                    } else {
                      await ref
                          .read(driverDashboardProvider.notifier)
                          .acceptRide(widget.request.rideId);
                      await DriverLocationService().startOnlineMode(
                        rideId: widget.request.rideId,
                      );
                    }
                    if (context.mounted) {
                      Navigator.of(context).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DriverRideDetailsPage(
                            rideId: widget.request.rideId,
                          ),
                        ),
                      );
                    }
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Action failed: $e')),
                      );
                    }
                  } finally {
                    if (mounted) setState(() => isSubmitting = false);
                  }
                },
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(),
                )
              : const Text('Accept'),
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
  String? _detailsPushedFor; // track last rideId for which we pushed details
  StreamSubscription? _liveRideSub; // <— NEW
  bool _detailsPushed = false; // <— NEW
  String? _liveWatchingRideId;
  bool _isOnline = false;
  late final StreamSubscription<List<ConnectivityResult>> _connSub;
  final _geoHasher = GeoHasher();
  String? _driverGeoHashPrefix;
  final Set<String> _shownRequestIds = {};
  StreamSubscription<List<PendingRequest>>? _pendingSub;
  GoogleMapController? _mapController;
  Position? _currentPosition;
  Timer? _locationUpdateTimer;
  final bool _mapError = false;
  final String _mapErrorMessage = '';
  int _selectedIndex = 0;

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
        final isVerified = data[AppFields.verified] as bool? ?? true;
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

    _startLocationUpdates();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.listen<AsyncValue<List<PendingRequest>>>(pendingRequestsProvider, (
        prev,
        next,
      ) async {
        if (!_isOnline) return;
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
      // React to the driver’s "active ride" doc -> then follow RTDB /ridesLive/{rideId}
      ref.listen<AsyncValue<DocumentSnapshot?>>(driverDashboardProvider, (
        prev,
        next,
      ) {
        final doc = next.asData?.value;
        final newRideId = doc?.id;
        if (newRideId == null) {
          // No active ride -> stop watching live status and reset.
          _liveRideSub?.cancel();
          _liveRideSub = null;
          _liveWatchingRideId = null;
          _detailsPushed = false;
          return;
        }
        if (_liveWatchingRideId == newRideId) return; // already watching
        _attachLiveRide(newRideId);
      });
    });
    ref.listen<
      AsyncValue<DocumentSnapshot<Map<String, dynamic>>?>
    >(driverDashboardProvider, (prev, next) {
      final doc = next.asData?.value;
      if (doc == null) {
        _detailsPushedFor = null; // reset when no active ride
        return;
      }
      final data = doc.data();
      if (data == null) return;
      final rideId = doc.id;
      final status = (data[AppFields.status] ?? '').toString();

      // Open details when it reaches any ongoing state and we haven't pushed yet
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
    });
  }

  void _attachLiveRide(String rideId) {
    _liveRideSub?.cancel();
    _liveWatchingRideId = rideId;
    _detailsPushed = false;

    _liveRideSub = ridesLiveStream(rideId).listen((live) {
      if (!mounted) return;
      final status = (live?['status'] ?? '').toString();
      final driverId = (live?['driverId'] ?? '').toString();

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
          .child(AppFields.geohash)
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

  void _startLocationUpdates() {
    // If this gets called more than once, prevent multiple timers.
    _locationUpdateTimer?.cancel();

    _locationUpdateTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      if (!_isOnline) return;

      try {
        // 1) Get current GPS position → this is the `pos` you asked about
        final Position pos = await Geolocator.getCurrentPosition(
          locationSettings:
              locationSettings, // Pass locationSettings instead of desiredAccuracy
        );

        // Keep UI in sync
        if (mounted) {
          setState(() {
            _currentPosition = pos;
          });
        }

        // 2) Resolve current driver uid → this is the `uid` you asked about
        final String? uid = await getDriverUid();
        if (uid != null) {
          // Encode geohash for discovery radius features (already in your code)
          final String gh = _geoHasher.encode(
            pos.latitude,
            pos.longitude,
            precision: GeoCfg.driverHashPrecision,
          );

          // 3) Update the canonical "who is online & where" node
          await _rtdb.child(AppPaths.driversOnline).child(uid).update({
            AppFields.lat: pos.latitude,
            AppFields.lng: pos.longitude,
            AppFields.geohash: gh,
            AppFields.updatedAt: ServerValue.timestamp,
          });

          // 4) ALSO update the rider-facing live location node
          //    (this is what the Rider app prefers to watch)
          await _rtdb.child(AppPaths.driverLocations).child(uid).update({
            AppFields.lat: pos.latitude,
            AppFields.lng: pos.longitude,
            AppFields.updatedAt: ServerValue.timestamp,
          });
        }

        // 5) Smoothly pan the map to the latest position if visible
        if (_mapController != null && _currentPosition != null) {
          _mapController!.animateCamera(
            CameraUpdate.newLatLng(
              LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            ),
          );
        }
      } catch (e) {
        if (kDebugMode) {
          print('Location update failed: $e');
        }
      }
    });
  }

  @override
  void dispose() {
    _connSub.cancel();
    _pendingSub?.cancel();
    _locationUpdateTimer?.cancel();
    _mapController?.dispose();
    _liveRideSub?.cancel(); // <— NEW
    super.dispose();
  }

  Future<void> _toggleOnline(bool v) async {
    setState(() => _isOnline = v);
    if (v) {
      await DriverLocationService().startOnlineMode();
    } else {
      await DriverLocationService().goOffline();
      _shownRequestIds.clear();
    }
  }

  void _onItemTapped(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
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
        body: pages[_selectedIndex],
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
