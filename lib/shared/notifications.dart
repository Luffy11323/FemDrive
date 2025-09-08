// lib/notifications.dart
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// ─────────────────────────────────────────────────────────────────
/// Channel & sound ids (match native asset names on each platform)
/// ─────────────────────────────────────────────────────────────────
const _chIncomingId = 'ride_incoming_ch';
const _chIncomingNm = 'Incoming Ride';
const _chAcceptId = 'ride_accept_ch';
const _chAcceptNm = 'Ride Accepted';
const _chCancelId = 'ride_cancel_ch';
const _chCancelNm = 'Ride Cancelled';
const _chEmergencyId = 'ride_emergency_ch';
const _chEmergencyNm = 'Emergency Alert';

const _androidEmergencySound = RawResourceAndroidNotificationSound(
  'ride_incoming_15s', // same sound file as incoming ride
);
const _iosEmergencySound = 'ride_incoming_15s.wav';

const _idEmergency = 9104; // Unique ID

const _androidIncomingSound = RawResourceAndroidNotificationSound(
  'ride_incoming_15s',
);
const _androidAcceptSound = RawResourceAndroidNotificationSound(
  'ride_accept_3s',
);
const _androidCancelSound = RawResourceAndroidNotificationSound(
  'ride_cancel_2s',
);

const _iosIncomingSound = 'ride_incoming_15s.wav';
const _iosAcceptSound = 'ride_accept_3s.wav';
const _iosCancelSound = 'ride_cancel_2s.wav';

/// A stable id to control the “ringing” notification so we can cancel it.
const _idIncoming = 9101;
const _idAccept = 9102;
const _idCancel = 9103;

final _fln = FlutterLocalNotificationsPlugin();

/// Call this once in main() after Firebase.initializeApp()
Future<void> initRideNotifs() async {
  // iOS permission (alerts, sounds, badges)
  if (Platform.isIOS || Platform.isMacOS) {
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      announcement: false,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
    );
  }

  // Android 13+ runtime notification permission should be requested in your UI.
  // (Leave as-is here; app can request via permission_handler if needed.)

  // Initialize local notifications
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosInit = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );

  await _fln.initialize(
    const InitializationSettings(android: androidInit, iOS: iosInit),
    onDidReceiveNotificationResponse: (resp) {
      // Handle taps (payload carries rideId). You can route to details from here.
      if (kDebugMode) {
        print('[LocalNotif tap] payload=${resp.payload}');
      }
    },
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  // Create Android channels (Android 8+). No audio attributes needed.
  final android = _fln
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      _chIncomingId,
      _chIncomingNm,
      description: 'Incoming ride alerts',
      importance: Importance.max,
      playSound: true,
      sound: _androidIncomingSound,
    ),
  );

  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      _chAcceptId,
      _chAcceptNm,
      description: 'Ride accepted chime',
      importance: Importance.high,
      playSound: true,
      sound: _androidAcceptSound,
    ),
  );

  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      _chCancelId,
      _chCancelNm,
      description: 'Ride cancelled tone',
      importance: Importance.high,
      playSound: true,
      sound: _androidCancelSound,
    ),
  );

  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      _chEmergencyId,
      _chEmergencyNm,
      description: 'Emergency alerts from rides',
      importance: Importance.max,
      playSound: true,
      sound: _androidEmergencySound,
    ),
  );

  // Hook FCM foreground messages → show local notification (with sound)
  FirebaseMessaging.onMessage.listen((m) async {
    try {
      await _handleRemote(message: m, isBackground: false);
    } catch (e, st) {
      if (kDebugMode) {
        print('[FCM onMessage error] $e\n$st');
      }
    }
  });

  // Register background handler (data or notification payloads)
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
}

/// Background tap callback (iOS 10+)
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse resp) {
  // Keep minimal; app is in background isolate here.
  if (kDebugMode) {
    print('[LocalNotif background tap] payload=${resp.payload}');
  }
}

