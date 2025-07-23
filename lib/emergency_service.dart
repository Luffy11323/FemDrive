import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class EmergencyService {
  static final _fire = FirebaseFirestore.instance;

  static Future<void> sendEmergency({
    required String rideId,
    required String currentUid,
    required String otherUid,
  }) async {
    try {
      // ✅ Mark user as unverified
      await _fire.collection('users').doc(otherUid).update({'verified': false});

      // ✅ Cancel the ride
      await _fire.collection('rides').doc(rideId).update({
        'status': 'cancelled',
      });

      // ✅ Notify backend via REST API
      final response = await http.post(
        Uri.parse('https://fem-drive.vercel.app/api/emergency'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'rideId': rideId,
          'reportedBy': currentUid,
          'otherUid': otherUid,
        }),
      );

      if (response.statusCode != 200) {
        throw Exception('Backend error: ${response.body}');
      }
    } catch (e) {
      throw Exception('Failed to send emergency: $e');
    }
  }
}
