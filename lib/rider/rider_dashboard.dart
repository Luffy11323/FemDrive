// rider_dashboard.dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui; // for BackdropFilter blur

import 'package:async/async.dart';
import 'package:femdrive/shared/emergency_service.dart';
import 'package:femdrive/rider/rider_dashboard_controller.dart';
import 'package:femdrive/rider/rider_services.dart'; // MapService, GeocodingService
import 'package:femdrive/shared/notifications.dart';
import 'package:femdrive/widgets/payment_services.dart';
import 'package:femdrive/widgets/share_service.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:logger/logger.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart';

final connectivityProvider = StreamProvider<ConnectivityResult>((ref) {
  return Connectivity().onConnectivityChanged.cast<ConnectivityResult>();
});

final locationPermissionProvider = FutureProvider<bool>((ref) async {
  final permission = await Permission.location.request();
  return permission == PermissionStatus.granted;
});

final driverLocationProvider = StreamProvider.family<LatLng?, String>((
  ref,
  driverId,
) {
  final root = FirebaseDatabase.instance.ref();
  // Canonical
  final a = root.child('driverLocations/$driverId').onValue.map((e) {
    final m = (e.snapshot.value as Map?)?.cast<String, dynamic>();
    final lat = (m?['lat'] as num?)?.toDouble();
    final lng = (m?['lng'] as num?)?.toDouble();
    return (lat != null && lng != null) ? LatLng(lat, lng) : null;
  });
  // Legacy fallback
  final b = root.child('drivers/$driverId/location').onValue.map((e) {
    final m = (e.snapshot.value as Map?)?.cast<String, dynamic>();
    final lat = (m?['lat'] as num?)?.toDouble();
    final lng = (m?['lng'] as num?)?.toDouble();
    return (lat != null && lng != null) ? LatLng(lat, lng) : null;
  });
  // Prefer A; if it emits nulls, continue listening to both and pick the first non-null
  return StreamZip<LatLng?>([
    a,
    b,
  ]).map((vals) => vals.firstWhere((v) => v != null, orElse: () => null));
});

/// Live ride status + (optionally) driver live lat/lng from RTDB
class RideLive {
  final String status;
  final String? driverId;
  final LatLng? driverLatLng;
  final int? etaSecs;
  RideLive({
    required this.status,
    this.driverId,
    this.driverLatLng,
    this.etaSecs,
  });
}

final rtdbRideLiveProvider = StreamProvider.family<RideLive?, String>((
  ref,
  rideId,
) {
  final liveRef = FirebaseDatabase.instance.ref('ridesLive/$rideId');
  return liveRef.onValue.map((event) {
    final data = (event.snapshot.value as Map?)?.cast<String, dynamic>();
    if (data == null) return null;
    return RideLive(
      status: (data['status'] ?? '').toString(),
      driverId: data['driverId'] as String?,
      driverLatLng:
          null, // ← keep null; location comes from driverLocationProvider
      etaSecs: (data['etaSecs'] as num?)?.toInt(),
    );
  });
});

/// Provides nearby online drivers (live updates) for the map overlay
//final nearbyDriversProvider =
//  StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) async* {
//  final loc = await MapService().currentLocation();
//yield* NearbyDriversService().streamNearbyDriversFast(
//loc,
//  ); // RTDB version
//  });

/// Rider Dashboard Main Page
class RiderDashboard extends ConsumerStatefulWidget {
  const RiderDashboard({super.key});

  @override
  ConsumerState<RiderDashboard> createState() => _RiderDashboardState();
}

class _RiderDashboardState extends ConsumerState<RiderDashboard> {
  final _logger = Logger();
  GoogleMapController? _mapController;
  LatLng? _currentLocation;

  final _pickupController = TextEditingController();
  final _dropoffController = TextEditingController();
  Set<Polyline> _polylines = {};
  // --- live trim for driver->pickup leg ---
  List<LatLng> _driverLeg = const [];
  Set<Polyline> _trimmed = {};
  LatLng? _lastDriverTick;

