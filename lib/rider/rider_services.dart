// rider_services.dart
// ignore_for_file: unused_import

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:femdrive/driver/driver_services.dart';
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
        return Stream<List<Map<String, dynamic>>>.value(const []);
      }
      return NearbyDriversService().streamNearbyDriversFast(center);
    });

class RadarSearchingOverlay extends StatefulWidget {
  final LatLng pickup;
  final String message;
  final VoidCallback onCancel;
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
  Timer? _zoomTimer;
  final List<double> _zoomSteps = [18.0, 17.0, 16.0, 15.0, 14.0, 13.5, 13.0, 12.7];
  int _zoomIndex = 0;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    if (widget.mapController != null) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!mounted || widget.mapController == null) return;
        _animateToStep(0);
        _zoomTimer = Timer.periodic(const Duration(seconds: 3), (_) {
          if (!mounted || widget.mapController == null) return;
          _zoomIndex = (_zoomIndex + 1).clamp(0, _zoomSteps.length - 1);
          _animateToStep(_zoomIndex);
          if (_zoomIndex >= _zoomSteps.length - 1) {
            _zoomTimer?.cancel();
          }
        });
      });
    }
  }

  Future<void> _animateToStep(int idx) async {
    try {
      final startZoom = await widget.mapController!.getZoomLevel();
      final targetZoom = _zoomSteps[idx];
      const steps = 20;
      const durationMs = 1000;

      for (var i = 1; i <= steps; i++) {
        if (!mounted) return;
        final t = i / steps;
        final easedT = Curves.easeInOut.transform(t);
        final newZoom = startZoom + (targetZoom - startZoom) * easedT;
        await widget.mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(widget.pickup, newZoom),
        );
        await Future.delayed(Duration(milliseconds: durationMs ~/ steps));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _ctl.dispose();
    _zoomTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Container(
      color: Colors.black.withValues(alpha: 0.3),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Spacer(),
          
          // Radar animation
          AnimatedBuilder(
            animation: _ctl,
            builder: (_, _) => CustomPaint(
              painter: _RadarPainter(progress: _ctl.value),
              size: const Size(240, 240),
            ),
          ),
          
          const SizedBox(height: 40),
          
          // Message
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              children: [
                Text(
                  widget.message,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'This may take a moment...',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          
          const Spacer(),
          
          // Cancel button
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
            child: FilledButton.tonal(
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 56),
                backgroundColor: theme.colorScheme.errorContainer,
                foregroundColor: theme.colorScheme.onErrorContainer,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: widget.onCancel,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.close_rounded),
                  const SizedBox(width: 8),
                  Text(
                    'Cancel Search',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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
    
    // Background circles
    final bgPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.blue.withValues(alpha: 0.2);
    
    for (var i = 1; i <= 3; i++) {
      canvas.drawCircle(center, (maxR / 3) * i, bgPaint);
    }
    
    // Center dot with glow
    final glowPaint = Paint()
      ..color = Colors.blue.withValues(alpha: 0.3)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawCircle(center, 12, glowPaint);
    
    final centerDot = Paint()..color = Colors.blue;
    canvas.drawCircle(center, 8, centerDot);

    // Animated rings
    for (var i = 0; i < 3; i++) {
      final t = (progress + i / 3) % 1.0;
      final r = 16 + t * (maxR - 16);
      final alpha = (1 - t).clamp(0.0, 1.0);
      
      final ringPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.blue.withValues(alpha: 0.6 * alpha);
      
      canvas.drawCircle(center, r, ringPaint);
      
      final fillPaint = Paint()
        ..color = Colors.blue.withValues(alpha: 0.1 * alpha)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, r, fillPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _RadarPainter oldDelegate) =>
      oldDelegate.progress != progress;
}


/* --------------------------------------------------------------
   The rest of the file (RideService, MapService, chat, etc.)
   remains exactly as you provided – no changes were needed there.
   -------------------------------------------------------------- */

class RideService {
  final _firestore = FirebaseFirestore.instance;
  final _rtdb = FirebaseDatabase.instance.ref();
  final _logger = Logger();

  Future<String> requestRide(Map<String, dynamic> rideData) async {
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) throw Exception('User not logged in');

      // --- 1) Firestore ride doc (canonical) ---
      final firestoreRide = {
        ...rideData,
        'riderId': currentUid,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      };
      final rideRef = await _firestore.collection('rides').add(firestoreRide);
      final rideId = rideRef.id;
      // --- 2) RTDB mirrors for fast UI / dispatch ---
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

      // --- 3) Nearby drivers (single snapshot) & fan-out notifications ---
      final pickupLoc = LatLng(
        (rideData['pickupLat'] as num).toDouble(),
        (rideData['pickupLng'] as num).toDouble(),
      );

      final drivers = await NearbyDriversService()
          .streamNearbyDriversFast(pickupLoc)
          .first
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => <Map<String, dynamic>>[],
          );

      // Filter drivers by the selected rideType
      String norm(String s) => s.toLowerCase().trim();
      final wantedType = norm((rideData['rideType'] ?? '').toString());
      final filteredDrivers = drivers
          .where((d) => norm((d['rideType'] ?? '').toString()) == wantedType)
          .toList();

      if (filteredDrivers.isEmpty) {
        await _rtdb.child('ridesLive/$rideId').update({'status': 'searching'});
        _logger.i(
          '[RideService] No drivers found for type "$wantedType" → ride $rideId marked as searching',
        );
      } else {
        final Map<String, Object?> updates = {};
        var count = 0;
        for (final d in filteredDrivers) {
          final driverId = (d['id'] ?? d['uid'])?.toString();
          if (driverId == null || driverId.isEmpty) continue;

          updates['driver_notifications/$driverId/$rideId'] = {
            'rideId': rideId,
            'pickup': rideData['pickup'],
            'dropoff': rideData['dropoff'],
            'pickupLat': rideData['pickupLat'],
            'pickupLng': rideData['pickupLng'],
            'dropoffLat': rideData['dropoffLat'],
            'dropoffLng': rideData['dropoffLng'],
            'fare': rideData['fare'],
            'rideType': wantedType,
            'timestamp': ServerValue.timestamp,
          };
          count++;
        }
        if (updates.isNotEmpty) {
          await _rtdb.update(updates);
        }
        _logger.i(
          '[RideService] Notified $count "$wantedType" drivers for ride $rideId',
        );
      }

      return rideId;
    } catch (e, st) {
      _logger.e('requestRide failed', error: e, stackTrace: st);
      throw Exception('Unable to request ride: $e');
    }
  }

  Future<void> expireCounterFare(String rideId) async {
    try {
      await _firestore.collection('rides').doc(rideId).update({
        'counterFare': FieldValue.delete(),
        'counterExpiredAt': FieldValue.serverTimestamp(),
      });

      await _rtdb.child('ridesLive/$rideId').update({
        'counterFare': null,
        'counterExpiredAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      });
    } catch (e, st) {
      _logger.e('expireCounterFare failed', error: e, stackTrace: st);
      throw Exception('Unable to expire counter: $e');
    }
  }

  Future<void> cancelRide(String rideId) async {
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) throw Exception('User not logged in');

      await _firestore.collection('rides').doc(rideId).update({
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
        'driverId': FieldValue.delete(),
        'driverName': FieldValue.delete(),
      });

      try {
        await _rtdb.child('rides/$currentUid/$rideId').remove();
      } catch (_) {}

      await _rtdb.child('ridesLive/$rideId').update({
        'status': 'cancelled',
        'cancelledAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      });

      final notifsSnap = await _rtdb.child('driver_notifications').get();
      final updates = <String, Object?>{};
      if (notifsSnap.exists && notifsSnap.value is Map) {
        final map = notifsSnap.value as Map;
        map.forEach((driverKey, ridesMap) {
          if (ridesMap is Map && ridesMap.containsKey(rideId)) {
            updates['driver_notifications/$driverKey/$rideId'] = null;
          }
        });
      }
      if (updates.isNotEmpty) {
        await _rtdb.update(updates);
      }

      await _rtdb.child('rides_pending/$rideId').remove();
      await _rtdb.child('rideRequests/$rideId').remove();
    } catch (e) {
      Logger().e('Failed to cancel ride: $e');
      throw Exception('Unable to cancel ride: $e');
    }
  }

  Future<void> fanoutDeleteDriverNotificationsForRide(String rideId) async {
    final root = FirebaseDatabase.instance.ref();

    try {
      final snap = await root.child(AppPaths.driverNotifications).get();
      if (!snap.exists || snap.value is! Map) return;

      final updates = <String, Object?>{};
      final map = Map<Object?, Object?>.from(snap.value as Map);

      map.forEach((driverKey, ridesMap) {
        if (ridesMap is Map && ridesMap.containsKey(rideId)) {
          updates['${AppPaths.driverNotifications}/$driverKey/$rideId'] = null;
        }
      });

      if (updates.isNotEmpty) {
        await root.update(updates);
      }
    } catch (e) {
      // Best-effort cleanup
    }
  }

  Future<void> acceptCounterFare(String rideId, double counterFare) async {
    final fire = FirebaseFirestore.instance;
    final rtdb = FirebaseDatabase.instance.ref();
    final rideRef = fire.collection(AppPaths.ridesCollection).doc(rideId);

    String? driverId;

    await fire.runTransaction((txn) async {
      final snap = await txn.get(rideRef);
      if (!snap.exists) throw Exception('Ride not found');
      final data = snap.data() as Map<String, dynamic>;

      final status = (data[AppFields.status] ?? '').toString();
      if (status == RideStatus.cancelled || status == RideStatus.completed) {
        throw Exception('Ride is no longer active');
      }

      String proposedBy =
          (data['counterDriverId'] ?? data['counter_driver_id'] ?? '')
              .toString();

      if (proposedBy.isEmpty) {
        try {
          final live = await rtdb.child('${AppPaths.ridesLive}/$rideId').get();
          final liveMap = (live.value as Map?)?.cast<String, dynamic>();
          proposedBy =
              (liveMap?['counterDriverId'] ??
                      liveMap?['counter_driver_id'] ??
                      '')
                  .toString();
        } catch (_) {}
      }

      if (proposedBy.isEmpty) {
        throw Exception('Missing counterDriverId');
      }

      driverId = proposedBy;

      txn.update(rideRef, {
        AppFields.fare: counterFare,
        'counterFare': FieldValue.delete(),
        'counterDriverId': FieldValue.delete(),
        'counter_driver_id': FieldValue.delete(),
        AppFields.status: RideStatus.accepted,
        AppFields.driverId: driverId,
        AppFields.acceptedAt: FieldValue.serverTimestamp(),
      });
    });

    final now = ServerValue.timestamp;
    await rtdb.child('${AppPaths.ridesLive}/$rideId').update({
      AppFields.status: RideStatus.accepted,
      AppFields.fare: counterFare,
      AppFields.driverId: driverId,
      'counterFare': null,
      'counterDriverId': null,
      AppFields.acceptedAt: now,
      AppFields.updatedAt: now,
    });

    try {
      final riderId = FirebaseAuth.instance.currentUser?.uid;
      if (riderId != null) {
        await rtdb.child('rides/$riderId/$rideId').update({
          'counterFare': null,
          'counterDriverId': null,
          'updatedAt': now,
        });
      }
    } catch (_) {}

    try {
      await rtdb.child('${AppPaths.ridesPendingA}/$rideId').remove();
    } catch (_) {}
    try {
      await rtdb.child('${AppPaths.ridesPendingB}/$rideId').remove();
    } catch (_) {}

    try {
      final notifsSnap = await rtdb.child(AppPaths.driverNotifications).get();
      if (notifsSnap.exists && notifsSnap.value is Map) {
        final map = Map<Object?, Object?>.from(notifsSnap.value as Map);
        final updates = <String, Object?>{};

        map.forEach((driverKey, ridesMap) {
          if (ridesMap is Map && ridesMap.containsKey(rideId)) {
            updates['${AppPaths.driverNotifications}/$driverKey/$rideId'] =
                null;
          }
        });

        if (updates.isNotEmpty) {
          await rtdb.update(updates);
        }
      }
    } catch (_) {}

    if (driverId != null && driverId!.isNotEmpty) {
      try {
        await rtdb.child('${AppPaths.notifications}/$driverId').push().set({
          AppFields.type: OfferType.rideAccepted,
          AppFields.rideId: rideId,
          AppFields.timestamp: now,
        });
      } catch (_) {}
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

final riderServiceProvider = Provider<RideService>((ref) => RideService());
final riderMessagesProvider =
    StreamProvider.family<List<Map<String, dynamic>>, String>((ref, rideId) {
      final svc = ref.watch(
        riderServiceProvider,
      ); // you already expose RiderService
      return svc.listenMessages(rideId);
    });
final riderCurrentUserIdProvider = Provider<String?>(
  (_) => FirebaseAuth.instance.currentUser?.uid,
);

class ChatFields {
  static const senderId = 'senderId';
  static const text = 'text';
  static const timestamp = 'timestamp';
}

extension RiderChat on RideService {
  DatabaseReference get _db => FirebaseDatabase.instance.ref();
  FirebaseAuth get _auth => FirebaseAuth.instance;

  /// Send a chat message to /rides/{rideId}/messages via server endpoint
  Future<void> sendMessage(String rideId, String message) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw Exception('Not logged in');
    if (rideId.isEmpty || message.trim().isEmpty) return;

    try {
      final response = await http.post(
        Uri.parse('https://fem-drive.vercel.app/rides/$rideId/messages'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'senderId': uid,
          'text': message.trim(),
        }),
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to send message: ${response.body}');
      }
    } catch (e) {
      debugPrint('Error sending message: $e');
      rethrow;
    }
  }

  /// Live stream of messages sorted by timestamp ASC (unchanged)
  Stream<List<Map<String, dynamic>>> listenMessages(String rideId) {
    final ref = _db.child('rides/$rideId/messages');
    return ref.onValue.map((event) {
      final raw = event.snapshot.value as Map?;
      if (raw == null) return <Map<String, dynamic>>[];

      final list = raw.entries.map((e) {
        final m = Map<String, dynamic>.from(e.value as Map);
        m['id'] = e.key;
        return m;
      }).toList();

      list.sort((a, b) {
        final ta = (a[ChatFields.timestamp] as num?)?.toInt() ?? 0;
        final tb = (b[ChatFields.timestamp] as num?)?.toInt() ?? 0;
        return ta.compareTo(tb);
      });
      return list;
    });
  }
}
class RiderChatController extends StateNotifier<AsyncValue<void>> {
  RiderChatController(this.ref) : super(const AsyncData(null));
  final Ref ref;

  Future<void> send(String rideId, String text) async {
    if (text.trim().isEmpty) return;
    state = const AsyncLoading();
    try {
      await ref.read(riderServiceProvider).sendMessage(rideId, text.trim());
      state = const AsyncData(null);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }
}

final riderChatControllerProvider =
    StateNotifierProvider<RiderChatController, AsyncValue<void>>(
      (ref) => RiderChatController(ref),
    );

class RiderChatPage extends ConsumerStatefulWidget {
  final String rideId;
  final String? otherDisplayName; // optional title (driver name)
  const RiderChatPage({super.key, required this.rideId, this.otherDisplayName});

  @override
  ConsumerState<RiderChatPage> createState() => _RiderChatPageState();
}

class _RiderChatPageState extends ConsumerState<RiderChatPage> {
  final _text = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    await ref.read(riderChatControllerProvider.notifier).send(widget.rideId, t);
    _text.clear();
    await Future.delayed(const Duration(milliseconds: 40));
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent + 72,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(riderCurrentUserIdProvider);
    final msgs = ref.watch(riderMessagesProvider(widget.rideId));
    final sending = ref.watch(riderChatControllerProvider).isLoading;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.otherDisplayName == null
              ? 'Chat'
              : 'Chat with ${widget.otherDisplayName}',
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: msgs.when(
              data: (list) {
                if (list.isEmpty) {
                  return const Center(child: Text('Say hi 👋'));
                }

                // Add post frame callback to scroll to the bottom
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scroll.hasClients) {
                    _scroll.animateTo(
                      _scroll.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  }
                });

                return ListView.separated(
                  controller: _scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 16,
                  ),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final m = list[i];
                    final sender = m[ChatFields.senderId]?.toString();
                    final text = (m[ChatFields.text] ?? '').toString();
                    final ts = (m[ChatFields.timestamp] as num?)?.toInt();
                    final isMe = (sender != null && sender == uid);

                    final timeStr = ts == null
                        ? ''
                        : DateTime.fromMillisecondsSinceEpoch(
                            ts,
                          ).toLocal().toString().substring(11, 16);

                    return Align(
                      alignment: isMe
                          ? Alignment.centerRight
                          : Alignment.centerLeft,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: isMe
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Colors.grey.shade200,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                          child: Column(
                            crossAxisAlignment: isMe
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              Text(text),
                              const SizedBox(height: 2),
                              Text(
                                timeStr,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: Colors.black54),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Chat error: $e')),
            ),
          ),

          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      decoration: const InputDecoration(
                        hintText: 'Type a message…',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: sending ? null : _send,
                    child: sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}