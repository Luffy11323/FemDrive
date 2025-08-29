// ignore_for_file: use_build_context_synchronously, deprecated_member_use

import 'dart:convert';
import 'package:femdrive/location/directions_service.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:geocoding/geocoding.dart';
import 'package:femdrive/emergency_service.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart';
import '/rider/nearby_drivers_service.dart';
import 'package:flutter/foundation.dart';

// Securely load API key
const String googleApiKey = String.fromEnvironment(
  'GOOGLE_API_KEY',
  defaultValue: '',
);

class MapService {
  final poly = PolylinePoints(apiKey: googleApiKey);

  Future<LatLng> currentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      return LatLng(position.latitude, position.longitude);
    } catch (e) {
      throw Exception('Failed to get current location: $e');
    }
  }

  Future<List<LatLng>> getRoute(LatLng start, LatLng end) async {
    try {
      final result = await poly.getRouteBetweenCoordinatesV2(
        request: RoutesApiRequest(
          origin: PointLatLng(start.latitude, start.longitude),
          destination: PointLatLng(end.latitude, end.longitude),
          travelMode: TravelMode.driving,
        ),
      );

      if (result.routes.isEmpty) throw Exception('No route found');
      final route = result.routes.first;
      final points = route.polylinePoints ?? [];
      return points.map((p) => LatLng(p.latitude, p.longitude)).toList();
    } catch (e) {
      throw Exception('Failed to fetch route: $e');
    }
  }

  Future<Map<String, dynamic>> getRateAndEta(
    LatLng origin,
    LatLng destination,
  ) async {
    try {
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
    } catch (e) {
      throw Exception('Failed to fetch rate and ETA: $e');
    }
  }
}

class PlaceService {
  Future<LatLng?> geocodeFromText(String text) async {
    try {
      final locations = await locationFromAddress(text);
      if (locations.isNotEmpty) {
        final loc = locations.first;
        return LatLng(loc.latitude, loc.longitude);
      }
      return null;
    } catch (e) {
      throw Exception('Failed to geocode address: $e');
    }
  }

  Future<List<Map<String, dynamic>>> autoComplete(String input) async {
    if (input.isEmpty) return [];
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/place/autocomplete/json?input=$input&key=$googleApiKey',
      );
      final response = await http.get(url);
      final data = json.decode(response.body);
      if (data['status'] == 'OK') {
        return List<Map<String, dynamic>>.from(data['predictions']);
      }
      return [];
    } catch (e) {
      throw Exception('Failed to fetch autocomplete suggestions: $e');
    }
  }

  Future<LatLng?> getLatLngFromPlaceId(String placeId) async {
    try {
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
    } catch (e) {
      throw Exception('Failed to fetch place details: $e');
    }
  }
}

class RideService {
  final _fire = FirebaseFirestore.instance;
  final _rtdb = FirebaseDatabase.instance;

  String? _lastUid;
  String? get userId {
    final current = FirebaseAuth.instance.currentUser?.uid;
    if (current != null) _lastUid = current;
    return current ?? _lastUid;
  }

  Stream<DocumentSnapshot?> listenActiveRide() {
    final uid = userId;
    if (uid == null) return const Stream.empty();

    return _fire
        .collection('rides')
        .where('riderId', isEqualTo: uid)
        .where('status', whereIn: ['pending', 'accepted', 'in_progress'])
        .orderBy('createdAt', descending: false)
        .limit(1)
        .snapshots()
        .map((s) => s.docs.isNotEmpty ? s.docs.first : null);
  }

