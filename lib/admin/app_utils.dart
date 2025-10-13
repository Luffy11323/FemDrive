import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart' hide Query;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class AppPaths {
  static const String ridesCollection = 'rides';
  static const String usersCollection = 'users';
  static const String phonesCollection = 'phones';
  static const String emergenciesCollection = 'emergencies';
  static const String ratingsCollection = 'ratings';
  static const String receiptsCollection = 'receipts';
  static const String ridesLive = 'ridesLive';
  static const String driversOnline = 'drivers_online';
  static const String driverNotifications = 'driver_notifications';
  static const String notifications = 'notifications';
  static const String ridesPendingA = 'ridesPendingA';
  static const String ridesPendingB = 'ridesPendingB';
}

class AppFields {
  static const String uid = 'uid';
  static const String phone = 'phone';
  static const String username = 'username';
  static const String role = 'role';
  static const String createdAt = 'createdAt';
  static const String verified = 'verified';
  static const String trustScore = 'trustScore';
  static const String requiresManualReview = 'requiresManualReview';
  static const String cnicNumber = 'cnicNumber';
  static const String cnicBase64 = 'cnicBase64';
  static const String verifiedCnic = 'verifiedCnic';
  static const String documentsUploaded = 'documentsUploaded';
  static const String uploadTimestamp = 'uploadTimestamp';
  static const String carType = 'carType';
  static const String carModel = 'carModel';
  static const String altContact = 'altContact';
  static const String licenseBase64 = 'licenseBase64';
  static const String verifiedLicense = 'verifiedLicense';
  static const String awaitingVerification = 'awaitingVerification';
  static const String status = 'status';
  static const String fare = 'fare';
  static const String driverId = 'driverId';
  static const String riderId = 'riderId';
  static const String pickup = 'pickup';
  static const String dropoff = 'dropoff';
  static const String pickupLat = 'pickupLat';
  static const String pickupLng = 'pickupLng';
  static const String dropoffLat = 'dropoffLat';
  static const String dropoffLng = 'dropoffLng';
  static const String paymentStatus = 'paymentStatus';
  static const String paymentMethod = 'paymentMethod';
  static const String amount = 'amount';
  static const String paymentTimestamp = 'paymentTimestamp';
  static const String earnings = 'earnings';
  static const String emergencyTriggered = 'emergencyTriggered';
  static const String cancelledBy = 'cancelledBy';
  static const String cancelReason = 'cancelReason';
  static const String cancelledAt = 'cancelledAt';
  static const String reportedBy = 'reportedBy';
  static const String otherUid = 'otherUid';
  static const String rideId = 'rideId';
  static const String type = 'type';
  static const String timestamp = 'timestamp';
  static const String lat = 'lat';
  static const String lng = 'lng';
  static const String updatedAt = 'updatedAt';
  static const String rating = 'rating';
  static const String comment = 'comment';
}

class RideStatus {
  static const String pending = 'pending';
  static const String searching = 'searching';
  static const String accepted = 'accepted';
  static const String driverArrived = 'driver_arrived';
  static const String inProgress = 'in_progress';
  static const String onTrip = 'onTrip';
  static const String completed = 'completed';
  static const String cancelled = 'cancelled';
  static List<String> get values => [pending, searching, accepted, driverArrived, inProgress, onTrip, completed, cancelled];
}

class AdminService {
  static final _fire = FirebaseFirestore.instance;
  static final _rtdb = FirebaseDatabase.instance.ref();

  static Future<Map<String, dynamic>?> searchData(String query) async {
    if (query.isEmpty) return null;
    try {
      var rideSnap = await _fire.collection(AppPaths.ridesCollection).doc(query).get();
      if (rideSnap.exists) return {'collection': AppPaths.ridesCollection, 'doc': rideSnap};
      var userSnap = await _fire.collection(AppPaths.usersCollection).doc(query).get();
      if (userSnap.exists) return {'collection': AppPaths.usersCollection, 'doc': userSnap};
      var emergencySnap = await _fire.collection(AppPaths.emergenciesCollection).doc(query).get();
      if (emergencySnap.exists) return {'collection': AppPaths.emergenciesCollection, 'doc': emergencySnap};
      return null;
    } catch (e) {
      throw Exception('Search failed: $e');
    }
  }

