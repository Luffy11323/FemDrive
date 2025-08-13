import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'firebase_options.dart';
import 'theme.dart';

// Auth & Pages
import 'login_page.dart';
import 'sign_up_page.dart';
import 'driver_dashboard.dart';
import 'rider_dashboard.dart';
import 'admin.dart';
import 'rider/rider_services.dart';
import 'driver/driver_services.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint("🔔 Background Notification: ${message.messageId}");
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  runApp(const FemDriveApp());
}

class FemDriveApp extends StatefulWidget {
  const FemDriveApp({super.key});

  @override
  State<FemDriveApp> createState() => _FemDriveAppState();
}

class _FemDriveAppState extends State<FemDriveApp> {
  @override
  void initState() {
    super.initState();
    _setupFCM();
  }

  Future<void> _setupFCM() async {
    final fbm = FirebaseMessaging.instance;
    await fbm.requestPermission();
    final token = await fbm.getToken();
    final user = FirebaseAuth.instance.currentUser;

    if (token != null && user != null) {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update(
        {'fcmToken': token},
      );
    }

    FirebaseMessaging.onMessage.listen((msg) {
      final notif = msg.notification;
      if (notif != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${notif.title}: ${notif.body}'),
            backgroundColor: Colors.teal,
          ),
        );
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      final data = msg.data;
      final action = data['action'];
      final rideId = data['rideId'];
      if (action == 'NEW_REQUEST') {
        navigatorKey.currentState?.pushNamed(
          '/driver-ride-details',
          arguments: rideId,
        );
      } else if (action == 'RIDER_STATUS') {
        navigatorKey.currentState?.pushNamed('/dashboard');
      }
    });

    final initialMsg = await fbm.getInitialMessage();
    if (initialMsg != null) {
      final action = initialMsg.data['action'];
      final rideId = initialMsg.data['rideId'];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (action == 'NEW_REQUEST') {
          navigatorKey.currentState?.pushNamed(
            '/driver-ride-details',
            arguments: rideId,
          );
        } else if (action == 'RIDER_STATUS') {
          navigatorKey.currentState?.pushNamed('/dashboard');
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'FemDrive',
      theme: femTheme,
      debugShowCheckedModeBanner: false,
      home: const LoginPage(),
      routes: {
        '/login': (context) => const LoginPage(),
        '/signup': (context) => const SignUpPage(),
        '/dashboard': (context) => const RiderDashboardPage(),
        '/driver-dashboard': (context) => const DriverDashboard(),
        '/admin': (context) => const AdminDriverVerificationPage(),
        '/profile': (context) => const ProfilePage(),
        '/past-rides': (context) => const PastRidesPage(),
        '/driver-ride-details': (context) {
          final rideId = ModalRoute.of(context)!.settings.arguments as String;
          return DriverRideDetailsPage(rideId: rideId);
        },
      },
    );
  }
}
