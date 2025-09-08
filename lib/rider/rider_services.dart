//rider_services.dart
// ignore_for_file: unused_import

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:femdrive/rider/nearby_drivers_service.dart';
import 'package:femdrive/rider/rider_dashboard_controller.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:geocoding/geocoding.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:logger/logger.dart';
import '../location/directions_service.dart';
import 'package:femdrive/widgets/payment_services.dart';
import '../rating_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_polyline_algorithm/google_polyline_algorithm.dart';

final String googleApiKey = 'AIzaSyCRpuf1w49Ri0gNiiTPOJcSY7iyhyC-2c4';
// A reactive center for driver search (current location or pickup)
final driverSearchCenterProvider = StateProvider<LatLng?>((ref) => null);

// Nearby drivers stream reacts to the center above
final nearbyDriversProvider =
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
      final center = ref.watch(driverSearchCenterProvider);
      if (center == null) {
        // No center yet → emit empty list once
        return Stream<List<Map<String, dynamic>>>.value(
          const <Map<String, dynamic>>[],
        );
      }
      return NearbyDriversService().streamNearbyDrivers(center);
    });

class RadarSearchingOverlay extends StatefulWidget {
  final LatLng pickup;
  final String message;
  final VoidCallback onCancel;

  // NEW: to animate the map from here
  final GoogleMapController? mapController;

  const RadarSearchingOverlay({
    super.key,
    required this.pickup,
    required this.message,
    required this.onCancel,
    this.mapController,
  });

  @override
  State<RadarSearchingOverlay> createState() => _RadarSearchingOverlayState();
}

