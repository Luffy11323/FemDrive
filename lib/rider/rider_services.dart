import 'dart:convert';
import 'package:femdrive/location/directions_service.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
// ignore: unnecessary_import
import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:geocoding/geocoding.dart';
import 'package:femdrive/emergency_service.dart'; // Adjust path if needed

import 'package:http/http.dart' as http;

// Replace with your Google Maps API Key
const String googleApiKey = 'AIzaSyCRpuf1w49Ri0gNiiTPOJcSY7iyhyC-2c4';

/// MAP SERVICE
class MapService {
  final poly = PolylinePoints();

  Future<LatLng> currentLocation() async {
    final position = await Geolocator.getCurrentPosition();
    return LatLng(position.latitude, position.longitude);
  }

  Future<List<LatLng>> getRoute(LatLng start, LatLng end) async {
    final result = await poly.getRouteBetweenCoordinates(
      googleApiKey: googleApiKey,
      request: PolylineRequest(
        origin: PointLatLng(start.latitude, start.longitude),
        destination: PointLatLng(end.latitude, end.longitude),
        mode: TravelMode.driving,
      ),
    );

    if (result.points.isEmpty) throw Exception('No route found');
    return result.points.map((p) => LatLng(p.latitude, p.longitude)).toList();
  }

  Future<Map<String, dynamic>> getRateAndEta(
    LatLng origin,
    LatLng destination,
  ) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/distancematrix/json'
      '?origins=${origin.latitude},${origin.longitude}'
      '&destinations=${destination.latitude},${destination.longitude}'
      '&key=$googleApiKey',
    );
    final response = await http.get(url);
    final data = jsonDecode(response.body);
    if (data['status'] != 'OK') throw Exception('Distance Matrix failed');
    final element = data['rows'][0]['elements'][0];
    if (element['status'] != 'OK') throw Exception('Route unavailable');

    final distanceMeters = element['distance']['value'];
    final durationSeconds = element['duration']['value'];
    return {
      'distanceKm': distanceMeters / 1000,
      'durationMin': durationSeconds / 60,
    };
  }
}

/// PLACE SERVICE
class PlaceService {
  Future<LatLng?> geocodeFromText(String text) async {
    try {
      final locations = await locationFromAddress(text);
      if (locations.isNotEmpty) {
        final loc = locations.first;
        return LatLng(loc.latitude, loc.longitude);
      }
    } catch (_) {}
    return null;
  }

  Future<List<Map<String, dynamic>>> autoComplete(String input) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/autocomplete/json?input=$input&key=$googleApiKey',
    );
    final response = await http.get(url);
    final data = json.decode(response.body);
    if (data['status'] == 'OK') {
      return List<Map<String, dynamic>>.from(data['predictions']);
    }
    return [];
  }

  Future<LatLng?> getLatLngFromPlaceId(String placeId) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/details/json?place_id=$placeId&key=$googleApiKey',
    );
    final response = await http.get(url);
    final data = json.decode(response.body);
    if (data['status'] == 'OK') {
      final location = data['result']['geometry']['location'];
      return LatLng(location['lat'], location['lng']);
    }
    return null;
  }
}

/// RIDE SERVICE

class RideService {
  final _fire = FirebaseFirestore.instance;
  final _rtdb = FirebaseDatabase.instance;
  final String userId = FirebaseAuth.instance.currentUser!.uid;

  Stream<DocumentSnapshot?> listenActiveRide() {
    return _fire
        .collection('rides')
        .where('riderId', isEqualTo: userId)
        .where('status', whereIn: ['pending', 'accepted', 'in_progress'])
        .orderBy('createdAt', descending: false)
        .limit(1)
        .snapshots()
        .map((s) => s.docs.isNotEmpty ? s.docs.first : null);
  }

