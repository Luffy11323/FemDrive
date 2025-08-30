// rider_dashboard.dart

import 'package:femdrive/emergency_service.dart';
import 'package:femdrive/rider/nearby_drivers_service.dart';
import 'package:femdrive/rider/rider_dashboard_controller.dart';
import 'package:femdrive/rider/rider_services.dart'; // MapService, GeocodingService
import 'package:femdrive/widgets/payment_services.dart';
import 'package:femdrive/widgets/share_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:logger/logger.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';

/// Provides nearby online drivers (live updates) for the map overlay
final nearbyDriversProvider =
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) async* {
      final loc = await MapService().currentLocation();
      yield* NearbyDriversService().streamNearbyDrivers(loc);
    });

/// Rider Dashboard Main Page
class RiderDashboard extends ConsumerStatefulWidget {
  const RiderDashboard({super.key});

  @override
  ConsumerState<RiderDashboard> createState() => _RiderDashboardState();
}

class _RiderDashboardState extends ConsumerState<RiderDashboard> {
  final _logger = Logger();
  GoogleMapController? _mapController;
  LatLng? _currentLocation;

  @override
  void initState() {
    super.initState();
    _loadCurrentLocation();
  }

  Future<void> _loadCurrentLocation() async {
    try {
      final loc = await MapService().currentLocation();
      setState(() => _currentLocation = loc);
    } catch (e) {
      _logger.e("Failed to fetch current location: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final ridesAsync = ref.watch(riderDashboardProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Rider Dashboard')),
      drawer: _buildDrawer(context),
      body: Stack(
        children: [
          /// Map with my location + nearby drivers
          Consumer(
            builder: (context, ref, _) {
              final nearbyAsync = ref.watch(nearbyDriversProvider);
              return nearbyAsync.when(
                data: (drivers) => GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target:
                        _currentLocation ?? const LatLng(37.7749, -122.4194),
                    zoom: 14,
                  ),
                  onMapCreated: (controller) => _mapController = controller,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: true,
                  markers: {
                    if (_currentLocation != null)
                      Marker(
                        markerId: const MarkerId("me"),
                        position: _currentLocation!,
                        icon: BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueAzure,
                        ),
                      ),
                    ...drivers.map((d) {
                      final gp = d['location']; // GeoPoint
                      return Marker(
                        markerId: MarkerId(
                          d['uid'] ?? d['id'] ?? UniqueKey().toString(),
                        ),
                        position: LatLng(gp.latitude, gp.longitude),
                        icon: BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueOrange,
                        ),
                      );
                    }),
                  },
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, st) => Center(child: Text("Map error: $e")),
              );
            },
          ),

          /// Active Ride Overlays (Status / Driver / Counter Fare / SOS / Share / Receipt)
          ridesAsync.when(
            data: (rideData) {
              if (rideData == null || rideData.isEmpty) {
                return const SizedBox.shrink();
              }

              // The provider currently returns Map<String,dynamic>?,
              // but in your old UI you showed multiple rides. We’ll pick "the" active ride.
              final ride = rideData; // single active ride map
              final status = (ride['status'] ?? '').toString();

              return Stack(
                children: [
                  Align(
                    alignment: Alignment.topCenter,
                    child: RideStatusWidget(ride: ride),
                  ),

                  if (ride['driverId'] != null)
                    Align(
                      alignment: Alignment.topRight,
                      child: DriverDetailsWidget(driverId: ride['driverId']),
                    ),

                  if (ride['counterFare'] != null &&
                      status != 'completed' &&
                      status != 'cancelled')
                    Align(
                      alignment: Alignment.center,
                      child: CounterFareWidget(rideId: ride['id']),
                    ),

                  if (status == 'accepted' ||
                      status == 'in_progress' ||
                      status == 'onTrip')
                    Positioned(
                      bottom: 160,
                      right: 16,
                      child: ShareTripButton(rideId: ride['id']),
                    ),

                  if (status != 'completed' && status != 'cancelled')
                    Positioned(
                      bottom: 100,
                      right: 16,
                      child: SOSButton(ride: ride),
                    ),

                  if (status == 'completed')
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: ReceiptWidget(ride: ride),
                    ),
                ],
              );
            },
            loading: () => const Align(
              alignment: Alignment.topCenter,
              child: LinearProgressIndicator(),
            ),
            error: (e, st) => Align(
              alignment: Alignment.topCenter,
              child: Text("Ride error: $e"),
            ),
          ),

