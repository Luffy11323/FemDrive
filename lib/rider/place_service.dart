import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

/// Replace with your own Google Maps API key
const String googleApiKey = 'AIzaSyCRpuf1w49Ri0gNiiTPOJcSY7iyhyC-2c4';

class PlaceService {
  /// Geocode an address string to coordinates
  Future<LatLng?> geocodeFromText(String text) async {
    try {
      final locations = await locationFromAddress(text);
      if (locations.isNotEmpty) {
        final loc = locations.first;
        return LatLng(loc.latitude, loc.longitude);
      }
    } catch (e) {
      debugPrint("Geocoding failed: $e");
      return null;
    }
    return null;
  }

  /// Autocomplete location names using Google Places API
  Future<List<Map<String, dynamic>>> autoComplete(String input) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/autocomplete/json?input=$input&key=$googleApiKey',
    );

    try {
      final response = await http.get(url);
      final data = json.decode(response.body);

      if (data['status'] == 'OK') {
        return List<Map<String, dynamic>>.from(data['predictions']);
      } else {
        debugPrint("Autocomplete failed: ${data['status']}");
      }
    } catch (e) {
      debugPrint("Autocomplete exception: $e");
    }

    return [];
  }

  /// Get LatLng coordinates from a Place ID using Google Places API
  Future<LatLng?> getLatLngFromPlaceId(String placeId) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/place/details/json?place_id=$placeId&key=$googleApiKey',
    );

    try {
      final response = await http.get(url);
      final data = json.decode(response.body);

      if (data['status'] == 'OK') {
        final location = data['result']['geometry']['location'];
        return LatLng(location['lat'], location['lng']);
      } else {
        debugPrint("Place details failed: ${data['status']}");
      }
    } catch (e) {
      debugPrint("Place ID lookup failed: $e");
    }

    return null;
  }
}
