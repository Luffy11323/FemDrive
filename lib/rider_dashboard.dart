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

  @override
  void initState() {
    super.initState();

    // ✅ Fetch active ride after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(riderDashboardProvider.notifier).fetchActiveRide();

      // Listen for ride state changes
      ref.listen<AsyncValue<DocumentSnapshot?>>(riderDashboardProvider, (
        previous,
        next,
      ) async {
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
            final user = FirebaseAuth.instance.currentUser;

            // --- Handle completed ride & rating dialog ---
            if (status == 'completed' && !_ratingShown && driverId != null) {
              _ratingShown = true;

              final exists = await RatingService().hasAlreadyRated(
                rideId,
                user!.uid,
              );
              if (!exists && mounted) {
                showDialog(
                  context: context,
                  builder: (_) => RatingDialog(
                    onSubmit: (stars, comment) async {
                      await RatingService().submitRating(
                        rideId: rideId,
                        fromUid: user.uid,
                        toUid: driverId,
                        rating: stars.toDouble(),
                        comment: comment,
                      );
                      if (mounted) Navigator.pop(context);
                    },
                  ),
                );
              }
            }

            // --- Handle accepted/in_progress ride & tracking ---
            if ((status == 'accepted' || status == 'in_progress') &&
                !_trackingStarted) {
              _trackingStarted = true;
              LocationService().startTracking('rider', rideId);
            }

            // Reset tracking if ride ends or is cancelled
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
                // Stop tracking on logout
                if (_trackingStarted) {
                  _trackingStarted = false;
                  LocationService().stop();
                }

                await FirebaseAuth.instance.signOut();
                if (!context.mounted) return;
                Navigator.popUntil(context, (r) => r.isFirst);

                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('You have been logged out')),
                );

                // Reset rating flag for next session
                _ratingShown = false;
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