  Future<void> requestRide(Map<String, dynamic> data) async {
    final uid = userId;
    if (uid == null) throw Exception('User not logged in');

    try {
      final doc = await _fire.collection('rides').add({
        ...data,
        'riderId': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      final rideId = doc.id;

      await _rtdb.ref('rides_pending/$rideId').set({
        'pickup': data['pickup'],
        'dropoff': data['dropoff'],
        'pickupLat': data['pickupLat'],
        'pickupLng': data['pickupLng'],
        'dropoffLat': data['dropoffLat'],
        'dropoffLng': data['dropoffLng'],
        'fare': data['fare'],
        'rideType': data['rideType'],
        'note': data['note'] ?? '',
        'riderId': uid,
        'rideId': rideId,
        'createdAt': ServerValue.timestamp,
      });

      try {
        await http.post(
          Uri.parse('https://fem-drive.vercel.app/api/notify/status'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'riderId': uid,
            'status': 'pending',
            'rideId': rideId,
          }),
        );
      } catch (e) {
        if (kDebugMode) {
          print('Failed to send notification: $e');
        }
        // Continue flow despite notification failure
      }
    } catch (e) {
      throw Exception('Failed to request ride: $e');
    }
  }

  Future<void> cancelRide(String id) async {
    final uid = userId;
    if (uid == null) throw Exception('User not logged in');

    try {
      await _fire.collection('rides').doc(id).update({
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
      });

      await _rtdb.ref('rides_pending/$id').remove();

      try {
        await http.post(
          Uri.parse('https://fem-drive.vercel.app/api/notify/status'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'riderId': uid,
            'status': 'cancelled',
            'rideId': id,
          }),
        );
      } catch (e) {
        if (kDebugMode) {
          print('Failed to send cancellation notification: $e');
        }
        // Continue flow despite notification failure
      }
    } catch (e) {
      throw Exception('Failed to cancel ride: $e');
    }
  }

  Future<void> acceptCounterFare(String rideId, double counterFare) async {
    final uid = userId;
    if (uid == null) throw Exception('User not logged in');

    try {
      await _fire.collection('rides').doc(rideId).update({
        'fare': counterFare,
        'status': 'accepted',
        'acceptedAt': FieldValue.serverTimestamp(),
      });

      try {
        await http.post(
          Uri.parse('https://fem-drive.vercel.app/api/notify/status'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'riderId': uid,
            'status': 'accepted',
            'rideId': rideId,
          }),
        );
      } catch (e) {
        if (kDebugMode) {
          print('Failed to send counter-fare notification: $e');
        }
        // Continue flow despite notification failure
      }
    } catch (e) {
      throw Exception('Failed to accept counter-fare: $e');
    }
  }

  Stream<QuerySnapshot> pastRides() {
    final uid = userId;
    if (uid == null) return const Stream.empty();

    return _fire
        .collection('rides')
        .where('riderId', isEqualTo: uid)
        .where('status', whereIn: ['cancelled', 'completed'])
        .orderBy('createdAt', descending: true)
        .snapshots();
  }
}

class UserService {
  final _fire = FirebaseFirestore.instance;

  String? _lastUid;
  String? get uid {
    final current = FirebaseAuth.instance.currentUser?.uid;
    if (current != null) _lastUid = current;
    return current ?? _lastUid;
  }

  Stream<DocumentSnapshot> userStream() {
    final uid = this.uid;
    if (uid == null) throw Exception('No UID available');
    return _fire.collection('users').doc(uid).snapshots();
  }

  Future<void> updateProfile(Map<String, dynamic> data) async {
    final uid = this.uid;
    if (uid == null) throw Exception('No UID available');
    await _fire.collection('users').doc(uid).set(data, SetOptions(merge: true));
  }
}

class RatingService {
  final _fire = FirebaseFirestore.instance;

  Future<bool> hasAlreadyRated(String rideId, String fromUid) async {
    try {
      final q = await _fire
          .collection('ratings')
          .where('rideId', isEqualTo: rideId)
          .where('fromUid', isEqualTo: fromUid)
          .limit(1)
          .get();
      return q.docs.isNotEmpty;
    } catch (e) {
      if (kDebugMode) {
        print('Failed to check rating: $e');
      }
      return false;
    }
  }

