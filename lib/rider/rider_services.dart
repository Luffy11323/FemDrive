import 'dart:convert';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:share_plus/share_plus.dart';
import 'package:logger/logger.dart';
import '../location/directions_service.dart';
import 'nearby_drivers_service.dart';

const String googleApiKey = String.fromEnvironment(
  'GOOGLE_API_KEY',
  defaultValue: '',
);

class MapService {
  final poly = PolylinePoints(apiKey: googleApiKey);
  final _logger = Logger();

  Future<LatLng> currentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        // ignore: deprecated_member_use
        desiredAccuracy: LocationAccuracy.high,
      );
      return LatLng(position.latitude, position.longitude);
    } catch (e) {
      _logger.e('Failed to get current location: $e');
      throw Exception(
        'Unable to get current location. Please check permissions.',
      );
    }
  }

  Future<List<LatLng>> getRoute(LatLng start, LatLng end) async {
    try {
      if (googleApiKey.isEmpty) {
        throw Exception('Google API key is missing or invalid');
      }
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
      _logger.e('Failed to fetch route: $e');
      throw Exception('Unable to load route. Please try again.');
    }
  }

  Future<Map<String, dynamic>> getRateAndEta(
    LatLng origin,
    LatLng destination,
  ) async {
    try {
      if (googleApiKey.isEmpty) {
        throw Exception('Google API key is missing or invalid');
      }
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
      _logger.e('Failed to fetch rate and ETA: $e');
      throw Exception('Unable to calculate fare and ETA. Please try again.');
    }
  }
}

class PlaceService {
  final _logger = Logger();

  Future<LatLng?> geocodeFromText(String text) async {
    try {
      if (googleApiKey.isEmpty) {
        throw Exception('Google API key is missing or invalid');
      }
      final locations = await locationFromAddress(text);
      if (locations.isNotEmpty) {
        final loc = locations.first;
        return LatLng(loc.latitude, loc.longitude);
      }
      return null;
    } catch (e) {
      _logger.e('Failed to geocode address: $e');
      throw Exception('Invalid address. Please try again.');
    }
  }

  Future<List<Map<String, dynamic>>> autoComplete(String input) async {
    if (input.isEmpty) return [];
    try {
      if (googleApiKey.isEmpty) {
        throw Exception('Google API key is missing or invalid');
      }
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
      _logger.e('Failed to fetch autocomplete suggestions: $e');
      throw Exception('Unable to load address suggestions. Please try again.');
    }
  }

  Future<LatLng?> getLatLngFromPlaceId(String placeId) async {
    try {
      if (googleApiKey.isEmpty) {
        throw Exception('Google API key is missing or invalid');
      }
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
      _logger.e('Failed to fetch place details: $e');
      throw Exception('Unable to load place details. Please try again.');
    }
  }
}

class RideService {
  final _fire = FirebaseFirestore.instance;
  final _rtdb = FirebaseDatabase.instance;
  final _logger = Logger();

  String? _lastUid;
  String? get userId {
    final current = FirebaseAuth.instance.currentUser?.uid;
    if (current != null) _lastUid = current;
    return current ?? _lastUid;
  }

  Stream<Map<String, dynamic>?> listenActiveRide() {
    final uid = userId;
    if (uid == null) return const Stream.empty();
    return _rtdb.ref('rides').child(uid).onValue.map((event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      return data != null ? Map<String, dynamic>.from(data) : null;
    });
  }

