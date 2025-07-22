import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage msg) async {
  await NotificationService.instance.initialize();
  NotificationService.instance.showNotification(msg);
}

class NotificationService {
  NotificationService._();
  static final instance = NotificationService._();

  final _fln = FlutterLocalNotificationsPlugin();

  Future initialize() async {
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
        _handleNavigation(response.payload);
      },
    );

    FirebaseMessaging.onMessage.listen((msg) => showNotification(msg));
    FirebaseMessaging.onMessageOpenedApp.listen(
      (msg) => _handleNavigation(msg.data['screen']),
    );
  }

  Future showNotification(RemoteMessage msg) async {
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
        ),
        iOS: DarwinNotificationDetails(),
      ),
      payload: msg.data['screen'],
    );
  }

  void _handleNavigation(String? screen) {
    if (screen == 'ride_details') {
      // e.g., navigate to ride details screen
    }
  }

  Future<String?> getToken() => FirebaseMessaging.instance.getToken();
}