  int _nearestIndex(List<LatLng> route, LatLng p) {
    if (route.isEmpty) return 0;
    double best = double.infinity;
    int bestIdx = 0;
    for (var i = 0; i < route.length; i++) {
      final d = Geolocator.distanceBetween(
        p.latitude,
        p.longitude,
        route[i].latitude,
        route[i].longitude,
      );
      if (d < best) {
        best = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  final Set<String> _arrivedNotified = {};
  final Set<String> _startedNotified = {};
  final Set<String> _completedNotified = {};
  final Set<String> _noDriversNotified = {};

  void _applyTrimmedRoute(
    List<LatLng> route,
    LatLng me, {
    String id = 'driver_to_pickup',
  }) {
    if (route.length < 2) return;
    final cutAt = _nearestIndex(route, me);
    final remaining = <LatLng>[
      me,
      ...route.sublist(cutAt.clamp(0, route.length - 1)),
    ];
    final covered = route.sublist(0, cutAt.clamp(0, route.length));

    _trimmed = {
      Polyline(
        polylineId: PolylineId('${id}_remaining'),
        points: remaining,
        color: Colors.blue,
        width: 6,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
      ),
      if (covered.isNotEmpty)
        Polyline(
          polylineId: PolylineId('${id}_covered'),
          points: covered,
          color: Colors.grey,
          width: 6,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
        ),
    };
  }

  double _bearingBetween(LatLng a, LatLng b) {
    final lat1 = a.latitude * (math.pi / 180.0);
    final lon1 = a.longitude * (math.pi / 180.0);
    final lat2 = b.latitude * (math.pi / 180.0);
    final lon2 = b.longitude * (math.pi / 180.0);
    final dLon = lon2 - lon1;
    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    var brng = math.atan2(y, x) * 180.0 / math.pi;
    brng = (brng + 360.0) % 360.0;
    return brng;
  }

  Future<void> _followCamera(LatLng me) async {
    if (_driverLeg.length >= 2) {
      final idx = _nearestIndex(_driverLeg, me);
      final next = _driverLeg[(idx + 1).clamp(0, _driverLeg.length - 1)];
      final bearing = _bearingBetween(me, next);
      await _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: me, zoom: 17.0, tilt: 45.0, bearing: bearing),
        ),
      );
    } else {
      await _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: me, zoom: 17.0, tilt: 45.0),
        ),
      );
    }
  }

  bool _trafficEnabled = false;
  MapType _mapType = MapType.normal;
  double? _fare;
  int? _eta;
  double? _distanceKm;
  LatLng? _pickupLatLng;
  LatLng? _dropoffLatLng;
  final Set<String> _acceptedNotified = {};
  final Set<String> _cancelNotified = {};
  //  final Set<String> _counterNotified = {};
  //  final Set<String> _emergencyNotified = {};

  @override
  void initState() {
    super.initState();
    _loadCurrentLocation();
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _dropoffController.dispose();
    super.dispose();
  }

  Future<void> _drawRoute({
    required LatLng from,
    required LatLng to,
    required String id,
    required Color color,
    int width = 6,
  }) async {
    try {
      final points = await MapService().getRoute(from, to);
      _logger.i(
        '[route] ${from.latitude},${from.longitude} -> ${to.latitude},${to.longitude} | pts=${points.length}',
      );
      if (!mounted || points.isEmpty) return;
      setState(() {
        _polylines = {
          Polyline(
            polylineId: PolylineId(id),
            points: points,
            color: color,
            width: width,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
        };
      });
      await _fitToBounds(from, to);
    } catch (e) {
      _logger.e('Failed to draw route "$id": $e');
    }
  }

  // same signature + store points for trimming when id == 'driver_to_pickup'
  Future<void> _drawRouteAndStore({
    required LatLng from,
    required LatLng to,
    required String id,
    required Color color,
    int width = 6,
  }) async {
    final points = await MapService().getRoute(from, to);
    if (!mounted || points.isEmpty) return;

    if (id == 'driver_to_pickup') {
      _driverLeg = points;
      _applyTrimmedRoute(_driverLeg, from, id: id); // initial cut from 'from'
      setState(() {
        _polylines = {}; // clear legacy single polyline
        _polylines = {..._trimmed}; // show covered+remaining
      });
    } else {
      setState(() {
        _polylines = {
          Polyline(
            polylineId: PolylineId(id),
            points: points,
            color: color,
            width: width,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          ),
        };
      });
    }
    await _fitToBounds(from, to);
  }

  Future<void> _loadCurrentLocation() async {
    try {
      final loc = await MapService().currentLocation();

      // Resolve a human-readable address for the pickup field
      String? addr = await GeocodingService.reverseGeocode(
        lat: loc.latitude,
        lng: loc.longitude,
      );
      addr ??= 'My location'; // fallback label

      setState(() {
        _currentLocation = loc;
        _pickupLatLng = loc;
        _pickupController.text = addr!; // <-- real address now
      });

      // Keep nearby driver query centered around the pickup
      ref.read(driverSearchCenterProvider.notifier).state = loc;
    } catch (e) {
      _logger.e("Failed to fetch current location: $e");
    }
  }

  Future<void> _fitToBounds(LatLng a, LatLng b) async {
    if (_mapController == null) return;
    var sw = LatLng(
      a.latitude < b.latitude ? a.latitude : b.latitude,
      a.longitude < b.longitude ? a.longitude : b.longitude,
    );
    var ne = LatLng(
      a.latitude > b.latitude ? a.latitude : b.latitude,
      a.longitude > b.longitude ? a.longitude : b.longitude,
    );

    // nudge if identical
    if (sw.latitude == ne.latitude && sw.longitude == ne.longitude) {
      const d = 0.0005;
      sw = LatLng(sw.latitude - d, sw.longitude - d);
      ne = LatLng(ne.latitude + d, ne.longitude + d);
    }

    await _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(southwest: sw, northeast: ne),
        72,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ridesAsync = ref.watch(riderDashboardProvider);
    final rideData = ridesAsync.value;
    final assignedDriverId = (rideData?['driverId'] as String?);
    final rideId = (rideData?['id'] as String?);
    final staticStatus = (rideData?['status'] ?? '').toString();
    final dash = ref.watch(riderDashboardProvider);
    final rideDataa = dash.asData?.value;
    final statuss = (rideData?['status'] as String?) ?? '';

    // ✅ side-effect: keep camera centered on pickup while searching
    if (_mapController != null && rideDataa != null && statuss == 'searching') {
      final pLat = (rideDataa['pickupLat'] as num?)?.toDouble();
      final pLng = (rideDataa['pickupLng'] as num?)?.toDouble();
      if (pLat != null && pLng != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _mapController!.animateCamera(
            CameraUpdate.newLatLngZoom(LatLng(pLat, pLng), 16),
          );
        });
      }
    }

    // Pull live overlay (fast) if ride exists
    RideLive? live;
    if (rideId != null) {
      live = ref.watch(rtdbRideLiveProvider(rideId)).value;
    }

    // Prefer live status if present
    final status = (live?.status.isNotEmpty == true)
        ? live!.status
        : staticStatus;

    // Prefer live driver lat/lng
    LatLng? driverLatLng = live?.driverLatLng;

    // Fallback to driver stream if live didn’t include coords
    final dlat = (rideData?['driverLat'] as num?)?.toDouble();
    final dlng = (rideData?['driverLng'] as num?)?.toDouble();
    if (dlat != null && dlng != null) {
      driverLatLng = LatLng(dlat, dlng);
    } else if (assignedDriverId != null && assignedDriverId.isNotEmpty) {
      // fallback to driver location provider
      driverLatLng = ref.watch(driverLocationProvider(assignedDriverId)).value;
    }
    // live trim + follow camera while heading to pickup
    if (driverLatLng != null && status == 'accepted' && _driverLeg.isNotEmpty) {
      // avoid redundant rebuild churn
      if (_lastDriverTick == null ||
          Geolocator.distanceBetween(
                _lastDriverTick!.latitude,
                _lastDriverTick!.longitude,
                driverLatLng.latitude,
                driverLatLng.longitude,
              ) >
              3) {
        _lastDriverTick = driverLatLng;
        _applyTrimmedRoute(_driverLeg, driverLatLng, id: 'driver_to_pickup');
        // merge with any other polylines you already show
        setState(() => _polylines = {..._trimmed});
        _followCamera(driverLatLng);
      }
    }

    final hasActive = const {
      'pending',
      'searching',
      'accepted',
      'driverArrived', // ✅ keep form hidden & continue tracking
      'in_progress',
      'onTrip',
    }.contains(status);

    if (!hasActive &&
        _pickupLatLng == null &&
        _dropoffLatLng == null &&
        _polylines.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _polylines = {});
      });
    }
    final pLat2 = (rideData?['pickupLat'] as num?)?.toDouble();
    final pLng2 = (rideData?['pickupLng'] as num?)?.toDouble();
    final LatLng? safePickup = (pLat2 != null && pLng2 != null)
        ? LatLng(pLat2, pLng2)
        : (_pickupLatLng ?? _currentLocation);

    final bool showRadar =
        rideData != null &&
        (status == 'pending' || status == 'searching') &&
        safePickup != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rider Dashboard'),
        surfaceTintColor: Colors.transparent,
      ),
      drawer: _buildDrawer(context),
      body: SafeArea(
        child: Stack(
          children: [
            // --- Map with live markers and route ---
            Consumer(
              builder: (context, ref, _) {
                final nearbyAsync = ref.watch(nearbyDriversProvider);
                return nearbyAsync.when(
                  data: (drivers) {
                    final status = (rideData?['status'] ?? '').toString();
                    final hasActive =
                        status == 'accepted' ||
                        status == 'in_progress' ||
                        status == 'onTrip' ||
                        status == 'driverArrived';

                    final markers = <Marker>{
                      // Rider current location only when idle/planning
                      if (_currentLocation != null &&
                          !hasActive &&
                          (_pickupLatLng == null ||
                              (_pickupLatLng == _currentLocation)) &&
                          _dropoffLatLng == null)
                        Marker(
                          markerId: const MarkerId("me"),
                          position: _currentLocation!,
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueAzure,
                          ),
                        ),

                      // Pickup shown only until trip starts
                      if (_pickupLatLng != null &&
                          (status == 'accepted' || status == 'driverArrived'))
                        Marker(
                          markerId: const MarkerId("pickup"),
                          position: _pickupLatLng!,
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueGreen,
                          ),
                        ),

                      // Dropoff shown only during trip
                      if (_dropoffLatLng != null &&
                          (status == 'in_progress' || status == 'onTrip'))
                        Marker(
                          markerId: const MarkerId("dropoff"),
                          position: _dropoffLatLng!,
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueRed,
                          ),
                        ),

                      // Live driver marker whenever we know it
                      if (driverLatLng != null)
                        Marker(
                          markerId: const MarkerId('driver_live'),
                          position: driverLatLng,
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueOrange,
                          ),
                          infoWindow: const InfoWindow(title: 'Driver'),
                        ),

                      // Nearby drivers (hidden once one is assigned)
                      ...drivers
                          .where((d) => d['location'] != null)
                          .where(
                            (d) => (d['id'] ?? d['uid']) != assignedDriverId,
                          )
                          .map((d) {
                            final loc = d['location'];
                            LatLng? pos;
                            if (loc is GeoPoint) {
                              pos = LatLng(loc.latitude, loc.longitude);
                            } else if (loc is LatLng) {
                              pos = loc;
                            } else {
                              return null;
                            }

                            final id =
                                (d['id'] ?? d['uid'] ?? UniqueKey().toString())
                                    .toString();
                            final username = (d['username'] ?? 'Driver')
                                .toString();
                            final rating = (d['rating'] ?? '—').toString();
                            final rideType = (d['rideType'] ?? '—').toString();

                            return Marker(
                              markerId: MarkerId('driver_$id'),
                              position: pos,
                              icon: BitmapDescriptor.defaultMarkerWithHue(
                                BitmapDescriptor.hueOrange,
                              ),
                              infoWindow: InfoWindow(
                                title: username,
                                snippet: '⭐ $rating • $rideType',
                              ),
                            );
                          })
                          .whereType<Marker>(),
                    };

                    return Stack(
                      children: [
                        GoogleMap(
                          initialCameraPosition: CameraPosition(
                            target:
                                _currentLocation ??
                                const LatLng(37.7749, -122.4194),
                            zoom: 14,
                          ),
                          padding: const EdgeInsets.only(bottom: 280),
                          onMapCreated: (controller) =>
                              _mapController = controller,

                          myLocationEnabled: true,
                          myLocationButtonEnabled: false,
                          compassEnabled: false,
                          zoomControlsEnabled: false,
                          mapToolbarEnabled: false,

                          trafficEnabled: _trafficEnabled,
                          mapType: _mapType,

                          markers: markers,
                          polylines: _polylines,
                        ),
                        Positioned(
                          top: 16,
                          right: 12,
                          child: _MapControls(
                            onZoomIn: () => _mapController?.animateCamera(
                              CameraUpdate.zoomIn(),
                            ),
                            onZoomOut: () => _mapController?.animateCamera(
                              CameraUpdate.zoomOut(),
                            ),
                            onRecenter: () {
                              if (_currentLocation != null) {
                                _mapController?.animateCamera(
                                  CameraUpdate.newLatLngZoom(
                                    _currentLocation!,
                                    15,
                                  ),
                                );
                              }
                            },
                            trafficEnabled: _trafficEnabled,
                            onToggleTraffic: () => setState(
                              () => _trafficEnabled = !_trafficEnabled,
                            ),
                            mapType: _mapType,
                            onToggleMapType: () => setState(() {
                              _mapType = _mapType == MapType.normal
                                  ? MapType.satellite
                                  : MapType.normal;
                            }),
                          ),
                        ),
                        if (drivers.isEmpty)
                          Positioned(
                            top: 16,
                            left: 16,
                            right: 16,
                            child: _Frosted(
                              child: Row(
                                children: [
                                  const Icon(Icons.info_outline, size: 18),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'No nearby drivers available',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelLarge,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, st) => Center(child: Text("Map error: $e")),
                );
              },
            ),
            if (rideData != null &&
                (status == 'in_progress' || status == 'onTrip') &&
                _dropoffLatLng != null &&
                assignedDriverId != null)
              Positioned.fill(
                child: _RiderNavMap(
                  rideId: rideId!,
                  driverId: assignedDriverId,
                  dropoff: _dropoffLatLng!,
                  pickup: _pickupLatLng,
                ),
              ),
            // --- Fare/ETA/Distance pill (like route summary) ---
            if (_fare != null && _eta != null && _distanceKm != null)
              Positioned(
                top: 72,
                left: 12,
                right: 12,
                child: Row(
                  children: [
                    _InfoPill(
                      icon: Icons.attach_money_rounded,
                      label: 'Fare',
                      value: '\$${_fare!.toStringAsFixed(2)}',
                    ),
                    const SizedBox(width: 8),
                    _InfoPill(
                      icon: Icons.schedule_rounded,
                      label: 'ETA',
                      value: '${_eta!} min',
                    ),
                    const SizedBox(width: 8),
                    _InfoPill(
                      icon: Icons.route_rounded,
                      label: 'Distance',
                      value: '${_distanceKm!.toStringAsFixed(1)} km',
                    ),
                  ],
                ),
              ),

            // --- Ride state overlays (unchanged logic, polished visuals) ---
            ridesAsync.when(
              data: (rideData) {
                if (rideData == null || rideData.isEmpty) {
                  return const SizedBox.shrink();
                }

                final ride = rideData;
                final status = (ride['status'] ?? '').toString();
                // --- Route switching logic ---
                switch (status) {
                  case 'accepted':
                    if (_acceptedNotified.add(ride['id'])) {
                      showAccepted(rideId: ride['id']);
                    }

                    // Replace planning polyline with driver → pickup
                    if (driverLatLng != null && _pickupLatLng != null) {
                      _drawRouteAndStore(
                        from: driverLatLng,
                        to: _pickupLatLng!,
                        id: 'driver_to_pickup',
                        color: Colors.orange,
                      );
                    } else {
                      // No driver yet: keep map clean (avoid stale planning line)
                      if (_polylines.isNotEmpty) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) setState(() => _polylines = {});
                        });
                      }
                    }
                    break;

                  case 'in_progress':
                  case 'onTrip':
                    if (_startedNotified.add(ride['id'])) {
                      showRideStarted(rideId: ride['id']);
                    }
                    // Show current driver (live) → dropoff; fallback...
                    if (_dropoffLatLng != null) {
                      final origin =
                          driverLatLng ?? _currentLocation ?? _pickupLatLng;
                      if (origin != null) {
                        _drawRoute(
                          from: origin,
                          to: _dropoffLatLng!,
                          id: 'to_dropoff_live',
                          color: Colors.blue,
                        );
                      }
                    }
                    break;

                  case 'searching':
                    // Optional: keep the map clean during searching
                    if (_polylines.isNotEmpty) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) setState(() => _polylines = {});
                      });
                    }
                    break;

                  case 'completed':
                    if (_completedNotified.add(ride['id'])) {
                      showRideCompleted(rideId: ride['id']);
                    }
                    // After a short delay, you navigate; clear line now to avoid flash
                    if (_polylines.isNotEmpty) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) setState(() => _polylines = {});
                      });
                    }
                    Future.delayed(const Duration(seconds: 4), () {
                      if (mounted) {
                        if (!context.mounted) return;
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const RiderDashboard(),
                          ),
                        );
                      }
                    });
                    break;
                  case 'no_drivers':
                    if (_noDriversNotified.add(ride['id'])) {
                      showNoDrivers(rideId: ride['id']);
                    }
                    break;

                  case 'cancelled':
                    if (_cancelNotified.add(ride['id'])) {
                      showCancelled(rideId: ride['id']);
                    }

                    if (_polylines.isNotEmpty) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) setState(() => _polylines = {});
                      });
                    }
                    break;
                  case 'driver_arrived':
                    if (_arrivedNotified.add(ride['id'])) {
                      showDriverArrived(rideId: ride['id']);
                    }
                    // keep/adjust your map logic as needed
                    break;

                  default:
                    // Idle/planning state: do nothing here.
                    // The planning polyline is drawn by RideForm.onFareUpdated (pickup+dropoff set).
                    break;
                }

                return Stack(
                  children: [
                    Align(
                      alignment: Alignment.topCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 44),
                        child: RideStatusWidget(ride: ride),
                      ),
                    ),
                    if (ride['driverId'] != null)
                      Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: DriverDetailsWidget(
                            driverId: ride['driverId'],
                          ),
                        ),
                      ),
                    if (status == 'accepted' ||
                        status == 'in_progress' ||
                        status == 'onTrip')
                      Positioned(
                        bottom: 172,
                        right: 16,
                        child: ShareTripButton(rideId: ride['id']),
                      ),

                    if (status != 'completed' && status != 'cancelled')
                      Positioned(
                        bottom: 110,
                        right: 16,
                        child: SOSButton(ride: ride),
                      ),
                    // ⤵️ Always show Cancel for accepted / in_progress / onTrip
                    if (status == 'accepted' ||
                        status == 'in_progress' ||
                        status == 'onTrip')
                      Positioned(
                        bottom: 46, // below SOS
                        left: 16,
                        right: 16,
                        child: _RiderCancelButton(rideId: ride['id']),
                      ),

                    if (status != 'completed' && status != 'cancelled')
                      Positioned(
                        bottom: 56, // just above SOS
                        right: 16,
                        child: FilledButton.tonalIcon(
                          icon: const Icon(Icons.cancel),
                          label: const Text('Cancel Ride'),
                          onPressed: () async {
                            try {
                              final id = (ride['id'] as String?);
                              if (id == null || id.isEmpty) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Ride is not initialized yet',
                                      ),
                                    ),
                                  );
                                }
                                return;
                              }
                              await ref
                                  .read(riderDashboardProvider.notifier)
                                  .cancelRide(id);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Ride cancelled'),
                                  ),
                                );
                                showCancelledByRider(rideId: id);
                              }
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Failed to cancel: $e'),
                                  ),
                                );
                              }
                            }
                          },
                        ),
                      ),

                    if (status == 'completed')
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: ReceiptWidget(ride: ride),
                      ),
                  ],
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (e, st) => const SizedBox.shrink(),
            ),
            // 1) Radar overlay during pending/searching
            if (showRadar)
              Positioned.fill(
                child: RadarSearchingOverlay(
                  pickup: safePickup,
                  message: 'Finding a driver near you…',
                  onCancel: () async {
                    try {
                      final id = (rideData['id'] as String?);
                      if (id == null || id.isEmpty) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Please wait a moment… setting up ride',
                              ),
                            ),
                          );
                        }
                        return;
                      }

                      await ref
                          .read(riderDashboardProvider.notifier)
                          .cancelRide(id);
                      if (context.mounted) {
                        showCancelledByRider(rideId: id);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Ride cancelled')),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Failed to cancel: $e')),
                        );
                      }
                    }
                  },
                  mapController:
                      _mapController, // <-- added for zoom-out (Patch 2)
                ),
              ),

            if (rideData != null &&
                rideData['counterFare'] != null &&
                status != 'completed' &&
                status != 'cancelled')
              CounterFareModalLauncher(ride: rideData),

            // 2) Show RideForm only when no active ride
            if (!hasActive)
              Align(
                alignment: Alignment.bottomCenter,
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        blurRadius: 24,
                        color: Colors.black26,
                        offset: Offset(0, -6),
                      ),
                    ],
                  ),
                  child: DraggableScrollableSheet(
                    initialChildSize: 0.35,
                    minChildSize: 0.20,
                    maxChildSize: 0.88,
                    builder: (_, controller) => ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(16),
                      ),
                      child: Material(
                        color: Theme.of(context).colorScheme.surface,
                        child: RideForm(
                          mapController: _mapController,
                          scrollController: controller,
                          currentLocation: _currentLocation,
                          pickupController: _pickupController,
                          dropoffController: _dropoffController,
                          onFareUpdated:
                              (
                                fare,
                                eta,
                                distanceKm,
                                routePoints, {
                                pickup,
                                dropoff,
                              }) async {
                                if (!mounted) return;
                                setState(() {
                                  _fare = fare;
                                  _eta = eta;
                                  _distanceKm = distanceKm;
                                  if (pickup != null) _pickupLatLng = pickup;
                                  if (dropoff != null) _dropoffLatLng = dropoff;
                                  _polylines = {
                                    Polyline(
                                      polylineId: const PolylineId('route'),
                                      points: routePoints,
                                      color: Colors.blue,
                                      width: 6,
                                      startCap: Cap.roundCap,
                                      endCap: Cap.roundCap,
                                      jointType: JointType.round,
                                    ),
                                  };
                                });
                                if (_pickupLatLng != null &&
                                    _dropoffLatLng != null) {
                                  await _fitToBounds(
                                    _pickupLatLng!,
                                    _dropoffLatLng!,
                                  );
                                }
                              },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Drawer _buildDrawer(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cs.primary,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: const [
                  Icon(
                    Icons.directions_car_filled_rounded,
                    color: Colors.white,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'FemDrive Menu',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _DrawerTile(
              icon: Icons.person,
              title: 'Profile',
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/profile');
              },
            ),
            _DrawerTile(
              icon: Icons.history_rounded,
              title: 'Past Rides',
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/past-rides');
              },
            ),
            _DrawerTile(
              icon: Icons.payment_rounded,
              title: 'Payment Methods',
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/payment');
              },
            ),
            _DrawerTile(
              icon: Icons.settings_rounded,
              title: 'Settings',
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/settings');
              },
            ),
            _DrawerTile(
              icon: Icons.support_agent_rounded,
              title: 'Help & Support',
              onTap: () {
                Navigator.pop(context);
                Navigator.pushNamed(context, '/help-center');
              },
            ),
            const Divider(),
            _DrawerTile(
              icon: Icons.logout_rounded,
              title: 'Logout',
              onTap: () async {
                await FirebaseAuth.instance.signOut();
                if (context.mounted) {
                  Navigator.of(context).pushReplacementNamed('/');
                }
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// ---------------- Ride Form (restored here) ----------------
class RideForm extends ConsumerStatefulWidget {
  final GoogleMapController? mapController;
  final ScrollController scrollController;
  final LatLng? currentLocation;
  final TextEditingController? pickupController;
  final TextEditingController? dropoffController;
  final void Function(
    double fare,
    int eta,
    double distanceKm,
    List<LatLng> routePoints, {
    LatLng? pickup,
    LatLng? dropoff,
  })?
  onFareUpdated;

  const RideForm({
    super.key,
    required this.mapController,
    required this.scrollController,
    required this.currentLocation,
    this.pickupController,
    this.dropoffController,
    this.onFareUpdated,
  });

  @override
  ConsumerState<RideForm> createState() => _RideFormState();
}

class _RideFormState extends ConsumerState<RideForm> {
  final _logger = Logger();
  late final TextEditingController _pickupController;
  late final TextEditingController _dropoffController;
  final _noteController = TextEditingController();
  final _pickupFocus = FocusNode();
  final _dropoffFocus = FocusNode();
  final _pickupSuggestionsCtl = SuggestionsController<PlacePrediction>();
  final _dropoffSuggestionsCtl = SuggestionsController<PlacePrediction>();
  LatLng? _pickupLatLng;
  LatLng? _dropoffLatLng;
  String? _selectedRideType = 'Ride mini';
  String? _selectedPaymentMethod = 'Cash';
  double? _fare;
  int? _eta;
  double? _distanceKm;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _pickupController = widget.pickupController ?? TextEditingController();
    _dropoffController = widget.dropoffController ?? TextEditingController();
    if (_pickupLatLng == null && widget.currentLocation != null) {
      _pickupLatLng = widget.currentLocation;
    }
  }

  @override
  void dispose() {
    if (widget.pickupController == null) _pickupController.dispose();
    if (widget.dropoffController == null) _dropoffController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _panTo(LatLng? pos) async {
    if (pos == null || widget.mapController == null) return;
    try {
      await widget.mapController!.animateCamera(
        CameraUpdate.newLatLngZoom(pos, 15),
      );
    } catch (e) {
      _logger.e('Map pan failed: $e');
    }
  }

  Future<void> _updateRouteAndFare({bool sendMarkers = false}) async {
    if (_pickupLatLng == null || _dropoffLatLng == null) return;

    try {
      final routePoints = await MapService().getRoute(
        _pickupLatLng!,
        _dropoffLatLng!,
      );
      if (routePoints.isEmpty) {
        _logger.w('No route points returned for the selected locations');
        return;
      }

      final result = await MapService().getRateAndEtaFromCoords(
        _pickupLatLng!,
        _dropoffLatLng!,
        _selectedRideType!,
      );
      _logger.i('Route points: ${routePoints.length}');
      _logger.i('Fare calc: $result');

      if (!mounted) return;
      setState(() {
        _fare = (result['total'] as num?)?.toDouble();
        _eta = (result['etaMinutes'] as num?)?.toInt();
        _distanceKm = (result['distanceKm'] as num?)?.toDouble();
      });

      widget.onFareUpdated?.call(
        _fare ?? 0,
        _eta ?? 0,
        _distanceKm ?? 0,
        routePoints,
        pickup: sendMarkers ? _pickupLatLng : null,
        dropoff: sendMarkers ? _dropoffLatLng : null,
      );

      if (widget.mapController != null) {
        var sw = LatLng(
          math.min(_pickupLatLng!.latitude, _dropoffLatLng!.latitude),
          math.min(_pickupLatLng!.longitude, _dropoffLatLng!.longitude),
        );
        var ne = LatLng(
          math.max(_pickupLatLng!.latitude, _dropoffLatLng!.latitude),
          math.max(_pickupLatLng!.longitude, _dropoffLatLng!.longitude),
        );

        if (sw.latitude == ne.latitude && sw.longitude == ne.longitude) {
          const d = 0.0005; // ~50m
          sw = LatLng(sw.latitude - d, sw.longitude - d);
          ne = LatLng(ne.latitude + d, ne.longitude + d);
        }

        await widget.mapController!.animateCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(southwest: sw, northeast: ne),
            50,
          ),
        );
      }
    } catch (e) {
      _logger.e('Route/fare update failed: $e');
    }
  }

  Future<void> _requestRide() async {
    if (_fare == null ||
        _pickupLatLng == null ||
        _dropoffLatLng == null ||
        _selectedPaymentMethod == null) {
      setState(() => _errorMessage = 'Incomplete details to request a ride.');
      return;
    }

    try {
      final controller = ref.read(riderDashboardProvider.notifier);
      await controller.createRide(
        _pickupController.text.trim(),
        _dropoffController.text.trim(),
        _fare!,
        GeoPoint(_pickupLatLng!.latitude, _pickupLatLng!.longitude),
        GeoPoint(_dropoffLatLng!.latitude, _dropoffLatLng!.longitude),
        rideType: _selectedRideType!,
        note: _noteController.text.trim(),
      );

      final ride = ref.read(riderDashboardProvider).value;
      if (ride != null) {
        await PaymentService().processPayment(
          rideId: ride['id'] ?? '',
          amount: _fare!,
          paymentMethod: _selectedPaymentMethod!,
          userId: FirebaseAuth.instance.currentUser!.uid,
        );
        showPaymentConfirmed(rideId: ride['id'] ?? '');
      }

      if (context.mounted) {
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ride requested successfully')),
        );
      }
    } catch (e) {
      showPaymentFailed(
        rideId: (ref.read(riderDashboardProvider).value?['id'] ?? '') as String,
      );
      setState(() => _errorMessage = 'Ride request failed: $e');
      _logger.e('Ride request error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Material(
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: SingleChildScrollView(
        controller: widget.scrollController,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
        child: Column(
          children: [
            // Handlebar
            Container(
              width: 44,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: cs.outline.withAlpha(120),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Ride Type (horizontal selector)
            RideTypePicker(
              options: const [
                RideOption('Ride mini', 'Ride', Icons.directions_car_rounded),
                RideOption('Ride X', 'Comfort', Icons.time_to_leave_rounded),
                RideOption('Bike', 'EV/Scooty', Icons.local_shipping_rounded),
              ],
              selected: _selectedRideType!,
              onChanged: (v) async {
                setState(() => _selectedRideType = v);
                await _updateRouteAndFare(); // recalc fare/ETA when user switches
              },
            ),
            const SizedBox(height: 12),

            /// Pickup
            Material(
              color: Colors.transparent,
              child: TypeAheadField<PlacePrediction>(
                controller: _pickupController,
                focusNode: _pickupFocus,
                suggestionsController: _pickupSuggestionsCtl,
                debounceDuration: const Duration(milliseconds: 250),
                hideOnEmpty: true,
                hideOnUnfocus: true,
                hideWithKeyboard: true,
                retainOnLoading: true,
                constraints: const BoxConstraints(maxHeight: 280),
                suggestionsCallback: (query) async {
                  if (query.trim().isEmpty) return const [];
                  final lat = widget.currentLocation?.latitude ?? 0.0;
                  final lng = widget.currentLocation?.longitude ?? 0.0;
                  final res = await MapService().getPlaceSuggestions(
                    query,
                    lat,
                    lng,
                  );
                  _logger.i('[AC] pickup "$query" -> ${res.length}');
                  return res;
                },
                itemBuilder: (context, p) => ListTile(
                  dense: true,
                  title: Text(
                    p.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                onSelected: (p) async {
                  _pickupController.text = p.description;
                  final latLng = await MapService().getLatLngFromPlaceId(
                    p.placeId,
                  );
                  if (latLng == null) {
                    setState(
                      () => _errorMessage = 'Failed to locate pickup address',
                    );
                    return;
                  }
                  _pickupLatLng = latLng;
                  ref.read(driverSearchCenterProvider.notifier).state = latLng;
                  await _updateRouteAndFare(sendMarkers: true);
                  await _panTo(latLng);
                },
                builder: (context, providedController, providedFocusNode) {
                  return TextField(
                    controller: providedController,
                    focusNode: providedFocusNode,
                    decoration: const InputDecoration(
                      labelText: 'Pickup Location',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.radio_button_checked_rounded),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),

            /// Dropoff
            Material(
              color: Colors.transparent,
              child: TypeAheadField<PlacePrediction>(
                controller: _dropoffController,
                focusNode: _dropoffFocus,
                suggestionsController: _dropoffSuggestionsCtl,
                debounceDuration: const Duration(milliseconds: 250),
                hideOnEmpty: true,
                hideOnUnfocus: true,
                hideWithKeyboard: true,
                retainOnLoading: true,
                constraints: const BoxConstraints(maxHeight: 280),
                suggestionsCallback: (query) async {
                  if (query.trim().isEmpty) return const [];
                  final lat = widget.currentLocation?.latitude ?? 0.0;
                  final lng = widget.currentLocation?.longitude ?? 0.0;
                  final res = await MapService().getPlaceSuggestions(
                    query,
                    lat,
                    lng,
                  );
                  _logger.i('[AC] dropoff "$query" -> ${res.length}');
                  return res;
                },
                itemBuilder: (context, p) => ListTile(
                  dense: true,
                  title: Text(
                    p.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                onSelected: (p) async {
                  _dropoffController.text = p.description;
                  final latLng = await MapService().getLatLngFromPlaceId(
                    p.placeId,
                  );
                  if (latLng == null) {
                    setState(
                      () => _errorMessage = 'Failed to locate dropoff address',
                    );
                    return;
                  }
                  _dropoffLatLng = latLng;
                  await _updateRouteAndFare(sendMarkers: true);
                  await _panTo(latLng);
                },
                builder: (context, providedController, providedFocusNode) {
                  return TextField(
                    controller: providedController,
                    focusNode: providedFocusNode,
                    decoration: const InputDecoration(
                      labelText: 'Dropoff Location',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.location_on_rounded),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),

            /// Payment Method
            DropdownButtonFormField<String>(
              isExpanded: true,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
              initialValue: _selectedPaymentMethod,
              decoration: const InputDecoration(
                labelText: 'Payment Method',
                border: OutlineInputBorder(),
              ),
              items: const [
                'Cash',
                'Credit Card',
                'Wallet',
              ].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
              onChanged: (v) => setState(() => _selectedPaymentMethod = v),
            ),
            const SizedBox(height: 12),

            /// Notes
            TextField(
              controller: _noteController,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.edit_note_rounded),
              ),
            ),
            const SizedBox(height: 16),

            // Primary CTA
            FilledButton(
              onPressed:
                  (_fare != null &&
                      _pickupLatLng != null &&
                      _dropoffLatLng != null &&
                      _selectedPaymentMethod != null)
                  ? _requestRide
                  : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              child: Text(
                _fare == null
                    ? 'Find a driver'
                    : 'Request Ride (\$${_fare!.toStringAsFixed(2)})',
              ),
            ),

            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// ---------------- Ride Status Widget ----------------
class RideStatusWidget extends ConsumerStatefulWidget {
  final Map<String, dynamic> ride;
  const RideStatusWidget({super.key, required this.ride});

  @override
  ConsumerState<RideStatusWidget> createState() => _RideStatusWidgetState();
}

class _RideStatusWidgetState extends ConsumerState<RideStatusWidget>
    with SingleTickerProviderStateMixin {
  double _rating = 0;
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOut,
    );
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) _controller.reverse();
    });
    _controller.forward(); // Trigger fade-in on build
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ride = widget.ride;
    final pickup = ride['pickup'] ?? 'Unknown';
    final dropoff = ride['dropoff'] ?? 'Unknown';
    final status = ride['status']?.toString() ?? 'Unknown';

    return FadeTransition(
      opacity: _fadeAnimation,
      child: _Frosted(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.directions_car, size: 16),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Ride: $pickup → $dropoff | Status: $status',
                style: const TextStyle(fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            if (status == 'completed') ...[
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (_) => _buildRatingDialog(
                      context,
                      (ride['driverId'] ?? '') as String,
                    ),
                  );
                },
                child: const Icon(Icons.star, color: Colors.amber, size: 20),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRatingDialog(BuildContext context, String driverId) {
    return AlertDialog(
      title: const Text("Rate Driver"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Slider(
            value: _rating,
            min: 0,
            max: 5,
            divisions: 5,
            label: _rating.toStringAsFixed(1),
            onChanged: (value) => setState(() => _rating = value),
          ),
          Text("Rating: ${_rating.toStringAsFixed(1)} / 5"),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel"),
        ),
        FilledButton(
          onPressed: () async {
            await _submitRating(driverId, _rating);
            if (context.mounted) {
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Thanks for your feedback!")),
              );
            }
          },
          child: const Text("Submit"),
        ),
      ],
    );
  }

  Future<void> _submitRating(String driverId, double rating) async {
    if ((driverId).isEmpty || rating <= 0) return;

    final driverRef = FirebaseFirestore.instance
        .collection('drivers')
        .doc(driverId);

    await FirebaseFirestore.instance.runTransaction((transaction) async {
      final snapshot = await transaction.get(driverRef);
      if (!snapshot.exists) {
        throw Exception("Driver not found");
      }
      final data = snapshot.data()!;
      final int ratingCount = (data['ratingCount'] ?? 0) as int;
      final double avgRating = (data['avgRating'] ?? 0.0).toDouble();

      final newCount = ratingCount + 1;
      final newAvg = ((avgRating * ratingCount) + rating) / newCount;

      transaction.update(driverRef, {
        'ratingCount': newCount,
        'avgRating': newAvg,
      });
    });
  }
}

/// ---------------- SOS Button (active rides only) ----------------
class SOSButton extends StatelessWidget {
  final Map<String, dynamic> ride;
  const SOSButton({super.key, required this.ride});

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      icon: const Icon(Icons.sos),
      onPressed: () async {
        try {
          await EmergencyService.sendEmergency(
            rideId: ride['id'],
            currentUid: FirebaseAuth.instance.currentUser!.uid,
            otherUid: ride['driverId'] ?? '',
          );
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Emergency reported successfully")),
            );
            showEmergencyAlert(rideId: ride['id']);
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text("Error: $e")));
          }
        }
      },
      label: const Text("SOS"),
      style: FilledButton.styleFrom(backgroundColor: Colors.red),
    );
  }
}

/// ---------------- Driver Details (live) ----------------
class DriverDetailsWidget extends StatelessWidget {
  final String driverId;
  const DriverDetailsWidget({super.key, required this.driverId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(driverId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }
        final d = snapshot.data!.data()! as Map<String, dynamic>;
        final veh = (d['vehicle'] ?? {}) as Map<String, dynamic>;
        return Card(
          margin: const EdgeInsets.all(12),
          child: ListTile(
            leading: CircleAvatar(
              backgroundImage:
                  (d['photoUrl'] != null &&
                      (d['photoUrl'] as String).isNotEmpty)
                  ? NetworkImage(d['photoUrl'])
                  : null,
              radius: 24,
              child:
                  (d['photoUrl'] == null || (d['photoUrl'] as String).isEmpty)
                  ? const Icon(Icons.person)
                  : null,
            ),
            title: Text(d['username'] ?? 'Driver'),
            subtitle: Text("⭐ ${(d['averageRating'] ?? 'N/A').toString()}"),
            trailing: Text(
              '${veh['make'] ?? '—'} ${veh['model'] ?? ''}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ).animate().slideX(begin: 1, duration: 250.ms);
      },
    );
  }
}

/// ---------------- Share Trip ----------------
class ShareTripButton extends StatelessWidget {
  final String rideId;
  const ShareTripButton({super.key, required this.rideId});

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: () async {
        try {
          await ShareService().shareTripStatus(
            rideId: rideId,
            userId: FirebaseAuth.instance.currentUser!.uid,
          );
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Trip status shared')));
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Error sharing trip: $e')));
          }
        }
      },
      icon: const Icon(Icons.share),
      label: const Text('Share Trip Status'),
    );
  }
}

/// ---------------- Receipt (shows when completed) ----------------
class ReceiptWidget extends StatelessWidget {
  final Map<String, dynamic> ride;
  const ReceiptWidget({super.key, required this.ride});

  @override
  Widget build(BuildContext context) {
    if (ride['status'] != 'completed') return const SizedBox.shrink();

    final fare = (ride['fare'] as num?)?.toDouble() ?? 0;
    final ts = (ride['createdAt'] as Timestamp?)?.toDate();

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Receipt', style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            Text('Pickup: ${ride['pickup']}'),
            Text('Dropoff: ${ride['dropoff']}'),
            Text('Fare: \$${fare.toStringAsFixed(2)}'),
            Text('Payment: ${ride['paymentMethod'] ?? '—'}'),
            if (ts != null) Text('Date: $ts'),
          ],
        ),
      ),
    ).animate().fadeIn(duration: 250.ms);
  }
}

