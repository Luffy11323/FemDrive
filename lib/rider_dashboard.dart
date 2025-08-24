import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:femdrive/location/location_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'rider/rider_dashboard_controller.dart';
import 'rider/rider_services.dart';

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

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Logged-in UID'),
              content: Text('Your UID is: $universalUid'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            ).animate().fadeIn(duration: 400.ms),
          );
        }
      });

      FirebaseFirestore.instance
          .collection('users')
          .doc(universalUid)
          .snapshots()
          .listen((snap) async {
            if (!mounted) return;
            final data = snap.data();
            if (data == null) return;
            final isVerified = data['verified'] as bool? ?? true;
            if (!isVerified) {
              if (_trackingStarted) {
                _trackingStarted = false;
                LocationService().stop();
              }
              _ratingShown = false;

              await FirebaseAuth.instance.signOut();
              if (!mounted) return;

              Navigator.popUntil(context, (route) => route.isFirst);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('You have been logged out')),
              );
            }
          });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(riderDashboardProvider.notifier).fetchActiveRide();

      ref.listen<AsyncValue<DocumentSnapshot?>>(riderDashboardProvider, (
        prev,
        next,
      ) {
        next.whenOrNull(
          data: (rideDoc) async {
            if (rideDoc == null) {
              _trackingStarted = false;
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

              final exists = await RatingService().hasAlreadyRated(
                rideId,
                uid!,
              );

              if (!exists && mounted) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  showDialog(
                    context: context,
                    builder: (_) => Animate(
                      effects: [ScaleEffect(duration: 300.ms)],
                      child: RatingDialog(
                        onSubmit: (stars, comment) async {
                          await RatingService().submitRating(
                            rideId: rideId,
                            fromUid: uid,
                            toUid: driverId,
                            rating: stars.toDouble(),
                            comment: comment,
                          );
                          if (mounted) Navigator.pop(context);
                        },
                      ),
                    ),
                  );
                });
              }
            }

            if ((status == 'accepted' || status == 'in_progress') &&
                !_trackingStarted) {
              _trackingStarted = true;
              LocationService().startTracking('rider', rideId);
            }

            if ((status == 'completed' || status == 'cancelled') &&
                _trackingStarted) {
              _trackingStarted = false;
              LocationService().stop();
            }
          },
        );
      });
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
              error: (e, _) => Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error, color: Colors.red, size: 48),
                    const SizedBox(height: 16),
                    Text('Error: $e'),
                    const SizedBox(height: 16),
                    OutlinedButton(
                      onPressed: () => ref
                          .read(riderDashboardProvider.notifier)
                          .fetchActiveRide(),
                      child: const Text('Retry'),
                    ),
                  ],
                ).animate().fadeIn(duration: 400.ms),
              ),
              data: (rideDoc) => AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: rideDoc == null
                    ? RideForm(
                        key: const ValueKey('ride_form'),
                        onSubmit: (pickup, dropoff, fare, pcLL, dcLL) {
                          ref
                              .read(riderDashboardProvider.notifier)
                              .fetchActiveRide();
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
              ),
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
            Navigator.pop(context); // Close drawer
            Navigator.pushNamed(context, '/past-rides');
          },
        ).animate().fadeIn(duration: 400.ms, delay: 100.ms),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Logout'),
          onTap: () async {
            Navigator.pop(context); // Close drawer
            if (_trackingStarted) {
              _trackingStarted = false;
              LocationService().stop();
            }
            _ratingShown = false;

            try {
              await FirebaseAuth.instance.signOut();
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Logout failed: $e')));
              }
              return;
            }

            if (!mounted) return;

            Navigator.pushNamedAndRemoveUntil(
              context,
              '/login',
              (route) => false,
            );
          },
        ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
      ],
    );
  }
}

// Placeholder for RideForm and RideStatusCard (unchanged from original)
class RideForm extends StatelessWidget {
  final Function(String, String, double, List<double>, List<double>) onSubmit;

  const RideForm({super.key, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('Ride Form Placeholder'));
  }
}

class RideStatusCard extends StatelessWidget {
  final DocumentSnapshot ride;
  final VoidCallback onCancel;

  const RideStatusCard({super.key, required this.ride, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('Ride Status Placeholder'));
  }
}

// Placeholder for RatingDialog (unchanged from original)
class RatingDialog extends StatelessWidget {
  final Function(int, String) onSubmit;

  const RatingDialog({super.key, required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rate Your Ride'),
      content: const Text('Rating Dialog Placeholder'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => onSubmit(5, 'Great ride!'),
          child: const Text('Submit'),
        ),
      ],
    );
  }
}
