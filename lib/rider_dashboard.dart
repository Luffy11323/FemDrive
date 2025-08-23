import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:femdrive/location/location_service.dart';
import 'package:flutter/material.dart';
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

  /// Universal UID to be used anywhere in the dashboard
  String? universalUid;

  @override
  void initState() {
    super.initState();

    // Existing universal UID logic
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser != null) {
      universalUid = currentUser.uid;

      // Optional: test popup
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
            ),
          );
        }
      });

      // ---------- VERIFIED AUTO-LOGOUT LISTENER ----------
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
              // Stop tracking and reset rating
              if (_trackingStarted) {
                _trackingStarted = false;
                LocationService().stop();
              }
              _ratingShown = false;

              // Sign out Firebase
              await FirebaseAuth.instance.signOut();
              if (!mounted) return;

              // Navigate to root safely
              Navigator.popUntil(context, (route) => route.isFirst);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('You have been logged out')),
              );
            }
          });
    }

    // Existing ride fetching and listener logic
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
                    builder: (_) => RatingDialog(
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
    final state = ref.watch(riderDashboardProvider);
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(title: const Text('Rider Dashboard')),
      drawer: Drawer(
        child: ListView(
          children: [
            UserAccountsDrawerHeader(
              accountName: Text(user?.email?.split('@').first ?? ''),
              accountEmail: Text(user?.email ?? ''),
              currentAccountPicture: const CircleAvatar(
                child: Icon(Icons.person),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('Profile'),
              onTap: () => Navigator.pushNamed(context, '/profile'),
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Past Rides'),
              onTap: () => Navigator.pushNamed(context, '/past-rides'),
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Logout'),
              onTap: () async {
                // Stop tracking safely
                if (_trackingStarted) {
                  _trackingStarted = false;
                  LocationService().stop();
                }

                // Reset rating flag for next session
                _ratingShown = false;

                try {
                  await FirebaseAuth.instance.signOut();
                } catch (e) {
                  if (mounted) {
                    // ignore: use_build_context_synchronously
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Logout failed: $e')),
                    );
                  }
                  return;
                }

                if (!mounted) return;

                // ✅ FIX: Navigate to login route and let main.dart handle the reset
                Navigator.pushNamedAndRemoveUntil(
                  // ignore: use_build_context_synchronously
                  context,
                  '/login',
                  (route) => false,
                );
              },
            ),
          ],
        ),
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (rideDoc) {
          if (rideDoc == null) {
            return RideForm(
              onSubmit: (pickup, dropoff, fare, pcLL, dcLL) {
                ref.read(riderDashboardProvider.notifier).fetchActiveRide();
              },
            );
          }

          return RideStatusCard(
            ride: rideDoc,
            onCancel: () async {
              await ref
                  .read(riderDashboardProvider.notifier)
                  .cancelRide(rideDoc.id);
            },
          );
        },
      ),
    );
  }
}
