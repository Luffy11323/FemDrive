import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

class DirectionsService {
  static final _apiKey = dotenv.env['GOOGLE_API_KEY'] ?? '';
  static final _logger = Logger();

  static final Map<String, Map<String, dynamic>> _routeCache = {};

  /// 🔹 Fetch directions between two coordinates
  static Future<Map<String, dynamic>?> getRoute(
    LatLng from,
    LatLng to, {
    required String role,
    List<LatLng>? waypoints,
  }) async {
    try {
      final cacheKey =
          '${from.latitude},${from.longitude}->${to.latitude},${to.longitude}:$role:${waypoints ?? ''}';
      if (_routeCache.containsKey(cacheKey)) {
        return _routeCache[cacheKey];
      }

      final wpString = waypoints != null && waypoints.isNotEmpty
          ? '&waypoints=${waypoints.map((p) => '${p.latitude},${p.longitude}').join('|')}'
          : '';

      final url =
          'https://maps.googleapis.com/maps/api/directions/json?origin=${from.latitude},${from.longitude}&destination=${to.latitude},${to.longitude}$wpString&key=$_apiKey';

      final res = await http.get(Uri.parse(url));

      if (res.statusCode != 200) {
        _logger.e('HTTP error: ${res.statusCode}, ${res.body}');
        throw Exception(
          'Failed to fetch directions: ${res.statusCode} - ${res.body}',
        );
      }

      final data = jsonDecode(res.body);
      if ((data['routes'] as List).isEmpty) {
        _logger.e('No routes found: ${data['status']}');
        throw Exception('No routes found: ${data['status']}');
      }

      final route = data['routes'][0];
      final leg = route['legs'][0];

      final durationText = leg['duration']['text'];
      final durationSeconds = leg['duration']['value'];
      final distanceKm = (leg['distance']['value'] as int) / 1000.0;

      final points = PolylinePoints.decodePolyline(
        route['overview_polyline']['points'],
      ).map((p) => LatLng(p.latitude, p.longitude)).toList();

      final result = {
        'polyline': points,
        'etaText': durationText,
        'etaSeconds': durationSeconds,
        'distanceKm': distanceKm,
        'bounds': route['bounds'],
        'role': role,
      };

      _routeCache[cacheKey] = result;
      return result;
    } catch (e) {
      _logger.e('DirectionsService: Error fetching route: $e');
      return null;
    }
  }

  /// 🔹 Get just the distance
  static Future<double> getDistance(LatLng from, LatLng to) async {
    try {
      final route = await getRoute(from, to, role: 'rider');
      return route?['distanceKm'] ?? 0.0;
    } catch (e) {
      _logger.w('Failed to fetch distance: $e');
      return 0.0;
    }
  }

  /// 🔹 Autocomplete Places API
  static Future<List<Map<String, String>>> getAutocompleteSuggestions(
    String input,
    LatLng location,
  ) async {
    try {
      final url =
          'https://maps.googleapis.com/maps/api/place/autocomplete/json'
          '?input=${Uri.encodeComponent(input)}'
          '&location=${location.latitude},${location.longitude}'
          '&radius=50000'
          '&key=$_apiKey';

      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200)
        throw Exception('Failed to fetch autocomplete');

      final data = jsonDecode(res.body);
      final predictions = data['predictions'] as List;

      return predictions.map<Map<String, String>>((p) {
        return {'description': p['description'], 'placeId': p['place_id']};
      }).toList();
    } catch (e) {
      _logger.e('Autocomplete error: $e');
      return [];
    }
  }

  /// 🔹 Get place details using Place ID
  static Future<LatLng?> getPlaceCoordinates(String placeId) async {
    try {
      final url =
          'https://maps.googleapis.com/maps/api/place/details/json'
          '?place_id=$placeId&key=$_apiKey';

      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200)
        throw Exception('Failed to fetch place details');

      final data = jsonDecode(res.body);
      final location = data['result']['geometry']['location'];
      return LatLng(location['lat'], location['lng']);
    } catch (e) {
      _logger.e('Place details error: $e');
      return null;
    }
  }

  static void clearCache() => _routeCache.clear();
}
