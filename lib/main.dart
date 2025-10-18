import 'package:femdrive/driver/profile_page.dart';
import 'package:femdrive/location/location_service.dart';
import 'package:femdrive/past_rides_page.dart';
import 'package:femdrive/rider/rider_notification_service.dart';
import 'package:femdrive/rider/rider_profile_page.dart';
import 'package:femdrive/shared/notifications.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:logger/logger.dart';
import 'firebase_options.dart';
import 'theme.dart';
import 'package:femdrive/extras/help_support_page.dart';
import 'package:femdrive/extras/payment_page.dart';
import 'package:femdrive/extras/settings_page.dart';
import 'splash_screen.dart'; // Import the new splash screen

// Pages
import 'login_page.dart';
import 'sign_up_page.dart';
import 'driver/driver_dashboard.dart';
import 'rider/rider_dashboard.dart';
import 'admin/admin_panel.dart';
import 'driver/driver_ride_details_page.dart' as details;

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  debugPrint("🔔 BG Notification: ${message.messageId}, data=${message.data}");

  final data = message.data;
  final action = data['action'];
  final rideId = data['rideId'];

  if (action == 'NEW_REQUEST') {
    debugPrint("📩 Driver BG NEW_REQUEST for ride $rideId");
    await RiderNotificationService.instance.show(message);
  } else if (action == 'COUNTER_FARE') {
    debugPrint("📩 Rider BG COUNTER_FARE for ride $rideId");
    await RiderNotificationService.instance.show(message);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  await initRideNotifs();

  await _setupFcmAndToken();

  final logger = Logger();
  bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    logger.w('Location services disabled');
    await Geolocator.openLocationSettings();
  }

  LocationPermission permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      logger.w('Location permission denied');
    }
  } else if (permission == LocationPermission.deniedForever) {
    logger.w('Location permission permanently denied');
    await Geolocator.openAppSettings();
  }

  runApp(const ProviderScope(child: FemDriveApp()));
}

Future<void> _setupFcmAndToken() async {
  final fbm = FirebaseMessaging.instance;

  await fbm.requestPermission(alert: true, badge: true, sound: true);

  await fbm.setForegroundNotificationPresentationOptions(
    alert: true,
    badge: true,
    sound: true,
  );

  await _storeCurrentTokenIfLoggedIn();

  FirebaseAuth.instance.authStateChanges().listen((user) async {
    if (user != null) {
      await _storeCurrentTokenIfLoggedIn();
    }
  });

  fbm.onTokenRefresh.listen((newToken) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      try {
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'fcmToken': newToken,
        }, SetOptions(merge: true));
        debugPrint('🔁 FCM token refreshed & saved');
      } catch (e) {
        debugPrint('❗ Error saving refreshed token: $e');
      }
    }
  });

  FirebaseMessaging.onMessage.listen((msg) {
    final data = msg.data;
    final action = data['action'];
    final rideId = data['rideId'];

    if (action == 'NEW_REQUEST') {
      debugPrint("📨 FG Driver NEW_REQUEST: $rideId");
      RiderNotificationService.instance.show(msg);
    } else if (action == 'COUNTER_FARE') {
      debugPrint("📨 FG Rider COUNTER_FARE: $rideId");
      RiderNotificationService.instance.show(msg);
    } else {
      final notif = msg.notification;
      if (notif != null) {
        debugPrint('📨 FG msg: ${notif.title} — ${notif.body}');
      }
    }
  });

  FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationNavigation);

  final initial = await fbm.getInitialMessage();
  if (initial != null) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleNotificationNavigation(initial);
    });
  }
}

Future<void> _storeCurrentTokenIfLoggedIn() async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return;
  try {
    final token = await FirebaseMessaging.instance.getToken();
    if (token != null && token.isNotEmpty) {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'fcmToken': token,
      }, SetOptions(merge: true));
      debugPrint('✅ Saved FCM token for $uid');
    }
  } catch (e, st) {
    debugPrint('❗ FCM token save failed: $e\n$st');
  }
}

