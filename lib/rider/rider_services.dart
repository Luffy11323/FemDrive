// ignore_for_file: unused_import

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
import 'package:logger/logger.dart';
import '../location/directions_service.dart';
import 'nearby_drivers_service.dart';
import 'package:femdrive/widgets/payment_services.dart';
import '../rating_service.dart';

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

  Future<List<String>> getPlaceSuggestions(
    String query,
    double lat,
    double lng,
  ) async {
    try {
      if (googleApiKey.isEmpty) {
        throw Exception('Google API key is missing or invalid');
      }
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/place/autocomplete/json'
        '?input=$query'
        '&location=$lat,$lng'
        '&radius=50000'
        '&key=$googleApiKey',
      );
      final response = await http.get(url);
      final data = jsonDecode(response.body);
      if (data['status'] != 'OK') throw Exception('Autocomplete failed');
      return (data['predictions'] as List)
          .map((p) => p['description'] as String)
          .toList();
    } catch (e) {
      _logger.e('Failed to fetch place suggestions: $e');
      return [];
    }
  }

  Future<Map<String, dynamic>> getRateAndEta(
    String pickup,
    String dropoff,
    String rideType,
  ) async {
    try {
      if (googleApiKey.isEmpty) {
        throw Exception('Google API key is missing or invalid');
      }
      final pickupLoc = (await GeocodingService.getLatLngFromAddress(pickup))!;
      final dropoffLoc = (await GeocodingService.getLatLngFromAddress(
        dropoff,
      ))!;
      final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/distancematrix/json'
        '?origins=${pickupLoc.latitude},${pickupLoc.longitude}'
        '&destinations=${dropoffLoc.latitude},${dropoffLoc.longitude}'
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
      throw Exception('Unable to calculate rate and ETA: $e');
    }
  }
}

class RideService {
  final _firestore = FirebaseFirestore.instance;
  final _rtdb = FirebaseDatabase.instance.ref();
  final _logger = Logger();

  Future<void> requestRide(Map<String, dynamic> rideData) async {
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) throw Exception('User not logged in');
      rideData['riderId'] = currentUid;
      rideData['status'] = 'pending';
      rideData['createdAt'] = FieldValue.serverTimestamp();

      final rideRef = await _firestore.collection('rides').add(rideData);
      final rideId = rideRef.id;
      await _rtdb.child('rides/$currentUid/$rideId').set({
        'id': rideId,
        ...rideData,
      });

      // Notify nearby drivers
      final pickupLoc = GeoPoint(rideData['pickupLat'], rideData['pickupLng']);
      final nearbyDrivers = await NearbyDriversService().getNearbyDrivers(
        LatLng(pickupLoc.latitude, pickupLoc.longitude),
        rideData['rideType'],
      );
      for (var driver in nearbyDrivers) {
        await _rtdb.child('driver_notifications/${driver['uid']}/$rideId').set({
          'rideId': rideId,
          'pickup': rideData['pickup'],
          'dropoff': rideData['dropoff'],
          'fare': rideData['fare'],
          'timestamp': ServerValue.timestamp,
        });
      }
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
