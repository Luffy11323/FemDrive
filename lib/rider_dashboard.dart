import 'package:femdrive/location/location_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// ignore: unused_import
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart';
// ignore: unused_import
import 'package:cloud_firestore/cloud_firestore.dart';

import 'rider/rider_dashboard_controller.dart';
import 'rider/rider_services.dart'; // Single point of access for RideForm, RideStatusCard, etc.

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
    ref.read(riderDashboardProvider.notifier).fetchActiveRide();
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
              onTap: () {
                FirebaseAuth.instance.signOut();
                Navigator.popUntil(context, (r) => r.isFirst);
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

          final data = rideDoc.data() as Map<String, dynamic>;
          final status = data['status'];
          final driverId = data['driverId'];
          final rideId = rideDoc.id;

          if (status == 'completed' && !_ratingShown && driverId != null) {
            _ratingShown = true;
            RatingService().hasAlreadyRated(rideId, user!.uid).then((exists) {
              if (!exists && mounted) {
                showDialog(
                  // ignore: use_build_context_synchronously
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
                      // ignore: use_build_context_synchronously
                      if (mounted) Navigator.pop(context);
                    },
                  ),
                );
              }
            });
          }

          if ((status == 'accepted' || status == 'in_progress') &&
              !_trackingStarted) {
            _trackingStarted = true;
            LocationService().startTracking('rider', rideId);
          }

          return RideStatusCard(
            ride: rideDoc,
            onCancel: () async {
              await ref
                  .read(riderDashboardProvider.notifier)
                  .cancelRide(rideId);
            },
          );
        },
      ),
    );
  }
}
