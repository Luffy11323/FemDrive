import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';

final riderDashboardProvider =
    StateNotifierProvider<
      RiderDashboardController,
      AsyncValue<DocumentSnapshot?>
    >((ref) => RiderDashboardController()..fetchActiveRide());

class RiderDashboardController
    extends StateNotifier<AsyncValue<DocumentSnapshot?>> {
  RiderDashboardController() : super(const AsyncLoading());

  final fire = FirebaseFirestore.instance;

  /// Store last known UID as fallback
  String? _lastUid;

  /// Always get the current UID dynamically, fallback to last known
  String? get uid {
    final current = FirebaseAuth.instance.currentUser?.uid;
    if (current != null) _lastUid = current;
    return current ?? _lastUid;
  }

  /// Stream active ride safely
  Stream<DocumentSnapshot?> get rideStream {
    final currentUid = uid;
    if (currentUid == null) return const Stream.empty();

    return fire
        .collection('rides')
        .where('riderId', isEqualTo: currentUid)
        .where('status', whereIn: ['pending', 'accepted', 'in_progress'])
        .orderBy('createdAt', descending: false)
        .limit(1)
        .snapshots()
        .map((s) => s.docs.isNotEmpty ? s.docs.first : null);
  }

  /// Fetch active ride
  void fetchActiveRide() {
    final currentUid = uid;
    if (currentUid == null) {
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
      },
    );
  }

  /// Create a new ride request
  Future<void> createRide(
    String pickup,
    String dropoff,
    double fare,
    GeoPoint pickupLocation,
    GeoPoint dropoffLocation,
  ) async {
    final currentUid = uid;
    if (currentUid == null) return;

    try {
      final docRef = await fire.collection('rides').add({
        'riderId': currentUid,
        'pickup': pickup,
        'dropoff': dropoff,
        'pickupLocation': pickupLocation,
        'dropoffLocation': dropoffLocation,
        'fare': fare,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });

      final newRide = await docRef.get();
      state = AsyncData(newRide);
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }

  /// Cancel an active ride
  Future<void> cancelRide(String rideId) async {
    final currentUid = uid;
    if (currentUid == null) return;

    try {
      await fire.collection('rides').doc(rideId).update({
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
      });
      fetchActiveRide();
    } catch (e, st) {
      state = AsyncError(e, st);
    }
  }
}