Future<void> _handleNotificationNavigation(RemoteMessage msg) async {
  final data = msg.data;
  final action = data['action'];
  final rideId = data['rideId'];

  if (action == 'NEW_REQUEST') {
    navigatorKey.currentState?.pushNamed(
      '/driver-ride-details',
      arguments: rideId,
    );
  } else if (action == 'COUNTER_FARE') {
    navigatorKey.currentState?.pushNamed('/dashboard', arguments: rideId);
  } else if (action == 'RIDER_STATUS') {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      if (doc.exists) {
        final role = doc['role'];
        if (role == 'driver') {
          navigatorKey.currentState?.pushNamed('/driver-dashboard');
        } else {
          navigatorKey.currentState?.pushNamed('/dashboard');
        }
      }
    }
  }
}

final userProvider = StreamProvider<User?>(
  (ref) => FirebaseAuth.instance.authStateChanges(),
);

final userDocProvider = StreamProvider<DocumentSnapshot?>((ref) {
  final user = ref.watch(userProvider).asData?.value;
  if (user == null) return const Stream.empty();
  return FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .snapshots();
});

class FemDriveApp extends StatefulWidget {
  const FemDriveApp({super.key});

  @override
  State<FemDriveApp> createState() => _FemDriveAppState();
}

class _FemDriveAppState extends State<FemDriveApp> {
  String? _lastKnownUid;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      await _setupFCM();
    } catch (e) {
      debugPrint('❗ Error during FCM setup in _initializeApp: $e');
    }
  }

  String? getSafeUid() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      _lastKnownUid = uid;
    } else {
      _lastKnownUid = null;
    }
    return uid ?? _lastKnownUid;
  }

  Future<void> _setupFCM() async {
    final fbm = FirebaseMessaging.instance;

    await fbm.requestPermission();

    final uid = getSafeUid();
    if (uid == null) return;

    try {
      final token = await fbm.getToken();
      debugPrint("FCM Token: $token");
      if (token != null) {
        await FirebaseFirestore.instance.collection('users').doc(uid).set({
          'fcmToken': token,
        }, SetOptions(merge: true));
      }

      debugPrint("FCM setup completed");
    } catch (e, stack) {
      debugPrint("FCM setup failed: $e\n$stack");
    }
    fbm.onTokenRefresh.listen((newToken) async {
      final currentUid = getSafeUid();
      if (currentUid != null) {
        try {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(currentUid)
              .set({'fcmToken': newToken}, SetOptions(merge: true));
        } catch (e) {
          debugPrint('Error updating refreshed FCM token: $e');
        }
      }
    });

    FirebaseMessaging.onMessage.listen((msg) {
      final notif = msg.notification;
      if (notif != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${notif.title ?? ''}: ${notif.body ?? ''}'),
            backgroundColor: Theme.of(context).colorScheme.primary,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationNavigation);

    try {
      final initialMsg = await fbm.getInitialMessage();
      if (initialMsg != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _handleNotificationNavigation(initialMsg);
        });
      }
    } catch (e) {
      debugPrint('Error handling initial FCM message: $e');
    }
  }

  void clearLastKnownUid() {
    _lastKnownUid = null;
  }

  Route<dynamic> _generateRoute(RouteSettings settings) {
    Widget page;
    switch (settings.name) {
      case '/login':
        page = const LoginPage();
        break;
      case '/signup':
        page = const SignUpPage();
        break;
      case '/dashboard':
        page = const RiderDashboard();
        break;
      case '/driver-dashboard':
        page = const DriverDashboard();
        break;
      case '/admin':
        page = const AdminPanelApp();
        break;
      case '/settings':
        page = const SettingsPage();
        break;
      case '/payment':
        page = const PaymentPage();
        break;
      case '/help-center':
        page = const HelpCenterPage();
        break;
      case '/profile':
        final user = FirebaseAuth.instance.currentUser;
        if (user == null) {
          page = const LoginPage();
        } else {
          page = FutureBuilder<DocumentSnapshot>(
            future: FirebaseFirestore.instance
                .collection('users')
                .doc(user.uid)
                .get(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Scaffold(
                  body: Center(child: CircularProgressIndicator()),
                );
              }
              if (!snapshot.hasData || !snapshot.data!.exists) {
                return const LoginPage();
              }
              final role = snapshot.data!.get('role');
              return role == 'driver' ? const ProfilePage() : const RiderProfilePage();
            },
          );
        }
        break;
      case '/past-rides':
        page = const PastRidesPage();
        break;
      case '/driver-ride-details':
        final rideId = settings.arguments as String?;
        page = rideId != null
            ? details.DriverRideDetailsPage(rideId: rideId)
            : const LoginPage();
        break;
      default:
        page = const LoginPage();
    }
    return PageRouteBuilder(
      settings: settings,
      pageBuilder: (_, _, _) => page,
      transitionsBuilder: (_, animation, _, child) {
        return FadeTransition(
          opacity: animation.drive(CurveTween(curve: Curves.easeInOut)),
          child: child,
        );
      },
      transitionDuration: const Duration(milliseconds: 400),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'FemDrive',
      theme: femLightTheme,
      darkTheme: femDarkTheme,
      themeMode: ThemeMode.system,
      debugShowCheckedModeBanner: false,
      home: const SplashScreen(),
      onGenerateRoute: _generateRoute,
    );
  }
}

