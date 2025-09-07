//rider_dashboard_controller.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import 'rider_services.dart'; // RideService, MapService etc.

/// Dashboard state: latest active ride (or null)
final riderDashboardProvider =
    StateNotifierProvider<
      RiderDashboardController,
      AsyncValue<Map<String, dynamic>?>
    >((ref) => RiderDashboardController()..fetchActiveRide());

class RiderDashboardController
    extends StateNotifier<AsyncValue<Map<String, dynamic>?>> {
  RiderDashboardController() : super(const AsyncLoading());

  final _logger = Logger();
  final fire = FirebaseFirestore.instance;
  final rtdb = FirebaseDatabase.instance.ref();

  // ---- Nearby drivers cache (for overlays/help text)
  List<Map<String, dynamic>> _nearbyDrivers = const [];
  List<Map<String, dynamic>> get nearbyDrivers => _nearbyDrivers;
  void updateNearbyDrivers(List<Map<String, dynamic>> drivers) {
    _nearbyDrivers = drivers;
    _logger.i("Updated nearby drivers cache: ${drivers.length}");
    // If you want to trigger rebuilds without changing the ride state:
    // state = state;
  }

  StreamSubscription<Map<String, dynamic>?>? _rideSub;

  String? _lastUid;
  String? get uid {
    final u = FirebaseAuth.instance.currentUser?.uid;
    if (u != null) _lastUid = u;
    return u ?? _lastUid;
  }

  /// Stream the latest (most recent) ride node for this rider from RTDB.
  Stream<Map<String, dynamic>?> _rideStreamFor(String riderId) {
    final query = rtdb
        .child('rides/$riderId')
        .orderByChild('createdAt')
        .limitToLast(1);

    // onValue returns the last N nodes as a map; we unwrap the single child.
    return query.onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw == null) return null;

      if (raw is Map) {
        // keys are rideIds; pick the only/last
        final map = Map<dynamic, dynamic>.from(raw);
        if (map.isEmpty) return null;
        final latestKey = map.keys.first;
        final latest = Map<dynamic, dynamic>.from(map[latestKey]);
        final parsed = latest.map((k, v) => MapEntry(k.toString(), v));
        // inject id for convenience if missing
        parsed['id'] ??= latestKey.toString();
        return parsed;
      }

      // If a single child is returned directly (edge case)
      if (raw is List && raw.isNotEmpty) {
        final latest = Map<dynamic, dynamic>.from(raw.last);
        return latest.map((k, v) => MapEntry(k.toString(), v));
      }

      return null;
    });
  }

  void fetchActiveRide() {
    final riderId = uid;
    if (riderId == null) {
      _logger.w('No UID; clearing state');
      state = const AsyncData(null);
      _cancelRideStream();
      return;
    }

    state = const AsyncLoading();
    _cancelRideStream();

    _rideSub = _rideStreamFor(riderId).listen(
      (ride) {
        state = AsyncData(ride);
      },
      onError: (err, st) {
        _logger.e('Ride stream error', error: err, stackTrace: st);
        state = AsyncError(err, st);
      },
    );
  }

  void _cancelRideStream() {
    _rideSub?.cancel();
    _rideSub = null;
  }

  void clearCachedUid() {
    _lastUid = null;
    state = const AsyncData(null);
    _cancelRideStream();
  }

  /// Creates ride via service; also seeds state with a quick optimistic value.
  Future<void> createRide(
    String pickup,
    String dropoff,
    double fare,
    GeoPoint pickupLocation,
    GeoPoint dropoffLocation,
    WidgetRef ref, {
    required String rideType,
    String note = '',
  }) async {
    final riderId = uid;
    if (riderId == null) throw Exception('User not logged in');

    try {
      final rideId = await RideService().requestRide({
        'pickup': pickup,
        'dropoff': dropoff,
        'pickupLat': pickupLocation.latitude,
        'pickupLng': pickupLocation.longitude,
        'dropoffLat': dropoffLocation.latitude,
        'dropoffLng': dropoffLocation.longitude,
        'fare': fare,
        'rideType': rideType,
        'note': note,
      }, ref);

      // Optimistic state: the RTDB stream will take over shortly
      state = AsyncData({
        'id': rideId,
        'pickup': pickup,
        'dropoff': dropoff,
        'pickupLat': pickupLocation.latitude,
        'pickupLng': pickupLocation.longitude,
        'dropoffLat': dropoffLocation.latitude,
        'dropoffLng': dropoffLocation.longitude,
        'fare': fare,
        'rideType': rideType,
        'note': note,
        'status': 'pending',
      });
    } catch (e, st) {
      _logger.e('createRide failed', error: e, stackTrace: st);
      state = AsyncError(e, st);
      rethrow;
    }
  }

  Future<void> cancelRide(String rideId) async {
    try {
      await RideService().cancelRide(rideId);
      // RTDB stream will emit null/updated status automatically.
    } catch (e, st) {
      _logger.e('cancelRide failed', error: e, stackTrace: st);
      state = AsyncError(e, st);
      rethrow;
    }
  }

  /// Called by your Counter-Offer dialog actions
  Future<void> handleCounterFare(
    String rideId,
    double counterFare,
    bool accept,
  ) async {
    try {
      if (accept) {
        await RideService().acceptCounterFare(rideId, counterFare);
      } else {
        await cancelRide(rideId);
      }
      // Stream will update status; no manual state juggling required.
    } catch (e, st) {
      _logger.e('handleCounterFare failed', error: e, stackTrace: st);
      state = AsyncError(e, st);
      rethrow;
    }
  }

  @override
  void dispose() {
    _cancelRideStream();
    super.dispose();
  }
}
