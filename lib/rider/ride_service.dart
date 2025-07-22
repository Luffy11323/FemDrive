import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class RideService {
  final _fire = FirebaseFirestore.instance;
  final String userId = FirebaseAuth.instance.currentUser!.uid;

  // Listen to active ride changes in real-time
  Stream<DocumentSnapshot?> listenActiveRide() {
    return _fire
        .collection('rides')
        .where('riderId', isEqualTo: userId)
        .where('status', whereIn: ['pending', 'accepted', 'in_progress'])
        .orderBy('createdAt', descending: false)
        .limit(1)
        .snapshots()
        .map((s) => s.docs.isNotEmpty ? s.docs.first : null);
  }

  // Add a new ride
  Future<void> requestRide(Map<String, dynamic> data) async {
    try {
      await _fire.collection('rides').add(data);
    } catch (e) {
      rethrow;
    }
  }

  // Cancel a ride
  Future<void> cancelRide(String id) async {
    try {
      await _fire.collection('rides').doc(id).update({
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      rethrow;
    }
  }

  // Fetch past rides
  Stream<QuerySnapshot> pastRides() {
    return _fire
        .collection('rides')
        .where('riderId', isEqualTo: userId)
        .where('status', whereIn: ['cancelled', 'completed'])
        .orderBy('createdAt', descending: true)
        .snapshots();
  }
}
