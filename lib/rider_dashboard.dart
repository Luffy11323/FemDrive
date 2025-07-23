import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'rider/rider_services.dart';
import 'location/location_service.dart';

class RiderDashboardPage extends StatefulWidget {
  const RiderDashboardPage({super.key});
  @override
  State<RiderDashboardPage> createState() => _RiderDashboardPageState();
}

class _RiderDashboardPageState extends State<RiderDashboardPage> {
  final rs = RideService();
  bool _ratingShown = false;
  bool _trackingStarted = false;

  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};

  Future<bool> handleLocationPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return false;
    }

    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      return false;
    }

    return true;
  }

  Future<void> _callSupport() async {
    final Uri telUri = Uri(scheme: 'tel', path: '03144179082');
    if (await canLaunchUrl(telUri)) {
      await launchUrl(telUri);
    } else {
      throw 'Could not launch dialer';
    }
  }

  void _addOrUpdateMarker(String markerId, LatLng position) {
    setState(() {
      _markers.removeWhere((m) => m.markerId.value == markerId);
      _markers.add(Marker(markerId: MarkerId(markerId), position: position));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rider Dashboard'),
        leading: Builder(
          builder: (context) {
            return IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => Scaffold.of(context).openDrawer(),
            );
          },
        ),
      ),
      drawer: Drawer(
        child: ListView(
          children: [
            UserAccountsDrawerHeader(
              accountName: Text(
                FirebaseAuth.instance.currentUser!.email!.split('@').first,
              ),
              accountEmail: Text(FirebaseAuth.instance.currentUser!.email!),
              currentAccountPicture: const CircleAvatar(
                child: Icon(Icons.person),
              ),
              decoration: BoxDecoration(color: Theme.of(context).primaryColor),
            ),
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('Profile & Settings'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/profile');
              },
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('Past Rides'),
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/past-rides');
              },
            ),
            ListTile(
              leading: const Icon(Icons.call),
              title: const Text('Call Support'),
              onTap: _callSupport,
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
      body: Column(
        children: [
          Expanded(
            flex: 2,
            child: GoogleMap(
              onMapCreated: (controller) {
                _mapController = controller;
              },
              markers: _markers,
              initialCameraPosition: const CameraPosition(
                target: LatLng(30.1575, 71.5249), // Default to Multan or adjust
                zoom: 14,
              ),
              myLocationEnabled: true,
              myLocationButtonEnabled: true,
            ),
          ),
          Expanded(
            flex: 3,
            child: StreamBuilder<DocumentSnapshot?>(
              stream: rs.listenActiveRide(),
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.active) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(
                    child: Text(
                      'Error: ${snap.error}',
                      style: const TextStyle(color: Colors.red),
                    ),
                  );
                }

                final rideDoc = snap.data;
                if (rideDoc != null) {
                  final data = rideDoc.data() as Map<String, dynamic>;
                  final status = data['status'];
                  final rideId = rideDoc.id;
                  final driverId = data['driverId'];

                  // Show rating dialog if needed
                  if (status == 'completed' &&
                      !_ratingShown &&
                      driverId != null) {
                    _ratingShown = true;

                    RatingService().hasAlreadyRated(rideId, rs.userId).then((
                      exists,
                    ) {
                      if (!exists && mounted) {
                        showDialog(
                          // ignore: use_build_context_synchronously
                          context: context,
                          builder: (_) => RatingDialog(
                            onSubmit: (stars, comment) async {
                              await RatingService().submitRating(
                                rideId: rideId,
                                fromUid: rs.userId,
                                toUid: driverId,
                                rating: stars.toDouble(),
                                comment: comment,
                              );
                              if (mounted) {
                                // ignore: use_build_context_synchronously
                                Navigator.pop(context); // Close dialog
                                setState(() {}); // Rebuild to hide rating again
                              }
                            },
                          ),
                        );
                      }
                    });
                  }

                  // Listen to real-time updates of ride
                  return StreamBuilder<DocumentSnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('rides')
                        .doc(rideId)
                        .snapshots(),
                    builder: (ctx, rideSnap) {
                      if (!rideSnap.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }

                      final ride = rideSnap.data!;
                      final data = ride.data() as Map<String, dynamic>;

                      // Start tracking once
                      if (data['status'] == 'accepted' && !_trackingStarted) {
                        _trackingStarted = true;
                        LocationService().startTracking('rider', ride.id);
                      }

                      // Update map with driver location
                      final dLat = data['driverLat'];
                      final dLng = data['driverLng'];
                      if (dLat != null && dLng != null) {
                        final driverPosition = LatLng(dLat, dLng);
                        _mapController?.animateCamera(
                          CameraUpdate.newLatLng(driverPosition),
                        );
                        _addOrUpdateMarker('driver', driverPosition);
                      }

                      return RideStatusCard(
                        ride: ride,
                        onCancel: () async {
                          try {
                            await rs.cancelRide(ride.id);
                          } catch (e) {
                            if (mounted) {
                              // ignore: use_build_context_synchronously
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Cancel failed: $e')),
                              );
                            }
                          }
                        },
                      );
                    },
                  );
                }

                return RideForm(
                  onSubmit: (pickup, dropoff, rate, pickupLL, dropoffLL) async {
                    try {
                      await rs.requestRide({
                        'riderId': rs.userId,
                        'pickup': pickup,
                        'dropoff': dropoff,
                        'pickupLat': pickupLL.latitude,
                        'pickupLng': pickupLL.longitude,
                        'dropoffLat': dropoffLL.latitude,
                        'dropoffLng': dropoffLL.longitude,
                        'carType': 'luxury',
                        'rate': rate,
                        'status': 'pending',
                        'createdAt': FieldValue.serverTimestamp(),
                        'driverId': null,
                      });
                    } catch (e) {
                      if (mounted) {
                        // ignore: use_build_context_synchronously
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Request Failed: $e')),
                        );
                      }
                    }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
