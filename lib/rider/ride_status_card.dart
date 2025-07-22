import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:femdrive/emergency_service.dart';
import 'package:femdrive/location/directions_service.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class RideStatusCard extends StatefulWidget {
  final DocumentSnapshot ride;
  final VoidCallback onCancel;

  const RideStatusCard({required this.ride, required this.onCancel, super.key});

  @override
  State<RideStatusCard> createState() => _RideStatusCardState();
}

class _RideStatusCardState extends State<RideStatusCard> {
  late Map<String, dynamic> data;
  Set<Marker> _markers = {};
  late LatLng pickup;
  late LatLng dropoff;
  GoogleMapController? _mapController;
  Polyline? _polyline;
  String? _eta;

  @override
  void initState() {
    super.initState();
    data = widget.ride.data() as Map<String, dynamic>;
    pickup = LatLng(data['pickupLat'], data['pickupLng']);
    dropoff = LatLng(data['dropoffLat'], data['dropoffLng']);

    _markers = {
      Marker(markerId: const MarkerId('pickup'), position: pickup),
      Marker(markerId: const MarkerId('dropoff'), position: dropoff),
    };

    _fetchRoute();
  }

  Future<void> _fetchRoute() async {
    final routeData = await DirectionsService.getRoute(pickup, dropoff);
    if (routeData != null) {
      setState(() {
        _eta = routeData['eta'];
        _polyline = Polyline(
          polylineId: const PolylineId('route'),
          color: Colors.green,
          width: 5,
          points: routeData['polyline'],
        );
      });
    }
  }

  void _updateDriverMarker(LatLng position) {
    final driverMarker = Marker(
      markerId: const MarkerId('driver'),
      position: position,
      icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
    );

    setState(() {
      _markers.removeWhere((m) => m.markerId.value == 'driver');
      _markers.add(driverMarker);
    });

    _mapController?.animateCamera(CameraUpdate.newLatLng(position));
  }

  @override
  Widget build(BuildContext context) {
    final driver = data['driverName'] ?? 'Not Assigned';
    final status = (data['status'] ?? 'unknown').toString();
    final pickupText = data['pickup'] ?? 'N/A';
    final dropoffText = data['dropoff'] ?? 'N/A';
    final rate = data['rate']?.toString() ?? '--';
    final rideId = data['rideId'];

    return Column(
      children: [
        SizedBox(
          height: 250,
          child: StreamBuilder<DocumentSnapshot>(
            stream: FirebaseFirestore.instance
                .collection('rides')
                .doc(rideId)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasData && snapshot.data!.exists) {
                final liveData = snapshot.data!.data() as Map<String, dynamic>;

                if (liveData['driverLat'] != null &&
                    liveData['driverLng'] != null) {
                  final driverPos = LatLng(
                    liveData['driverLat'],
                    liveData['driverLng'],
                  );
                  _updateDriverMarker(driverPos);
                }
              }

              return GoogleMap(
                markers: _markers,
                polylines: _polyline == null ? {} : {_polyline!},
                initialCameraPosition: CameraPosition(target: pickup, zoom: 15),
                onMapCreated: (controller) {
                  _mapController = controller;
                },
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
              );
            },
          ),
        ),
        if (_eta != null)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              'ETA: $_eta',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        Card(
          margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "$pickupText → $dropoffText",
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text("Status: ${status.toUpperCase()}"),
                Text("Rate: \$$rate"),
                Text("Driver: $driver"),
                const SizedBox(height: 10),
                if (status == 'accepted') ...[
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                    ),
                    onPressed: () async {
                      await EmergencyService.sendEmergency(
                        rideId: rideId,
                        currentUid: FirebaseAuth.instance.currentUser!.uid,
                        otherUid: data['riderId'] ?? data['driverId'],
                      );
                    },
                    child: const Text('Emergency'),
                  ),
                ],
                if (status == 'pending' || status == 'accepted')
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      icon: const Icon(Icons.cancel, color: Colors.red),
                      onPressed: widget.onCancel,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