/// FCM background isolate entry point
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // You must not call Firebase.initializeApp() again if already done by core logic.
  // The local notifications plugin is process-safe; we just render a local notif.
  try {
    await _handleRemote(message: message, isBackground: true);
  } catch (e, st) {
    if (kDebugMode) {
      print('[FCM BG handler error] $e\n$st');
    }
  }
}

/// Centralized mapping from FCM → local notifications
Future<void> _handleRemote({
  required RemoteMessage message,
  required bool isBackground,
}) async {
  final data = message.data;
  final action = (data['action'] ?? '').toString(); // e.g. NEW_REQUEST
  final status = (data['status'] ?? '').toString(); // e.g. accepted/cancelled
  final rideId = (data['rideId'] ?? '').toString();
  final title = message.notification?.title;
  final body = message.notification?.body;

  if (kDebugMode) {
    print(
      '[FCM ${isBackground ? 'BG' : 'FG'}] action=$action status=$status rideId=$rideId',
    );
  }

  if (action == 'NEW_REQUEST') {
    await showIncomingRide(rideId: rideId, title: title, body: body);
    return;
  }
  if (action == 'EMERGENCY') {
    await showEmergencyAlert(rideId: rideId, title: title, body: body);
    return;
  }

  switch (status) {
    case 'accepted':
      await showAccepted(rideId: rideId, title: title, body: body);
      break;
    case 'cancelled':
      await showCancelled(rideId: rideId, title: title, body: body);
      break;
    default:
      // Optional: surface other statuses if you want (arrived, in_progress, completed)
      break;
  }
}

/// ── Incoming Ride (15s) — persistent until accept/cancel ─────────────────
Future<void> showIncomingRide({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.show(
      _idIncoming,
      title ?? 'Incoming Ride',
      body ?? 'Pickup nearby. Tap to view.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _chIncomingId,
          _chIncomingNm,
          priority: Priority.max,
          importance: Importance.max,
          category: AndroidNotificationCategory.call,
          ongoing: true, // keep “ringing” card until action
          // Sound is bound to channel; no need to set here again.
        ),
        iOS: const DarwinNotificationDetails(sound: _iosIncomingSound),
      ),
      payload: rideId,
    );
  } catch (e, st) {
    if (kDebugMode) {
      print('[showIncomingRide error] $e\n$st');
    }
  }
}

/// ── Accepted (3s) — stop ringing, play short chime ───────────────────────
Future<void> showAccepted({String? rideId, String? title, String? body}) async {
  try {
    await _fln.cancel(_idIncoming); // stop incoming if still present
    await _fln.show(
      _idAccept,
      title ?? 'Ride Accepted',
      body ?? 'Your ride has been accepted.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _chAcceptId,
          _chAcceptNm,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(sound: _iosAcceptSound),
      ),
      payload: rideId,
    );
  } catch (e, st) {
    if (kDebugMode) {
      print('[showAccepted error] $e\n$st');
    }
  }
}

/// ── Cancelled (2s) — stop ringing, play short tone ───────────────────────
Future<void> showCancelled({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.cancel(_idIncoming);
    await _fln.show(
      _idCancel,
      title ?? 'Ride Cancelled',
      body ?? 'The request was cancelled.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _chCancelId,
          _chCancelNm,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(sound: _iosCancelSound),
      ),
      payload: rideId,
    );
  } catch (e, st) {
    if (kDebugMode) {
      print('[showCancelled error] $e\n$st');
    }
  }
}

/// ── Emergency Alert (15s siren) ──────────────────────────────────────────
Future<void> showEmergencyAlert({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.show(
      _idEmergency,
      title ?? '🚨 Emergency Triggered',
      body ?? 'A ride has reported an emergency.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _chEmergencyId,
          _chEmergencyNm,
          priority: Priority.max,
          importance: Importance.max,
          category: AndroidNotificationCategory.alarm,
          ongoing: true,
        ),
        iOS: const DarwinNotificationDetails(sound: _iosEmergencySound),
      ),
      payload: rideId,
    );
  } catch (e, st) {
    if (kDebugMode) {
      print('[showEmergencyAlert error] $e\n$st');
    }
  }
}
