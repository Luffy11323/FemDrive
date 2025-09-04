// rider_dashboard.dart

import 'dart:async';
import 'dart:math';

import 'package:femdrive/emergency_service.dart';
import 'package:femdrive/rider/nearby_drivers_service.dart';
import 'package:femdrive/rider/rider_dashboard_controller.dart';
import 'package:femdrive/rider/rider_services.dart'; // MapService, GeocodingService
import 'package:femdrive/widgets/payment_services.dart';
import 'package:femdrive/widgets/share_service.dart';
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

/// Provides nearby online drivers (live updates) for the map overlay
final nearbyDriversProvider =
    StreamProvider.autoDispose<List<Map<String, dynamic>>>((ref) async* {
      final loc = await MapService().currentLocation();
      yield* NearbyDriversService().streamNearbyDrivers(loc);
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

  double? _fare;
  int? _eta;
  double? _distanceKm;

  LatLng? _pickupLatLng;
  LatLng? _dropoffLatLng;

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

  Future<void> _loadCurrentLocation() async {
    try {
      final loc = await MapService().currentLocation();
      setState(() => _currentLocation = loc);

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

  Future<void> _panTo(LatLng? pos) async {
    if (pos == null || _mapController == null) return;
    try {
      await _mapController!.animateCamera(CameraUpdate.newLatLngZoom(pos, 15));
    } catch (e) {
      _logger.e('Map pan failed: $e');
    }
  }

  Future<void> _updateRouteAndFare() async {
    if (_pickupLatLng == null || _dropoffLatLng == null) return;

    try {
      final routePoints = await MapService().getRoute(
        _pickupLatLng!,
        _dropoffLatLng!,
      );

      final result = await MapService().getRateAndEta(
        _pickupController.text.trim(),
        _dropoffController.text.trim(),
        'Economy',
      );

      setState(() {
        _fare = result['total']?.toDouble();
        _eta = result['etaMinutes']?.toInt();
        _distanceKm = result['distanceKm']?.toDouble();
        _polylines = {
          Polyline(
            polylineId: const PolylineId('route'),
            points: routePoints,
            color: Colors.blue,
            width: 5,
          ),
        };
      });

      if (_mapController != null) {
        final bounds = LatLngBounds(
          southwest: LatLng(
            min(_pickupLatLng!.latitude, _dropoffLatLng!.latitude),
            min(_pickupLatLng!.longitude, _dropoffLatLng!.longitude),
          ),
          northeast: LatLng(
            max(_pickupLatLng!.latitude, _dropoffLatLng!.latitude),
            max(_pickupLatLng!.longitude, _dropoffLatLng!.longitude),
          ),
        );
        await _mapController!.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, 50),
        );
      }
    } catch (e) {
      _logger.e('Failed to update route/fare: $e');
    }
  }

  Widget _buildLocationPicker() {
    Widget buildTypeAheadField({
      required TextEditingController controller,
      required String label,
      required bool isPickup,
    }) {
      return TypeAheadField<PlacePrediction>(
        suggestionsCallback: (query) async {
          if (query.isEmpty || _currentLocation == null) return [];
          try {
            return await MapService().getPlaceSuggestions(
              query,
              _currentLocation!.latitude,
              _currentLocation!.longitude,
            );
          } catch (e) {
            _logger.e('Autocomplete error: $e');
            return [];
          }
        },
        itemBuilder: (context, prediction) =>
            ListTile(title: Text(prediction.description)),
        onSelected: (prediction) async {
          controller.text = prediction.description;
          try {
            final latLng = await MapService().getLatLngFromPlaceId(
              prediction.placeId,
            );
            if (latLng != null) {
              setState(() {
                if (isPickup) {
                  _pickupLatLng = latLng;
                } else {
                  _dropoffLatLng = latLng;
                }
              });
              await _updateRouteAndFare();
              await _panTo(latLng);
            }
          } catch (e) {
            _logger.e('Failed to set $label LatLng on selection: $e');
          }
        },
        builder: (context, textEditingController, focusNode) {
          return TextField(
            controller: controller,
            focusNode: focusNode,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
          );
        },
      );
    }

    return Column(
      children: [
        buildTypeAheadField(
          controller: _pickupController,
          label: 'Pickup Location',
          isPickup: true,
        ),
        const SizedBox(height: 8),
        buildTypeAheadField(
          controller: _dropoffController,
          label: 'Dropoff Location',
          isPickup: false,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ridesAsync = ref.watch(riderDashboardProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Rider Dashboard')),
      drawer: _buildDrawer(context),
      body: Stack(
        children: [
          Consumer(
            builder: (context, ref, _) {
              final nearbyAsync = ref.watch(nearbyDriversProvider);
              return nearbyAsync.when(
                data: (drivers) {
                  final markers = <Marker>{
                    if (_currentLocation != null)
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
                    ...drivers.where((d) => d['location'] != null).map((d) {
                      final gp = d['location'];
                      if (gp is! GeoPoint) return null;

                      final id = (d['id'] ?? d['uid'] ?? UniqueKey().toString())
                          .toString();
                      final username = (d['username'] ?? 'Driver').toString();
                      final rating = (d['rating'] ?? '—').toString();
                      final rideType = (d['rideType'] ?? '—').toString();

                      return Marker(
                        markerId: MarkerId('driver_$id'),
                        position: LatLng(gp.latitude, gp.longitude),
                        icon: BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueOrange,
                        ),
                        infoWindow: InfoWindow(
                          title: username,
                          snippet: '⭐ $rating • $rideType',
                        ),
                      );
                    }).whereType<Marker>(),
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
                        padding: EdgeInsets.only(bottom: 260),
                        onMapCreated: (controller) =>
                            _mapController = controller,
                        myLocationEnabled: true,
                        myLocationButtonEnabled: true,
                        markers: markers,
                        polylines: _polylines,
                      ),

                      if (drivers.isEmpty)
                        Positioned(
                          top: 20,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 153),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                'No nearby drivers available',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, st) => Center(child: Text("Map error: $e")),
              );
            },
          ),

          if (_fare != null && _eta != null && _distanceKm != null)
            Positioned(
              top: 80,
              left: 16,
              right: 16,
              child: Card(
                color: Colors.white70,
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Text('Fare: \$${_fare!.toStringAsFixed(2)}'),
                      Text('ETA: ${_eta!} min'),
                      Text('Distance: ${_distanceKm!.toStringAsFixed(1)} km'),
                    ],
                  ),
                ),
              ),
            ),

          ridesAsync.when(
            data: (rideData) {
              if (rideData == null || rideData.isEmpty) {
                return const SizedBox.shrink();
              }

              final ride = rideData;
              final status = (ride['status'] ?? '').toString();

              return Stack(
                children: [
                  Align(
                    alignment: Alignment.topCenter,
                    child: RideStatusWidget(ride: ride),
                  ),
                  if (ride['driverId'] != null)
                    Align(
                      alignment: Alignment.topRight,
                      child: DriverDetailsWidget(driverId: ride['driverId']),
                    ),
                  if (ride['counterFare'] != null &&
                      status != 'completed' &&
                      status != 'cancelled')
                    Align(
                      alignment: Alignment.center,
                      child: CounterFareWidget(rideId: ride['id']),
                    ),
                  if (status == 'accepted' ||
                      status == 'in_progress' ||
                      status == 'onTrip')
                    Positioned(
                      bottom: 160,
                      right: 16,
                      child: ShareTripButton(rideId: ride['id']),
                    ),
                  if (status != 'completed' && status != 'cancelled')
                    Positioned(
                      bottom: 100,
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

          Align(
            alignment: Alignment.bottomCenter,
            child: DraggableScrollableSheet(
              initialChildSize: 0.35,
              minChildSize: 0.2,
              maxChildSize: 0.88,
              builder: (_, controller) => RideForm(
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

                      // Fit after state is applied
                      if (_pickupLatLng != null && _dropoffLatLng != null) {
                        await _fitToBounds(_pickupLatLng!, _dropoffLatLng!);
                      }
                    },
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          showModalBottomSheet(
            context: context,
            builder: (context) => Padding(
              padding: const EdgeInsets.all(16.0),
              child: _buildLocationPicker(),
            ),
          );
        },
        child: const Icon(Icons.add_location),
      ),
    );
  }

  Drawer _buildDrawer(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          const DrawerHeader(
            decoration: BoxDecoration(color: Color.fromARGB(255, 226, 58, 162)),
            child: Text(
              'FemDrive Menu',
              style: TextStyle(color: Colors.white, fontSize: 20),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.person),
            title: const Text('Profile'),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/profile');
            },
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('Past Rides'),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/past-rides');
            },
          ),
          ListTile(
            leading: const Icon(Icons.payment),
            title: const Text('Payment Methods'),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/payment');
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Settings'),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/settings');
            },
          ),
          ListTile(
            leading: const Icon(Icons.help),
            title: const Text('Help & Support'),
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/help-center');
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Logout'),
            onTap: () async {
              await FirebaseAuth.instance.signOut();
              if (context.mounted) {
                Navigator.of(context).pushReplacementNamed('/');
              }
            },
          ),
        ],
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
  String? _selectedRideType = 'Economy';
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
        _selectedRideType ?? 'Economy',
      );

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
          min(_pickupLatLng!.latitude, _dropoffLatLng!.latitude),
          min(_pickupLatLng!.longitude, _dropoffLatLng!.longitude),
        );
        var ne = LatLng(
          max(_pickupLatLng!.latitude, _dropoffLatLng!.latitude),
          max(_pickupLatLng!.longitude, _dropoffLatLng!.longitude),
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
        ref,
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
    return Material(
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      child: SingleChildScrollView(
        controller: widget.scrollController,
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            /// Pickup
            Material(
              // ensures ink/taps work above sheets/maps
              color: Colors.transparent,
              child: TypeAheadField<PlacePrediction>(
                // 🔑 make TA listen to YOUR controller & focus node
                controller: _pickupController,
                focusNode: _pickupFocus,
                suggestionsController: _pickupSuggestionsCtl,

                // UX & robustness
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
                  _pickupController.text = p.description; // keep UI in sync
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

                  // recenter nearby drivers
                  ref.read(driverSearchCenterProvider.notifier).state = latLng;

                  await _updateRouteAndFare(sendMarkers: true);
                  await _panTo(latLng);
                },

                // build the text field (use the provided controller/focus)
                builder: (context, providedController, providedFocusNode) {
                  return TextField(
                    controller: providedController,
                    focusNode: providedFocusNode,
                    decoration: const InputDecoration(
                      labelText: 'Pickup Location',
                      border: OutlineInputBorder(),
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
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),

            /// Ride Type
            DropdownButtonFormField<String>(
              initialValue: _selectedRideType,
              decoration: const InputDecoration(
                labelText: 'Ride Type',
                border: OutlineInputBorder(),
              ),
              items: const [
                'Economy',
                'Premium',
                'XL',
                'Electric',
              ].map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
              onChanged: (v) async {
                setState(() => _selectedRideType = v);
                await _updateRouteAndFare();
              },
            ),
            const SizedBox(height: 12),

            /// Payment Method
            DropdownButtonFormField<String>(
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
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            ElevatedButton(
              onPressed:
                  (_fare != null &&
                      _pickupLatLng != null &&
                      _dropoffLatLng != null &&
                      _selectedPaymentMethod != null)
                  ? _requestRide
                  : null,
              child: Text(
                _fare == null
                    ? 'Request Ride'
                    : 'Request Ride (\$${_fare!.toStringAsFixed(2)})',
              ),
            ),

            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
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
      child: Container(
        margin: const EdgeInsets.only(top: 40),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withAlpha((0.75 * 255).round()),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.directions_car, color: Colors.white, size: 16),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Ride: $pickup → $dropoff | Status: $status',
                style: const TextStyle(color: Colors.white),
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
                    builder: (_) =>
                        _buildRatingDialog(context, ride['driverId']),
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
        ElevatedButton(
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
    return ElevatedButton.icon(
      icon: const Icon(Icons.sos),
      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
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

/// ---------------- Counter Fare (accept / reject) ----------------
class CounterFareWidget extends ConsumerWidget {
  final String rideId;
  const CounterFareWidget({super.key, required this.rideId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('rides')
          .doc(rideId)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data?.data() == null) {
          return const SizedBox.shrink();
        }
        final ride = snapshot.data!.data()! as Map<String, dynamic>;
        final cf = (ride['counterFare'] as num?)?.toDouble();
        if (cf == null) return const SizedBox.shrink();

        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Driver Counter-Offer',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text('Proposed Fare: \$${cf.toStringAsFixed(2)}'),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          try {
                            await ref
                                .read(riderDashboardProvider.notifier)
                                .handleCounterFare(rideId, cf, true);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Counter-offer accepted'),
                                ),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Error: $e')),
                              );
                            }
                          }
                        },
                        child: const Text('Accept'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          try {
                            await ref
                                .read(riderDashboardProvider.notifier)
                                .handleCounterFare(rideId, cf, false);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Counter-offer rejected'),
                                ),
                              );
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Error: $e')),
                              );
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                        ),
                        child: const Text('Reject'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ).animate().fadeIn(duration: 250.ms);
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
    return ElevatedButton.icon(
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