          /// The request panel (draggable)
          Align(
            alignment: Alignment.bottomCenter,
            child: DraggableScrollableSheet(
              initialChildSize: 0.35,
              minChildSize: 0.2,
              maxChildSize: 0.88,
              builder: (_, controller) => RideForm(
                mapController: _mapController,
                scrollController: controller,
                currentLocation: _currentLocation,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Drawer _buildDrawer(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Colors.deepPurple),
            child: Text(
              'FemDrive Menu',
              style: TextStyle(color: Colors.white, fontSize: 20),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('Profile'),
            onTap: () {}, // keep placeholder to preserve route structure
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Past Rides'),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PastRidesListWidget()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.payment),
            title: const Text('Payment Methods'),
            onTap: () {},
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Settings'),
            onTap: () {},
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Logout'),
            onTap: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                Navigator.of(context).pushReplacementNamed('/');
              }
            },
          ),
        ],
      ),
    );
  }
}

/// ---------------- Ride Form (restored here) ----------------
class RideForm extends ConsumerStatefulWidget {
  final GoogleMapController? mapController;
  final ScrollController scrollController;
  final LatLng? currentLocation;

  const RideForm({
    super.key,
    required this.mapController,
    required this.scrollController,
    required this.currentLocation,
  });

  @override
  ConsumerState<RideForm> createState() => _RideFormState();
}

class _RideFormState extends ConsumerState<RideForm> {
  final _logger = Logger();
  final _pickupController = TextEditingController();
  final _dropoffController = TextEditingController();
  final _noteController = TextEditingController();

  LatLng? _pickupLatLng;
  LatLng? _dropoffLatLng;
  String? _selectedRideType = 'Economy';
  String? _selectedPaymentMethod = 'Cash';
  double? _fare;
  String? _errorMessage;