/// ---------------- Past Rides Page ----------------
class PastRidesListWidget extends StatelessWidget {
  const PastRidesListWidget({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(title: const Text("Past Rides")),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('rides')
            .where('riderId', isEqualTo: uid)
            .where('status', isEqualTo: 'completed')
            .orderBy('completedAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.data!.docs.isEmpty) {
            return const Center(child: Text("No past rides found"));
          }
          return ListView(
            children: snapshot.data!.docs.map((doc) {
              final ride = doc.data() as Map<String, dynamic>;
              final fare = (ride['fare'] as num?)?.toDouble() ?? 0;
              final completedAt = (ride['completedAt'] as Timestamp?)?.toDate();
              return ListTile(
                leading: const Icon(Icons.receipt_long),
                title: Text("${ride['pickup']} → ${ride['dropoff']}"),
                subtitle: Text(
                  "Fare: \$${fare.toStringAsFixed(2)} • ${ride['rideType'] ?? '—'}"
                  "${completedAt != null ? " • ${completedAt.toLocal()}" : ""}",
                ),
                onTap: () {
                  showDialog(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Ride Receipt'),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('From: ${ride['pickup']}'),
                          Text('To: ${ride['dropoff']}'),
                          Text('Fare: \$${fare.toStringAsFixed(2)}'),
                          Text('Ride Type: ${ride['rideType'] ?? '—'}'),
                          Text('Payment: ${ride['paymentMethod'] ?? '—'}'),
                          if (completedAt != null)
                            Text('Completed: $completedAt'),
                        ],
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  );
                },
              );
            }).toList(),
          );
        },
      ),
    );
  }
}

