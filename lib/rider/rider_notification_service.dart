import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'rider_dashboard_controller.dart';
// ignore: unused_import
import 'rider_services.dart';
import 'package:flutter/foundation.dart';

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

    try {
      await _flutterLocal.initialize(
        const InitializationSettings(android: androidInit, iOS: iosInit),
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          _route({'screen': response.payload});
        },
      );
    } catch (e) {
      if (kDebugMode) {
        print(
          'NotificationService: Failed to initialize local notifications: $e',
        );
      }
    }

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
      if (kDebugMode) {
        print('NotificationService: Failed to show notification: $e');
      }
    }
  }

  void _handleInAppUI(RemoteMessage msg) {
    final screen = msg.data['screen'];
    final rideId = msg.data['rideId'];
    final status = msg.data['status'];
    final counterFare = msg.data['counterFare'] != null
        ? double.tryParse(msg.data['counterFare'])
        : null;

    final context = riderNavigatorKey.currentContext;
    if (context == null) {
      if (kDebugMode) {
        print('NotificationService: No context available for in-app UI');
      }
      return;
    }

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
    } else if (screen == 'counter_fare' &&
        rideId != null &&
        counterFare != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showDialog(
          context: context,
          builder: (ctx) => CounterFareDialog(
            rideId: rideId,
            counterFare: counterFare,
            onAccept: () {
              try {
                ProviderScope.containerOf(context)
                    .read(riderDashboardProvider.notifier)
                    .handleCounterFare(rideId, counterFare, true);
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to accept counter-fare: $e')),
                );
              }
            },
            onReject: () {
              try {
                ProviderScope.containerOf(context)
                    .read(riderDashboardProvider.notifier)
                    .handleCounterFare(rideId, counterFare, false);
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to reject counter-fare: $e')),
                );
              }
            },
          ),
        );
      });
    }
  }

  void _route(Map<String, dynamic>? data) {
    if (data == null) return;
    final screen = data['screen'];
    final rideId = data['rideId'];

    if ((screen == 'ride_status' || screen == 'counter_fare') &&
        rideId != null) {
      riderNavigatorKey.currentState?.pushNamed('/dashboard');
    } else {
      if (kDebugMode) {
        print('NotificationService: Unknown screen route: $screen');
      }
    }
  }

  Future<String?> getToken() async {
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (e) {
      if (kDebugMode) {
        print('NotificationService: Failed to get FCM token: $e');
      }
      return null;
    }
  }
}

class CounterFareDialog extends StatelessWidget {
  final String rideId;
  final double counterFare;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const CounterFareDialog({
    super.key,
    required this.rideId,
    required this.counterFare,
    required this.onAccept,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Driver Counter Offer'),
      content: Text(
        'The driver has offered a fare of \$${counterFare.toStringAsFixed(2)}. Accept?',
      ),
      actions: [
        TextButton(onPressed: onReject, child: const Text('Reject')),
        ElevatedButton(onPressed: onAccept, child: const Text('Accept')),
      ],
    );
  }
}