  @override
  void dispose() {
    _pickupController.dispose();
    _dropoffController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<List<String>> _fetchSuggestions(String query) async {
    if (query.trim().length < 3) return [];
    try {
      final origin =
          widget.currentLocation ?? await MapService().currentLocation();
      return MapService().getPlaceSuggestions(
        query,
        origin.latitude,
        origin.longitude,
      );
    } catch (e) {
      _logger.e('Failed suggestions: $e');
      return [];
    }
  }

  Future<void> _panTo(LatLng? pos) async {
    if (pos == null || widget.mapController == null) return;
    await widget.mapController!.animateCamera(
      CameraUpdate.newLatLngZoom(pos, 15),
    );
  }

  Future<void> _calculateFareAndRoute() async {
    if (_pickupLatLng == null ||
        _dropoffLatLng == null ||
        _selectedRideType == null) {
      setState(
        () => _errorMessage = 'Please select pickup, dropoff and ride type.',
      );
      return;
    }
    try {
      final rateAndEta = await MapService().getRateAndEta(
        _pickupController.text.trim(),
        _dropoffController.text.trim(),
        _selectedRideType!,
      );
      setState(() {
        _fare = (rateAndEta['total'] as num).toDouble();
        _errorMessage = null;
      });
    } catch (e) {
      setState(() => _errorMessage = 'Unable to calculate fare: $e');
      _logger.e('Rate & ETA error: $e');
    }
  }

  Future<void> _requestRide() async {
    if (_fare == null ||
        _pickupLatLng == null ||
        _dropoffLatLng == null ||
        _selectedPaymentMethod == null) {
      setState(() => _errorMessage = 'Incomplete details to request a ride.');
      return;
    }
    try {
      final controller = ref.read(riderDashboardProvider.notifier);
      await controller.createRide(
        _pickupController.text.trim(),
        _dropoffController.text.trim(),
        _fare!,
        GeoPoint(_pickupLatLng!.latitude, _pickupLatLng!.longitude),
        GeoPoint(_dropoffLatLng!.latitude, _dropoffLatLng!.longitude),
        ref, // 👈 Add this here
        rideType: _selectedRideType!,
        note: _noteController.text.trim(),
      );

      final ride = ref.read(riderDashboardProvider).value;
      if (ride != null) {
        await PaymentService().processPayment(
          rideId: ride['id'] ?? '',
          amount: _fare!,
          paymentMethod: _selectedPaymentMethod!,
          userId: FirebaseAuth.instance.currentUser!.uid,
        );
      }

      if (context.mounted) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Ride requested')));
      }
    } catch (e) {
      setState(() => _errorMessage = 'Ride request failed: $e');
      _logger.e('Ride request error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: SingleChildScrollView(
        controller: widget.scrollController,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Grip
            Container(
              width: 44,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            /// Pickup
            TypeAheadField<String>(
              suggestionsCallback: _fetchSuggestions,
              builder: (context, controller, focusNode) {
                controller.text = _pickupController.text;
                return TextField(
                  controller: _pickupController,
                  focusNode: focusNode,
                  decoration: const InputDecoration(
                    labelText: 'Pickup Location',
                    border: OutlineInputBorder(),
                  ),
                );
              },
              itemBuilder: (context, suggestion) =>
                  ListTile(title: Text(suggestion)),
              onSelected: (suggestion) async {
                _pickupController.text = suggestion;
                _pickupLatLng = await GeocodingService.getLatLngFromAddress(
                  suggestion,
                );
                await _panTo(_pickupLatLng);
                setState(() {});
              },
            ),
            const SizedBox(height: 12),

            /// Dropoff
            TypeAheadField<String>(
              suggestionsCallback: _fetchSuggestions,
              builder: (context, controller, focusNode) {
                controller.text = _dropoffController.text;
                return TextField(
                  controller: _dropoffController,
                  focusNode: focusNode,
                  decoration: const InputDecoration(
                    labelText: 'Dropoff Location',
                    border: OutlineInputBorder(),
                  ),
                );
              },
              itemBuilder: (context, suggestion) =>
                  ListTile(title: Text(suggestion)),
              onSelected: (suggestion) async {
                _dropoffController.text = suggestion;
                _dropoffLatLng = await GeocodingService.getLatLngFromAddress(
                  suggestion,
                );
                await _panTo(_dropoffLatLng);
                setState(() {});
              },
            ),
            const SizedBox(height: 12),

            /// Ride Type
            DropdownButtonFormField<String>(
              initialValue: _selectedRideType,
              decoration: const InputDecoration(
                labelText: 'Ride Type',
                border: OutlineInputBorder(),
              ),
              items: const [
                'Economy',
                'Premium',
                'XL',
                'Electric',
              ].map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (v) => setState(() => _selectedRideType = v),
            ),
            const SizedBox(height: 12),

            /// Payment
            DropdownButtonFormField<String>(
              initialValue: _selectedPaymentMethod,
              decoration: const InputDecoration(
                labelText: 'Payment Method',
                border: OutlineInputBorder(),
              ),
              items: const [
                'Cash',
                'Credit Card',
                'Wallet',
              ].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
              onChanged: (v) => setState(() => _selectedPaymentMethod = v),
            ),
            const SizedBox(height: 12),

            /// Notes
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            /// Action Buttons
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed:
                        (_pickupLatLng != null &&
                            _dropoffLatLng != null &&
                            _selectedRideType != null)
                        ? _calculateFareAndRoute
                        : null,
                    child: const Text('Calculate Fare & Route'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Consumer(
                    builder: (context, ref, _) {
                      final asyncDrivers = ref.watch(nearbyDriversProvider);

                      return asyncDrivers.when(
                        data: (drivers) {
                          if (drivers.isEmpty) {
                            return const Center(
                              child: Text(
                                '🚗 No drivers currently nearby',
                                style: TextStyle(color: Colors.grey),
                              ),
                            );
                          }

                          if (_selectedRideType == null) {
                            final rt = drivers.first['rideType'] as String?;
                            if (rt != null && rt.isNotEmpty) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                setState(() => _selectedRideType = rt);
                              });
                            }
                          }

                          return Center(
                            child: Text(
                              '🚗 ${drivers.length} drivers nearby',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          );
                        },
                        loading: () => const Center(
                          child: Text(
                            '🔍 Searching for drivers…',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ),
                        error: (e, _) => Center(
                          child: Text(
                            '⚠️ Error loading drivers',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            ElevatedButton(
              onPressed:
                  (_fare != null &&
                      _pickupLatLng != null &&
                      _dropoffLatLng != null &&
                      _selectedPaymentMethod != null)
                  ? _requestRide
                  : null,
              child: Text(
                _fare == null
                    ? 'Request Ride'
                    : 'Request Ride (\$${_fare!.toStringAsFixed(2)})',
              ),
            ),

            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 300.ms);
  }
}

/// ---------------- Ride Status Widget ----------------
class RideStatusWidget extends ConsumerStatefulWidget {
  final Map<String, dynamic> ride;
  const RideStatusWidget({super.key, required this.ride});

  @override
  ConsumerState<RideStatusWidget> createState() => _RideStatusWidgetState();
}

class _RideStatusWidgetState extends ConsumerState<RideStatusWidget> {
  double _rating = 0;

  @override
  Widget build(BuildContext context) {
    final ride = widget.ride;

    return Card(
      margin: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Ride: ${ride['pickup']} → ${ride['dropoff']}",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            Text("Status: ${ride['status']}"),
            if (ride['fare'] != null)
              Text(
                "Fare: \$${(ride['fare'] as num).toStringAsFixed(2)}",
                style: const TextStyle(color: Colors.green),
              ),
            const SizedBox(height: 12),

            if (ride['status'] == 'completed')
              ElevatedButton.icon(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (_) =>
                        _buildRatingDialog(context, ride['driverId']),
                  );
                },
                icon: const Icon(Icons.star_rate),
                label: const Text("Rate Driver"),
              ),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 300.ms).scale(delay: 80.ms);
  }

  Widget _buildRatingDialog(BuildContext context, String driverId) {
    return AlertDialog(
      title: const Text("Rate Driver"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Slider(
            value: _rating,
            min: 0,
            max: 5,
            divisions: 5,
            label: _rating.toStringAsFixed(1),
            onChanged: (value) => setState(() => _rating = value),
          ),
          Text("Rating: ${_rating.toStringAsFixed(1)} / 5"),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel"),
        ),
        ElevatedButton(
          onPressed: () async {
            await _submitRating(driverId, _rating);
            if (context.mounted) {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Thanks for your feedback!")),
              );
            }
          },
          child: const Text("Submit"),
        ),
      ],
    );
  }

  Future<void> _submitRating(String driverId, double rating) async {
    if ((driverId).isEmpty || rating <= 0) return;

    final driverRef = FirebaseFirestore.instance
        .collection('drivers')
        .doc(driverId);

    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(driverRef);
      if (!snapshot.exists) {
        throw Exception("Driver not found");
      }
      final data = snapshot.data()!;
      final int ratingCount = (data['ratingCount'] ?? 0) as int;
      final double avgRating = (data['avgRating'] ?? 0.0).toDouble();

      final newCount = ratingCount + 1;
      final newAvg = ((avgRating * ratingCount) + rating) / newCount;

      transaction.update(driverRef, {
        'ratingCount': newCount,
        'avgRating': newAvg,
      });
    });
  }
}

/// ---------------- SOS Button (active rides only) ----------------
class SOSButton extends StatelessWidget {
  final Map<String, dynamic> ride;
  const SOSButton({super.key, required this.ride});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      icon: const Icon(Icons.sos),
      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
      onPressed: () async {
        try {
          await EmergencyService.sendEmergency(
            rideId: ride['id'],
            currentUid: FirebaseAuth.instance.currentUser!.uid,
            otherUid: ride['driverId'] ?? '',
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Emergency reported successfully")),
            );
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text("Error: $e")));
          }
        }
      },
      label: const Text("SOS"),
    );
  }
}