class InitialScreen extends ConsumerWidget {
  const InitialScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(userProvider);
    return userAsync.when(
      data: (user) {
        if (user == null) {
          debugPrint("🔐 No user authenticated, showing LoginPage");
          return const LoginPage();
        }

        debugPrint("🔐 User authenticated: ${user.uid}");
        final userDocAsync = ref.watch(userDocProvider);
        return userDocAsync.when(
          data: (doc) {
            if (doc == null || !doc.exists) {
              debugPrint("🔐 User doc doesn't exist, showing LoginPage");
              return const LoginPage();
            }

            final data = doc.data() as Map<String, dynamic>? ?? {};
            final role = data['role'];
            final isVerified = data['verified'] == true;

            debugPrint("🔐 User role: $role, verified: $isVerified");

            switch (role) {
              case 'admin':
                debugPrint("🔐 Redirecting to AdminPage");
                return const AdminPanelApp();
              case 'driver':
                if (!isVerified) {
                  debugPrint("🔐 Driver not verified, signing out");
                  WidgetsBinding.instance.addPostFrameCallback((_) async {
                    await FirebaseAuth.instance.signOut();
                  });
                  return const LoginPage();
                }

                final driverId = user.uid;
                WidgetsBinding.instance.addPostFrameCallback((_) async {
                  try {
                    await LocationService().initBackgroundTracking(driverId);
                    await LocationService().startBackground();
                    debugPrint(
                      "🚀 Background tracking initialized for driver $driverId",
                    );
                  } catch (e) {
                    debugPrint("❗ Failed to init background tracking: $e");
                  }
                });

                debugPrint("🔐 Redirecting to DriverDashboard");
                return const DriverDashboard();

              case 'rider':
                debugPrint("🔐 Redirecting to RiderDashboard");
                return const RiderDashboard();
              default:
                debugPrint("🔐 Unknown role: $role, showing LoginPage");
                return const LoginPage();
            }
          },
          loading: () {
            debugPrint("🔐 Loading user document...");
            return Scaffold(
              body: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Theme.of(context).colorScheme.primary.withValues(alpha: 0.8),
                      Theme.of(context).colorScheme.surface,
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Theme.of(context).colorScheme.onPrimary,
                        ),
                        strokeWidth: 3.0,
                      ).animate().fadeIn(duration: 400.ms).scaleXY(
                            begin: 0.8,
                            end: 1.0,
                            curve: Curves.easeInOut,
                          ),
                      const SizedBox(height: 16),
                      Text(
                        'Loading your journey...',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontWeight: FontWeight.w600,
                            ),
                      ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
                    ],
                  ),
                ),
              ),
            );
          },
          error: (error, stackTrace) {
            debugPrint("🔐 Error loading user document: $error");
            return const LoginPage();
          },
        );
      },
      loading: () {
        debugPrint("🔐 Loading user authentication...");
        return Scaffold(
          body: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Theme.of(context).colorScheme.primary.withValues(alpha:0.8),
                  Theme.of(context).colorScheme.surface,
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Theme.of(context).colorScheme.onPrimary,
                    ),
                    strokeWidth: 3.0,
                  ).animate().fadeIn(duration: 400.ms).scaleXY(
                        begin: 0.8,
                        end: 1.0,
                        curve: Curves.easeInOut,
                      ),
                  const SizedBox(height: 16),
                  Text(
                    'Authenticating...',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                  ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
                ],
              ),
            ),
          ),
        );
      },
      error: (error, stackTrace) {
        debugPrint("🔐 Authentication error: $error");
        return const LoginPage();
      },
    );
  }
}