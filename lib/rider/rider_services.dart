// ignore_for_file: unused_import

import 'dart:convert';
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

class RideService {
  final _firestore = FirebaseFirestore.instance;
  final _rtdb = FirebaseDatabase.instance.ref();
  final _logger = Logger();

  Future<void> requestRide(Map<String, dynamic> rideData, WidgetRef ref) async {
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) throw Exception('User not logged in');

      // Firestore-specific map
      final firestoreRide = {
        ...rideData,
        'riderId': currentUid,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(), // ✅ Firestore timestamp
      };

      // Save ride to Firestore
      final rideRef = await _firestore.collection('rides').add(firestoreRide);
      final rideId = rideRef.id;

      // RTDB-specific map
      final rtdbRide = {
        'id': rideId,
        ...rideData,
        'riderId': currentUid,
        'status': 'pending',
        'createdAt': ServerValue.timestamp, // ✅ RTDB timestamp
      };

      // Mirror ride in Realtime DB
      await _rtdb.child('rides/$currentUid/$rideId').set(rtdbRide);

      // --- 🔹 Subscribe to nearby drivers live stream ---
      final pickupLoc = LatLng(rideData['pickupLat'], rideData['pickupLng']);

      ref.read(driverSearchCenterProvider.notifier).state = pickupLoc;

      ref.read(nearbyDriversProvider.stream).listen((nearbyDrivers) async {
        _logger.i("Nearby drivers updated: $nearbyDrivers");

        // Update dashboard state
        ref
            .read(riderDashboardProvider.notifier)
            .updateNearbyDrivers(nearbyDrivers);

        // Push notifications to drivers
        for (var driver in nearbyDrivers) {
          await _rtdb
              .child('driver_notifications/${driver['id']}/$rideId')
              .set({
                'rideId': rideId,
                'pickup': rideData['pickup'],
                'dropoff': rideData['dropoff'],
                'fare': rideData['fare'],
                'timestamp': ServerValue.timestamp,
              });
        }
      });
    } catch (e) {
      _logger.e('Failed to request ride: $e');
      throw Exception('Unable to request ride: $e');
    }
  }

  Future<void> cancelRide(String rideId) async {
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) throw Exception('User not logged in');
      await _firestore.collection('rides').doc(rideId).update({
        'status': 'cancelled',
      });
      await _rtdb.child('rides/$currentUid/$rideId').remove();
      final snapshot = await _rtdb
          .child('driver_notifications')
          .orderByChild('rideId')
          .equalTo(rideId)
          .get();

      for (var child in snapshot.children) {
        await child.ref.remove();
      }
    } catch (e) {
      _logger.e('Failed to cancel ride: $e');
      throw Exception('Unable to cancel ride: $e');
    }
  }

  Future<void> acceptCounterFare(String rideId, double counterFare) async {
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) throw Exception('User not logged in');
      await _firestore.collection('rides').doc(rideId).update({
        'fare': counterFare,
        'counterFare': null,
        'status': 'accepted',
      });
    } catch (e) {
      _logger.e('Failed to accept counter-fare: $e');
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
    } catch (e) {
      _logger.e('Failed to submit rating: $e');
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
      final location = locations.first;
      return LatLng(location.latitude, location.longitude);
    } catch (e) {
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