/// ---------------- Driver Details (live) ----------------
class DriverDetailsWidget extends StatelessWidget {
  final String driverId;
  const DriverDetailsWidget({super.key, required this.driverId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(driverId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }
        final d = snapshot.data!.data()! as Map<String, dynamic>;
        final veh = (d['vehicle'] ?? {}) as Map<String, dynamic>;
        return Card(
          margin: const EdgeInsets.all(12),
          child: ListTile(
            leading: CircleAvatar(
              backgroundImage:
                  (d['photoUrl'] != null &&
                      (d['photoUrl'] as String).isNotEmpty)
                  ? NetworkImage(d['photoUrl'])
                  : null,
              radius: 24,
              child:
                  (d['photoUrl'] == null || (d['photoUrl'] as String).isEmpty)
                  ? const Icon(Icons.person)
                  : null,
            ),
            title: Text(d['username'] ?? 'Driver'),
            subtitle: Text("⭐ ${(d['averageRating'] ?? 'N/A').toString()}"),
            trailing: Text(
              '${veh['make'] ?? '—'} ${veh['model'] ?? ''}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ).animate().slideX(begin: 1, duration: 250.ms);
      },
    );
  }
}

/// ---------------- Counter Fare (accept / reject) ----------------
class CounterFareWidget extends ConsumerWidget {
  final String rideId;
  const CounterFareWidget({super.key, required this.rideId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('rides')
          .doc(rideId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data?.data() == null) {
          return const SizedBox.shrink();
        }
        final ride = snapshot.data!.data()! as Map<String, dynamic>;
        final cf = (ride['counterFare'] as num?)?.toDouble();
        if (cf == null) return const SizedBox.shrink();

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Driver Counter-Offer',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text('Proposed Fare: \$${cf.toStringAsFixed(2)}'),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          try {
                            await ref
                                .read(riderDashboardProvider.notifier)
                                .handleCounterFare(rideId, cf, true);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Counter-offer accepted'),
                                ),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Error: $e')),
                              );
                            }
                          }
                        },
                        child: const Text('Accept'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          try {
                            await ref
                                .read(riderDashboardProvider.notifier)
                                .handleCounterFare(rideId, cf, false);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Counter-offer rejected'),
                                ),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Error: $e')),
                              );
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                        child: const Text('Reject'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ).animate().fadeIn(duration: 250.ms);
      },
    );
  }
}

