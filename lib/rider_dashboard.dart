import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
// ignore: unused_import
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
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

  Future<void> _callSupport() async {
    final Uri telUri = Uri(scheme: 'tel', path: '03144179082');
    if (await canLaunchUrl(telUri)) {
      await launchUrl(telUri);
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
                target: LatLng(30.1575, 71.5249),
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
                if (!snap.hasData) {
                  return RideForm(
                    onSubmit:
                        (pickup, dropoff, rate, pickupLL, dropoffLL) async {
                          try {
                            final rideRef = await FirebaseFirestore.instance
                                .collection('rides')
                                .add({
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

                            final rideId = rideRef.id;

                            // Push to RTDB
                            await FirebaseDatabase.instance
                                .ref('rides_pending/$rideId')
                                .set({
                                  'pickup': pickup,
                                  'dropoff': dropoff,
                                  'pickupLat': pickupLL.latitude,
                                  'pickupLng': pickupLL.longitude,
                                  'dropoffLat': dropoffLL.latitude,
                                  'dropoffLng': dropoffLL.longitude,
                                  'rate': rate,
                                  'riderId': rs.userId,
                                  'createdAt': ServerValue.timestamp,
                                });

                            // Call backend API to notify drivers
                            await http.post(
                              Uri.parse(
                                'https://fem-drive.vercel.app/api/pair/ride',
                              ),
                              headers: {'Content-Type': 'application/json'},
                              body: jsonEncode({
                                'rideId': rideId,
                                'pickupLat': pickupLL.latitude,
                                'pickupLng': pickupLL.longitude,
                              }),
                            );
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
                }

                final rideDoc = snap.data;
                if (rideDoc == null) return const SizedBox.shrink();

                final data = rideDoc.data() as Map<String, dynamic>;
                final status = data['status'];
                final rideId = rideDoc.id;
                final driverId = data['driverId'];

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
                              Navigator.pop(context);
                              setState(() {});
                            }
                          },
                        ),
                      );
                    }
                  });
                }

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
                    final rdata = ride.data() as Map<String, dynamic>;

                    if (rdata['status'] == 'accepted' && !_trackingStarted) {
                      _trackingStarted = true;
                      LocationService().startTracking('rider', ride.id);
                    }

                    final dLat = rdata['driverLat'];
                    final dLng = rdata['driverLng'];
                    if (dLat != null && dLng != null) {
                      final driverPos = LatLng(dLat, dLng);
                      _mapController?.animateCamera(
                        CameraUpdate.newLatLng(driverPos),
                      );
                      _addOrUpdateMarker('driver', driverPos);
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
              },
            ),
          ),
        ],
      ),
    );
  }
}
