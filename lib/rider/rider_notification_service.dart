import 'dart:io';

import 'package:femdrive/main.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logger/logger.dart';
// ignore: unused_import
import 'rider_services.dart';

@pragma('vm:entry-point')
Future<void> _firebaseRiderBackgroundHandler(RemoteMessage message) async {
  await RiderNotificationService.instance.initialize();
  await RiderNotificationService.instance.show(message);
}

class RiderNotificationService {
  RiderNotificationService._();
  static final instance = RiderNotificationService._();
  final _flutterLocal = FlutterLocalNotificationsPlugin();
  final _logger = Logger();

  Future<void> initialize() async {
    FirebaseMessaging.onBackgroundMessage(_firebaseRiderBackgroundHandler);

    if (Platform.isIOS) {
      await FirebaseMessaging.instance.requestPermission();
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();

    try {
      await _flutterLocal.initialize(
        const InitializationSettings(android: androidInit, iOS: iosInit),
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          _route(response.payload);
        },
      );
    } catch (e) {
      _logger.e('Failed to initialize local notifications: $e');
      ScaffoldMessenger.of(navigatorKey.currentContext!).showSnackBar(
        SnackBar(content: Text('Failed to initialize notifications: $e')),
      );
    }

    FirebaseMessaging.onMessage.listen((msg) {
      show(msg);
      _handleInAppUI(msg);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      _route(msg.data['screen']);
    });
  }

  Future<void> show(RemoteMessage msg) async {
    final notif = msg.notification;
    if (notif == null) return;

    try {
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
    } catch (e) {
      _logger.e('Failed to show notification: $e');
      ScaffoldMessenger.of(navigatorKey.currentContext!).showSnackBar(
        SnackBar(content: Text('Failed to show notification: $e')),
      );
    }
  }

  void _handleInAppUI(RemoteMessage msg) {
    final screen = msg.data['screen'];
    final _ = msg.data['rideId'];
    final status = msg.data['status'];
    final _ = msg.data['counterFare'] != null
        ? double.tryParse(msg.data['counterFare'])
        : null;

    final context = navigatorKey.currentContext;
    if (context == null) {
      _logger.w('No context available for in-app UI');
      return;
    }

    if (screen == 'ride_status' && status != null) {
      final message = switch (status) {
        'pending' => 'Ride requested. Waiting for driver...',
        'accepted' => 'Driver accepted your ride!',
        'driver_arrived' => 'Your driver has arrived.',
        'in_progress' => 'Your ride is now in progress.',
        'onTrip' => 'Your ride is now in progress.',
        'completed' => 'Your ride is completed.',
        'cancelled' => 'Your ride was cancelled.',
        _ => 'Ride status updated.',
      };

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.primary,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _route(String? screen) {
    if (screen == 'ride_status' || screen == 'counter_fare') {
      navigatorKey.currentState?.pushNamed('/dashboard');
    } else {
      _logger.w('Unknown screen route: $screen');
    }
  }

  Future<String?> getToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      _logger.e('Failed to get FCM token: $e');
      return null;
    }
  }
}