class CounterFareModalLauncher extends StatefulWidget {
  final Map<String, dynamic> ride;
  const CounterFareModalLauncher({super.key, required this.ride});

  @override
  State<CounterFareModalLauncher> createState() =>
      _CounterFareModalLauncherState();
}

class _CounterFareModalLauncherState extends State<CounterFareModalLauncher> {
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  @override
  void didUpdateWidget(covariant CounterFareModalLauncher oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShow());
  }

  void _maybeShow() {
    if (_shown) return;

    final cf = (widget.ride['counterFare'] as num?)?.toDouble();
    if (cf == null) return;

    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return;

    final rid = widget.ride['id'] as String?;
    if (rid == null || rid.isEmpty) return;

    _shown = true;

    // Schedule dialog safely after the current frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      // Hook for your backend/state logic
      showCounterFare(rideId: rid);

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CounterFareDialog(ride: widget.ride, ttlSeconds: 15),
      ).then((_) {
        // Reset only once the dialog is fully dismissed
        _shown = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _CounterFareDialog extends ConsumerStatefulWidget {
  final Map<String, dynamic> ride;
  final int ttlSeconds; // countdown length
  const _CounterFareDialog({
    required this.ride,
    this.ttlSeconds = 15, // default 30s
  });

  @override
  ConsumerState<_CounterFareDialog> createState() => _CounterFareDialogState();
}

class _CounterFareDialogState extends ConsumerState<_CounterFareDialog> {
  late int _remaining;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _remaining = widget.ttlSeconds;

    // start 1s countdown
    _timer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!mounted) return;
      setState(() => _remaining--);

      // Auto-expire when countdown hits 0
      if (_remaining <= 0) {
        t.cancel();
        _timer = null;
        try {
          await ref
              .read(riderDashboardProvider.notifier)
              .expireCounterFare(widget.ride['id']);
        } catch (_) {
          // swallow — UI will still close when counter value disappears
        }
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop(); // auto-hide
        }
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cf = (widget.ride['counterFare'] as num?)?.toDouble() ?? 0;
    final baseFare = (widget.ride['fare'] as num?)?.toDouble() ?? 0;
    final pickup = (widget.ride['pickup'] ?? '—').toString();
    final dropoff = (widget.ride['dropoff'] ?? '—').toString();

    return AlertDialog(
      title: Row(
        children: [
          const Text('Driver Counter-Offer'),
          const Spacer(),
          // small countdown pill
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black12,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('${_remaining}s'),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('From: $pickup'),
          Text('To:   $dropoff'),
          const SizedBox(height: 8),
          Text('Your fare:  \$${baseFare.toStringAsFixed(2)}'),
          Text(
            'Counter:   \$${cf.toStringAsFixed(2)}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          const Text(
            'If you don’t respond, this counter will auto-expire.',
            style: TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            try {
              await ref
                  .read(riderDashboardProvider.notifier)
                  .handleCounterFare(widget.ride['id'], cf, false);

              showCounterFareRejected(rideId: widget.ride['id']);

              if (context.mounted) {
                Navigator.of(context, rootNavigator: true).pop();
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Error: $e')));
              }
            }
          },
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: const Text('Reject'),
        ),

        FilledButton(
          onPressed: () async {
            try {
              await ref
                  .read(riderDashboardProvider.notifier)
                  .handleCounterFare(widget.ride['id'], cf, true);

              showCounterFareAccepted(rideId: widget.ride['id']);

              if (context.mounted) {
                Navigator.of(context, rootNavigator: true).pop();
              }
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Error: $e')));
              }
            }
          },
          child: const Text('Accept'),
        ),
      ],
    );
  }
}

