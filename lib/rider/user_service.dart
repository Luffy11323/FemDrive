import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class UserService {
  final _fire = FirebaseFirestore.instance;
  final String uid = FirebaseAuth.instance.currentUser!.uid;

  Stream<DocumentSnapshot> userStream() {
    return _fire.collection('users').doc(uid).snapshots();
  }

  Future<void> updateProfile(Map<String, dynamic> data) async {
    try {
      await _fire.collection('users').doc(uid).update(data);
    } catch (e) {
      rethrow;
    }
  }
}