  Future<void> submitRating({
    required String rideId,
    required String fromUid,
    required String toUid,
    required double rating,
    String? comment,
  }) async {
    try {
      await _fire.collection('ratings').add({
        'rideId': rideId,
        'fromUid': fromUid,
        'toUid': toUid,
        'rating': rating,
        'comment': comment ?? '',
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      throw Exception('Failed to submit rating: $e');
    }
  }
}

class PastRidesPage extends StatefulWidget {
  const PastRidesPage({super.key});

  @override
  State<PastRidesPage> createState() => _PastRidesPageState();
}

class _PastRidesPageState extends State<PastRidesPage> {
  String? _lastUid;
  String? get uid {
    final current = FirebaseAuth.instance.currentUser?.uid;
    if (current != null) _lastUid = current;
    return current ?? _lastUid;
  }

  @override
  Widget build(BuildContext context) {
    final currentUid = uid;

    if (currentUid == null) {
      return const Scaffold(body: Center(child: Text('No user logged in.')));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Past Rides')),
      body: StreamBuilder<QuerySnapshot>(
        stream: RideService().pastRides(),
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
              final fare = ride['fare'];
              final status = ride['status'];
              final time = ride['createdAt']?.toDate();
              final rideType = ride['rideType'] ?? 'Unknown';
              final note = ride['note'] ?? '';

              return Card(
                margin: const EdgeInsets.all(10),
                child: ListTile(
                  leading: Icon(
                    status == 'completed' ? Icons.check_circle : Icons.cancel,
                    color: status == 'completed' ? Colors.green : Colors.red,
                  ),
                  title: Text('$pickup ➝ $dropoff'),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        time?.toLocal().toString().split('.')[0] ?? 'Unknown',
                      ),
                      Text('Type: $rideType'),
                      if (note.isNotEmpty) Text('Note: $note'),
                    ],
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
  void dispose() {
    commentCtrl.dispose();
    super.dispose();
  }

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
            decoration: const InputDecoration(labelText: 'Comment (optional)'),
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
          onPressed: rating > 0
              ? () {
                  widget.onSubmit(rating, commentCtrl.text.trim());
                }
              : null,
          child: const Text('Submit'),
        ),
      ],
    );
  }
}

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
  String? errorMessage;