class RideOption {
  final String key; // "Ride mini", "Ride X", etc.
  final String label; // visible label
  final IconData icon; // leading icon
  const RideOption(this.key, this.label, this.icon);
}

class RideTypePicker extends StatelessWidget {
  final List<RideOption> options;
  final String selected;
  final ValueChanged<String> onChanged;

  const RideTypePicker({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return SizedBox(
      height: 72,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: options.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final opt = options[i];
          final isSelected = opt.key == selected;

          return InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => onChanged(opt.key),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isSelected ? cs.primary.withAlpha(26) : cs.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isSelected ? cs.primary : cs.outlineVariant,
                  width: isSelected ? 1.6 : 1,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: cs.primary.withAlpha(31),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : const [],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    opt.icon,
                    color: isSelected ? cs.primary : cs.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    opt.label,
                    style: TextStyle(
                      color: isSelected ? cs.primary : cs.onSurface,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// ---------------- Small shared UI helpers ----------------
class _DrawerTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  const _DrawerTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: cs.onSurfaceVariant),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      visualDensity: VisualDensity.compact,
      trailing: const Icon(Icons.chevron_right_rounded),
    );
  }
}

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _InfoPill({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.surfaceContainer, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06 * 255),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.labelLarge),
                  Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Frosted extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const _Frosted({
    required this.child,
    this.padding = const EdgeInsets.all(12),
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: cs.surface.withValues(alpha: 209.1),
            border: Border.all(color: cs.surfaceContainer, width: 1),
          ),
          child: child,
        ),
      ),
    );
  }
}

