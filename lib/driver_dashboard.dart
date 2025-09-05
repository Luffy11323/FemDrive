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

final _auth = FirebaseAuth.instance;
final _fire = FirebaseFirestore.instance;
final _rtdb = FirebaseDatabase.instance.ref();

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
    return Card.filled(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: 250.ms,
                child: Column(
                  key: ValueKey(e.hashCode),
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Today\'s Rides',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${e.asData?.value.totalRides ?? 0}',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Today\'s Earnings',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '\$${(e.asData?.value.totalEarnings ?? 0).toStringAsFixed(2)}',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Tooltip(
              message: 'Wallet',
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.1 * 255),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.account_balance_wallet, size: 36),
              ),
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
        return RefreshIndicator(
          onRefresh: () async => ref.invalidate(pastRidesProvider),
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            itemCount: qSnap.docs.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (ctx, i) {
              final raw = qSnap.docs[i].data();
              final fare = (raw[AppFields.fare] as num?)?.toDouble();
              final ts = raw[AppFields.completedAt] as Timestamp?;
              final dt = ts?.toDate();
              final fareStr = fare != null
                  ? '\$${fare.toStringAsFixed(2)}'
                  : '--';
              final dateStr = dt != null
                  ? '${dt.toLocal()}'.split('.').first
                  : '-';
              final status = (raw[AppFields.status] ?? '')
                  .toString()
                  .toUpperCase();

              final isCancelled = status == RideStatus.cancelled;
              final chipColor = isCancelled
                  ? Colors.red.withValues(alpha: 0.12 * 255)
                  : Colors.green.withValues(alpha: 0.14 * 255);

              return Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.12 * 255),
                    child: const Icon(Icons.directions_car),
                  ),
                  title: Text(
                    '${raw[AppFields.pickup] ?? '-'} → ${raw[AppFields.dropoff] ?? '-'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Fare: $fareStr • $dateStr'),
                  ),
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: chipColor,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      status,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ).animate().slideX(
                begin: 0.1 * (i % 2 == 0 ? 1 : -1),
                end: 0,
                duration: 400.ms,
                delay: (90 * i).ms,
              );
            },
          ),
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
              Card.filled(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Total Rides',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${summary.totalRides}',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Total Earnings',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '\$${summary.totalEarnings.toStringAsFixed(2)}',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.stacked_line_chart, size: 40),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Weekly Breakdown',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(height: 8),
              weekly.when(
                data: (map) => Card(
                  child: SingleChildScrollView(
                    child: DataTable(
                      columns: const [
                        DataColumn(label: Text('Date')),
                        DataColumn(label: Text('Earnings')),
                      ],
                      rows: map.entries
                          .map(
                            (e) => DataRow(
                              cells: [
                                DataCell(Text(e.key)),
                                DataCell(
                                  Text('\$${e.value.toStringAsFixed(2)}'),
                                ),
                              ],
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
                loading: () => const Padding(
                  padding: EdgeInsets.all(12.0),
                  child: CircularProgressIndicator(),
                ),
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
                tooltip: _isEditing ? 'Save changes' : 'Edit profile',
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
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 28,
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            child: const Icon(
                              Icons.person,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              data[AppFields.username] ?? 'Driver',
                              style: Theme.of(context).textTheme.titleLarge,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      prefixIcon: Icon(Icons.badge_outlined),
                    ),
                    enabled: _isEditing,
                    validator: (value) =>
                        value?.isEmpty == true ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _phoneController,
                    decoration: const InputDecoration(
                      labelText: 'Phone',
                      prefixIcon: Icon(Icons.phone_outlined),
                    ),
                    enabled: _isEditing,
                    validator: (value) =>
                        value?.isEmpty == true ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _vehicleController,
                    decoration: const InputDecoration(
                      labelText: 'Vehicle Info',
                      prefixIcon: Icon(Icons.directions_car_outlined),
                    ),
                    enabled: _isEditing,
                  ),
                  const SizedBox(height: 12),
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
                child: FilledButton.icon(
                  icon: const Icon(Icons.sos),
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.red,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 14,
                    ),
                  ),
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
                  label: const Text('Send Emergency Alert'),
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
    // keep AlertDialog (called by showDialog in dashboard) but modernize its internals
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.local_taxi_outlined),
          const SizedBox(width: 8),
          const Text('New Ride Request'),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.request.pickupLabel != null)
              _kv('From', widget.request.pickupLabel!),
            if (widget.request.dropoffLabel != null)
              _kv('To', widget.request.dropoffLabel!),
            _kv(
              'Pickup',
              '${widget.request.pickupLat.toStringAsFixed(4)}, ${widget.request.pickupLng.toStringAsFixed(4)}',
            ),
            _kv(
              'Dropoff',
              '${widget.request.dropoffLat.toStringAsFixed(4)}, ${widget.request.dropoffLng.toStringAsFixed(4)}',
            ),
            if (estimatedDistance != null)
              _kv('Distance', '${estimatedDistance!.toStringAsFixed(2)} km'),
            const SizedBox(height: 6),
            if (widget.request.fare != null)
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.08 * 255),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Suggested Fare: \$${widget.request.fare!.toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            TextField(
              controller: fareController,
              decoration: const InputDecoration(
                labelText: 'Counter Fare (optional)',
                prefixIcon: Icon(Icons.attach_money),
              ),
              keyboardType: TextInputType.number,
            ),
            if (errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  errorMessage!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
          ],
        ),
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
        FilledButton(
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
          style: FilledButton.styleFrom(
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

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 74,
            child: Text(k, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(v, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
        ],
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
    _locationUpdateTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      if (!_isOnline) return;
      try {
        final pos = await Geolocator.getCurrentPosition();
        setState(() {
          _currentPosition = pos;
        });
        final uid = await getDriverUid();
        if (uid != null) {
          await _rtdb.child(AppPaths.driversOnline).child(uid).update({
            AppFields.lat: pos.latitude,
            AppFields.lng: pos.longitude,
            AppFields.geohash: _geoHasher.encode(
              pos.latitude,
              pos.longitude,
              precision: GeoCfg.driverHashPrecision,
            ),
            AppFields.updatedAt: ServerValue.timestamp,
          });
        }
        if (_mapController != null && _currentPosition != null) {
          _mapController!.animateCamera(
            CameraUpdate.newLatLng(
              LatLng(_currentPosition!.latitude, _currentPosition!.longitude),
            ),
          );
        }
      } catch (e) {
        if (kDebugMode) print('Location update failed: $e');
      }
    });
  }

  @override
  void dispose() {
    _connSub.cancel();
    _pendingSub?.cancel();
    _locationUpdateTimer?.cancel();
    _mapController?.dispose();
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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color:
                        (_isOnline
                                ? Colors.green
                                : Theme.of(context).colorScheme.error)
                            .withValues(alpha: 0.15 * 255),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    children: [
                      Icon(_isOnline ? Icons.wifi : Icons.wifi_off, size: 16),
                      const SizedBox(width: 6),
                      Text(_isOnline ? 'Online' : 'Offline'),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Tooltip(
                  message: 'Toggle availability',
                  child: Switch(
                    value: _isOnline,
                    onChanged: _toggleOnline,
                    activeThumbColor: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 8),
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
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.history),
              label: 'Past Rides',
            ),
            NavigationDestination(
              icon: Icon(Icons.account_balance_wallet_outlined),
              label: 'Earnings',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              label: 'Profile',
            ),
            NavigationDestination(
              icon: Icon(Icons.emergency_outlined),
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
                textAlign: TextAlign.center,
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
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ride',
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${data[AppFields.pickup] ?? '-'} → ${data[AppFields.dropoff] ?? '-'}',
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(Icons.attach_money, size: 18),
                            const SizedBox(width: 6),
                            Text(
                              'Fare: \$${data[AppFields.fare] is num ? (data[AppFields.fare] as num).toStringAsFixed(2) : '--'}',
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            const Icon(Icons.flag_circle_outlined, size: 18),
                            const SizedBox(width: 6),
                            Text(
                              'Status: ${data[AppFields.status]?.toString().toUpperCase() ?? '-'}',
                            ),
                          ],
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