  @override
  void dispose() {
    _displayNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _saveProfile() async {
    if (_displayNameController.text.isEmpty || _phoneController.text.isEmpty) {
      setState(() => errorMessage = 'Please complete all fields');
      return;
    }

    setState(() {
      loading = true;
      errorMessage = null;
    });
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
      setState(() => errorMessage = 'Error: $e');
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _logout() async {
    try {
      await FirebaseAuth.instance.signOut();
      if (mounted) {
        Navigator.pushNamedAndRemoveUntil(context, '/login', (route) => false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You have been logged out')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Logout failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
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
          _displayNameController.text = doc['username'] ?? '';
          _phoneController.text = doc['phone'] ?? '';
          final role = doc['role'] as String;
          final verified =
              (doc.data() as Map<String, dynamic>?)?.containsKey(
                'licenseUrl',
              ) ??
              false;

          return Padding(
            padding: const EdgeInsets.all(16),
            child: ListView(
              children: [
                Center(
                  child: CircleAvatar(
                    radius: 40,
                    backgroundColor: Theme.of(context).colorScheme.secondary,
                    child: Text(doc['username']?[0].toUpperCase() ?? 'R'),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _displayNameController,
                  decoration: InputDecoration(
                    labelText: 'Username',
                    errorText: errorMessage,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  decoration: InputDecoration(
                    labelText: 'Phone',
                    errorText: errorMessage,
                  ),
                  keyboardType: TextInputType.phone,
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
                if (role == 'driver')
                  ListTile(
                    leading: const Icon(Icons.document_scanner),
                    title: verified
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
                          ),
                  ),
                const SizedBox(height: 20),
                if (errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      errorMessage!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
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
                  onPressed: _logout,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

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
  LatLng? _currentLocation;
  String? errorMessage;

  String? _lastUid;
  String? get currentUid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) _lastUid = uid;
    return uid ?? _lastUid;
  }

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
    _updateCurrentLocation();
  }

  Future<void> _fetchRoute() async {
    try {
      final current = await MapService().currentLocation();
      final routeData = await DirectionsService.getRoute(current, dropoff);
      if (routeData != null && mounted) {
        setState(() {
          _eta = routeData['eta'];
          _polyline = Polyline(
            polylineId: const PolylineId('route'),
            color: Colors.blue,
            width: 5,
            points: routeData['polyline'],
          );
        });
      }
    } catch (e) {
      setState(() => errorMessage = 'Failed to load route: $e');
      if (kDebugMode) {
        print('RideStatusCard: $errorMessage');
      }
    }
  }

  Future<void> _updateCurrentLocation() async {
    try {
      final current = await MapService().currentLocation();
      if (mounted) {
        setState(() {
          _currentLocation = current;
          _markers.removeWhere((m) => m.markerId.value == 'current');
          _markers.add(
            Marker(
              markerId: const MarkerId('current'),
              position: current,
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueGreen,
              ),
            ),
          );
        });
        _mapController?.animateCamera(CameraUpdate.newLatLng(current));
      }
    } catch (e) {
      setState(() => errorMessage = 'Failed to get current location: $e');
      if (kDebugMode) {
        print('RideStatusCard: $errorMessage');
      }
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
  }

  @override
  Widget build(BuildContext context) {
    final driver = data['driverName'] ?? 'Not Assigned';
    final status = (data['status'] ?? 'unknown').toString();
    final pickupText = data['pickup'] ?? 'N/A';
    final dropoffText = data['dropoff'] ?? 'N/A';
    final fare = data['fare']?.toStringAsFixed(2) ?? '--';
    final rideId = widget.ride.id;
    final rideType = data['rideType'] ?? 'Unknown';
    final note = data['note'] ?? '';

    Color statusColor;
    String statusText;
    switch (status) {
      case 'pending':
        statusColor = Colors.orange;
        statusText = 'Waiting for Driver';
        break;
      case 'accepted':
        statusColor = Colors.blue;
        statusText = 'Driver Assigned';
        break;
      case 'in_progress':
        statusColor = Colors.green;
        statusText = 'Ride In Progress';
        break;
      default:
        statusColor = Colors.grey;
        statusText = 'Unknown';
    }

    return Column(
      children: [
        if (errorMessage != null)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              errorMessage!,
              style: const TextStyle(color: Colors.red, fontSize: 14),
            ),
          ),
        SizedBox(
          height: 300,
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
                initialCameraPosition: CameraPosition(
                  target: _currentLocation ?? pickup,
                  zoom: 15,
                ),
                onMapCreated: (controller) {
                  _mapController = controller;
                  if (_currentLocation != null) {
                    controller.animateCamera(
                      CameraUpdate.newLatLng(_currentLocation!),
                    );
                  }
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
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
        LinearProgressIndicator(
          value: status == 'pending'
              ? null
              : (status == 'accepted' ? 0.5 : 1.0),
          color: statusColor,
          backgroundColor: statusColor.withOpacity(0.2),
        ),
        Card(
          margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "$pickupText → $dropoffText",
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.directions_car, color: statusColor),
                    const SizedBox(width: 8),
                    Text(
                      "Status: $statusText",
                      style: TextStyle(color: statusColor, fontSize: 16),
                    ),
                  ],
                ),
                Text("Fare: \$$fare"),
                Text("Driver: $driver"),
                Text("Ride Type: $rideType"),
                if (note.isNotEmpty) Text("Note: $note"),
                const SizedBox(height: 12),
                if (status == 'accepted' || status == 'in_progress')
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                        ),
                        onPressed: () async {
                          final uid = currentUid;
                          if (uid == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('User not available'),
                              ),
                            );
                            return;
                          }

                          final isDriver = data['driverId'] == uid;
                          final otherUid = isDriver
                              ? data['riderId']
                              : data['driverId'];

                          if (otherUid == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Unable to determine other user'),
                              ),
                            );
                            return;
                          }

                          try {
                            await EmergencyService.sendEmergency(
                              rideId: rideId,
                              currentUid: uid,
                              otherUid: otherUid,
                            );
                            if (mounted) {
                              Navigator.pushNamedAndRemoveUntil(
                                context,
                                '/dashboard',
                                (route) => false,
                              );
                            }
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Emergency failed: $e')),
                              );
                            }
                          }
                        },
                        child: const Text('Emergency'),
                      ),
                      if (status == 'accepted')
                        IconButton(
                          icon: const Icon(Icons.cancel, color: Colors.red),
                          onPressed: widget.onCancel,
                          tooltip: 'Cancel Ride',
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class RideForm extends StatefulWidget {
  final void Function(String, String, double, LatLng, LatLng, String, String)
  onSubmit;

  const RideForm({required this.onSubmit, super.key});

  @override
  State<RideForm> createState() => _RideFormState();
}

class _RideFormState extends State<RideForm>
    with SingleTickerProviderStateMixin {
  final pc = TextEditingController();
  final dc = TextEditingController();
  final noteCtrl = TextEditingController();
  String selectedCar = 'Standard';
  double? fare;
  String? eta;
  LatLng? pcLL, dcLL;
  bool loading = false;
  bool searchingDrivers = false;
  String? errorMessage;
  GoogleMapController? _mapController;
  final Set<Marker> _markers = {};
  final Set<Circle> _circles = {};
  Polyline? _polyline;
  String? activeRideId;

  String? _lastUid;
  final ps = PlaceService();
  final ms = MapService();
  final nds = NearbyDriversService();
  AnimationController? _radarController;
  Animation<double>? _radarAnimation;

  String? get uid {
    final current = FirebaseAuth.instance.currentUser?.uid;
    if (current != null) _lastUid = current;
    return current ?? _lastUid;
  }

  @override
  void initState() {
    super.initState();
    _setCurrentLocationAsPickup();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _radarAnimation = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(_radarController!);
  }

  @override
  void dispose() {
    _radarController?.dispose();
    pc.dispose();
    dc.dispose();
    noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _setCurrentLocationAsPickup() async {
    try {
      final current = await ms.currentLocation();
      final placemarks = await placemarkFromCoordinates(
        current.latitude,
        current.longitude,
      );
      if (placemarks.isNotEmpty && mounted) {
        setState(() {
          pc.text = placemarks.first.name ?? '';
          pcLL = current;
          _updateMarker('pickup', pcLL!);
          _mapController?.animateCamera(CameraUpdate.newLatLng(pcLL!));
        });
      }
    } catch (e) {
      setState(() => errorMessage = 'Failed to set current location: $e');
      if (kDebugMode) {
        print('RideForm: $errorMessage');
      }
    }
  }

  Future<void> calculateDetails() async {
    if (pc.text.isEmpty || dc.text.isEmpty) {
      setState(
        () => errorMessage = 'Please enter both pickup and drop-off locations',
      );
      return;
    }

    setState(() {
      loading = true;
      errorMessage = null;
    });
    try {
      pcLL = await ps.geocodeFromText(pc.text.trim());
      dcLL = await ps.geocodeFromText(dc.text.trim());

      if (pcLL == null || dcLL == null) {
        throw Exception('Invalid pickup or drop-off location');
      }

      final r = await ms.getRateAndEta(pcLL!, dcLL!);
      final distanceKm = r['distanceKm'] as double;
      final fareMultipliers = {'Standard': 1.5, 'Comfort': 2.0, 'Luxury': 3.0};
      fare = double.parse(
        (distanceKm * fareMultipliers[selectedCar]!).toStringAsFixed(2),
      );
      eta = '${r['durationMin'].round()} min';

      final route = await ms.getRoute(pcLL!, dcLL!);
      setState(() {
        _polyline = Polyline(
          polylineId: const PolylineId('route'),
          color: Colors.blue,
          width: 5,
          points: route,
        );
        _updateMarker('pickup', pcLL!);
        _updateMarker('dropoff', dcLL!);
        _mapController?.animateCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(
                pcLL!.latitude < dcLL!.latitude
                    ? pcLL!.latitude
                    : dcLL!.latitude,
                pcLL!.longitude < dcLL!.longitude
                    ? pcLL!.longitude
                    : dcLL!.longitude,
              ),
              northeast: LatLng(
                pcLL!.latitude > dcLL!.latitude
                    ? pcLL!.latitude
                    : dcLL!.latitude,
                pcLL!.longitude > dcLL!.longitude
                    ? pcLL!.longitude
                    : dcLL!.longitude,
              ),
            ),
            50,
          ),
        );
      });
    } catch (e) {
      setState(() => errorMessage = 'Failed to calculate fare/route: $e');
      if (kDebugMode) {
        print('RideForm: $errorMessage');
      }
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _searchNearbyDrivers() async {
    if (pcLL == null) {
      setState(() => errorMessage = 'Please set a pickup location first');
      return;
    }

    setState(() {
      searchingDrivers = true;
      errorMessage = null;
    });
    try {
      final drivers = await nds.fetchNearbyDrivers(pcLL!, 5.0); // 5km radius
      setState(() {
        _markers.removeWhere((m) => m.markerId.value.startsWith('driver_'));
        _circles.clear();
        for (var i = 0; i < drivers.length; i++) {
          final driver = drivers[i];
          _markers.add(
            Marker(
              markerId: MarkerId('driver_$i'),
              position: driver['position'],
              infoWindow: InfoWindow(title: driver['name']),
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueBlue,
              ),
            ),
          );
        }
        _circles.add(
          Circle(
            circleId: const CircleId('radar'),
            center: pcLL!,
            radius: 5000,
            fillColor: Colors.blue.withOpacity(0.1),
            strokeColor: Colors.blue,
            strokeWidth: 1,
          ),
        );
      });
    } catch (e) {
      setState(() => errorMessage = 'Failed to find nearby drivers: $e');
      if (kDebugMode) {
        print('RideForm: $errorMessage');
      }
    } finally {
      setState(() => searchingDrivers = false);
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
  @override
  Widget build(BuildContext context) {
    final currentUid = uid;
    return Column(
      children: [
        if (errorMessage != null)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              errorMessage!,
              style: const TextStyle(color: Colors.red, fontSize: 14),
            ),
          ),
        SizedBox(
          height: 300,
          child: AnimatedBuilder(
            animation: _radarAnimation!,
            builder: (context, child) {
              return GoogleMap(
                initialCameraPosition: const CameraPosition(
                  target: LatLng(30.1575, 71.5249),
                  zoom: 13,
                ),
                onMapCreated: (controller) => _mapController = controller,
                markers: _markers,
                polylines: _polyline == null ? {} : {_polyline!},
                circles: {
                  ..._circles,
                  if (searchingDrivers)
                    Circle(
                      circleId: const CircleId('radar_pulse'),
                      center: pcLL ?? const LatLng(0, 0),
                      radius: 5000 * _radarAnimation!.value,
                      fillColor: Colors.blue.withOpacity(
                        0.3 * (1 - _radarAnimation!.value),
                      ),
                      strokeColor: Colors.transparent,
                    ),
                },
                myLocationEnabled: true,
                myLocationButtonEnabled: true,
              );
            },
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TypeAheadField<String>(
                  builder: (context, controller, focusNode) {
                    return TextField(
                      controller: pc,
                      focusNode: focusNode,
                      decoration: const InputDecoration(
                        labelText: 'Pickup Location',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.location_on),
                      ),
                    );
                  },
                  suggestionsCallback: (pattern) async {
                    try {
                      final suggestions = await ps.autoComplete(pattern);
                      return suggestions
                          .map((s) => s['description'] as String)
                          .toList();
                    } catch (e) {
                      setState(
                        () => errorMessage =
                            'Failed to load pickup suggestions: $e',
                      );
                      return [];
                    }
                  },
                  itemBuilder: (context, suggestion) {
                    return ListTile(title: Text(suggestion));
                  },
                  onSelected: (suggestion) {
                    pc.text = suggestion;
                  },
                ),
                const SizedBox(height: 12),
                TypeAheadField<String>(
                  builder: (context, controller, focusNode) {
                    return TextField(
                      controller: dc,
                      focusNode: focusNode,
                      decoration: const InputDecoration(
                        labelText: 'Drop-off Location',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.flag),
                      ),
                    );
                  },
                  suggestionsCallback: (pattern) async {
                    try {
                      final suggestions = await ps.autoComplete(pattern);
                      return suggestions
                          .map((s) => s['description'] as String)
                          .toList();
                    } catch (e) {
                      setState(
                        () => errorMessage =
                            'Failed to load drop-off suggestions: $e',
                      );
                      return [];
                    }
                  },
                  itemBuilder: (context, suggestion) {
                    return ListTile(title: Text(suggestion));
                  },
                  onSelected: (suggestion) {
                    dc.text = suggestion;
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: selectedCar,
                  decoration: const InputDecoration(
                    labelText: 'Ride Type',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'Standard',
                      child: Text('Standard'),
                    ),
                    DropdownMenuItem(value: 'Comfort', child: Text('Comfort')),
                    DropdownMenuItem(value: 'Luxury', child: Text('Luxury')),
                  ],
                  onChanged: (v) => setState(() => selectedCar = v!),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Additional Note (optional)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 12),
                if (fare != null && eta != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '🚗 \$${fare!.toStringAsFixed(2)} • ETA: $eta',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                loading
                    ? const CircularProgressIndicator()
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: ElevatedButton(
                              onPressed: calculateDetails,
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size(double.infinity, 48),
                              ),
                              child: const Text('Calculate Fare & Route'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: _searchNearbyDrivers,
                              style: ElevatedButton.styleFrom(
                                minimumSize: const Size(double.infinity, 48),
                                backgroundColor: Colors.blueAccent,
                              ),
                              child: Text(
                                searchingDrivers
                                    ? 'Searching...'
                                    : 'Find Drivers',
                              ),
                            ),
                          ),
                        ],
                      ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed:
                      (fare != null &&
                          pcLL != null &&
                          dcLL != null &&
                          currentUid != null)
                      ? () async {
                          try {
                            widget.onSubmit(
                              pc.text.trim(),
                              dc.text.trim(),
                              fare!,
                              pcLL!,
                              dcLL!,
                              selectedCar,
                              noteCtrl.text.trim(),
                            );
                            final latest = await FirebaseFirestore.instance
                                .collection('rides')
                                .where('riderId', isEqualTo: currentUid)
                                .orderBy('createdAt', descending: true)
                                .limit(1)
                                .get();
                            if (latest.docs.isNotEmpty) {
                              setState(
                                () => activeRideId = latest.docs.first.id,
                              );
                            }
                          } catch (e) {
                            setState(
                              () => errorMessage = 'Error requesting ride: $e',
                            );
                            if (kDebugMode) {
                              print('RideForm: $errorMessage');
                            }
                          }
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    backgroundColor: Colors.green,
                  ),
                  child: const Text('Request Ride'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
