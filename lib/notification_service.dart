import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

// Define a global navigatorKey if not already defined elsewhere
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage msg) async {
  await NotificationService.instance.initialize();
  await NotificationService.instance._show(msg);
  NotificationService.instance._route(msg.data['screen']);
}

class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _fln = FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

    if (Platform.isIOS) {
      await FirebaseMessaging.instance.requestPermission();
    }

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings();

    await _fln.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        _route(response.payload);
      },
    );

    FirebaseMessaging.onMessage.listen((msg) => _show(msg));
    FirebaseMessaging.onMessageOpenedApp.listen(
      (msg) => _route(msg.data['screen']),
    );
  }

  Future<void> _show(RemoteMessage msg) async {
    final notif = msg.notification;
    if (notif == null) return;

    await _fln.show(
      notif.hashCode,
      notif.title,
      notif.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'high_imp',
          'High Importance',
          importance: Importance.max,
          priority: Priority.high,
          playSound: true,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: msg.data['screen'], // used for navigation
    );
  }

  void _route(String? screen) {
    // TODO: Replace with navigatorKey or callback to handle navigation
    if (screen == 'ride_details') {
      navigatorKey.currentState?.pushNamed('/driver-ride-details');
      print('[NotificationService] Navigate to: ride_details');
    }
    // Add more routes as needed
  }

  Future<String?> getToken() => FirebaseMessaging.instance.getToken();
}
