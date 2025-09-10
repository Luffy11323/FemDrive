import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// ─────────────────────────────────────────────────────────────────
/// Channels & ids (match native asset names you already ship)
/// ─────────────────────────────────────────────────────────────────
const _chIncomingId = 'ride_incoming_ch';
const _chIncomingNm = 'Incoming Ride';

const _chAcceptId = 'ride_accept_ch';
const _chAcceptNm = 'Ride Accepted';

const _chCancelId = 'ride_cancel_ch';
const _chCancelNm = 'Ride Cancelled';

const _chEmergencyId = 'ride_emergency_ch';
const _chEmergencyNm = 'Emergency Alert';

/// NEW (quiet channels for progress / reports / payment)
const _chProgressId = 'ride_progress_ch';
const _chProgressNm = 'Ride Progress';

const _chReportsId = 'ride_reports_ch';
const _chReportsNm = 'Reports & Safety';

const _chPaymentsId = 'ride_payments_ch';
const _chPaymentsNm = 'Payments';

/// Existing sounds you already reference
const _androidEmergencySound = RawResourceAndroidNotificationSound(
  'ride_incoming_15s',
);
const _iosEmergencySound = 'ride_incoming_15s.wav';

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

/// Stable ids to update/replace specific notifications
const _idIncoming = 9101;
const _idAccept = 9102;
const _idCancel = 9103;
const _idEmergency = 9104;

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
      if (kDebugMode) print('[LocalNotif tap] payload=${resp.payload}');
    },
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  // Android channels
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

  // NEW quiet channels (no custom sounds required)
  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      _chProgressId,
      _chProgressNm,
      description: 'Driver arrived, ride started, ride completed',
      importance: Importance.defaultImportance,
      playSound: true,
    ),
  );

  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      _chReportsId,
      _chReportsNm,
      description: 'Reports and safety alerts',
      importance: Importance.high,
      playSound: true,
    ),
  );

  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      _chPaymentsId,
      _chPaymentsNm,
      description: 'Payment status notifications',
      importance: Importance.high,
      playSound: true,
    ),
  );

  // Foreground FCM
  FirebaseMessaging.onMessage.listen((m) async {
    try {
      await _handleRemote(message: m, isBackground: false);
    } catch (e, st) {
      if (kDebugMode) print('[FCM onMessage error] $e\n$st');
    }
  });

  // Background FCM
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
}

/// Background tap callback (iOS 10+)
@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse resp) {
  if (kDebugMode) print('[LocalNotif background tap] payload=${resp.payload}');
}

/// FCM background isolate entry point
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await _handleRemote(message: message, isBackground: true);
  } catch (e, st) {
    if (kDebugMode) print('[FCM BG handler error] $e\n$st');
  }
}

/// Centralized mapping from FCM → local notifications
Future<void> _handleRemote({
  required RemoteMessage message,
  required bool isBackground,
}) async {
  final data = message.data;
  final action = (data['action'] ?? '').toString(); // actions win
  final status = (data['status'] ?? '').toString(); // fallback to status
  final rideId = (data['rideId'] ?? '').toString();
  final title = message.notification?.title;
  final body = message.notification?.body;

  if (kDebugMode) {
    print(
      '[FCM ${isBackground ? 'BG' : 'FG'}] action=$action status=$status rideId=$rideId',
    );
  }

  // ── Actions (explicit) ─────────────────────────────────────────
  if (action == 'PAYMENT_OK') {
    await showPaymentConfirmed(rideId: rideId);
    return;
  }

  if (action == 'PAYMENT_FAIL') {
    await showPaymentFailed(rideId: rideId);
    return;
  }

  if (action == 'COUNTER_FARE') {
    await showCounterFare(rideId: rideId);
    return;
  }

  if (action == 'REPORTED') {
    await showReportedAgainstYou(rideId: rideId);
    return;
  }

  switch (action) {
    case 'NEW_REQUEST':
      await showIncomingRide(rideId: rideId, title: title, body: body);
      return;
    case 'COUNTER_FARE':
      await showCounterFare(rideId: rideId, title: title, body: body);
      return;
    case 'COUNTER_FARE_ACCEPTED':
      await showCounterFareAccepted(rideId: rideId, title: title, body: body);
      return;
    case 'COUNTER_FARE_REJECTED':
      await showCounterFareRejected(rideId: rideId, title: title, body: body);
      return;
    case 'EMERGENCY':
      await showEmergencyAlert(rideId: rideId, title: title, body: body);
      return;
    case 'REPORTED_AGAINST_YOU':
      await showReportedAgainstYou(rideId: rideId, title: title, body: body);
      return;
    case 'CANCELLED_BY_RIDER':
      await showCancelledByRider(rideId: rideId, title: title, body: body);
      return;
    case 'CANCELLED_BY_DRIVER':
      await showCancelledByDriver(rideId: rideId, title: title, body: body);
      return;
    case 'PAYMENT_CONFIRMED':
      await showPaymentConfirmed(rideId: rideId, title: title, body: body);
      return;
    case 'PAYMENT_FAILED':
      await showPaymentFailed(rideId: rideId, title: title, body: body);
      return;
  }

  // ── Status (generic) ───────────────────────────────────────────
  switch (status) {
    case 'accepted':
      await showAccepted(rideId: rideId, title: title, body: body);
      break;
    case 'driver_arrived':
      await showDriverArrived(rideId: rideId, title: title, body: body);
      break;
    case 'in_progress':
      await showRideStarted(rideId: rideId, title: title, body: body);
      break;
    case 'onTrip':
      await showRideStarted(rideId: rideId, title: title, body: body);
      break;
    case 'completed':
      await showRideCompleted(rideId: rideId, title: title, body: body);
      break;
    case 'cancelled':
      // If 'byUid' is present and equals the current user -> showCancelledByRider
      // Otherwise -> showCancelledByDriver
      if (data['byUid'] == 'current_user_uid') {
        await showCancelledByRider(rideId: rideId, title: title, body: body);
      } else {
        await showCancelledByDriver(rideId: rideId, title: title, body: body);
      }
      break;
    case 'no_drivers':
      await showNoDrivers(rideId: rideId, title: title, body: body);
      break;
    default:
      break;
  }
}

