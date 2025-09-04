import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:logger/logger.dart';
import 'rider_services.dart';

final riderDashboardProvider =
    StateNotifierProvider<
      RiderDashboardController,
      AsyncValue<Map<String, dynamic>?>
    >((ref) => RiderDashboardController()..fetchActiveRide());

class RiderDashboardController
    extends StateNotifier<AsyncValue<Map<String, dynamic>?>> {
  RiderDashboardController() : super(const AsyncLoading());

  final _logger = Logger();
  List<Map<String, dynamic>> _nearbyDrivers = [];

  List<Map<String, dynamic>> get nearbyDrivers => _nearbyDrivers;

  void updateNearbyDrivers(List<Map<String, dynamic>> drivers) {
    _nearbyDrivers = drivers;
    _logger.i("Updated nearby drivers: $_nearbyDrivers");
  }

  final fire = FirebaseFirestore.instance;
  final rtdb = FirebaseDatabase.instance.ref();
  StreamSubscription? _rideSubscription;

  String? _lastUid;
  String? get uid {
    final current = FirebaseAuth.instance.currentUser?.uid;
    if (current != null) _lastUid = current;
    return current ?? _lastUid;
  }

  Stream<Map<String, dynamic>?> get rideStream {
    final currentUid = uid;
    if (currentUid == null) {
      _logger.w('No UID, returning empty stream');
      return const Stream.empty();
    }
    return rtdb.ref.onValue.map((event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      _logger.d('Ride stream updated: $data');
      return data != null ? Map<String, dynamic>.from(data) : null;
    });
  }

  void fetchActiveRide() {
    final currentUid = uid;
    if (currentUid == null) {
      _logger.w('No UID, setting state to null');
      state = const AsyncData(null);
      _cancelSubscription();
      return;
    }

    state = const AsyncLoading();
    _cancelSubscription();
    _rideSubscription = rideStream.listen(
      (data) {
        state = AsyncData(data);
      },
      onError: (err, stack) {
        state = AsyncError(err, stack);
        _logger.e('Error in ride stream: $err', stackTrace: stack);
      },
    );
  }

  void _cancelSubscription() {
    _rideSubscription?.cancel();
    _rideSubscription = null;
  }

  void clearCachedUid() {
    _lastUid = null;
    state = const AsyncData(null);
    _logger.i('Cleared cached UID');
    _cancelSubscription();
  }

  Future<void> createRide(
    String pickup,
    String dropoff,
    double fare,
    GeoPoint pickupLocation,
    GeoPoint dropoffLocation,
    WidgetRef ref, { // 🔹 Added ref here
    required String rideType,
    String note = '',
  }) async {
    final currentUid = uid;
    if (currentUid == null) throw Exception('User not logged in');

    try {
      // 🔹 Call requestRide with both params
      await RideService().requestRide({
        'pickup': pickup,
        'dropoff': dropoff,
        'pickupLat': pickupLocation.latitude,
        'pickupLng': pickupLocation.longitude,
        'dropoffLat': dropoffLocation.latitude,
        'dropoffLng': dropoffLocation.longitude,
        'fare': fare,
        'rideType': rideType,
        'note': note,
        'riderId': currentUid,
        'status': 'pending',
      }, ref);

      // 🔹 Optionally fetch latest ride to sync controller state
      final latest = await fire
          .collection('rides')
          .where('riderId', isEqualTo: currentUid)
          .orderBy('createdAt', descending: true)
          .limit(1)
          .get();

      if (latest.docs.isNotEmpty) {
        state = AsyncData({
          'id': latest.docs.first.id,
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
      }
    } catch (e, st) {
      state = AsyncError(e, st);
      _logger.e('Failed to create ride: $e', stackTrace: st);
      throw Exception('Unable to create ride: $e');
    }
  }

  Future<void> cancelRide(String rideId) async {
    final currentUid = uid;
    if (currentUid == null) throw Exception('User not logged in');

    try {
      await RideService().cancelRide(rideId);
      fetchActiveRide();
    } catch (e, st) {
      state = AsyncError(e, st);
      _logger.e('Failed to cancel ride: $e', stackTrace: st);
      throw Exception('Unable to cancel ride: $e');
    }
  }

  Future<void> handleCounterFare(
    String rideId,
    double counterFare,
    bool accept,
  ) async {
    final currentUid = uid;
    if (currentUid == null) throw Exception('User not logged in');

    try {
      if (accept) {
        await RideService().acceptCounterFare(rideId, counterFare);
      } else {
        await cancelRide(rideId);
      }
      fetchActiveRide();
    } catch (e, st) {
      state = AsyncError(e, st);
      _logger.e('Failed to handle counter-fare: $e', stackTrace: st);
      throw Exception('Unable to handle counter-fare: $e');
    }
  }

  @override
  void dispose() {
    _cancelSubscription();
    super.dispose();
  }
}
