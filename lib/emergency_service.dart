import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class EmergencyService {
  static final _fire = FirebaseFirestore.instance;
  static final _rtdb = FirebaseDatabase.instance;

  static Future<void> sendEmergency({
    required String rideId,
    required String currentUid,
    required String otherUid,
  }) async {
    try {
      // ✅ Mark user as unverified
      await _fire.collection('users').doc(otherUid).update({'verified': false});

      // ✅ Cancel the ride in Firestore
      await _fire.collection('rides').doc(rideId).update({
        'status': 'cancelled',
        'emergencyTriggered': true,
      });

      // ✅ Remove from RTDB if exists
      await _rtdb.ref('rides_pending/$rideId').remove();

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
