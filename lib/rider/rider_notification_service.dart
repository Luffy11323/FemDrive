import 'dart:io';
import 'package:femdrive/main.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:logger/logger.dart';

// ignore: unused_import
import 'rider_services.dart';

/// ✅ Background FCM entry point — required for notifications when app is killed
@pragma('vm:entry-point')
Future<void> _firebaseRiderBackgroundHandler(RemoteMessage message) async {
  // Re-initialize the service since background isolate is separate
  await RiderNotificationService.instance.initialize();
  await RiderNotificationService.instance.show(message);
}

/// 🔔 Rider-side Notification Service
/// Handles all background, foreground, and user-tap navigation logic.
class RiderNotificationService {
  RiderNotificationService._();
  static final instance = RiderNotificationService._();

  final _flutterLocal = FlutterLocalNotificationsPlugin();
  final _logger = Logger();

  /// Initialize FCM + Local Notification channels
  Future<void> initialize() async {
    // Register background message handler (safe to call multiple times)
    FirebaseMessaging.onBackgroundMessage(_firebaseRiderBackgroundHandler);

    // iOS permission
    if (Platform.isIOS) {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
    }

    // Local notifications initialization
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
      final context = navigatorKey.currentContext;
      if (context != null) {
        if(!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Notification init failed: $e')),
        );
      }
    }

    // 🔹 Foreground message listener
    FirebaseMessaging.onMessage.listen((msg) async {
      await show(msg);
      _handleInAppUI(msg);
    });

    // 🔹 App opened via notification
    FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      _route(msg.data['screen']);
    });
  }

  /// Display a local notification (foreground/background)
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
            'rider_channel', // unique channel ID
            'Rider Notifications',
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
        payload: msg.data['screen'], // used for navigation when tapped
      );

      _logger.i("Notification shown: ${notif.title}");
    } catch (e) {
      _logger.e('Failed to show notification: $e');
      final context = navigatorKey.currentContext;
      if (context != null) {
        if(!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to show notification: $e')),
        );
      }
    }
  }

  /// Handle in-app message when the app is already open
  void _handleInAppUI(RemoteMessage msg) {
    final screen = msg.data['screen'];
    final status = msg.data['status'];
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

  /// Handle deep-link routing from notification tap
  void _route(String? screen) {
    if (screen == 'ride_status' || screen == 'counter_fare') {
      navigatorKey.currentState?.pushNamed('/dashboard');
    } else {
      _logger.w('Unknown screen route: $screen');
    }
  }

  /// Retrieve the FCM token for sync
  Future<String?> getToken() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      _logger.i("✅ Rider FCM Token: $token");
      return token;
    } catch (e) {
      _logger.e('Failed to get FCM token: $e');
      return null;
    }
  }
}
