import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import './place_service.dart';
import './map_service.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class RideForm extends StatefulWidget {
  final void Function(String, String, double, LatLng, LatLng) onSubmit;

  const RideForm({required this.onSubmit, super.key});

  @override
  State<RideForm> createState() => _RideFormState();
}

class _RideFormState extends State<RideForm> {
  final pc = TextEditingController();
  final dc = TextEditingController();

  String selectedCar = 'Luxury';
  double? rate;
  String? eta;
  LatLng? pcLL, dcLL;
  bool loading = false;

  GoogleMapController? _mapController;
  // ignore: unused_field
  Marker? _driverMarker;
  final Set<Marker> _markers = {};

  final ps = PlaceService();
  final ms = MapService();

  String? activeRideId;

  Future<void> calculateDetails() async {
    setState(() => loading = true);
    try {
      pcLL = await ps.geocodeFromText(pc.text.trim());
      dcLL = await ps.geocodeFromText(dc.text.trim());

      if (pcLL == null || dcLL == null) {
        throw Exception('Invalid pickup or drop-off location');
      }

      final r = await ms.getRateAndEta(pcLL!, dcLL!);
      rate = double.parse((r['distanceKm'] * 1.5).toStringAsFixed(2));
      eta = '${r['durationMin'].round()} min';

      // Update markers on the map
      _updateMarker('pickup', pcLL!);
      _updateMarker('dropoff', dcLL!);

      _mapController?.animateCamera(CameraUpdate.newLatLng(pcLL!));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: ${e.toString()}')));
      }
    } finally {
      setState(() => loading = false);
    }
  }

  void _updateMarker(String id, LatLng pos, {Color color = Colors.red}) {
    setState(() {
      _markers.removeWhere((m) => m.markerId.value == id);
      _markers.add(
        Marker(
          markerId: MarkerId(id),
          position: pos,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            color == Colors.blue
                ? BitmapDescriptor.hueBlue
                : BitmapDescriptor.hueRed,
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 250,
          child: Stack(
            children: [
              GoogleMap(
                initialCameraPosition: const CameraPosition(
                  target: LatLng(30.1575, 71.5249),
                  zoom: 13,
                ),
                onMapCreated: (controller) {
                  _mapController = controller;
                },
                markers: Set<Marker>.from(_markers),
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
              ),

              /// 🛰️ Nested location tracking from Firestore subcollection
              if (activeRideId != null)
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('rides')
                      .doc(activeRideId)
                      .collection('locations')
                      .orderBy('ts', descending: true)
                      .limit(1)
                      .snapshots(),
                  builder: (ctx, snap) {
                    if (!snap.hasData || snap.data!.docs.isEmpty) {
                      return const SizedBox.shrink();
                    }

                    final loc =
                        snap.data!.docs.first.data() as Map<String, dynamic>;
                    final pos = LatLng(loc['lat'], loc['lng']);

                    _mapController?.animateCamera(CameraUpdate.newLatLng(pos));

                    _updateMarker('driver', pos, color: Colors.blue);

                    return const SizedBox.shrink(); // overlays nothing
                  },
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              TextField(
                controller: pc,
                decoration: const InputDecoration(labelText: 'Pickup'),
              ),
              TextField(
                controller: dc,
                decoration: const InputDecoration(labelText: 'Drop‑off'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: selectedCar,
                items: const [
                  DropdownMenuItem(value: 'Luxury', child: Text('Luxury')),
                  DropdownMenuItem(value: 'Comfort', child: Text('Comfort')),
                  DropdownMenuItem(value: 'Standard', child: Text('Standard')),
                ],
                onChanged: (v) => setState(() => selectedCar = v!),
              ),
              const SizedBox(height: 8),
              if (rate != null && eta != null)
                Text('🚗 \$${rate!.toStringAsFixed(2)} • ETA: $eta'),
              const SizedBox(height: 8),
              loading
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                      onPressed: calculateDetails,
                      child: const Text('Calculate'),
                    ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: rate != null && pcLL != null && dcLL != null
                    ? () async {
                        widget.onSubmit(
                          pc.text.trim(),
                          dc.text.trim(),
                          rate!,
                          pcLL!,
                          dcLL!,
                        );
                        // optional: wait for ride to be created and grab rideId
                        final rideDoc = await FirebaseFirestore.instance
                            .collection('rides')
                            .where(
                              'riderId',
                              isEqualTo: FirebaseAuth.instance.currentUser!.uid,
                            )
                            .orderBy('createdAt', descending: true)
                            .limit(1)
                            .get();
                        if (rideDoc.docs.isNotEmpty) {
                          setState(() {
                            activeRideId = rideDoc.docs.first.id;
                          });
                        }
                      }
                    : null,
                child: const Text('Request Ride'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