  static Stream<QuerySnapshot> getFilteredStream(
      String collection, String searchQuery, String? status, DateTimeRange? dateRange) {
    try {
      Query<Map<String, dynamic>> query = _fire.collection(collection);
      if (status != null && collection == AppPaths.ridesCollection) {
        query = query.where(AppFields.status, isEqualTo: status);
      }
      if (dateRange != null) {
        query = query
            .where(AppFields.createdAt, isGreaterThanOrEqualTo: Timestamp.fromDate(dateRange.start))
            .where(AppFields.createdAt, isLessThanOrEqualTo: Timestamp.fromDate(dateRange.end));
      }
      if (searchQuery.isNotEmpty) {
        query = query.where(FieldPath.documentId, isEqualTo: searchQuery);
      }
      return query.snapshots();
    } catch (e) {
      throw Exception('Failed to get filtered stream: $e');
    }
  }

  static Stream<QuerySnapshot> getDriverVerificationStream(String searchQuery, bool? verificationStatus) {
    try {
      var query = _fire.collection(AppPaths.usersCollection).where(AppFields.role, isEqualTo: 'driver');
      if (verificationStatus != null) {
        query = query.where(AppFields.verified, isEqualTo: verificationStatus);
      }
      if (searchQuery.isNotEmpty) {
        query = query.where(FieldPath.documentId, isEqualTo: searchQuery);
      }
      return query.snapshots();
    } catch (e) {
      throw Exception('Failed to get driver verification stream: $e');
    }
  }

  static Future<Map<String, int>> getRideStatusCounts() async {
    try {
      var snapshot = await _fire.collection(AppPaths.ridesCollection).get();
      Map<String, int> counts = {for (var status in RideStatus.values) status: 0};
      for (var doc in snapshot.docs) {
        String status = doc[AppFields.status] ?? RideStatus.cancelled;
        counts[status] = (counts[status] ?? 0) + 1;
      }
      return counts;
    } catch (e) {
      throw Exception('Failed to get ride status counts: $e');
    }
  }

  static Future<void> updateData(String collection, String docId, Map<String, dynamic> data) async {
    try {
      await _fire.collection(collection).doc(docId).update(data);
      if (collection == AppPaths.ridesCollection) {
        await _rtdb.child('${AppPaths.ridesLive}/$docId').update({
          AppFields.status: data[AppFields.status] ?? RideStatus.cancelled,
          AppFields.updatedAt: ServerValue.timestamp,
        });
      }
    } catch (e) {
      throw Exception('Update failed: $e');
    }
  }

  static Future<void> resolveEmergency(String emergencyId) async {
    try {
      await _fire.collection(AppPaths.emergenciesCollection).doc(emergencyId).update({
        'resolved': true,
        'resolvedAt': FieldValue.serverTimestamp(),
      });
      NotificationService.showNotification('Emergency Resolved', 'Emergency #$emergencyId has been resolved.');
    } catch (e) {
      throw Exception('Failed to resolve emergency: $e');
    }
  }

  static Future<void> sendEmergencyNotification(String rideId, String reportedBy, String otherUid) async {
    try {
      await _rtdb.child('${AppPaths.notifications}/$otherUid').push().set({
        AppFields.type: 'ride_cancelled',
        AppFields.rideId: rideId,
        'reason': 'emergency',
        AppFields.timestamp: ServerValue.timestamp,
      });
      await _rtdb.child('${AppPaths.notifications}/admin').push().set({
        AppFields.type: 'emergency',
        AppFields.rideId: rideId,
        AppFields.reportedBy: reportedBy,
        AppFields.otherUid: otherUid,
        AppFields.timestamp: ServerValue.timestamp,
      });
      NotificationService.showNotification('New Emergency', 'Emergency reported for ride #$rideId by $reportedBy');
    } catch (e) {
      throw Exception('Failed to send emergency notification: $e');
    }
  }
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin = FlutterLocalNotificationsPlugin();
  static VoidCallback? onEmergencyNotification;

  static Future<void> init() async {
    try {
      const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
      const initSettings = InitializationSettings(android: androidInit);
      await _notificationsPlugin.initialize(initSettings);
      FirebaseDatabase.instance.ref().child('${AppPaths.notifications}/admin').onChildAdded.listen((event) {
        try {
          if (event.snapshot.value is Map && (event.snapshot.value as Map)['type'] == 'emergency') {
            onEmergencyNotification?.call();
          }
        } catch (e) {
          if (kDebugMode) {
            print('Error processing notification: $e');
          }
        }
      });
    } catch (e) {
      throw Exception('Notification initialization failed: $e');
    }
  }

  static Future<void> showNotification(String title, String body) async {
    try {
      const androidDetails = AndroidNotificationDetails(
        'emergency_channel',
        'Emergency Alerts',
        channelDescription: 'Notifications for emergency events',
        priority: Priority.high,
        importance: Importance.high,
      );
      const notificationDetails = NotificationDetails(android: androidDetails);
      await _notificationsPlugin.show(0, title, body, notificationDetails);
    } catch (e) {
      throw Exception('Failed to show notification: $e');
    }
  }
}