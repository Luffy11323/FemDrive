// rider_dashboard.dart
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui; // for BackdropFilter blur

import 'package:async/async.dart';
import 'package:femdrive/shared/emergency_service.dart';
import 'package:femdrive/rider/nearby_drivers_service.dart';
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
final nearbyDriversProvider =
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) async* {
      final loc = await MapService().currentLocation();
      yield* NearbyDriversService().streamNearbyDriversFast(
        loc,
      ); // RTDB version
    });

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

    final hasActive = const {
      'pending',
      'searching',
      'accepted',
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
                    final markers = <Marker>{
                      if (_currentLocation != null &&
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
                      if (_pickupLatLng != null)
                        Marker(
                          markerId: const MarkerId("pickup"),
                          position: _pickupLatLng!,
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueGreen,
                          ),
                        ),
                      if (_dropoffLatLng != null)
                        Marker(
                          markerId: const MarkerId("dropoff"),
                          position: _dropoffLatLng!,
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueRed,
                          ),
                        ),
                      if (driverLatLng != null)
                        Marker(
                          markerId: const MarkerId('driver_live'),
                          position: driverLatLng,
                          icon: BitmapDescriptor.defaultMarkerWithHue(
                            BitmapDescriptor.hueOrange,
                          ),
                          infoWindow: const InfoWindow(title: 'Driver'),
                        ),

                      ...drivers
                          .where((d) => d['location'] != null)
                          .where(
                            (d) => (d['id'] ?? d['uid']) != assignedDriverId,
                          ) // avoid duplicate
                          .map((d) {
                            final loc = d['location'];
                            LatLng? pos;
                            if (loc is GeoPoint) {
                              pos = LatLng(loc.latitude, loc.longitude);
                            } else if (loc is LatLng) {
                              pos = loc;
                            } else {
                              return null; // unknown type
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

                          // 🔽 Brand: use our custom controls instead of defaults
                          myLocationEnabled: true,
                          myLocationButtonEnabled: false,
                          compassEnabled: false,
                          zoomControlsEnabled: false,
                          mapToolbarEnabled: false,

                          // 🔽 Our themed flags
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
                      _drawRoute(
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
                    // Show current driver (live) → dropoff; fallback to current/pickup if needed
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
      }

      if (context.mounted) {
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ride requested successfully')),
        );
      }
    } catch (e) {
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
                RideOption('Electric', 'City to city', Icons.place_rounded),
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
    _maybeShow();
  }

  void _maybeShow() {
    if (_shown) return;
    final cf = (widget.ride['counterFare'] as num?)?.toDouble();
    if (cf == null) return;
    _shown = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CounterFareDialog(ride: widget.ride),
    ).then((_) => _shown = false);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class _CounterFareDialog extends ConsumerWidget {
  final Map<String, dynamic> ride;
  const _CounterFareDialog({required this.ride});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cf = (ride['counterFare'] as num?)?.toDouble() ?? 0;
    final baseFare = (ride['fare'] as num?)?.toDouble() ?? 0;
    final pickup = (ride['pickup'] ?? '—').toString();
    final dropoff = (ride['dropoff'] ?? '—').toString();

    return AlertDialog(
      title: const Text('Driver Counter-Offer'),
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
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            try {
              await ref
                  .read(riderDashboardProvider.notifier)
                  .handleCounterFare(ride['id'], cf, false);
              if (context.mounted) Navigator.pop(context);
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
                  .handleCounterFare(ride['id'], cf, true);
              if (context.mounted) Navigator.pop(context);
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
