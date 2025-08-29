import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'rider_services.dart';
import 'package:flutter/foundation.dart';

final riderDashboardProvider =
    StateNotifierProvider<
      RiderDashboardController,
      AsyncValue<DocumentSnapshot?>
    >((ref) => RiderDashboardController()..fetchActiveRide());

class RiderDashboardController
    extends StateNotifier<AsyncValue<DocumentSnapshot?>> {
  RiderDashboardController() : super(const AsyncLoading());

  final fire = FirebaseFirestore.instance;

  String? _lastUid;
  String? get uid {
    final current = FirebaseAuth.instance.currentUser?.uid;
    if (current != null) _lastUid = current;
    return current ?? _lastUid;
  }

  Stream<DocumentSnapshot?> get rideStream {
    final currentUid = uid;
    if (currentUid == null) {
      if (kDebugMode) {
        print('RiderDashboardController: No UID, returning empty stream');
      }
      return const Stream.empty();
    }

    return fire
        .collection('rides')
        .where('riderId', isEqualTo: currentUid)
        .where('status', whereIn: ['pending', 'accepted', 'in_progress'])
        .orderBy('createdAt', descending: false)
        .limit(1)
        .snapshots()
        .map((s) {
          if (kDebugMode) {
            print(
              'RiderDashboardController: Ride stream updated, docs: ${s.docs.length}',
            );
          }
          return s.docs.isNotEmpty ? s.docs.first : null;
        });
  }

  void fetchActiveRide() {
    final currentUid = uid;
    if (currentUid == null) {
      if (kDebugMode) {
        print('RiderDashboardController: No UID, setting state to null');
      }
      state = const AsyncData(null);
      return;
    }

    state = const AsyncLoading();
    rideStream.listen(
      (doc) {
        state = AsyncData(doc);
      },
      onError: (err, stack) {
        state = AsyncError(err, stack);
        if (kDebugMode) {
          print('RiderDashboardController: Error in ride stream: $err');
        }
      },
    );
  }

  void clearCachedUid() {
    _lastUid = null;
    state = const AsyncData(null);
    if (kDebugMode) {
      print('RiderDashboardController: Cleared cached UID');
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
    final currentUid = uid;
    if (currentUid == null) throw Exception('User not logged in');

    try {
      final docRef = await fire.collection('rides').add({
        'riderId': currentUid,
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
        'createdAt': FieldValue.serverTimestamp(),
      });

      final newRide = await docRef.get();
      state = AsyncData(newRide);
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
      });
    } catch (e, st) {
      state = AsyncError(e, st);
      if (kDebugMode) {
        print('RiderDashboardController: Failed to create ride: $e');
      }
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
      if (kDebugMode) {
        print('RiderDashboardController: Failed to cancel ride: $e');
      }
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
      if (kDebugMode) {
        print('RiderDashboardController: Failed to handle counter-fare: $e');
      }
    }
  }
}