/// ---------------- Share Trip ----------------
class ShareTripButton extends StatelessWidget {
  final String rideId;
  const ShareTripButton({super.key, required this.rideId});

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      onPressed: () async {
        try {
          await ShareService().shareTripStatus(
            rideId: rideId,
            userId: FirebaseAuth.instance.currentUser!.uid,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Trip status shared')));
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Error sharing trip: $e')));
          }
        }
      },
      icon: const Icon(Icons.share),
      label: const Text('Share Trip Status'),
    );
  }
}

/// ---------------- Receipt (shows when completed) ----------------
class ReceiptWidget extends StatelessWidget {
  final Map<String, dynamic> ride;
  const ReceiptWidget({super.key, required this.ride});

  @override
  Widget build(BuildContext context) {
    if (ride['status'] != 'completed') return const SizedBox.shrink();

    final fare = (ride['fare'] as num?)?.toDouble() ?? 0;
    final ts = (ride['createdAt'] as Timestamp?)?.toDate();

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Receipt', style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            Text('Pickup: ${ride['pickup']}'),
            Text('Dropoff: ${ride['dropoff']}'),
            Text('Fare: \$${fare.toStringAsFixed(2)}'),
            Text('Payment: ${ride['paymentMethod'] ?? '—'}'),
            if (ts != null) Text('Date: $ts'),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 250.ms);
  }
}

/// ---------------- Past Rides Page ----------------
class PastRidesListWidget extends StatelessWidget {
  const PastRidesListWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(title: const Text("Past Rides")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('rides')
            .where('riderId', isEqualTo: uid)
            .where('status', isEqualTo: 'completed')
            .orderBy('completedAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.data!.docs.isEmpty) {
            return const Center(child: Text("No past rides found"));
          }
          return ListView(
            children: snapshot.data!.docs.map((doc) {
              final ride = doc.data() as Map<String, dynamic>;
              final fare = (ride['fare'] as num?)?.toDouble() ?? 0;
              final completedAt = (ride['completedAt'] as Timestamp?)?.toDate();
              return ListTile(
                leading: const Icon(Icons.receipt_long),
                title: Text("${ride['pickup']} → ${ride['dropoff']}"),
                subtitle: Text(
                  "Fare: \$${fare.toStringAsFixed(2)} • ${ride['rideType'] ?? '—'}"
                  "${completedAt != null ? " • ${completedAt.toLocal()}" : ""}",
                ),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Ride Receipt'),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('From: ${ride['pickup']}'),
                          Text('To: ${ride['dropoff']}'),
                          Text('Fare: \$${fare.toStringAsFixed(2)}'),
                          Text('Ride Type: ${ride['rideType'] ?? '—'}'),
                          Text('Payment: ${ride['paymentMethod'] ?? '—'}'),
                          if (completedAt != null)
                            Text('Completed: $completedAt'),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  );
                },
              );
            }).toList(),
          );
        },
      ),
    );
  }
}
