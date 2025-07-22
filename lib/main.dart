import 'package:femdrive/admin_driver_verification.dart';
import 'package:femdrive/driver/driver_services.dart';
import 'package:femdrive/login_page.dart';
import 'package:femdrive/sign_up_page.dart';
import 'package:femdrive/rider_dashboard.dart';
import 'package:femdrive/driver_dashboard.dart';
import 'package:femdrive/rider/past_rides_page.dart';
import 'package:femdrive/rider/profile_page.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'theme.dart';
import 'firebase_options.dart';

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
    _initFCM();
  }

  Future<void> _initFCM() async {
    final fbm = FirebaseMessaging.instance;

    await fbm.requestPermission();
    final token = await fbm.getToken();
    final user = FirebaseAuth.instance.currentUser;

    if (token != null && user != null) {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update(
        {'fcmToken': token},
      );
    }

    // Foreground notifications
    FirebaseMessaging.onMessage.listen((RemoteMessage msg) {
      if (msg.notification != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${msg.notification!.title}: ${msg.notification!.body}',
            ),
            backgroundColor: Colors.teal,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    });

    // Tapped from background
    FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      final data = msg.data;
      if (data['action'] == 'NEW_REQUEST' && mounted) {
        Navigator.pushNamed(
          context,
          '/driver-ride-details',
          arguments: data['rideId'],
        );
      } else {
        // handle other actions if needed
      }
    });

    // Cold start
    final initialMsg = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMsg?.data['action'] == 'NEW_REQUEST') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Navigator.pushNamed(
          context,
          '/driver-ride-details',
          arguments: initialMsg!.data['rideId'],
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FemDrive',
      theme: femTheme,
      debugShowCheckedModeBanner: false,
      home: const LoginPage(),
      routes: {
        '/signup': (context) => const SignUpPage(),
        '/dashboard': (context) => const RiderDashboardPage(),
        '/admin': (context) => const AdminDriverVerificationPage(),
        '/profile': (context) => const ProfilePage(),
        '/past-rides': (context) => const PastRidesPage(),
        '/driver-dashboard': (context) => const DriverDashboard(),
        '/login': (context) => const LoginPage(),
        '/driver-ride-details': (context) {
          final rideId = ModalRoute.of(context)!.settings.arguments as String;
          return DriverRideDetailsPage(rideId: rideId);
        },
      },
    );
  }
}