// --- Brand-themed floating controls with frosted card ---
class _MapControls extends StatelessWidget {
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onRecenter;
  final bool trafficEnabled;
  final VoidCallback onToggleTraffic;
  final MapType mapType;
  final VoidCallback onToggleMapType;

  const _MapControls({
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onRecenter,
    required this.trafficEnabled,
    required this.onToggleTraffic,
    required this.mapType,
    required this.onToggleMapType,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return _Frosted(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RoundIconButton(
            icon: Icons.add,
            tooltip: 'Zoom in',
            onPressed: onZoomIn,
            background: cs.primary,
            foreground: cs.onPrimary,
          ),
          const SizedBox(height: 8),
          _RoundIconButton(
            icon: Icons.remove,
            tooltip: 'Zoom out',
            onPressed: onZoomOut,
            background: cs.surface,
            foreground: cs.onSurface,
            borderColor: cs.surfaceContainer,
          ),
          const SizedBox(height: 8),
          _RoundIconButton(
            icon: Icons.my_location_rounded,
            tooltip: 'Recenter',
            onPressed: onRecenter,
            background: cs.surface,
            foreground: cs.primary,
            borderColor: cs.surfaceContainer,
          ),
          const SizedBox(height: 8),
          _RoundIconButton(
            icon: trafficEnabled
                ? Icons.traffic_rounded
                : Icons.traffic_outlined,
            tooltip: trafficEnabled ? 'Hide traffic' : 'Show traffic',
            onPressed: onToggleTraffic,
            background: trafficEnabled ? cs.primary : cs.surface,
            foreground: trafficEnabled ? cs.onPrimary : cs.primary,
            borderColor: cs.surfaceContainer,
          ),
          const SizedBox(height: 8),
          _RoundIconButton(
            icon: mapType == MapType.normal
                ? Icons.layers_rounded
                : Icons.satellite_alt_rounded,
            tooltip: mapType == MapType.normal ? 'Satellite' : 'Default map',
            onPressed: onToggleMapType,
            background: cs.surface,
            foreground: cs.onSurface,
            borderColor: cs.surfaceContainer,
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? background;
  final Color? foreground;
  final Color? borderColor;

  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.background,
    this.foreground,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Material(
        color: background ?? Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: borderColor ?? Colors.transparent, width: 1),
        ),
        elevation: 2,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 22, color: foreground),
          ),
        ),
      ),
    );
  }
}

