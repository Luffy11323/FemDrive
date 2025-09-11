// lib/navigation/directions_http.dart
import 'dart:convert';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;

class DirectionsHttp {
  final String apiKey = 'AIzaSyCRpuf1w49Ri0gNiiTPOJcSY7iyhyC-2c4';
  DirectionsHttp(String _);

  /// Returns {
  ///   "points": List< LatLng>,
  ///   "steps": List< Map< String,dynamic>>  // {primaryText, street, end:{lat,lng}, maneuver, durationSec, distanceM}
  ///   "totalMeters": double,
  ///   "totalSeconds": int
  /// }
  Future<Map<String, dynamic>> fetchRoute(LatLng origin, LatLng dest) async {
    final url =
        'https://maps.googleapis.com/maps/api/directions/json'
        '?origin=${origin.latitude},${origin.longitude}'
        '&destination=${dest.latitude},${dest.longitude}'
        '&mode=driving&alternatives=false&key=$apiKey';

    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw Exception(
        'Directions HTTP ${resp.statusCode}: ${resp.reasonPhrase}',
      );
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final status = (data['status'] as String?) ?? 'UNKNOWN';
    if (status != 'OK') {
      throw Exception(
        'Directions error: $status ${data['error_message'] ?? ''}',
      );
    }

    final route = (data['routes'] as List).first;
    final leg = (route['legs'] as List).first;

    final polyStr = route['overview_polyline']['points'] as String;
    final points = _decodePolyline(polyStr);

    final steps = <Map<String, dynamic>>[];
    for (final s in (leg['steps'] as List)) {
      final html = (s['html_instructions'] as String?) ?? '';
      final primary = html.replaceAll(RegExp(r'<[^>]*>'), '');
      String street = '';
      final m = RegExp(r'on ([^<]+)').firstMatch(primary);
      if (m != null) street = m.group(1)!;

      final end = s['end_location'] as Map<String, dynamic>;
      steps.add({
        'primaryText': primary,
        'street': street,
        'maneuver': (s['maneuver'] as String?) ?? '',
        'end': {
          'lat': (end['lat'] as num).toDouble(),
          'lng': (end['lng'] as num).toDouble(),
        },
        'distanceM': (s['distance']?['value'] as num?)?.toDouble() ?? 0.0,
        'durationSec': (s['duration']?['value'] as num?)?.toInt() ?? 0,
      });
    }

    final totalMeters = (leg['distance']?['value'] as num?)?.toDouble() ?? 0.0;
    final totalSeconds = (leg['duration']?['value'] as num?)?.toInt() ?? 0;

    return {
      'points': points,
      'steps': steps,
      'totalMeters': totalMeters,
      'totalSeconds': totalSeconds,
    };
  }

  List<LatLng> _decodePolyline(String poly) {
    final List<LatLng> points = [];
    int index = 0, lat = 0, lng = 0;

    while (index < poly.length) {
      int b, shift = 0, result = 0;
      do {
        b = poly.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = poly.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }
    return points;
  }
}
