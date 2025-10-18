import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import 'rider_services.dart'; // RideService, MapService etc.

/// Dashboard state: latest active ride and driver contact info (or null)
final riderDashboardProvider = StateNotifierProvider<
    RiderDashboardController,
    AsyncValue<Map<String, dynamic>?>>((ref) => RiderDashboardController()..fetchActiveRide());

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
  }

  // ---- Driver contact info cache
  Map<String, dynamic>? _driverInfo;
  Map<String, dynamic>? get driverInfo => _driverInfo;

  StreamSubscription<Map<String, dynamic>?>? _rideSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _driverInfoSub;

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

    return query.onValue.map((event) {
      final raw = event.snapshot.value;
      if (raw == null) return null;

      if (raw is Map) {
        final map = Map<dynamic, dynamic>.from(raw);
        if (map.isEmpty) return null;
        final latestKey = map.keys.first;
        final latest = Map<dynamic, dynamic>.from(map[latestKey]);
        final parsed = latest.map((k, v) => MapEntry(k.toString(), v));
        parsed['id'] ??= latestKey.toString();
        return parsed;
      }

      if (raw is List && raw.isNotEmpty) {
        final latest = Map<dynamic, dynamic>.from(raw.last);
        return latest.map((k, v) => MapEntry(k.toString(), v));
      }

      return null;
    });
  }

  /// Stream driver contact info when driverId is available
  void _subscribeToDriverInfo(String? driverId) {
    _driverInfoSub?.cancel();
    _driverInfoSub = null;

    // ✅ FIXED: Check for empty string
    if (driverId == null || driverId.isEmpty) {
      _logger.i('No driverId; clearing driver info');
      _driverInfo = null;
      return;
    }

    _driverInfoSub = fire
        .collection('users')
        .doc(driverId)
        .snapshots()
        .listen(
          (snap) {
            // ✅ FIXED: Check data is not null
            if (snap.exists && snap.data() != null) {
              _driverInfo = snap.data();
              _logger.i('Driver info updated for driverId: $driverId');
            
              // ✅ FIXED: Force state update with current ride data
              final currentRide = state.value;
              if (currentRide != null) {
                state = AsyncData({
                  ...currentRide,
                  'driverInfo': _driverInfo,
                  'driverId': driverId,
                });
              }
            } else {
              _driverInfo = null;
              _logger.w('Driver info not found for driverId: $driverId');
            }
          },
          onError: (err, st) {
            _logger.e('Driver info stream error', error: err, stackTrace: st);
            _driverInfo = null;
            // ✅ FIXED: Don't set error state for driver info
          },
        );
    }
  void fetchActiveRide() {
    final riderId = uid;
    if (riderId == null) {
      _logger.w('No UID; clearing state');
      state = const AsyncData(null);
      _cancelRideStream();
      _subscribeToDriverInfo(null);
      return;
    }

    state = const AsyncLoading();
    _cancelRideStream();

    _rideSub = _rideStreamFor(riderId).listen(
      (ride) {
        final driverId = ride?['driverId'] as String?;
    
        // ✅ FIXED: Only resubscribe if driverId changed
        final currentDriverId = state.value?['driverId'] as String?;
        if (driverId != currentDriverId) {
          _subscribeToDriverInfo(driverId);
        }
    
        // ✅ FIXED: Update state immediately
        state = AsyncData({
          ...?ride,
          'driverInfo': _driverInfo,
          'driverId': driverId,
        });
      },
      onError: (err, st) {
        _logger.e('Ride stream error', error: err, stackTrace: st);
        state = AsyncError(err, st);
        _subscribeToDriverInfo(null);
      },
    );
  }

  void _cancelRideStream() {
    _rideSub?.cancel();
    _rideSub = null;
    _driverInfoSub?.cancel();
    _driverInfoSub = null;
    _driverInfo = null;
  }

  void clearCachedUid() {
    _lastUid = null;
    state = const AsyncData(null);
    _cancelRideStream();
  }

  Future<void> expireCounterFare(String rideId) async {
    try {
      await RideService().expireCounterFare(rideId);
    } catch (e, st) {
      _logger.e('expireCounterFare failed', error: e, stackTrace: st);
      state = AsyncError(e, st);
      rethrow;
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
      });

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
        'driverInfo': null,
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
      _subscribeToDriverInfo(null);
    } catch (e, st) {
      _logger.e('cancelRide failed', error: e, stackTrace: st);
      state = AsyncError(e, st);
      rethrow;
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