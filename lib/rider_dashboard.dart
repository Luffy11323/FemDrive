import 'package:femdrive/emergency_service.dart';
import 'package:femdrive/rider/nearby_drivers_service.dart';
import 'package:femdrive/rider/rider_dashboard_controller.dart';
import 'package:femdrive/rider/rider_services.dart';
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

/// Rider Dashboard Main Page
class RiderDashboard extends ConsumerWidget {
  const RiderDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ridesAsync = ref.watch(riderDashboardProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Rider Dashboard')),
      body: ridesAsync.when(
        data: (rides) {
          if (rides!.isEmpty) {
            return const Center(child: Text('No rides yet'));
          }
          return ListView.builder(
            itemCount: rides.length,
            itemBuilder: (context, index) {
              final ride = rides.values.toList()[index];
              return RideStatusWidget(ride: ride);
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Error: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            builder: (_) => const RideForm(),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// ---------------- Ride Form ----------------
class RideForm extends ConsumerStatefulWidget {
  const RideForm({super.key});

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
  bool _searchingDrivers = false;
  List<String> _suggestions = [];

  @override
  void dispose() {
    _pickupController.dispose();
    _dropoffController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<List<String>> fetchSuggestions(String query, bool isPickup) async {
    if (query.length < 3) {
      setState(() => _suggestions.clear());
      return [];
    }
    try {
      final latLng = await MapService().currentLocation();
      final suggestions = await MapService().getPlaceSuggestions(
        query,
        latLng.latitude,
        latLng.longitude,
      );
      setState(() => _suggestions = suggestions);
      return suggestions;
    } catch (e) {
      _logger.e('Failed to fetch suggestions: $e');
      return [];
    }
  }

  Future<void> _calculateFareAndRoute() async {
    if (_pickupLatLng == null ||
        _dropoffLatLng == null ||
        _selectedRideType == null) {
      return;
    }
    try {
      final rateAndEta = await MapService().getRateAndEta(
        _pickupController.text.trim(),
        _dropoffController.text.trim(),
        _selectedRideType!,
      );
      setState(() => _fare = rateAndEta['total']);
    } catch (e) {
      setState(() => _errorMessage = e.toString());
      _logger.e('Rate and ETA error: $e');
    }
  }

  Future<void> _requestRide() async {
    if (_fare == null ||
        _pickupLatLng == null ||
        _dropoffLatLng == null ||
        _selectedPaymentMethod == null) {
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
        ScaffoldMessenger.of(
          // ignore: use_build_context_synchronously
          context,
        ).showSnackBar(const SnackBar(content: Text('Ride requested')));
      }
    } catch (e) {
      setState(() => _errorMessage = e.toString());
      _logger.e('Ride request error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            /// Pickup
            TypeAheadField<String>(
              builder: (context, controller, focusNode) {
                return TextField(
                  controller: _pickupController,
                  focusNode: focusNode,
                  decoration: const InputDecoration(
                    labelText: 'Pickup Location',
                    border: OutlineInputBorder(),
                  ),
                );
              },
              suggestionsCallback: (pattern) => fetchSuggestions(pattern, true),
              itemBuilder: (context, suggestion) =>
                  ListTile(title: Text(suggestion)),
              onSelected: (suggestion) async {
                _pickupController.text = suggestion;
                _pickupLatLng = await GeocodingService.getLatLngFromAddress(
                  suggestion,
                );
              },
            ),
            const SizedBox(height: 12),

            /// Dropoff
            TypeAheadField<String>(
              builder: (context, controller, focusNode) {
                return TextField(
                  controller: _dropoffController,
                  focusNode: focusNode,
                  decoration: const InputDecoration(
                    labelText: 'Dropoff Location',
                    border: OutlineInputBorder(),
                  ),
                );
              },
              suggestionsCallback: (pattern) =>
                  fetchSuggestions(pattern, false),
              itemBuilder: (context, suggestion) =>
                  ListTile(title: Text(suggestion)),
              onSelected: (suggestion) async {
                _dropoffController.text = suggestion;
                _dropoffLatLng = await GeocodingService.getLatLngFromAddress(
                  suggestion,
                );
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
              items: ['Economy', 'Premium', 'XL', 'Electric']
                  .map(
                    (type) => DropdownMenuItem(value: type, child: Text(type)),
                  )
                  .toList(),
              onChanged: (value) => setState(() => _selectedRideType = value),
            ),
            const SizedBox(height: 12),

            /// Payment
            DropdownButtonFormField<String>(
              initialValue: _selectedPaymentMethod,
              decoration: const InputDecoration(
                labelText: 'Payment Method',
                border: OutlineInputBorder(),
              ),
              items: ['Cash', 'Credit Card', 'Wallet']
                  .map(
                    (method) =>
                        DropdownMenuItem(value: method, child: Text(method)),
                  )
                  .toList(),
              onChanged: (value) =>
                  setState(() => _selectedPaymentMethod = value),
            ),
            const SizedBox(height: 12),

            /// Notes
            TextField(
              controller: _noteController,
              decoration: const InputDecoration(
                labelText: 'Notes',
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
                        _pickupLatLng != null &&
                            _dropoffLatLng != null &&
                            _selectedRideType != null
                        ? _calculateFareAndRoute
                        : null,
                    child: const Text('Calculate Fare & Route'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _searchingDrivers
                        ? null
                        : () async {
                            setState(() => _searchingDrivers = true);
                            try {
                              if (_pickupLatLng != null &&
                                  _dropoffLatLng != null) {
                                final drivers = await NearbyDriversService()
                                    .getNearbyDrivers(
                                      _pickupLatLng!,
                                      _dropoffLatLng!,
                                    );
                                if (drivers.isNotEmpty) {
                                  setState(
                                    () => _selectedRideType =
                                        drivers.first['rideType'],
                                  );
                                }
                              }
                            } catch (e) {
                              setState(
                                () => _errorMessage =
                                    'Failed to find drivers: $e',
                              );
                              _logger.e('Failed to search drivers: $e');
                            } finally {
                              setState(() => _searchingDrivers = false);
                            }
                          },
                    child: Text(
                      _searchingDrivers ? 'Searching...' : 'Find Drivers',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            ElevatedButton(
              onPressed:
                  _fare != null &&
                      _pickupLatLng != null &&
                      _dropoffLatLng != null &&
                      _selectedPaymentMethod != null
                  ? _requestRide
                  : null,
              child: const Text('Request Ride'),
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
    ).animate().fadeIn(duration: 400.ms);
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
                "Fare: \$${ride['fare']}",
                style: const TextStyle(color: Colors.green),
              ),
            const SizedBox(height: 12),

            /// Rating Button (only if completed)
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

            /// SOS for ongoing rides
            if (ride['status'] != 'completed' &&
                ride['status'] != 'cancelled') ...[
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: () async {
                  try {
                    await EmergencyService.sendEmergency(
                      rideId: ride['id'],
                      currentUid: FirebaseAuth.instance.currentUser!.uid,
                      otherUid: ride['driverId'] ?? '',
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Emergency reported successfully"),
                        ),
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
                icon: const Icon(Icons.sos),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                label: const Text("SOS"),
              ),
            ],
          ],
        ),
      ),
    ).animate().fadeIn(duration: 400.ms).scale(delay: 100.ms);
  }

  /// Rating Dialog
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
            onChanged: (value) {
              setState(() => _rating = value);
            },
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

  /// Firestore Rating Logic
  Future<void> _submitRating(String driverId, double rating) async {
    if (driverId.isEmpty || rating <= 0) return;

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

class DriverDetailsWidget extends ConsumerWidget {
  final String rideId;

  const DriverDetailsWidget({super.key, required this.rideId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('rides')
          .doc(rideId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.data() == null) {
          return const SizedBox.shrink();
        }
        final ride = snapshot.data!.data()! as Map<String, dynamic>;
        final driverId = ride['driverId'] as String?;

        if (driverId == null) {
          return const SizedBox.shrink();
        }

        return StreamBuilder<DocumentSnapshot>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(driverId)
              .snapshots(),
          builder: (context, driverSnapshot) {
            if (!driverSnapshot.hasData || !driverSnapshot.data!.exists) {
              return const SizedBox.shrink();
            }
            final driverData =
                driverSnapshot.data!.data()! as Map<String, dynamic>;

            return Card(
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Driver Details',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text('Name: ${driverData['username'] ?? 'Unknown'}'),
                    Text(
                      'Rating: ${driverData['averageRating']?.toStringAsFixed(1) ?? 'N/A'}',
                    ),
                    Text(
                      'Vehicle: ${driverData['vehicle']?['make'] ?? 'Unknown'} ${driverData['vehicle']?['model'] ?? ''}',
                    ),
                    Text(
                      'Plate: ${driverData['vehicle']?['plateNumber'] ?? 'N/A'}',
                    ),
                  ],
                ),
              ),
            ).animate().fadeIn(duration: 400.ms);
          },
        );
      },
    );
  }
}

class CounterFareWidget extends ConsumerWidget {
  final String rideId;
  final WidgetRef ref;

  const CounterFareWidget({super.key, required this.rideId, required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('rides')
          .doc(rideId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.data() == null) {
          return const SizedBox.shrink();
        }
        final ride = snapshot.data!.data()! as Map<String, dynamic>;
        final counterFare = ride['counterFare'] as double?;

        if (counterFare == null) {
          return const SizedBox.shrink();
        }

        return Card(
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Driver Counter-Offer',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text('Proposed Fare: \$${counterFare.toStringAsFixed(2)}'),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          try {
                            await ref
                                .read(riderDashboardProvider.notifier)
                                .handleCounterFare(rideId, counterFare, true);
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
                                .handleCounterFare(rideId, counterFare, false);
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
        ).animate().fadeIn(duration: 400.ms);
      },
    );
  }
}

class ShareTripButton extends StatelessWidget {
  final String rideId;

  const ShareTripButton({super.key, required this.rideId});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ElevatedButton.icon(
        onPressed: () async {
          try {
            await ShareService().shareTripStatus(
              rideId: rideId,
              userId: FirebaseAuth.instance.currentUser!.uid,
            );
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Trip status shared')),
              );
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
      ),
    );
  }
}

class ReceiptWidget extends StatelessWidget {
  final Map<String, dynamic> ride;

  const ReceiptWidget({super.key, required this.ride});

  @override
  Widget build(BuildContext context) {
    if (ride['status'] != 'completed') {
      return const SizedBox.shrink();
    }

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
            Text('Fare: \$${ride['fare']}'),
            Text('Payment: ${ride['paymentMethod']}'),
            Text('Date: ${(ride['createdAt'] as Timestamp).toDate()}'),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 400.ms);
  }
}
