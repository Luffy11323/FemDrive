//rider_services.dart
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
// nearby drivers (FAST RTDB) centered on driverSearchCenterProvider
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
    duration: const Duration(seconds: 3),
  )..repeat();

  if (widget.mapController != null) {
    Future.delayed(const Duration(seconds: 2), () {
      if (!mounted || widget.mapController == null) return;
      _animateToStep(0);
      _zoomTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (!mounted || widget.mapController == null) return;
        _zoomIndex = (_zoomIndex + 1).clamp(0, _zoomSteps.length - 1);
        _animateToStep(_zoomIndex);
        if (_zoomIndex >= _zoomSteps.length - 1) {
          _zoomTimer?.cancel();
          _zoomTimer = null;
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
    // ignore: unused_local_variable
    final stepSize = (targetZoom - startZoom) / steps;

    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final easedT = Curves.easeInOut.transform(t); // Apply easing
      final newZoom = startZoom + (targetZoom - startZoom) * easedT;
      await widget.mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(widget.pickup, newZoom),
      );
      await Future.delayed(Duration(milliseconds: durationMs ~/ steps));
    }
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

  Future<String> requestRide(Map<String, dynamic> rideData) async {
    try {
      final currentUid = FirebaseAuth.instance.currentUser?.uid;
      if (currentUid == null) throw Exception('User not logged in');

      // --- 1) Firestore canonical record ---
      final firestoreRide = {
        ...rideData,
        'riderId': currentUid,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
      };
      final rideRef = await _firestore.collection('rides').add(firestoreRide);
      final rideId = rideRef.id;

      // --- 2) RTDB live mirrors for dispatch & live tracking ---
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

      // --- 3) Search nearby drivers and fan-out notifications ---
      final pickupLoc = LatLng(
        (rideData['pickupLat'] as num).toDouble(),
        (rideData['pickupLng'] as num).toDouble(),
      );

      final drivers = await NearbyDriversService()
          .streamNearbyDriversFast(pickupLoc)
          .first
          .timeout(const Duration(seconds: 5), onTimeout: () => []);

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
        _logger.i('[RideService] ✅ Notified $count drivers for ride $rideId');
      }

      // --- 4) Background sync trigger ---
      try {
        // Mark this ride live for background update service (trip share)
        await _rtdb.child('ridesLive/$rideId').update({
          'trackingEnabled': true,
          'updatedAt': ServerValue.timestamp,
        });
      } catch (e) {
        _logger.w('[RideService] tracking flag failed silently: $e');
      }

      return rideId;
    } catch (e, st) {
      _logger.e('requestRide failed', error: e, stackTrace: st);
      throw Exception('Unable to request ride: $e');
    }
  }

  Future<void> expireCounterFare(String rideId) async {
    try {
      // Firestore: clear the counter and stamp expiry
      await _firestore.collection('rides').doc(rideId).update({
        'counterFare': FieldValue.delete(),
        'counterExpiredAt': FieldValue.serverTimestamp(),
      });

      // RTDB live mirror: clear the counter & stamp expiry
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

      // 1) Firestore: mark cancelled (keep existing timestamps)
      await _firestore.collection('rides').doc(rideId).update({
        'status': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
        // Optionally clear driver fields if they were set while rider cancelled early
        'driverId': FieldValue.delete(),
        'driverName': FieldValue.delete(),
      });

      // 2) Rider's RTDB mirror (optional if you don't rely on it anymore)
      try {
        await _rtdb.child('rides/$currentUid/$rideId').remove();
      } catch (_) {}

      // 3) Live broadcast: ridesLive
      await _rtdb.child('ridesLive/$rideId').update({
        'status': 'cancelled',
        'cancelledAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      });

      // 4) 🔥 Fan-out delete this ride from ALL driver_notifications
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

      // 5) (Optional) also clear your legacy broadcast queues if you still use them
      //    This prevents lingering entries in aggregated queues.
      await _rtdb
          .child('rides_pending/$rideId')
          .remove(); // AppPaths.ridesPendingA
      await _rtdb
          .child('rideRequests/$rideId')
          .remove(); // AppPaths.ridesPendingB
    } catch (e) {
      Logger().e('Failed to cancel ride: $e');
      throw Exception('Unable to cancel ride: $e');
    }
  }

  /// Rider accepts a driver's counter-fare.
  /// - Locks fare
  /// - Assigns the proposing driver
  /// - Marks status=accepted
  /// - Mirrors to RTDB live node
  /// - Deletes other drivers' notifications for this ride (best-effort)
  /// - Removes from pending queues (best-effort)
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
      // Best-effort cleanup; don't fail the main flow on this.
      // You can log it if you like.
      // debugPrint('[fanoutDeleteDriverNotificationsForRide] $e');
    }
  }

  Future<void> acceptCounterFare(String rideId, double counterFare) async {
    final fire = FirebaseFirestore.instance;
    final rtdb = FirebaseDatabase.instance.ref();
    final rideRef = fire.collection(AppPaths.ridesCollection).doc(rideId);

    String? driverId;

    // 1) Firestore: atomically accept the counter fare and lock the driver
    await fire.runTransaction((txn) async {
      final snap = await txn.get(rideRef);
      if (!snap.exists) throw Exception('Ride not found');
      final data = snap.data() as Map<String, dynamic>;

      final status = (data[AppFields.status] ?? '').toString();
      if (status == RideStatus.cancelled || status == RideStatus.completed) {
        throw Exception('Ride is no longer active');
      }

      // ✅ tolerate both snake/camel, and fallback to live node mirrored by driver
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
        'counter_driver_id': FieldValue.delete(), // ✅ clear both
        AppFields.status: RideStatus.accepted,
        AppFields.driverId: driverId,
        AppFields.acceptedAt: FieldValue.serverTimestamp(),
      });
    });

    // 2) RTDB live mirror: also clear counter fields
    final now = ServerValue.timestamp;
    await rtdb.child('${AppPaths.ridesLive}/$rideId').update({
      AppFields.status: RideStatus.accepted,
      AppFields.fare: counterFare,
      AppFields.driverId: driverId,
      'counterFare': null, // ✅ important
      'counterDriverId': null, // ✅ important
      AppFields.acceptedAt: now,
      AppFields.updatedAt: now,
    });

    // (Optional) also clear rider mirror if you rely on it in UI:
    try {
      final riderId = FirebaseAuth.instance.currentUser?.uid;
      if (riderId != null) {
        await rtdb.child('rides/$riderId/$rideId').update({
          'counterFare': null, // ✅ prevent re-pop
          'counterDriverId': null,
          'updatedAt': now,
        });
      }
    } catch (_) {}

    // 3) Best-effort: remove from any legacy/pending queues
    try {
      await rtdb.child('${AppPaths.ridesPendingA}/$rideId').remove();
    } catch (_) {}
    try {
      await rtdb.child('${AppPaths.ridesPendingB}/$rideId').remove();
    } catch (_) {}

    // 4) Fan-out delete: remove this ride's popup from ALL drivers
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
    } catch (_) {
      // Best-effort cleanup; ignore if rules block cross-user read/write.
    }

    // 5) Optional: nudge the selected driver (toast/chime)
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
final messagesProvider = StreamProvider.family<List<Map<String, dynamic>>, String>((ref, rideId) {
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
  static const read = 'read';
}

extension RiderChat on RideService {
  DatabaseReference get _db => FirebaseDatabase.instance.ref();
  FirebaseAuth get _auth => FirebaseAuth.instance;

  Future<void> sendMessage(String rideId, String message) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) throw Exception('Not logged in');
    if (rideId.isEmpty || message.trim().isEmpty) return;

    try {
      // 1️⃣ Push to Realtime Database (chat sync)
      await _db.child('rides/$rideId/messages').push().set({
        ChatFields.senderId: uid,
        ChatFields.text: message.trim(),
        ChatFields.timestamp: ServerValue.timestamp,
        ChatFields.read: false,
      });

      // 2️⃣ Fetch ride info from Firestore
      final rideSnap =
          await FirebaseFirestore.instance.collection('rides').doc(rideId).get();
      final data = rideSnap.data();
      if (data == null) return;

      final riderId = data['riderId'];
      final driverId = data['driverId'];
      final receiverId = uid == riderId ? driverId : riderId;
      if (receiverId == null) return;

      // 3️⃣ Fetch receiver’s FCM token
      final receiverSnap = await FirebaseFirestore.instance
          .collection('users')
          .doc(receiverId)
          .get();
      final receiverToken = receiverSnap.data()?['fcmToken'];
      if (receiverToken == null || receiverToken.isEmpty) {
        debugPrint('⚠️ No FCM token for receiver $receiverId');
        return;
      }

      // 4️⃣ Notify backend (Express endpoint)
      final response = await http.post(
        Uri.parse('https://femdrive-server.vercel.app/api/rides/$rideId/messages'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'senderId': driverId,
          'text': message.trim(),
        }),
      );

      if (response.statusCode != 200) {
        throw Exception('Notification failed: ${response.body}');
      }
    } catch (e) {
      debugPrint('Error sending message: $e');
      rethrow;
    }
  }

  Stream<List<Map<String, dynamic>>> listenMessages(String rideId) {
    final ref = _db.child('rides/$rideId/messages');
    return ref.onValue.map((event) {
      final raw = event.snapshot.value as Map<dynamic, dynamic>?;
      if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];
      final list = raw.entries.map((e) {
        final m = Map<String, dynamic>.from(e.value as Map);
        m['id'] = e.key;
        return m;
      }).toList();
      list.sort((a, b) {
        final ta = (a[ChatFields.timestamp] as num?)?.toInt() ?? 0;
        final tb = (b[ChatFields.timestamp] as num?)?.toInt() ?? 0;
        return tb.compareTo(ta); // DESC: newest first
      });
      return list;
    });
  }
  // rider_services.dart → Add to RideService class
  Future<void> markMessagesAsRead(String rideId, String readerId) async {
    try {
      final ref = _db.child('rides/$rideId/messages');
      final snap = await ref.get();
      if (!snap.exists) return;

      final updates = <String, dynamic>{};
      final data = snap.value as Map<dynamic, dynamic>? ?? {};

      data.forEach((key, msg) {
        if (msg is Map && msg[ChatFields.senderId] != readerId && msg[ChatFields.read] != true) {
          updates['$key/${ChatFields.read}'] = true;
        }
      });

      if (updates.isNotEmpty) {
        await ref.update(updates);
      }
    } catch (e) {
      _logger.e('markMessagesAsRead failed: $e');
    }
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
  Future<void> _send() async {
    final t = _text.text.trim();
    if (t.isEmpty) return;
    await ref.read(riderChatControllerProvider.notifier).send(widget.rideId, t);
      if (mounted) { 
        WidgetsBinding.instance.addPostFrameCallback((_) { 
          _text.clear(); 
          FocusManager.instance.primaryFocus?.unfocus(); 
          if (_scroll.hasClients) { 
            _scroll.animateTo( 
              _scroll.position.maxScrollExtent + 72, 
              duration: const Duration(milliseconds: 200), 
              curve: Curves.easeOut, 
            ); 
          } 
        }); 
      } 
  }
  @override
  Widget build(BuildContext context) {
    final uid = ref.watch(riderCurrentUserIdProvider);
    final msgs = ref.watch(messagesProvider(widget.rideId));
    return Scaffold(
      appBar: AppBar(title: Text(widget.otherDisplayName ?? 'Chat')),
      body: Column(
        children: [
          Expanded(
            child: msgs.when(
              data: (list) {
                if (list.isEmpty) return const Center(child: Text('Say hi 👋'));
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
                  itemCount: list.length,
                  itemBuilder: (_, i) {
                    final m = list[i];
                    final isMe = m[ChatFields.senderId] == uid;
                    return Align(
                      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: isMe ? Theme.of(context).colorScheme.primaryContainer : const Color.fromARGB(255, 48, 183, 236),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Column(
                            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                            children: [
                              Text(m[ChatFields.text] ?? ''),
                              Text(
                                DateTime.fromMillisecondsSinceEpoch(m[ChatFields.timestamp]?.toInt() ?? 0)
                                    .toLocal()
                                    .toString()
                                    .substring(11, 16),
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.black54),
                              ),
                              if (isMe && (m[ChatFields.read] == true) && i == list.length - 1)
                                const Text('Read', style: TextStyle(fontSize: 10, color: Colors.green)),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Chat error: $e')),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      decoration: const InputDecoration(hintText: 'Type a message…', border: OutlineInputBorder()),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: ref.watch(riderChatControllerProvider).isLoading ? null : _send,
                    child: ref.watch(riderChatControllerProvider).isLoading
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
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

class ShareTripService {
  final _logger = Logger();
  final String _apiBaseUrl = 'https://fem-drive.vercel.app/api/trip';
  String? _currentShareId;
  Timer? _expirationTimer;
  Timer? _locationUpdateTimer;

  /// 🚀 Start trip sharing (auto-syncs with driver background updates)
  Future<String> startSharing(String rideId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception('User not logged in');

    final idToken = await user.getIdToken(true); // ✅ force refresh
    final userId = user.uid;

    // Already sharing? Return cached link.
    if (_currentShareId != null && _locationUpdateTimer?.isActive == true) {
      return 'https://fem-drive.vercel.app/trip/$_currentShareId';
    }

    try {
      final response = await http.post(
        Uri.parse('$_apiBaseUrl/share'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $idToken',
        },
        body: jsonEncode({'rideId': rideId}),
      );

      if (response.statusCode != 200) {
        throw Exception('Failed to start sharing: ${response.body}');
      }

      final data = jsonDecode(response.body);
      _currentShareId = data['shareId'];
      final shareUrl = 'https://fem-drive.vercel.app/trip/$_currentShareId';

      // ✅ Sync to Firestore + RTDB
      await FirebaseFirestore.instance
          .collection('rides')
          .doc(rideId)
          .update({'shareId': _currentShareId});

      await FirebaseDatabase.instance.ref('trip_shares/$_currentShareId').set({
        'rideId': rideId,
        'userId': userId,
        'startedAt': ServerValue.timestamp,
        'active': true,
      });

      _startLocationUpdates();

      // Auto-stop after 3h (silent)
      _expirationTimer =
          Timer(const Duration(hours: 3), () => stopSharing(userId));

      return shareUrl;
    } catch (e) {
      _logger.e('startSharing failed: $e');
      _currentShareId = null;
      _locationUpdateTimer?.cancel();
      rethrow;
    }
  }

  /// 🛑 Stop sharing manually or after expiration
  Future<void> stopSharing(String userId) async {
    if (_currentShareId == null) return;

    final user = FirebaseAuth.instance.currentUser;
    final idToken = await user?.getIdToken(true);
    final shareId = _currentShareId;

    try {
      final response = await http.post(
        Uri.parse('$_apiBaseUrl/$shareId/stop'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $idToken',
        },
      );

      if (response.statusCode != 200) {
        _logger.w('Server stop response: ${response.body}');
      }

      // Mark inactive in RTDB
      await FirebaseDatabase.instance.ref('trip_shares/$shareId').update({
        'active': false,
        'stoppedAt': ServerValue.timestamp,
      });

      // Clean Firestore
      final rideSnap = await FirebaseFirestore.instance
          .collection('rides')
          .where('shareId', isEqualTo: shareId)
          .limit(1)
          .get();
      for (final doc in rideSnap.docs) {
        await doc.reference.update({'shareId': FieldValue.delete()});
      }

      _logger.i('Trip share $shareId stopped.');
    } catch (e) {
      _logger.e('Stop sharing error: $e');
    } finally {
      _expirationTimer?.cancel();
      _locationUpdateTimer?.cancel();
      _currentShareId = null;
    }
  }

  /// Background-safe polling for rider live updates (every 5s)
  void _startLocationUpdates() {
    if (_currentShareId == null) return;

    _locationUpdateTimer?.cancel();
    _locationUpdateTimer =
        Timer.periodic(const Duration(seconds: 5), (timer) async {
      try {
        final permission = await Geolocator.checkPermission();
        if (permission == LocationPermission.denied) {
          final req = await Geolocator.requestPermission();
          if (req == LocationPermission.denied) return;
        }

        final position = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high),
        );
        final speed = position.speed * 3.6;

        await FirebaseDatabase.instance
            .ref('trip_shares/$_currentShareId')
            .update({
          'lat': position.latitude,
          'lng': position.longitude,
          'speed': speed,
          'updatedAt': ServerValue.timestamp,
        });
      } catch (e) {
        _logger.w('Location update failed: $e');
      }
    });
  }
}
