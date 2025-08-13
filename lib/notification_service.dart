import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await NotificationService.instance.initialize();
  await NotificationService.instance.handleMessage(message);
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

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();

    await _fln.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
      onDidReceiveNotificationResponse: (response) {
        if (response.payload != null) {
          final screen = response.payload!;
          route({'screen': screen});
        }
      },
    );

    FirebaseMessaging.onMessage.listen(show);
    FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      route(msg.data);
    });
  }

  Future<void> show(RemoteMessage msg) async {
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
      payload: msg.data['screen'],
    );
  }

  Future<void> handleMessage(RemoteMessage message) async {
    await show(message);
    route(message.data);
  }

  void route(Map<String, dynamic> data) {
    final screen = data['screen'];
    final rideId = data['rideId'];

    switch (screen) {
      case 'driver_ride_details':
        if (rideId != null) {
          navigatorKey.currentState?.pushNamed(
            '/driver-ride-details',
            arguments: rideId,
          );
        }
        break;
      case 'dashboard':
        navigatorKey.currentState?.pushNamed('/dashboard');
        break;
      case 'profile':
        navigatorKey.currentState?.pushNamed('/profile');
        break;
      default:
        if (kDebugMode) {
          print('[NotificationService] Unhandled screen: $screen');
        }
    }
  }

  Future<String?> getToken() => FirebaseMessaging.instance.getToken();
}
