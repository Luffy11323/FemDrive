//rider_dashboard_controller.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:femdrive/location/location_service.dart';
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

  List<Map<String, dynamic>> _nearbyDrivers = const [];
  List<Map<String, dynamic>> get nearbyDrivers => _nearbyDrivers;

  void updateNearbyDrivers(List<Map<String, dynamic>> drivers) {
    _nearbyDrivers = drivers;
    _logger.i("Nearby drivers cache: ${drivers.length}");
  }

  StreamSubscription<Map<String, dynamic>?>? _rideSub;
  String? _lastUid;
  String? get uid {
    final u = FirebaseAuth.instance.currentUser?.uid;
    if (u != null) _lastUid = u;
    return u ?? _lastUid;
  }

  /// Stream latest ride node safely
  Stream<Map<String, dynamic>?> _rideStreamFor(String riderId) {
    final query = rtdb
        .child('rides/$riderId')
        .orderByChild('createdAt')
        .limitToLast(1);

    return query.onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw == null) return null;

      try {
        if (raw is Map) {
          final map = Map<dynamic, dynamic>.from(raw);
          if (map.isEmpty) return null;
          final latestKey = map.keys.first;
          final latest = Map<dynamic, dynamic>.from(map[latestKey]);
          final parsed = latest.map((k, v) => MapEntry(k.toString(), v));
          parsed['id'] ??= latestKey.toString();
          return parsed;
        } else if (raw is List && raw.isNotEmpty) {
          final latest = Map<dynamic, dynamic>.from(raw.last);
          return latest.map((k, v) => MapEntry(k.toString(), v));
        }
      } catch (e) {
        _logger.w('Malformed ride stream data: $e');
      }

      return null;
    }).handleError((e, st) {
      _logger.e('Ride stream fatal error: $e', stackTrace: st);
    });
  }

  void fetchActiveRide() {
    final riderId = uid;
    if (riderId == null) {
      _logger.w('No UID; clearing dashboard');
      _cancelRideStream();
      state = const AsyncData(null);
      return;
    }
    // Initialize background-safe location tracking once after login
    try {
      RiderLocationService.instance.init(riderId);
      // Start background updates to maintain rider presence even when idle
      RiderLocationService.instance.startBackground();
    } catch (e) {
      _logger.w("RiderLocationService init failed: $e");
    }

    _cancelRideStream();
    state = const AsyncLoading();

    _rideSub = _rideStreamFor(riderId).listen(
      (ride) async {
        if (ride == null) {
          _logger.w('No active ride found.');
          state = const AsyncData(null);
          return;
        }

        // 🔹 Auto-sync fallback: ensure Firestore consistency
        try {
          final fsSnap = await fire.collection('rides').doc(ride['id']).get();
          if (fsSnap.exists) {
            final fsData = fsSnap.data()!;
            ride.addAll(fsData);
          }
        } catch (e) {
          _logger.w('Firestore sync fallback failed silently: $e');
        }

        state = AsyncData(ride);
      },
      onError: (err, st) {
        _logger.e('Ride stream error', error: err, stackTrace: st);
        // Silent fallback: retry after short delay instead of breaking
        Future.delayed(const Duration(seconds: 4), fetchActiveRide);
      },
      cancelOnError: false,
    );
  }

  void _cancelRideStream() {
    try {
      _rideSub?.cancel();
    } catch (_) {}
    _rideSub = null;
  }

  void clearCachedUid() {
    _lastUid = null;
    _cancelRideStream();
    RiderLocationService.instance.stopForegroundUpdates();
    RiderLocationService.instance.stopBackground();
    state = const AsyncData(null);
  }

  Future<void> expireCounterFare(String rideId) async {
    try {
      await RideService().expireCounterFare(rideId);
    } catch (e) {
      _logger.w('expireCounterFare failed silently: $e');
    }
  }

  Future<void> createRide(
    String pickup,
    String dropoff,
    double fare,
    GeoPoint pickupLocation,
    GeoPoint dropoffLocation, {
    required String rideType,
    String note = '',
  }) async {
    final riderId = uid;
    if (riderId == null) {
      _logger.w('createRide: user not logged in');
      return;
    }

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
      });
      // Intensify foreground tracking for active ride
      try {
        await RiderLocationService.instance.stopBackground();
        await RiderLocationService.instance.startForegroundUpdates();
      } catch (e) {
        _logger.w("Failed to start foreground tracking for ride: $e");
      }

      // ✅ Silent optimistic UI update
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

      // ✅ Background flag
      try {
        await FirebaseDatabase.instance
            .ref('ridesLive/$rideId')
            .update({'trackingEnabled': true});
      } catch (_) {}

    } catch (e, st) {
      _logger.e('createRide failed', error: e, stackTrace: st);
      // fallback without crashing
      state = AsyncData(null);
    }
  }

  Future<void> cancelRide(String rideId) async {
    try {
      await RideService().cancelRide(rideId);
    } catch (e) {
      _logger.w('cancelRide failed silently: $e');
    }
    try {
      await RiderLocationService.instance.stopForegroundUpdates();
      await RiderLocationService.instance.startBackground(); // fallback to passive presence
   }catch (e) {
    _logger.w("Failed to downgrade rider tracking: $e");
    }
  }

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
    } catch (e) {
      _logger.w('handleCounterFare failed: $e');
    }
  }

  @override
  void dispose() {
    _cancelRideStream();
    super.dispose();
  }
}
