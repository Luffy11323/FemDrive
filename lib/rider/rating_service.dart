import 'package:cloud_firestore/cloud_firestore.dart';

class RatingService {
  final _fire = FirebaseFirestore.instance;
  Future<bool> hasAlreadyRated(String rideId, String fromUid) async {
    final q = await _fire
        .collection('ratings')
        .where('rideId', isEqualTo: rideId)
        .where('fromUid', isEqualTo: fromUid)
        .limit(1)
        .get();

    return q.docs.isNotEmpty;
  }

  Future<void> submitRating({
    required String rideId,
    required String fromUid,
    required String toUid,
    required double rating,
    String? comment,
  }) async {
    await _fire.collection('ratings').add({
      'rideId': rideId,
      'fromUid': fromUid,
      'toUid': toUid,
      'rating': rating,
      'comment': comment ?? '',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}