  Future<void> requestRide(Map<String, dynamic> data) async {
    final uid = userId;
    if (uid == null) throw Exception('User not logged in');

    try {
      final rideId = _rtdb.ref('rides').push().key!;
      await _rtdb.ref('rides/$rideId').set({
        ...data,
        'riderId': uid,
        'rideId': rideId,
        'status': 'pending',
        'createdAt': ServerValue.timestamp,
      });
      await _fire.collection('rides').doc(rideId).set({
        ...data,
        'riderId': uid,
        'rideId': rideId,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      _logger.e('Failed to request ride: $e');
      throw Exception('Unable to request ride. Please try again.');
    }
  }

  Future<void> cancelRide(String id) async {
    final uid = userId;
    if (uid == null) throw Exception('User not logged in');

    try {
      await _rtdb.ref('rides/$id').update({
        'status': 'cancelled',
        'cancelledAt': ServerValue.timestamp,
      });
      await _fire.collection('rides').doc(id).update({
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      _logger.e('Failed to cancel ride: $e');
      throw Exception('Unable to cancel ride. Please try again.');
    }
  }

  Future<void> acceptCounterFare(String rideId, double counterFare) async {
    final uid = userId;
    if (uid == null) throw Exception('User not logged in');

    try {
      await _rtdb.ref('rides/$rideId').update({
        'fare': counterFare,
        'status': 'accepted',
        'acceptedAt': ServerValue.timestamp,
      });
      await _fire.collection('rides').doc(rideId).update({
        'fare': counterFare,
        'status': 'accepted',
        'acceptedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      _logger.e('Failed to accept counter-fare: $e');
      throw Exception('Unable to accept counter-fare. Please try again.');
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

  Stream<List<Map<String, dynamic>>> messages(String rideId) {
    return _rtdb.ref('messages/$rideId').onValue.map((event) {
      final data = event.snapshot.value as Map<dynamic, dynamic>?;
      if (data == null) return [];
      return data.entries.map((e) {
        final msg = e.value as Map<dynamic, dynamic>;
        return {
          'id': e.key,
          'senderId': msg['senderId'],
          'message': msg['message'],
          'timestamp': msg['timestamp'],
        };
      }).toList();
    });
  }

  Future<void> sendMessage(String rideId, String message) async {
    final uid = userId;
    if (uid == null) throw Exception('User not logged in');
    try {
      await _rtdb.ref('messages/$rideId').push().set({
        'senderId': uid,
        'message': message,
        'timestamp': ServerValue.timestamp,
      });
    } catch (e) {
      _logger.e('Failed to send message: $e');
      throw Exception('Unable to send message. Please try again.');
    }
  }
}

class UserService {
  final _fire = FirebaseFirestore.instance;
  final _logger = Logger();

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
    try {
      await _fire
          .collection('users')
          .doc(uid)
          .set(data, SetOptions(merge: true));
    } catch (e) {
      _logger.e('Failed to update profile: $e');
      throw Exception('Unable to update profile. Please try again.');
    }
  }
}

class RatingService {
  final _fire = FirebaseFirestore.instance;
  final _logger = Logger();

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
      _logger.e('Failed to check rating: $e');
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
      _logger.e('Failed to submit rating: $e');
      throw Exception('Unable to submit rating. Please try again.');
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
            return Center(
              child: Text(
                'Error: ${snap.error}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            );
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
                      Text('Base Fare: \$${fare.toStringAsFixed(2)}'),
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
                  Navigator.pop(context);
                }
              : null,
          child: const Text('Submit'),
        ),
      ],
    );
  }
}

class RiderProfilePage extends StatefulWidget {
  const RiderProfilePage({super.key});
  @override
  State<RiderProfilePage> createState() => _RiderProfilePageState();
}

class _RiderProfilePageState extends State<RiderProfilePage> {
  final us = UserService();
  final _displayNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _homeAddressController = TextEditingController();
  final _workAddressController = TextEditingController();
  bool loading = false;
  String? errorMessage;
  final _logger = Logger();

  @override
  void dispose() {
    _displayNameController.dispose();
    _phoneController.dispose();
    _homeAddressController.dispose();
    _workAddressController.dispose();
    super.dispose();
  }

  void _saveProfile() async {
    if (_displayNameController.text.isEmpty || _phoneController.text.isEmpty) {
      setState(() => errorMessage = 'Please complete required fields');
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
        'homeAddress': _homeAddressController.text.trim(),
        'workAddress': _workAddressController.text.trim(),
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Profile updated')));
      }
    } catch (e) {
      setState(() => errorMessage = 'Error: $e');
      _logger.e('Profile update failed: $e');
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
      _logger.e('Logout failed: $e');
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
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            );
          }

          final doc = snap.data!;
          _displayNameController.text = doc['username'] ?? '';
          _phoneController.text = doc['phone'] ?? '';
          _homeAddressController.text = doc['homeAddress'] ?? '';
          _workAddressController.text = doc['workAddress'] ?? '';
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
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  decoration: InputDecoration(
                    labelText: 'Phone',
                    errorText: errorMessage,
                    border: const OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 12),
                TypeAheadField<String>(
                  builder: (context, controller, focusNode) {
                    return TextField(
                      controller: _homeAddressController,
                      focusNode: focusNode,
                      decoration: const InputDecoration(
                        labelText: 'Home Address (optional)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.home),
                      ),
                    );
                  },
                  suggestionsCallback: (pattern) async => await PlaceService()
                      .autoComplete(pattern)
                      .then(
                        (suggestions) => suggestions
                            .map((s) => s['description'] as String)
                            .toList(),
                      ),
                  itemBuilder: (context, suggestion) =>
                      ListTile(title: Text(suggestion)),
                  onSelected: (suggestion) =>
                      _homeAddressController.text = suggestion,
                ),
                const SizedBox(height: 12),
                TypeAheadField<String>(
                  builder: (context, controller, focusNode) {
                    return TextField(
                      controller: _workAddressController,
                      focusNode: focusNode,
                      decoration: const InputDecoration(
                        labelText: 'Work Address (optional)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.work),
                      ),
                    );
                  },
                  suggestionsCallback: (pattern) async => await PlaceService()
                      .autoComplete(pattern)
                      .then(
                        (suggestions) => suggestions
                            .map((s) => s['description'] as String)
                            .toList(),
                      ),
                  itemBuilder: (context, suggestion) =>
                      ListTile(title: Text(suggestion)),
                  onSelected: (suggestion) =>
                      _workAddressController.text = suggestion,
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
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
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
                    backgroundColor: Theme.of(context).colorScheme.error,
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
  final Map<String, dynamic> ride;
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
  final _logger = Logger();

  String? _lastUid;
  String? get currentUid {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) _lastUid = uid;
    return uid ?? _lastUid;
  }

  @override
  void initState() {
    super.initState();
    final data = widget.ride;
    pickup = LatLng(data['pickupLat'], data['pickupLng']);
    dropoff = LatLng(data['dropoffLat'], data['dropoffLng']);
    _markers = {
      Marker(markerId: const MarkerId('pickup'), position: pickup),
      Marker(markerId: const MarkerId('dropoff'), position: dropoff),
    };
    _fetchRoute();
    _updateCurrentLocation();
    _listenDriverLocation();
  }

  Future<void> _fetchRoute() async {
    try {
      final current = await MapService().currentLocation();
      final routeData = await DirectionsService.getRoute(
        current,
        dropoff,
        role: 'rider',
      );
      if (routeData != null && mounted) {
        setState(() {
          _eta = routeData['eta'];
          _polyline = Polyline(
            polylineId: const PolylineId('route'),
            color: Theme.of(context).colorScheme.primary,
            width: 5,
            points: routeData['polyline'],
          );
        });
      }
    } catch (e) {
      setState(() => errorMessage = e.toString());
      _logger.e('RideStatusCard: $errorMessage');
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
      setState(() => errorMessage = e.toString());
      _logger.e('RideStatusCard: $errorMessage');
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

  void _listenDriverLocation() {
    final rideId = widget.ride['id'];
    FirebaseDatabase.instance
        .ref('rides/$rideId')
        .onValue
        .listen(
          (event) {
            final data = event.snapshot.value as Map<dynamic, dynamic>?;
            if (data != null &&
                data['driverLat'] != null &&
                data['driverLng'] != null) {
              final driverPos = LatLng(
                data['driverLat'] as double,
                data['driverLng'] as double,
              );
              _updateDriverMarker(driverPos);
            }
          },
          onError: (e) {
            _logger.e('Failed to listen to driver location: $e');
            setState(
              () => errorMessage = 'Unable to track driver location: $e',
            );
          },
        );
  }

  Future<void> _shareTrip() async {
    try {
      final pickupText = data['pickup'] ?? 'N/A';
      final dropoffText = data['dropoff'] ?? 'N/A';
      final driver = data['driverName'] ?? 'Not Assigned';
      final shareText =
          'I’m on a FemDrive trip from $pickupText to $dropoffText with driver $driver. Track my ride!';
      // ignore: deprecated_member_use
      await Share.share(shareText);
    } catch (e) {
      _logger.e('Failed to share trip: $e');
      ScaffoldMessenger.of(
        // ignore: use_build_context_synchronously
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to share trip: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final driver = data['driverName'] ?? 'Not Assigned';
    final status = (data['status'] ?? 'unknown').toString();
    final pickupText = data['pickup'] ?? 'N/A';
    final dropoffText = data['dropoff'] ?? 'N/A';
    final fare = data['fare']?.toStringAsFixed(2) ?? '--';
    final rideId = widget.ride['id'];
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
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 14,
              ),
            ),
          ),
        SizedBox(
          height: 300,
          child: GoogleMap(
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
          // ignore: deprecated_member_use
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
                  '$pickupText → $dropoffText',
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
                      'Status: $statusText',
                      style: TextStyle(color: statusColor, fontSize: 16),
                    ),
                  ],
                ),
                Text('Fare: \$$fare'),
                Text('Driver: $driver'),
                Text('Ride Type: $rideType'),
                if (note.isNotEmpty) Text('Note: $note'),
                const SizedBox(height: 12),
                if (status == 'accepted' || status == 'in_progress') ...[
                  StreamBuilder<List<Map<String, dynamic>>>(
                    stream: RideService().messages(rideId),
                    builder: (context, snapshot) {
                      if (snapshot.hasError) {
                        return Text(
                          'Error loading messages: ${snapshot.error}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        );
                      }
                      if (!snapshot.hasData) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final messages = snapshot.data!;
                      return Column(
                        children: [
                          SizedBox(
                            height: 100,
                            child: ListView.builder(
                              itemCount: messages.length,
                              itemBuilder: (context, index) {
                                final msg = messages[index];
                                final isMe = msg['senderId'] == currentUid;
                                return ListTile(
                                  title: Text(msg['message']),
                                  subtitle: Text(
                                    DateTime.fromMillisecondsSinceEpoch(
                                      msg['timestamp'],
                                    ).toLocal().toString(),
                                  ),
                                  trailing: Text(isMe ? 'You' : 'Driver'),
                                );
                              },
                            ),
                          ),
                          TextField(
                            decoration: const InputDecoration(
                              labelText: 'Send a message',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: (value) async {
                              if (value.isNotEmpty) {
                                try {
                                  await RideService().sendMessage(
                                    rideId,
                                    value,
                                  );
                                } catch (e) {
                                  // ignore: use_build_context_synchronously
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Failed to send message: $e',
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                        ),
                        onPressed: () async {
                          // Placeholder for emergency_service.dart integration
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Emergency reported (pending implementation)',
                              ),
                            ),
                          );
                        },
                        child: const Text('Emergency'),
                      ),
                      ElevatedButton(
                        onPressed: _shareTrip,
                        child: const Text('Share Trip'),
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
  String? selectedPaymentMethod;
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
  final _logger = Logger();
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
      setState(() => errorMessage = e.toString());
      _logger.e('RideForm: $errorMessage');
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
          color: Theme.of(context).colorScheme.primary,
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
      setState(() => errorMessage = e.toString());
      _logger.e('RideForm: $errorMessage');
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
      final drivers = await nds.fetchNearbyDrivers(
        pcLL!,
        5.0,
        rideType: selectedCar,
      );
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
            // ignore: deprecated_member_use
            fillColor: Theme.of(context).colorScheme.primary.withOpacity(0.1),
            strokeColor: Theme.of(context).colorScheme.primary,
            strokeWidth: 1,
          ),
        );
      });
    } catch (e) {
      setState(() => errorMessage = e.toString());
      _logger.e('RideForm: $errorMessage');
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
  Widget build(BuildContext context) {
    final currentUid = uid;
    return Column(
      children: [
        if (errorMessage != null)
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(
              errorMessage!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 14,
              ),
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
                      fillColor: Theme.of(context).colorScheme.primary
                          // ignore: deprecated_member_use
                          .withOpacity(0.3 * (1 - _radarAnimation!.value)),
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
                      return await ps
                          .autoComplete(pattern)
                          .then(
                            (suggestions) => suggestions
                                .map((s) => s['description'] as String)
                                .toList(),
                          );
                    } catch (e) {
                      setState(() => errorMessage = e.toString());
                      return [];
                    }
                  },
                  itemBuilder: (context, suggestion) =>
                      ListTile(title: Text(suggestion)),
                  onSelected: (suggestion) => pc.text = suggestion,
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
                      return await ps
                          .autoComplete(pattern)
                          .then(
                            (suggestions) => suggestions
                                .map((s) => s['description'] as String)
                                .toList(),
                          );
                    } catch (e) {
                      setState(() => errorMessage = e.toString());
                      return [];
                    }
                  },
                  itemBuilder: (context, suggestion) =>
                      ListTile(title: Text(suggestion)),
                  onSelected: (suggestion) => dc.text = suggestion,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedCar,
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
                DropdownButtonFormField<String>(
                  initialValue: selectedPaymentMethod,
                  decoration: const InputDecoration(
                    labelText: 'Payment Method',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'Credit Card',
                      child: Text('Credit Card'),
                    ),
                    DropdownMenuItem(value: 'Wallet', child: Text('Wallet')),
                    DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                  ],
                  onChanged: (v) => setState(() => selectedPaymentMethod = v),
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
                                backgroundColor: Theme.of(
                                  context,
                                ).colorScheme.secondary,
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
                          currentUid != null &&
                          selectedPaymentMethod != null)
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
                            setState(() => errorMessage = e.toString());
                            _logger.e('RideForm: $errorMessage');
                          }
                        }
                      : null,
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(double.infinity, 48),
                    backgroundColor: Theme.of(context).colorScheme.primary,
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
