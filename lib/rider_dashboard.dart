import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:femdrive/rider/rider_dashboard_controller.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'rider/rider_services.dart';
import 'location/location_service.dart';

class RiderDashboardPage extends ConsumerStatefulWidget {
  const RiderDashboardPage({super.key});
  @override
  ConsumerState<RiderDashboardPage> createState() => _RiderDashboardPageState();
}

class _RiderDashboardPageState extends ConsumerState<RiderDashboardPage> {
  bool _trackingStarted = false;
  bool _ratingShown = false;
  String? universalUid;
  final _logger = Logger();

  @override
  void initState() {
    super.initState();
    universalUid = FirebaseAuth.instance.currentUser?.uid;
    if (universalUid == null) {
      _logger.e('No user logged in');
      WidgetsBinding.instance.addPostFrameCallback((_) => _signOut(context));
      return;
    }
    _listenToUserVerification();
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleRideStatus());
  }

  void _listenToUserVerification() {
    FirebaseFirestore.instance
        .collection('users')
        .doc(universalUid)
        .snapshots()
        .listen(
          (doc) {
            final verified = doc.data()?['verified'] ?? false;
            if (!verified && mounted) {
              // ignore: use_build_context_synchronously
              LocationService().stop().then((_) => _signOut(context));
            }
          },
          onError: (e) {
            _logger.e('Error listening to user verification: $e');
            // ignore: use_build_context_synchronously
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error checking verification: $e')),
            );
          },
        );
  }

  void _signOut(BuildContext context) async {
    try {
      await FirebaseAuth.instance.signOut();
      ref.read(riderDashboardProvider.notifier).clearCachedUid();
      if (mounted) {
        // ignore: use_build_context_synchronously
        Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Signed out: Account not verified')),
        );
      }
    } catch (e) {
      _logger.e('Sign out failed: $e');
      ScaffoldMessenger.of(
        // ignore: use_build_context_synchronously
        context,
      ).showSnackBar(SnackBar(content: Text('Sign out failed: $e')));
    }
  }

  void _handleRideStatus() {
    final state = ref.watch(riderDashboardProvider);
    state.when(
      data: (rideDoc) async {
        if (rideDoc == null) {
          if (_trackingStarted) {
            await LocationService().stop();
            setState(() {
              _trackingStarted = false;
              _ratingShown = false;
            });
          }
          return;
        }
        final data = rideDoc; // Already a Map<String, dynamic>
        final status = data['status'] as String? ?? 'unknown';
        final driverId = data['driverId'] as String?;
        final rideId = data['id'] as String? ?? 'unknown';

        if (status == 'completed' && !_ratingShown) {
          try {
            final hasRated = await RatingService().hasAlreadyRated(
              rideId,
              universalUid!,
            );
            if (!hasRated && mounted) {
              showDialog(
                context: context,
                builder: (ctx) => RatingDialog(
                  onSubmit: (rating, comment) async {
                    try {
                      await RatingService().submitRating(
                        rideId: rideId,
                        fromUid: universalUid!,
                        toUid: driverId!,
                        rating: rating.toDouble(),
                        comment: comment,
                      );
                      setState(() => _ratingShown = true);
                    } catch (e) {
                      _logger.e('Failed to submit rating: $e');
                      // ignore: use_build_context_synchronously
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to submit rating: $e')),
                      );
                    }
                  },
                ),
              );
            }
          } catch (e) {
            _logger.e('Error checking rating status: $e');
            // ignore: use_build_context_synchronously
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error checking rating: $e')),
            );
          }
        }

        if ((status == 'accepted' || status == 'in_progress') &&
            !_trackingStarted) {
          try {
            await LocationService().startTracking('rider', rideId);
            setState(() => _trackingStarted = true);
          } catch (e) {
            _logger.e('Failed to start tracking: $e');
            // ignore: use_build_context_synchronously
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to start location tracking: $e')),
            );
          }
        } else if ((status == 'completed' || status == 'cancelled') &&
            _trackingStarted) {
          try {
            await LocationService().stop();
            setState(() => _trackingStarted = false);
          } catch (e) {
            _logger.e('Failed to stop tracking: $e');
            // ignore: use_build_context_synchronously
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to stop location tracking: $e')),
            );
          }
        }
      },
      error: (e, st) {
        _logger.e('Ride state error: $e', stackTrace: st);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading ride status: $e')),
        );
      },
      loading: () {},
    );
  }

  Widget _buildDrawer() {
    final user = FirebaseAuth.instance.currentUser;
    final name = user?.email?.split('@')[0] ?? 'Rider';
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          UserAccountsDrawerHeader(
            accountName: Text(name),
            accountEmail: Text(user?.email ?? ''),
            currentAccountPicture: CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.secondary,
              child: Text(name[0].toUpperCase()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Past Rides'),
            onTap: () => Navigator.pushNamed(context, '/past-rides'),
          ).animate().fadeIn().slideX(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Logout'),
            onTap: () => _signOut(context),
          ).animate().fadeIn().slideX(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rideState = ref.watch(riderDashboardProvider);
    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFF28AB2),
        ), // Updated to match theme.dart's Soft Rose palette
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: const Color(0xFFF28AB2),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Rider Dashboard'),
          actions: [
            IconButton(
              icon: const Icon(Icons.person),
              onPressed: () => Navigator.pushNamed(
                context,
                '/profile',
              ), // Updated to navigate to RiderProfilePage
            ),
          ],
        ),
        drawer: _buildDrawer(),
        body: rideState.when(
          data: (rideDoc) => AnimatedSwitcher(
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
                                GeoPoint(pickupLL.latitude, pickupLL.longitude),
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
                    key: ValueKey(rideDoc['id']),
                    ride: rideDoc,
                    onCancel: () => ref
                        .read(riderDashboardProvider.notifier)
                        .cancelRide(rideDoc['id']),
                  ),
          ),
          loading: () => const Center(
            child: CircularProgressIndicator(),
          ).animate().fadeIn(),
          error: (err, stack) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Error: $err', style: const TextStyle(color: Colors.red)),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref
                      .read(riderDashboardProvider.notifier)
                      .fetchActiveRide(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
        floatingActionButton: rideState.asData?.value == null
            ? FloatingActionButton(
                onPressed: () => Scaffold.of(context).openDrawer(),
                backgroundColor: const Color(0xFFF28AB2),
                child: const Icon(Icons.menu),
              )
            : null,
      ),
    );
  }
}