  Future<void> requestRide(Map<String, dynamic> data) async {
    final doc = await _fire.collection('rides').add(data);
    final rideId = doc.id;

    // Push to RTDB for driver discovery
    await _rtdb.ref('rides_pending/$rideId').set({
      'pickup': data['pickup'],
      'dropoff': data['dropoff'],
      'pickupLat': data['pickupLat'],
      'pickupLng': data['pickupLng'],
      'dropoffLat': data['dropoffLat'],
      'dropoffLng': data['dropoffLng'],
      'rate': data['rate'],
      'riderId': userId,
      'rideId': rideId,
      'createdAt': ServerValue.timestamp,
    });

    // Trigger backend notification
    await http.post(
      Uri.parse('https://fem-drive.vercel.app/api/notify/status'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'riderId': userId,
        'status': 'pending',
        'rideId': rideId,
      }),
    );
  }

  Future<void> cancelRide(String id) async {
    await _fire.collection('rides').doc(id).update({
      'status': 'cancelled',
      'cancelledAt': FieldValue.serverTimestamp(),
    });

    await _rtdb.ref('rides_pending/$id').remove();

    await http.post(
      Uri.parse('https://fem-drive.vercel.app/api/notify/status'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'riderId': userId,
        'status': 'cancelled',
        'rideId': id,
      }),
    );
  }

  Stream<QuerySnapshot> pastRides() {
    return _fire
        .collection('rides')
        .where('riderId', isEqualTo: userId)
        .where('status', whereIn: ['cancelled', 'completed'])
        .orderBy('createdAt', descending: true)
        .snapshots();
  }
}

/// USER SERVICE
class UserService {
  final _fire = FirebaseFirestore.instance;
  final String uid = FirebaseAuth.instance.currentUser!.uid;

  Stream<DocumentSnapshot> userStream() {
    return _fire.collection('users').doc(uid).snapshots();
  }

  Future<void> updateProfile(Map<String, dynamic> data) async {
    await _fire.collection('users').doc(uid).update(data);
  }
}

/// RATING SERVICE
class RatingService {
  final _fire = FirebaseFirestore.instance;

  Future<bool> hasAlreadyRated(String rideId, String fromUid) async {
    final q = await _fire
        .collection('ratings')
        .where('rideId', isEqualTo: rideId)
        .where('fromUid', isEqualTo: fromUid)
        .limit(1)
        .get();

    return q.docs.isNotEmpty;
  }

  Future<void> submitRating({
    required String rideId,
    required String fromUid,
    required String toUid,
    required double rating,
    String? comment,
  }) async {
    await _fire.collection('ratings').add({
      'rideId': rideId,
      'fromUid': fromUid,
      'toUid': toUid,
      'rating': rating,
      'comment': comment ?? '',
      'createdAt': FieldValue.serverTimestamp(),
    });
  }
}