class _RiderCancelButton extends ConsumerWidget {
  final String rideId;
  const _RiderCancelButton({required this.rideId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: const Icon(Icons.cancel),
      label: const Text('Cancel ride'),
      onPressed: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Cancel this ride?'),
            content: const Text(
              'Are you sure you want to cancel? Your driver will be notified.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('No'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Yes, cancel'),
              ),
            ],
          ),
        );
        if (ok != true) return;

        try {
          await ref.read(riderDashboardProvider.notifier).cancelRide(rideId);
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('Ride cancelled')));
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Failed to cancel: $e')));
          }
        }
      },
    );
  }
}

class _RiderNavMap extends ConsumerStatefulWidget {
  final String rideId;
  final String driverId;
  final LatLng dropoff;
  final LatLng? pickup; // optional; used to seed the first route

  const _RiderNavMap({
    required this.rideId,
    required this.driverId,
    required this.dropoff,
    this.pickup,
  });

  @override
  ConsumerState<_RiderNavMap> createState() => _RiderNavMapState();
}

class _RiderNavMapState extends ConsumerState<_RiderNavMap> {
  final _log = Logger();

  GoogleMapController? _ctrl;

  // Route
  List<LatLng> _route = <LatLng>[];
  List<LatLng> _covered = <LatLng>[];
  List<LatLng> _remaining = <LatLng>[];
  Polyline? _polyCovered;
  Polyline? _polyRemaining;

