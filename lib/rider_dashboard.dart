import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:femdrive/location/location_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '/rider/rider_dashboard_controller.dart';
import '/rider/rider_services.dart';
import 'package:flutter/foundation.dart';

class RiderDashboardPage extends ConsumerStatefulWidget {
  const RiderDashboardPage({super.key});

  @override
  ConsumerState<RiderDashboardPage> createState() => _RiderDashboardPageState();
}

class _RiderDashboardPageState extends ConsumerState<RiderDashboardPage> {
  bool _trackingStarted = false;
  bool _ratingShown = false;
  String? universalUid;

  @override
  void initState() {
    super.initState();

    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      universalUid = currentUser.uid;
      if (kDebugMode) {
        print('RiderDashboard: Initialized with UID: $universalUid');
      }

      FirebaseFirestore.instance
          .collection('users')
          .doc(universalUid)
          .snapshots()
          .listen((snap) async {
            if (!mounted) return;
            final data = snap.data();
            if (data == null) {
              if (kDebugMode) {
                print(
                  'RiderDashboard: User document not found for UID: $universalUid',
                );
              }
              return;
            }
            final isVerified = data['verified'] as bool? ?? true;
            if (!isVerified) {
              if (_trackingStarted) {
                _trackingStarted = false;
                await LocationService().stop();
              }
              _ratingShown = false;

              await FirebaseAuth.instance.signOut();
              ref.read(riderDashboardProvider.notifier).clearCachedUid();
              if (!mounted) return;

              Navigator.pushNamedAndRemoveUntil(
                context,
                '/login',
                (route) => false,
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Logged out due to unverified status'),
                ),
              );
            }
          });
    } else {
      if (kDebugMode) {
        print('RiderDashboard: No authenticated user found');
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (kDebugMode) {
        print('RiderDashboard: Fetching active ride');
      }
      ref.read(riderDashboardProvider.notifier).fetchActiveRide();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Theme.of(context).brightness,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ),
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Rider Dashboard',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.person),
              tooltip: 'Profile',
              onPressed: () => Navigator.pushNamed(context, '/profile'),
            ),
          ],
        ),
        drawer: Drawer(child: _buildDrawer()),
        body: ref
            .watch(riderDashboardProvider)
            .when(
              loading: () => const Center(
                child: CircularProgressIndicator(),
              ).animate().fadeIn(duration: 400.ms),
              error: (e, _) {
                if (kDebugMode) {
                  print('RiderDashboard: Error loading ride: $e');
                }
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error, color: Colors.red, size: 48),
                      const SizedBox(height: 16),
                      Text(
                        'Failed to load ride: $e',
                        style: const TextStyle(fontSize: 16),
                      ),
                      const SizedBox(height: 16),
                      OutlinedButton(
                        onPressed: () {
                          if (kDebugMode) {
                            print('RiderDashboard: Retrying fetchActiveRide');
                          }
                          ref
                              .read(riderDashboardProvider.notifier)
                              .fetchActiveRide();
                        },
                        child: const Text('Retry'),
                      ),
                    ],
                  ).animate().fadeIn(duration: 400.ms),
                );
              },
              data: (rideDoc) {
                if (kDebugMode) {
                  print('RiderDashboard: Ride data: ${rideDoc?.data()}');
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _handleRideStatus(rideDoc);
                });
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: rideDoc == null
                      ? RideForm(
                          key: const ValueKey('ride_form'),
                          onSubmit:
                              (
                                pickup,
                                dropoff,
                                fare,
                                pickupLL,
                                dropoffLL,
                                rideType,
                                note,
                              ) {
                                ref
                                    .read(riderDashboardProvider.notifier)
                                    .createRide(
                                      pickup,
                                      dropoff,
                                      fare,
                                      GeoPoint(
                                        pickupLL.latitude,
                                        pickupLL.longitude,
                                      ),
                                      GeoPoint(
                                        dropoffLL.latitude,
                                        dropoffLL.longitude,
                                      ),
                                      rideType: rideType,
                                      note: note,
                                    );
                              },
                        )
                      : RideStatusCard(
                          key: const ValueKey('ride_status'),
                          ride: rideDoc,
                          onCancel: () async {
                            await ref
                                .read(riderDashboardProvider.notifier)
                                .cancelRide(rideDoc.id);
                          },
                        ),
                );
              },
            ),
        floatingActionButton: ref
            .watch(riderDashboardProvider)
            .when(
              data: (rideDoc) => rideDoc == null
                  ? FloatingActionButton(
                      onPressed: () => Scaffold.of(context).openDrawer(),
                      tooltip: 'Menu',
                      child: const Icon(Icons.menu),
                    )
                  : null,
              loading: () => null,
              error: (_, _) => null,
            ),
      ),
    );
  }

  void _handleRideStatus(DocumentSnapshot? rideDoc) async {
    if (rideDoc == null) {
      if (_trackingStarted) {
        _trackingStarted = false;
        await LocationService().stop();
      }
      _ratingShown = false;
      return;
    }

    final data = rideDoc.data() as Map<String, dynamic>;
    final status = data['status'];
    final driverId = data['driverId'];
    final rideId = rideDoc.id;
    final uid = universalUid ?? FirebaseAuth.instance.currentUser?.uid;

    if (status == 'completed' && !_ratingShown && driverId != null) {
      _ratingShown = true;
      final exists = await RatingService().hasAlreadyRated(rideId, uid!);
      if (!exists && mounted) {
        showDialog(
          context: context,
          builder: (_) => Animate(
            effects: [ScaleEffect(duration: 300.ms)],
            child: RatingDialog(
              onSubmit: (stars, comment) async {
                try {
                  await RatingService().submitRating(
                    rideId: rideId,
                    fromUid: uid,
                    toUid: driverId,
                    rating: stars.toDouble(),
                    comment: comment,
                  );
                  if (mounted) Navigator.pop(context);
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to submit rating: $e')),
                    );
                  }
                }
              },
            ),
          ),
        );
      }
    }

    if ((status == 'accepted' || status == 'in_progress') &&
        !_trackingStarted) {
      _trackingStarted = true;
      try {
        await LocationService().startTracking('rider', rideId);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to start tracking: $e')),
          );
        }
      }
    }

    if ((status == 'completed' || status == 'cancelled') && _trackingStarted) {
      _trackingStarted = false;
      try {
        await LocationService().stop();
      } catch (e) {
        if (kDebugMode) {
          print('RiderDashboard: Failed to stop tracking: $e');
        }
      }
    }
  }

  Widget _buildDrawer() {
    final user = FirebaseAuth.instance.currentUser;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        UserAccountsDrawerHeader(
          accountName: Text(user?.email?.split('@').first ?? 'Rider'),
          accountEmail: Text(user?.email ?? 'No email'),
          currentAccountPicture: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primary,
            child: const Icon(Icons.person, color: Colors.white),
          ),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primaryContainer,
          ),
        ).animate().slideY(begin: -0.2, end: 0, duration: 400.ms),
        ListTile(
          leading: const Icon(Icons.history),
          title: const Text('Past Rides'),
          onTap: () {
            Navigator.pop(context);
            Navigator.pushNamed(context, '/past-rides');
          },
        ).animate().fadeIn(duration: 400.ms, delay: 100.ms),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Logout'),
          onTap: () async {
            Navigator.pop(context);
            if (_trackingStarted) {
              _trackingStarted = false;
              await LocationService().stop();
            }
            _ratingShown = false;

            try {
              await FirebaseAuth.instance.signOut();
              ref.read(riderDashboardProvider.notifier).clearCachedUid();
              if (mounted) {
                Navigator.pushNamedAndRemoveUntil(
                  context,
                  '/login',
                  (route) => false,
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Logout failed: $e')));
              }
            }
          },
        ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
      ],
    );
  }
}
