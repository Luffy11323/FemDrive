import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:logger/logger.dart';
import 'driver/driver_services.dart';

class RatingService {
  final _fire = FirebaseFirestore.instance;
  final _logger = Logger();

  Future<bool> hasAlreadyRated(String rideId, String userId) async {
    try {
      final snapshot = await _fire
          .collection(AppPaths.ratingsCollection)
          .where('rideId', isEqualTo: rideId)
          .where('fromUid', isEqualTo: userId)
          .get();
      return snapshot.docs.isNotEmpty;
    } catch (e) {
      _logger.e('Error checking rating status: $e');
      throw Exception('Failed to check rating status: $e');
    }
  }

  Future<void> submitRating({
    required String rideId,
    required String fromUid,
    required String toUid,
    required double rating,
    required String comment,
  }) async {
    try {
      await _fire.collection(AppPaths.ratingsCollection).add({
        'rideId': rideId,
        'fromUid': fromUid,
        'toUid': toUid,
        AppFields.rating: rating,
        AppFields.comment: comment,
        AppFields.timestamp: FieldValue.serverTimestamp(),
      });

      // Update average rating for the recipient
      final ratings = await _fire
          .collection(AppPaths.ratingsCollection)
          .where('toUid', isEqualTo: toUid)
          .get();
      final avgRating = ratings.docs.isEmpty
          ? rating
          : ratings.docs
                    .map((doc) => (doc[AppFields.rating] as num).toDouble())
                    .reduce((a, b) => a + b) /
                ratings.docs.length;

      await _fire.collection('users').doc(toUid).update({
        'averageRating': avgRating,
      });
    } catch (e) {
      _logger.e('Failed to submit rating: $e');
      throw Exception('Failed to submit rating: $e');
    }
  }
}
