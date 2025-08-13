import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final GlobalKey<NavigatorState> riderNavigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> _firebaseRiderBackgroundHandler(RemoteMessage message) async {
  await RiderNotificationService.instance.initialize();
  await RiderNotificationService.instance._show(message);
  RiderNotificationService.instance._route(message.data);
}

class RiderNotificationService {
  RiderNotificationService._();
  static final instance = RiderNotificationService._();

  final _flutterLocal = FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(_firebaseRiderBackgroundHandler);

    if (Platform.isIOS) {
      await FirebaseMessaging.instance.requestPermission();
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();

    await _flutterLocal.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        _route({'screen': response.payload});
      },
    );

    FirebaseMessaging.onMessage.listen((msg) {
      _show(msg);
      _handleInAppUI(msg);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      _route(msg.data);
    });
  }

  Future<void> _show(RemoteMessage msg) async {
    final notif = msg.notification;
    if (notif == null) return;

    await _flutterLocal.show(
      notif.hashCode,
      notif.title,
      notif.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'rider_channel',
          'Rider Notifications',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: msg.data['screen'],
    );
  }

  void _handleInAppUI(RemoteMessage msg) {
    final screen = msg.data['screen'];
    final _ = msg.data['rideId'];
    final status = msg.data['status'];

    final context = riderNavigatorKey.currentContext;
    if (context == null) return;

    if (screen == 'ride_status' && status != null) {
      final message = switch (status) {
        'pending' => 'Ride requested. Waiting for driver...',
        'accepted' => 'Driver accepted your ride!',
        'in_progress' => 'Your ride is now in progress.',
        'completed' => 'Your ride is completed.',
        'cancelled' => 'Your ride was cancelled.',
        _ => 'Ride status updated.',
      };

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.blueAccent,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _route(Map<String, dynamic>? data) {
    if (data == null) return;
    final screen = data['screen'];
    final rideId = data['rideId'];

    if (screen == 'ride_status' && rideId != null) {
      riderNavigatorKey.currentState?.pushNamed('/dashboard');
    } else {
      if (kDebugMode) {
        print('[RiderNotification] Unknown screen route: $screen');
      }
    }
  }

  Future<String?> getToken() => FirebaseMessaging.instance.getToken();
}