/// ── Incoming Ride (15s, persistent) — Driver side
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
          ongoing: true,
        ),
        iOS: const DarwinNotificationDetails(sound: _iosIncomingSound),
      ),
      payload: rideId,
    );
  } catch (_) {}
}

/// ── Accepted (3s) — Rider side chime, stop incoming
Future<void> showAccepted({String? rideId, String? title, String? body}) async {
  try {
    await _fln.cancel(_idIncoming);
    await _fln.show(
      _idAccept,
      title ?? 'Ride Accepted',
      body ?? 'Your driver has accepted your ride.',
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
  } catch (_) {}
}

/// ── Driver arrived / Ride started / Completed / No drivers
Future<void> showDriverArrived({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.show(
      9201,
      title ?? 'Driver Arrived',
      body ?? 'Your driver has arrived.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _chProgressId,
          _chProgressNm,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: rideId,
    );
  } catch (_) {}
}

Future<void> showRideStarted({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.show(
      9202,
      title ?? 'Ride Started',
      body ?? 'Your ride has begun.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _chProgressId,
          _chProgressNm,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: rideId,
    );
  } catch (_) {}
}

Future<void> showRideCompleted({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.show(
      9203,
      title ?? 'Ride Completed',
      body ?? 'Thanks for riding with FemDrive!',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _chProgressId,
          _chProgressNm,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: rideId,
    );
  } catch (_) {}
}

Future<void> showNoDrivers({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.show(
      9204,
      title ?? 'No Drivers Available',
      body ?? 'Sorry, no drivers are currently available.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _chProgressId,
          _chProgressNm,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: rideId,
    );
  } catch (_) {}
}

/// ── Counter-fare (driver → rider) + results (rider → driver)
Future<void> showCounterFare({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.show(
      9205,
      title ?? 'Counter Fare',
      body ?? 'The driver proposed a different fare.',
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
  } catch (_) {}
}

Future<void> showCounterFareAccepted({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.show(
      9207,
      title ?? 'Counter Fare Accepted',
      body ?? 'Your counter offer was accepted.',
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
  } catch (_) {}
}

Future<void> showCounterFareRejected({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.show(
      9208,
      title ?? 'Counter Fare Rejected',
      body ?? 'Your counter offer was rejected.',
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
  } catch (_) {}
}

/// ── Cancel variants + generic cancelled
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
  } catch (_) {}
}

Future<void> showCancelledByRider({
  String? rideId,
  String? title,
  String? body,
}) async {
  await showCancelled(
    rideId: rideId,
    title: title ?? 'Ride Cancelled by Rider',
    body: body ?? 'The rider cancelled this ride.',
  );
}

Future<void> showCancelledByDriver({
  String? rideId,
  String? title,
  String? body,
}) async {
  await showCancelled(
    rideId: rideId,
    title: title ?? 'Ride Cancelled by Driver',
    body: body ?? 'The driver cancelled this ride.',
  );
}

/// ── SOS
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
  } catch (_) {}
}

Future<void> showReportedAgainstYou({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.show(
      9206,
      title ?? 'Safety Report Filed',
      body ?? 'A report was filed against you for this ride.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _chReportsId,
          _chReportsNm,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: rideId,
    );
  } catch (_) {}
}

/// ── Payment status (optional hook)
Future<void> showPaymentConfirmed({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.show(
      9301,
      title ?? 'Payment Confirmed',
      body ?? 'Your payment was successful.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _chPaymentsId,
          _chPaymentsNm,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: rideId,
    );
  } catch (_) {}
}

Future<void> showPaymentFailed({
  String? rideId,
  String? title,
  String? body,
}) async {
  try {
    await _fln.show(
      9302,
      title ?? 'Payment Failed',
      body ?? 'Please update your payment method.',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _chPaymentsId,
          _chPaymentsNm,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
      payload: rideId,
    );
  } catch (_) {}
}
