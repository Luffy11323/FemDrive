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
  final uid = FirebaseAuth.instance.currentUser!.uid;

  Stream<DocumentSnapshot?> get rideStream => fire
      .collection('rides')
      .where('riderId', isEqualTo: uid)
      .where('status', whereIn: ['pending', 'accepted', 'in_progress'])
      .orderBy('createdAt', descending: false)
      .limit(1)
      .snapshots()
      .map((s) => s.docs.isNotEmpty ? s.docs.first : null);

  void fetchActiveRide() {
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

  Future<void> cancelRide(String rideId) async {
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
