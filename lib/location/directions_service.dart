import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:logger/logger.dart';

class DirectionsService {
  static final _apiKey = 'AIzaSyCRpuf1w49Ri0gNiiTPOJcSY7iyhyC-2c4';
  static final _logger = Logger();

  /// In-memory cache to avoid repeated API calls for the same route
  static final Map<String, Map<String, dynamic>> _routeCache = {};

  /// Fetches route between [from] and [to].
  /// Returns:
  /// - overview_polyline (encoded string & decoded points)
  /// - etaText / etaSeconds
  /// - distanceKm
  /// - bounds
  /// - steps: List of { start:LatLng, end:LatLng, maneuver:String?, distanceMeters:int, durationSec:int, points:List< LatLng> }
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

      final wpString = (waypoints != null && waypoints.isNotEmpty)
          ? '&waypoints=${waypoints.map((p) => '${p.latitude},${p.longitude}').join('|')}'
          : '';

      final url =
          'https://maps.googleapis.com/maps/api/directions/json?origin=${from.latitude},${from.longitude}&destination=${to.latitude},${to.longitude}$wpString&key=$_apiKey';

      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) {
        throw Exception('Failed to fetch directions: ${res.statusCode}');
      }

      final data = jsonDecode(res.body);
      final routes = (data['routes'] as List?) ?? const [];
      if (routes.isEmpty) throw Exception('No routes found');

      final route = routes.first;
      final legs = (route['legs'] as List?) ?? const [];
      if (legs.isEmpty) throw Exception('No legs found');

      final leg = legs.first;

      // --- NEW: step extraction ---
      final rawSteps = (leg['steps'] as List? ?? []);
      final steps = rawSteps.map((s) {
        Map end = (s['end_location'] as Map? ?? const {});
        Map start = (s['start_location'] as Map? ?? const {});
        final enc = (s['polyline']?['points'] as String?) ?? '';
        return {
          'start': {'lat': (start['lat'] ?? 0.0), 'lng': (start['lng'] ?? 0.0)},
          'end': {'lat': (end['lat'] ?? 0.0), 'lng': (end['lng'] ?? 0.0)},
          'html': (s['html_instructions'] as String? ?? ''),
          'maneuver': (s['maneuver'] as String? ?? ''),
          'distanceM': (s['distance']?['value'] as int? ?? 0),
          'polyline': enc,
        };
      }).toList();

      final encoded = (route['overview_polyline']?['points'] as String?) ?? '';
      final points = _decodePolyline(encoded);

      final durationText = (leg['duration']?['text'] as String?) ?? '';
      final durationSeconds = (leg['duration']?['value'] as num?)?.toInt() ?? 0;
      final distanceKm =
          ((leg['distance']?['value'] as num?)?.toDouble() ?? 0) / 1000.0;

      final result = {
        'overview_polyline': {'points': encoded, 'decoded': points},
        'points': points, // kept for backward compatibility
        'etaText': durationText,
        'etaSeconds': durationSeconds,
        'distanceKm': distanceKm,
        'bounds': route['bounds'],

        // --- NEW: add steps to result ---
        'steps': steps,

        'role': role,
      };

      _routeCache[cacheKey] = result;
      return result;
    } catch (e) {
      _logger.e('DirectionsService: Error fetching route: $e');
      return null; // Safe failure
    }
  }

  /// Distance-only helper (km)
  static Future<double> getDistance(LatLng from, LatLng to) async {
    try {
      final url =
          'https://maps.googleapis.com/maps/api/directions/json?origin=${from.latitude},${from.longitude}&destination=${to.latitude},${to.longitude}&key=$_apiKey';

      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) {
        throw Exception('Failed to fetch directions: ${res.statusCode}');
      }

      final data = jsonDecode(res.body);
      final routes = data['routes'] as List? ?? const [];
      if (routes.isEmpty) return 0.0;

      final leg = (routes.first['legs'] as List?)?.first;
      final distanceMeters = (leg?['distance']?['value'] as num?)?.toInt() ?? 0;
      return distanceMeters / 1000.0;
    } catch (e) {
      _logger.w('DirectionsService: Failed to fetch distance: $e');
      return 0.0;
    }
  }

  /// Low-level encoded polyline decoder
  static List<LatLng> _decodePolyline(String encoded) {
    final pts = <LatLng>[];
    int index = 0, lat = 0, lng = 0;

    while (index < encoded.length) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlat = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlng = (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
      lng += dlng;

      pts.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return pts;
  }

  /// Clear cache (e.g., when starting a fresh ride)
  static void clearCache() => _routeCache.clear();
}