  // Follow-cam & reroute guards
  DateTime _lastBuiltAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _offRouteHits = 0;
  static const _offRouteThresholdM = 30.0;
  static const _offRouteHitsToReroute = 3;
  static const _rebuildCooldownSec = 8;

  @override
  void initState() {
    super.initState();
    // Seed route from pickup→dropoff if pickup provided; else from dropoff→dropoff (no-op) until first driver point arrives.
    final seedStart = widget.pickup ?? widget.dropoff;
    _buildRoute(from: seedStart, to: widget.dropoff);
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  // -------- Route building / trimming ---------------------------------------
  Future<void> _buildRoute({required LatLng from, required LatLng to}) async {
    try {
      final pts = await MapService().getRoute(from, to);
      if (!mounted || pts.isEmpty) return;

      setState(() {
        _route = pts;
        _covered = [_route.first];
        _remaining = List<LatLng>.from(_route);
        _polyCovered = Polyline(
          polylineId: const PolylineId('covered'),
          points: _covered,
          color: Colors.grey,
          width: 6,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
        );
        _polyRemaining = Polyline(
          polylineId: const PolylineId('remaining'),
          points: _remaining,
          color: Colors.blueAccent,
          width: 6,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
          jointType: JointType.round,
        );
      });

      // Fit initial bounds
      if (_ctrl != null && _route.length >= 2) {
        final a = _route.first, b = _route.last;
        final sw = LatLng(
          (a.latitude < b.latitude) ? a.latitude : b.latitude,
          (a.longitude < b.longitude) ? a.longitude : b.longitude,
        );
        final ne = LatLng(
          (a.latitude > b.latitude) ? a.latitude : b.latitude,
          (a.longitude > b.longitude) ? a.longitude : b.longitude,
        );
        await _ctrl!.animateCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(southwest: sw, northeast: ne),
            60,
          ),
        );
      }

      _lastBuiltAt = DateTime.now();
      _offRouteHits = 0;
    } catch (e) {
      _log.e('[RiderNav] buildRoute failed: $e');
    }
  }

  void _trimWith(LatLng cur) {
    if (_route.length < 2) return;

    final idx = _nearestIndex(cur, startFrom: 0);
    final safeIdx = idx.clamp(0, _route.length - 1);

    final newCovered = _route.sublist(0, safeIdx + 1);
    final newRemaining = [cur, ..._route.sublist(safeIdx + 1)];

    setState(() {
      _covered = newCovered;
      _remaining = newRemaining;
      _polyCovered =
          _polyCovered?.copyWith(pointsParam: _covered) ??
          Polyline(
            polylineId: const PolylineId('covered'),
            points: _covered,
            color: Colors.grey,
            width: 6,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          );
      _polyRemaining =
          _polyRemaining?.copyWith(pointsParam: _remaining) ??
          Polyline(
            polylineId: const PolylineId('remaining'),
            points: _remaining,
            color: Colors.blueAccent,
            width: 6,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
            jointType: JointType.round,
          );
    });
  }

  int _nearestIndex(LatLng p, {int startFrom = 0}) {
    double best = double.infinity;
    int bestIdx = startFrom.clamp(0, _route.length - 1);
    for (int i = startFrom; i < _route.length; i++) {
      final d = Geolocator.distanceBetween(
        p.latitude,
        p.longitude,
        _route[i].latitude,
        _route[i].longitude,
      );
      if (d < best) {
        best = d;
        bestIdx = i;
      }
      if (i - startFrom > 200) break; // cheap early-exit
    }
    return bestIdx;
  }

  double _bearing(LatLng a, LatLng b) {
    double toRad(double d) => d * (3.141592653589793 / 180.0);
    double toDeg(double r) => r * (180.0 / 3.141592653589793);
    final lat1 = toRad(a.latitude), lat2 = toRad(b.latitude);
    final dLon = toRad(b.longitude - a.longitude);
    final y = math.sin(dLon) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (toDeg(math.atan2(y, x)) + 360.0) % 360.0;
  }

  void _maybeReroute(LatLng cur) {
    if (_route.isEmpty) return;

    final idx = _nearestIndex(cur);
    final nearest = _route[idx];
    final dist = Geolocator.distanceBetween(
      cur.latitude,
      cur.longitude,
      nearest.latitude,
      nearest.longitude,
    );

    _offRouteHits = dist > _offRouteThresholdM ? _offRouteHits + 1 : 0;

    final cooldownOk =
        DateTime.now().difference(_lastBuiltAt).inSeconds > _rebuildCooldownSec;
    if (_offRouteHits >= _offRouteHitsToReroute && cooldownOk) {
      _offRouteHits = 0;
      _buildRoute(from: cur, to: widget.dropoff);
    }
  }

  // -------- Build ------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final driverPos = ref.watch(driverLocationProvider(widget.driverId)).value;

    // Smooth follow + trim each time driver moves
    if (driverPos != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;

        // Follow-cam with tilt & bearing
        double br = 0;
        if (_remaining.length >= 2) {
          br = _bearing(_remaining.first, _remaining[1]);
        }
        await _ctrl?.animateCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(target: driverPos, zoom: 17, tilt: 45, bearing: br),
          ),
        );

        // Trim and maybe reroute
        _trimWith(driverPos);
        _maybeReroute(driverPos);
      });
    }

    final markers = <Marker>{
      if (driverPos != null)
        Marker(
          markerId: const MarkerId('driver'),
          position: driverPos,
          rotation: 0,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueOrange,
          ),
        ),
      // Keep only dropoff marker in nav mode
      Marker(
        markerId: const MarkerId('dropoff'),
        position: widget.dropoff,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ),
    };

    final polylines = <Polyline>{
      if (_polyCovered != null) _polyCovered!,
      if (_polyRemaining != null) _polyRemaining!,
    };

    return GoogleMap(
      initialCameraPosition: CameraPosition(target: widget.dropoff, zoom: 15),
      markers: markers,
      polylines: polylines,
      myLocationEnabled: false,
      myLocationButtonEnabled: false,
      compassEnabled: false,
      zoomControlsEnabled: false,
      mapToolbarEnabled: false,
      onMapCreated: (c) => _ctrl = c,
    );
  }
}