/// PAST RIDES PAGE
class PastRidesPage extends StatelessWidget {
  const PastRidesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    return Scaffold(
      appBar: AppBar(title: const Text('Past Rides')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('rides')
            .where('riderId', isEqualTo: uid)
            .where('status', whereIn: ['completed', 'cancelled'])
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData || snap.data!.docs.isEmpty) {
            return const Center(child: Text('No past rides found.'));
          }

          final rides = snap.data!.docs;
          return ListView.builder(
            itemCount: rides.length,
            itemBuilder: (context, index) {
              final ride = rides[index];
              final pickup = ride['pickup'];
              final dropoff = ride['dropoff'];
              final fare = ride['rate'];
              final status = ride['status'];
              final time = ride['createdAt']?.toDate();

              return Card(
                margin: const EdgeInsets.all(10),
                child: ListTile(
                  leading: Icon(
                    status == 'completed' ? Icons.check_circle : Icons.cancel,
                    color: status == 'completed' ? Colors.green : Colors.red,
                  ),
                  title: Text('$pickup ➝ $dropoff'),
                  subtitle: Text(
                    time?.toLocal().toString().split('.')[0] ?? 'Unknown',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Text('\$${fare.toStringAsFixed(2)}'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// RATING DIALOG
class RatingDialog extends StatefulWidget {
  final Function(int rating, String comment) onSubmit;
  const RatingDialog({required this.onSubmit, super.key});

  @override
  State<RatingDialog> createState() => _RatingDialogState();
}

class _RatingDialogState extends State<RatingDialog> {
  int rating = 0;
  final commentCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rate Your Driver'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (i) {
              return IconButton(
                icon: Icon(
                  i < rating ? Icons.star : Icons.star_border,
                  color: Colors.amber,
                ),
                onPressed: () => setState(() => rating = i + 1),
              );
            }),
          ),
          TextField(
            controller: commentCtrl,
            decoration: const InputDecoration(labelText: 'Comment'),
            maxLines: 2,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Skip'),
        ),
        ElevatedButton(
          onPressed: () {
            widget.onSubmit(rating, commentCtrl.text.trim());
            Navigator.pop(context);
          },
          child: const Text('Submit'),
        ),
      ],
    );
  }
}

/// PROFILE PAGE
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final us = UserService();
  final _displayNameController = TextEditingController();
  final _phoneController = TextEditingController();
  bool loading = false;

  @override
  void dispose() {
    _displayNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _saveProfile() async {
    if (_displayNameController.text.isEmpty || _phoneController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Complete all fields')));
      return;
    }

    setState(() => loading = true);
    try {
      await us.updateProfile({
        'username': _displayNameController.text.trim(),
        'phone': _phoneController.text.trim(),
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Profile updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile & Settings')),
      body: StreamBuilder(
        stream: us.userStream(),
        builder: (ctx, snap) {
          if (!snap.hasData) {
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

          final doc = snap.data!;
          _displayNameController.text = doc['username'];
          _phoneController.text = doc['phone'];
          final role = doc['role'] as String;
          final verified =
              (doc.data() as Map<String, dynamic>?)?.containsKey(
                'licenseUrl',
              ) ??
              false;

          final statusBadge = verified
              ? Row(
                  children: const [
                    Icon(Icons.verified, color: Colors.green),
                    SizedBox(width: 4),
                    Text('Verified'),
                  ],
                )
              : Row(
                  children: const [
                    Icon(Icons.hourglass_top, color: Colors.orange),
                    SizedBox(width: 4),
                    Text('Pending'),
                  ],
                );

          return Padding(
            padding: const EdgeInsets.all(16),
            child: ListView(
              children: [
                Center(
                  child: CircleAvatar(
                    radius: 40,
                    backgroundColor: Theme.of(context).colorScheme.secondary,
                    child: Text(doc['username'][0].toUpperCase()),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _displayNameController,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  decoration: const InputDecoration(labelText: 'Phone'),
                ),
                const SizedBox(height: 20),
                ListTile(
                  leading: Icon(
                    role == 'driver' ? Icons.directions_car : Icons.person,
                  ),
                  title: Text(
                    'Role: ${role[0].toUpperCase()}${role.substring(1)}',
                  ),
                ),
                const SizedBox(height: 10),
                if (role == 'driver')
                  ListTile(
                    leading: const Icon(Icons.document_scanner),
                    title: statusBadge,
                  ),
                const SizedBox(height: 20),
                loading
                    ? const Center(child: CircularProgressIndicator())
                    : ElevatedButton(
                        onPressed: _saveProfile,
                        child: const Text('Save Changes'),
                      ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  icon: const Icon(Icons.logout),
                  label: const Text('Logout'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                  ),
                  onPressed: () {
                    FirebaseAuth.instance.signOut();
                    Navigator.popUntil(context, (r) => r.isFirst);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

//Ride Status Card
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
                onMapCreated: (controller) => _mapController = controller,
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
                if (status == 'accepted')
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                    ),
                    onPressed: () async {
                      final currentUid = FirebaseAuth.instance.currentUser!.uid;
                      final isDriver = data['driverId'] == currentUid;
                      final otherUid = isDriver
                          ? data['riderId']
                          : data['driverId'];

                      if (otherUid == null) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Unable to determine other user.'),
                          ),
                        );
                        return;
                      }

                      await EmergencyService.sendEmergency(
                        rideId: rideId,
                        currentUid: currentUid,
                        otherUid: otherUid,
                      );

                      if (mounted) {
                        Navigator.popUntil(context, (route) => route.isFirst);
                      }
                    },
                    child: const Text('Emergency'),
                  ),
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

//Ride Form
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
  final Set<Marker> _markers = {};
  String? activeRideId;

  final ps = PlaceService();
  final ms = MapService();

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
                onMapCreated: (controller) => _mapController = controller,
                markers: Set<Marker>.from(_markers),
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
              ),
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
                    return const SizedBox.shrink();
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
                        final latest = await FirebaseFirestore.instance
                            .collection('rides')
                            .where(
                              'riderId',
                              isEqualTo: FirebaseAuth.instance.currentUser!.uid,
                            )
                            .orderBy('createdAt', descending: true)
                            .limit(1)
                            .get();
                        if (latest.docs.isNotEmpty) {
                          setState(() => activeRideId = latest.docs.first.id);
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
