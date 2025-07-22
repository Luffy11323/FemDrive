import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:http/http.dart' as http;

const String googleApiKey = 'YOUR_ACTUAL_API_KEY_HERE';

class MapService {
  final poly = PolylinePoints();

  Future<LatLng> currentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition();
      return LatLng(position.latitude, position.longitude);
    } catch (e) {
      throw Exception('Failed to get location: $e');
    }
  }

  Future<List<LatLng>> getRoute(LatLng start, LatLng end) async {
    try {
      final result = await poly.getRouteBetweenCoordinates(
        googleApiKey: googleApiKey,
        request: PolylineRequest(
          origin: PointLatLng(start.latitude, start.longitude),
          destination: PointLatLng(end.latitude, end.longitude),
          mode: TravelMode.driving,
        ),
      );

      if (result.points.isEmpty) {
        throw Exception('No route found');
      }

      return result.points.map((p) => LatLng(p.latitude, p.longitude)).toList();
    } catch (e) {
      throw Exception('Failed to fetch route: $e');
    }
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
    try {
      final response = await http.get(url);
      final data = jsonDecode(response.body);
      if (data['status'] != 'OK') {
        throw Exception('Distance Matrix failed: ${data['status']}');
      }
      final element = data['rows'][0]['elements'][0];
      if (element['status'] != 'OK') {
        throw Exception('Route unavailable: ${element['status']}');
      }
      final distanceMeters = element['distance']['value'];
      final durationSeconds = element['duration']['value'];
      return {
        'distanceKm': distanceMeters / 1000,
        'durationMin': durationSeconds / 60,
      };
    } catch (e) {
      throw Exception('Failed to get rate and ETA: $e');
    }
  }
}