class _RadarSearchingOverlayState extends State<RadarSearchingOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  // NEW: zoom-out timer state
  Timer? _zoomTimer;
  // Approx zooms for ~50m, 100m, 200m, 400m, 800m, 1.6km, 3.2km, 5km-ish
  final List<double> _zoomSteps = [
    18.0,
    17.0,
    16.0,
    15.0,
    14.0,
    13.5,
    13.0,
    12.7,
  ];
  int _zoomIndex = 0;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    // Kick off gradual zoom-out, self-contained
    if (widget.mapController != null) {
      // Center immediately at the first step, then expand every 1.5s
      _animateToStep(0);
      _zoomTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
        if (!mounted || widget.mapController == null) return;
        _zoomIndex = (_zoomIndex + 1).clamp(0, _zoomSteps.length - 1);
        _animateToStep(_zoomIndex);

        // stop when we reach last step (~5km view)
        if (_zoomIndex >= _zoomSteps.length - 1) {
          _zoomTimer?.cancel();
          _zoomTimer = null;
        }
      });
    }
  }

  Future<void> _animateToStep(int idx) async {
    try {
      final zoom = _zoomSteps[idx];
      await widget.mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(widget.pickup, zoom),
      );
    } catch (_) {
      /* ignore animate errors */
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    _zoomTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // We DO want to block map gestures while searching, so keep IgnorePointer(false)?
    // To freeze the map, we actually want to absorb pointer events:
    return IgnorePointer(
      ignoring: false, // allow tapping Cancel button
      child: Container(
        color: Colors.black.withAlpha((0.15 * 255).round()),
        child: Stack(
          children: [
            // Pulses (centered on the pickup)
            Center(
              child: AnimatedBuilder(
                animation: _ctl,
                builder: (_, _) {
                  return CustomPaint(
                    painter: _RadarPainter(progress: _ctl.value),
                    size: const Size(220, 220),
                  );
                },
              ),
            ),

            // Message
            Positioned(
              bottom: 140,
              left: 24,
              right: 24,
              child: Column(
                children: const [
                  // keep styles as you had
                ],
              ),
            ),

            // Cancel
            Positioned(
              bottom: 60,
              left: 24,
              right: 24,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: widget.onCancel,
                icon: const Icon(Icons.close),
                label: const Text('Cancel ride'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double progress;
  _RadarPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxR = math.min(size.width, size.height) / 2;
    final bg = Paint()..color = Colors.white.withAlpha((0.15 * 255).round());
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = Colors.white.withAlpha((0.7 * 255).round());

    // base dot
    canvas.drawCircle(center, 6, Paint()..color = Colors.white);

    // 3 expanding rings
    for (var i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1.0;
      final r = 12 + t * (maxR - 12);
      final alpha = (1 - t).clamp(0.0, 1.0);
      ring.color = Colors.white.withAlpha(((0.35 * alpha) * 255).round());
      canvas.drawCircle(center, r, ring);
      canvas.drawCircle(center, r, bg);
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class RideService {
  final _firestore = FirebaseFirestore.instance;
  final _rtdb = FirebaseDatabase.instance.ref();
  final _logger = Logger();

  Future<String> requestRide(
    Map<String, dynamic> rideData,
    WidgetRef ref,
  ) async {
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) throw Exception('User not logged in');

      // --- 1) Firestore ride doc ---
      final firestoreRide = {
        ...rideData,
        'riderId': currentUid,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      };
      final rideRef = await _firestore.collection('rides').add(firestoreRide);
      final rideId = rideRef.id;

      // --- 2) RTDB mirrors ---
      await _rtdb.child('rides/$currentUid/$rideId').set({
        'id': rideId,
        ...rideData,
        'riderId': currentUid,
        'status': 'pending',
        'createdAt': ServerValue.timestamp,
      });

      await _rtdb.child('ridesLive/$rideId').set({
        'status': 'pending',
        'riderId': currentUid,
        'pickupLat': rideData['pickupLat'],
        'pickupLng': rideData['pickupLng'],
        'dropoffLat': rideData['dropoffLat'],
        'dropoffLng': rideData['dropoffLng'],
        'fare': rideData['fare'],
        'rideType': rideData['rideType'],
        'createdAt': ServerValue.timestamp,
      });

      // --- 3) Update search center ---
      final pickupLoc = LatLng(rideData['pickupLat'], rideData['pickupLng']);
      ref.read(driverSearchCenterProvider.notifier).state = pickupLoc;

      // --- 4) Fetch nearby drivers once and notify all ---
      final drivers = await NearbyDriversService()
          .streamNearbyDriversFast(pickupLoc)
          .first
          .timeout(const Duration(seconds: 5), onTimeout: () => []);

      if (drivers.isEmpty) {
        await _rtdb.child('ridesLive/$rideId').update({'status': 'searching'});
        print('[RideService] No drivers found → ride marked as searching');
      } else {
        final Map<String, Object?> updates = {};
        for (final d in drivers) {
          final driverId = (d['id'] ?? '').toString();
          if (driverId.isEmpty) continue;
          final payload = {
            'rideId': rideId,
            'pickup': rideData['pickup'],
            'dropoff': rideData['dropoff'],
            'pickupLat': rideData['pickupLat'],
            'pickupLng': rideData['pickupLng'],
            'dropoffLat': rideData['dropoffLat'],
            'dropoffLng': rideData['dropoffLng'],
            'fare': rideData['fare'],
            'timestamp': ServerValue.timestamp,
          };
          updates['driver_notifications/$driverId/$rideId'] = payload;
          print('[RideService] Queued notify → $driverId for ride=$rideId');
        }
        await _rtdb.update(updates);
        print(
          '[RideService] ✅ Notified ${updates.length} drivers for ride=$rideId',
        );
      }

      return rideId;
    } catch (e) {
      _logger.e('Failed to request ride: $e');
      throw Exception('Unable to request ride: $e');
    }
  }

  Future<void> cancelRide(String rideId) async {
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) throw Exception('User not logged in');

      // Firestore: mark cancelled
      await _firestore.collection('rides').doc(rideId).update({
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
      });

      // Rider mirror: remove (optional if you keep using it)
      await _rtdb.child('rides/$currentUid/$rideId').remove();

      // ✅ Live broadcast
      await _rtdb.child('ridesLive/$rideId').update({
        'status': 'cancelled',
        'cancelledAt': ServerValue.timestamp,
      });

      // Clean driver notifications
      final snapshot = await _rtdb.child('driver_notifications').get();
      for (final driverNode in snapshot.children) {
        final notifRef = driverNode.ref.child(rideId);
        final notif = await notifRef.get();
        if (notif.exists) {
          await notifRef.remove();
        }
      }
    } catch (e) {
      Logger().e('Failed to cancel ride: $e');
      throw Exception('Unable to cancel ride: $e');
    }
  }

  Future<void> acceptCounterFare(String rideId, double counterFare) async {
    try {
      // Firestore
      await _firestore.collection('rides').doc(rideId).update({
        'fare': counterFare,
        'counterFare': null,
        'status': 'accepted',
        'acceptedAt': FieldValue.serverTimestamp(),
      });

      // ✅ Live
      await _rtdb.child('ridesLive/$rideId').update({
        'status': 'accepted',
        'fare': counterFare,
        'acceptedAt': ServerValue.timestamp,
      });
    } catch (e) {
      Logger().e('Failed to accept counter-fare: $e');
      throw Exception('Unable to accept counter-fare: $e');
    }
  }

  Future<void> submitRating({
    required String rideId,
    required String fromUid,
    required String toUid,
    required double rating,
    required String comment,
  }) async {
    try {
      await RatingService().submitRating(
        rideId: rideId,
        fromUid: fromUid,
        toUid: toUid,
        rating: rating,
        comment: comment,
      );
    } catch (e, st) {
      _logger.e('Failed to submit rating', error: e, stackTrace: st);
      throw Exception('Unable to submit rating: $e');
    }
  }
}

class PlacePrediction {
  final String description;
  final String placeId;

  PlacePrediction({required this.description, required this.placeId});

  factory PlacePrediction.fromJson(Map<String, dynamic> json) {
    return PlacePrediction(
      description: json['description'],
      placeId: json['place_id'],
    );
  }
}

class GeocodingService {
  static Future<LatLng?> getLatLngFromAddress(String address) async {
    try {
      final locations = await locationFromAddress(address);
      if (locations.isEmpty) return null;
      final l = locations.first;
      return LatLng(l.latitude, l.longitude);
    } catch (_) {
      return null;
    }
  }

  // NEW: reverse geocode lat/lng -> a readable address string
  static Future<String?> reverseGeocode({
    required double lat,
    required double lng,
  }) async {
    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isEmpty) return null;
      final p = placemarks.first;

      // Build a concise line (tweak to taste)
      final parts = <String>[
        if ((p.name ?? '').isNotEmpty) p.name!,
        if ((p.subLocality ?? '').isNotEmpty) p.subLocality!,
        if ((p.locality ?? '').isNotEmpty) p.locality!,
        if ((p.administrativeArea ?? '').isNotEmpty) p.administrativeArea!,
      ];
      return parts.where((s) => s.trim().isNotEmpty).join(', ');
    } catch (_) {
      return null;
    }
  }
}

class MapService {
  final poly = PolylinePoints(apiKey: googleApiKey);
  final _logger = Logger();

  Future<LatLng> currentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      return LatLng(position.latitude, position.longitude);
    } catch (e) {
      _logger.e('Failed to get current location: $e');
      throw Exception('Unable to get current location. Check permissions.');
    }
  }

  Future<List<LatLng>> getRoute(LatLng start, LatLng end) async {
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${start.latitude},${start.longitude}'
        '&destination=${end.latitude},${end.longitude}'
        '&mode=driving'
        '&key=$googleApiKey',
      );

      final resp = await http.get(url);
      if (resp.statusCode != 200) {
        _logger.e('Directions HTTP ${resp.statusCode}: ${resp.body}');
        return const [];
      }

      final data = jsonDecode(resp.body);
      final status = data['status'] as String? ?? 'UNKNOWN';
      if (status != 'OK') {
        _logger.e('Directions status=$status msg=${data['error_message']}');
        return const [];
      }

      final routes = data['routes'] as List;
      if (routes.isEmpty) return const [];

      final encoded = routes[0]['overview_polyline']['points'] as String?;
      if (encoded == null || encoded.isEmpty) return const [];

      final decoded = decodePolyline(encoded); // List<List<num>>
      return decoded
          .map((e) => LatLng((e[0]).toDouble(), (e[1]).toDouble()))
          .toList();
    } catch (e) {
      _logger.e('Failed to fetch route (Directions JSON): $e');
      return const [];
    }
  }

  Future<List<PlacePrediction>> getPlaceSuggestions(
    String query,
    double lat,
    double lng,
  ) async {
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/place/autocomplete/json'
        '?input=${Uri.encodeQueryComponent(query)}'
        '&location=$lat,$lng'
        '&radius=50000'
        '&key=$googleApiKey',
      );
      final response = await http.get(url);
      final data = jsonDecode(response.body);
      if (data['status'] != 'OK') {
        _logger.e(
          'Autocomplete failed: ${data['status']}, ${data['error_message']}',
        );
        throw Exception('Autocomplete failed: ${data['error_message']}');
      }
      final predictions = (data['predictions'] as List)
          .map((p) => PlacePrediction.fromJson(p))
          .toList();
      return predictions;
    } catch (e) {
      _logger.e('Failed to fetch place suggestions: $e');
      return [];
    }
  }

  Future<LatLng?> getLatLngFromPlaceId(String placeId) async {
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/place/details/json'
        '?place_id=$placeId&key=$googleApiKey',
      );
      final response = await http.get(url);
      final data = jsonDecode(response.body);
      if (data['status'] != 'OK') throw Exception('Details API failed');
      final loc = data['result']['geometry']['location'];
      return LatLng(loc['lat'], loc['lng']);
    } catch (e) {
      _logger.e('Failed to fetch location from place_id: $e');
      return null;
    }
  }

  Future<Map<String, dynamic>> getRateAndEta(
    String pickup,
    String dropoff,
    String rideType,
  ) async {
    try {
      final pickupLoc = await GeocodingService.getLatLngFromAddress(pickup);
      final dropoffLoc = await GeocodingService.getLatLngFromAddress(dropoff);
      if (pickupLoc == null || dropoffLoc == null) {
        throw Exception('Invalid location coordinates');
      }
      return getRateAndEtaFromCoords(pickupLoc, dropoffLoc, rideType);
    } catch (e) {
      _logger.e('Failed to get rate and ETA: $e');
      throw Exception('Unable to calculate rate and ETA');
    }
  }

  Future<Map<String, dynamic>> getRateAndEtaFromCoords(
    LatLng pickup,
    LatLng dropoff,
    String rideType,
  ) async {
    try {
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/distancematrix/json'
        '?origins=${pickup.latitude},${pickup.longitude}'
        '&destinations=${dropoff.latitude},${dropoff.longitude}'
        '&key=$googleApiKey',
      );
      final response = await http.get(url);
      final data = jsonDecode(response.body);
      if (data['status'] != 'OK') throw Exception('Distance Matrix failed');
      final element = data['rows'][0]['elements'][0];
      if (element['status'] != 'OK') throw Exception('Route unavailable');

      final distanceMeters = element['distance']['value'];
      final durationSeconds = element['duration']['value'];
      final distanceKm = distanceMeters / 1000;
      final etaMinutes = durationSeconds / 60;

      final fareBreakdown = PaymentService().calculateFareBreakdown(
        distanceKm: distanceKm,
        rideType: rideType,
      );
      return {
        'total': fareBreakdown['total'],
        'etaMinutes': etaMinutes.round(),
        'distanceKm': distanceKm,
      };
    } catch (e) {
      _logger.e('Failed to get rate and ETA: $e');
      throw Exception('Unable to calculate rate and ETA');
    }
  }
}
