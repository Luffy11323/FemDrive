import 'dart:convert';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

class DirectionsService {
  static const _apiKey = 'AIzaSyCRpuf1w49Ri0gNiiTPOJcSY7iyhyC-2c4';

  static Future<Map<String, dynamic>?> getRoute(LatLng from, LatLng to) async {
    try {
      final url =
          'https://maps.googleapis.com/maps/api/directions/json?origin=${from.latitude},${from.longitude}&destination=${to.latitude},${to.longitude}&key=$_apiKey';

      final res = await http.get(Uri.parse(url));

      if (res.statusCode != 200) {
        throw Exception('Failed to fetch directions: ${res.statusCode}');
      }

      final data = jsonDecode(res.body);
      if ((data['routes'] as List).isEmpty) {
        throw Exception('No routes found');
      }

      final route = data['routes'][0];
      final leg = route['legs'][0];
      final duration = leg['duration']['text'];

      final points = PolylinePoints.decodePolyline(
        route['overview_polyline']['points'],
      ).map((p) => LatLng(p.latitude, p.longitude)).toList();

      return {'polyline': points, 'eta': duration};
    } catch (e) {
      if (kDebugMode) {
        print('DirectionsService: Error fetching route: $e');
      }
      throw Exception('Failed to fetch route: $e');
    }
  }
}
