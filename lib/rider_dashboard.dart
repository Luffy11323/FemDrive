// rider_dashboard.dart

import 'dart:async';
import 'dart:math';

import 'package:femdrive/emergency_service.dart';
import 'package:femdrive/location/directions_service.dart';
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
import 'package:carousel_slider/carousel_slider.dart' as cs;
import 'package:shimmer/shimmer.dart'; // Add to pubspec.yaml
// For Timer (already imported)
import 'package:geocoding/geocoding.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

final String googleApiKey = dotenv.env['GOOGLE_API_KEY'] ?? '';
final connectivityProvider = StreamProvider<ConnectivityResult>((ref) {
  return Connectivity().onConnectivityChanged.cast<ConnectivityResult>();
});

final locationPermissionProvider = FutureProvider<bool>((ref) async {
  final permission = await Permission.location.request();
  return permission == PermissionStatus.granted;
});

final nearbyDriversProvider =
    StreamProvider.family<List<Map<String, dynamic>>, LatLng>((
      ref,
      center,
    ) async* {
      yield* NearbyDriversService().streamNearbyDrivers(center);
    });

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
  LatLng? _pickupLatLng;
  LatLng? _dropoffLatLng;
  String _selectedRideType = 'Economy';
  final List<String> _rideTypes = ['Economy', 'Premium', 'SUV'];
  bool _isLoadingRoute = false;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _loadCurrentLocation();
  }

  @override
  void dispose() {
    _pickupController.dispose();
    _dropoffController.dispose();
    _debounceTimer?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentLocation() async {
    try {
      final loc = await MapService().currentLocation();
      setState(() => _currentLocation = loc);

      // Reverse geocode for default pickup address
      List<Placemark> placemarks = await placemarkFromCoordinates(
        loc.latitude,
        loc.longitude,
      );
      if (placemarks.isNotEmpty) {
        _pickupController.text =
            '${placemarks[0].name ?? ''}, ${placemarks[0].locality ?? ''}, ${placemarks[0].country ?? ''}';
        _pickupLatLng = loc;
        _updateNearbyDrivers(loc);
      }
      await _panTo(loc);
    } catch (e) {
      _logger.e("Failed to fetch current location: $e");
      if (context.mounted) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Location error: $e')));
      }
    }
  }

  Future<void> _panTo(LatLng? pos) async {
    if (pos == null || _mapController == null) return;
    try {
      await _mapController!.animateCamera(CameraUpdate.newLatLngZoom(pos, 15));
    } catch (e) {
      _logger.e('Map pan failed: $e');
    }
  }

  void _updateNearbyDrivers(LatLng center) {
    ref.read(nearbyDriversProvider(center));
  }

  Future<void> _updateRouteAndFare() async {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(Duration(milliseconds: 500), () async {
      if (_pickupLatLng == null || _dropoffLatLng == null) return;
      setState(() => _isLoadingRoute = true);
      try {
        final routePoints = await MapService().getRoute(
          _pickupLatLng!,
          _dropoffLatLng!,
        );
        final result = await MapService().getRateAndEtaFromCoords(
          _pickupLatLng!,
          _dropoffLatLng!,
          _selectedRideType,
        );
        setState(() {
          _fare = result['total'];
          _eta = result['etaMinutes'];
          _polylines = {
            Polyline(
              polylineId: PolylineId('route'),
              points: routePoints,
              color: Colors.blue,
              width: 5,
            ),
          };
        });
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
        await _mapController?.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, 50),
        );
      } catch (e) {
        _logger.e('Failed to update route/fare: $e');
        if (context.mounted) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Route error: $e')));
        }
      } finally {
        setState(() => _isLoadingRoute = false);
      }
    });
  }

  Widget _buildLocationPicker() {
    return DraggableScrollableSheet(
      initialChildSize: 0.3,
      minChildSize: 0.1,
      maxChildSize: 0.6,
      builder: (_, controller) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          boxShadow: [BoxShadow(blurRadius: 10, color: Colors.black26)],
        ),
        child: ListView(
          controller: controller,
          padding: EdgeInsets.all(16),
          children: [
            // Ride Type Slider
            cs.CarouselSlider(
              options: cs.CarouselOptions(
                height: 80,
                enlargeCenterPage: true,
                enableInfiniteScroll: false,
                onPageChanged: (index, _) =>
                    setState(() => _selectedRideType = _rideTypes[index]),
              ),
              items: _rideTypes
                  .map(
                    (type) => Card(
                      elevation: 4,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      color: _selectedRideType == type
                          ? Colors.blueAccent
                          : Colors.grey[200],
                      child: Center(
                        child: Text(
                          type,
                          style: TextStyle(
                            fontSize: 18,
                            color: _selectedRideType == type
                                ? Colors.white
                                : Colors.black,
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
            SizedBox(height: 16),

            // Pickup Autocomplete
            TypeAheadField<Map<String, String>>(
              builder: (context, controller, focusNode) {
                return TextField(
                  controller: _pickupController,
                  focusNode: focusNode,
                  decoration: InputDecoration(
                    hintText: 'Pickup Location',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
              },
              suggestionsCallback: (pattern) async {
                if (pattern.length < 3) return [];
                return await DirectionsService.getAutocompleteSuggestions(
                  pattern,
                  _currentLocation ?? LatLng(37.7749, -122.4194),
                );
              },
              itemBuilder: (context, suggestion) =>
                  ListTile(title: Text(suggestion['description'] ?? '')),
              onSelected: (suggestion) async {
                try {
                  final placeId = suggestion['placeId']!;
                  final coords = await DirectionsService.getPlaceCoordinates(
                    placeId,
                  );
                  if (coords != null) {
                    _pickupLatLng = coords;
                    _pickupController.text = suggestion['description']!;
                    setState(() {});
                    await _panTo(_pickupLatLng);
                    _updateNearbyDrivers(_pickupLatLng!);
                    if (_dropoffLatLng != null) await _updateRouteAndFare();
                  }
                } catch (e) {
                  _logger.e('Failed to set pickup location: $e');
                  if (context.mounted) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('Pickup error: $e')));
                  }
                }
              },
            ),
            SizedBox(height: 8),

            // Dropoff Autocomplete
            TypeAheadField<Map<String, String>>(
              builder: (context, controller, focusNode) {
                return TextField(
                  controller: _dropoffController,
                  focusNode: focusNode,
                  decoration: InputDecoration(
                    hintText: 'Dropoff Location',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                );
              },
              suggestionsCallback: (pattern) async {
                if (pattern.length < 3) return [];
                return await DirectionsService.getAutocompleteSuggestions(
                  pattern,
                  _pickupLatLng ??
                      _currentLocation ??
                      LatLng(37.7749, -122.4194),
                );
              },
              itemBuilder: (context, suggestion) =>
                  ListTile(title: Text(suggestion['description'] ?? '')),
              onSelected: (suggestion) async {
                try {
                  final placeId = suggestion['placeId']!;
                  final coords = await DirectionsService.getPlaceCoordinates(
                    placeId,
                  );
                  if (coords != null) {
                    _dropoffLatLng = coords;
                    _dropoffController.text = suggestion['description']!;
                    setState(() {});
                    await _panTo(_dropoffLatLng);
                    if (_pickupLatLng != null) await _updateRouteAndFare();
                  }
                } catch (e) {
                  _logger.e('Failed to set dropoff location: $e');
                  if (context.mounted) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Dropoff error: $e')),
                    );
                  }
                }
              },
            ),
            SizedBox(height: 16),

            // Request Button with loading
            ElevatedButton(
              onPressed:
                  (_pickupLatLng != null &&
                      _dropoffLatLng != null &&
                      !_isLoadingRoute)
                  ? () async {
                      try {
                        await ref
                            .read(riderDashboardProvider.notifier)
                            .createRide(
                              _pickupController.text,
                              _dropoffController.text,
                              _fare ?? 0.0,
                              GeoPoint(
                                _pickupLatLng!.latitude,
                                _pickupLatLng!.longitude,
                              ),
                              GeoPoint(
                                _dropoffLatLng!.latitude,
                                _dropoffLatLng!.longitude,
                              ),
                              ref,
                              rideType: _selectedRideType,
                            );
                        if (context.mounted) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Ride requested!')),
                          );
                        }
                      } catch (e) {
                        if (context.mounted) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text('Error: $e')));
                        }
                      }
                    }
                  : null,
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isLoadingRoute
                  ? CircularProgressIndicator()
                  : Text('Request Ride'),
            ),

            // Fare and ETA Display
            if (_fare != null && _eta != null)
              Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text(
                  'Estimated Fare: \$${_fare!.toStringAsFixed(2)} | ETA: $_eta min',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(riderDashboardProvider);
    final connectivityAsync = ref.watch(connectivityProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rider Dashboard'),
        elevation: 0,
        backgroundColor: Theme.of(context).primaryColor,
      ),
      drawer: _buildDrawer(context),
      body: Stack(
        children: [
          Consumer(
            builder: (context, ref, _) {
              final nearbyAsync = ref.watch(
                nearbyDriversProvider(
                  _pickupLatLng ??
                      _currentLocation ??
                      LatLng(37.7749, -122.4194),
                ),
              );
              return nearbyAsync.when(
                data: (drivers) => GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target:
                        _currentLocation ?? const LatLng(37.7749, -122.4194),
                    zoom: 14,
                  ),
                  onMapCreated: (controller) => _mapController = controller,
                  myLocationEnabled: true,
                  myLocationButtonEnabled: true,
                  trafficEnabled: true,
                  markers: {
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
                    ...drivers.map((d) {
                      final gp = d['location'];
                      return Marker(
                        markerId: MarkerId(d['id'] ?? UniqueKey().toString()),
                        position: LatLng(gp.latitude, gp.longitude),
                        icon: BitmapDescriptor.defaultMarkerWithHue(
                          BitmapDescriptor.hueOrange,
                        ),
                        infoWindow: InfoWindow(
                          title: d['username'] ?? 'Driver',
                        ),
                      );
                    }),
                  },
                  polylines: _polylines,
                ),
                loading: () => Shimmer.fromColors(
                  baseColor: Colors.grey[300]!,
                  highlightColor: Colors.grey[100]!,
                  child: Container(color: Colors.white),
                ),
                error: (e, _) => Center(child: Text('Map error: $e')),
              );
            },
          ),
          if (connectivityAsync.asData?.value == ConnectivityResult.none)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.red,
                padding: EdgeInsets.all(8),
                child: Text(
                  'Offline: Please check your network',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          _buildLocationPicker(),
        ],
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

  LatLng? _pickupLatLng;
  LatLng? _dropoffLatLng;
  String? _selectedRideType = 'Economy';
  String? _selectedPaymentMethod = 'Cash';
  double? _fare;
  int? _eta;
  double? _distanceKm;
  String? _errorMessage;

  Timer? _debouncePickup;
  Timer? _debounceDropoff;
  Timer? _debounceTimer;

  GoogleMapController? _mapController;
  Set<Polyline> _polylines = {};
  Set<Marker> _markers = {};
  bool _isLoadingRoute = false;

  @override
  void initState() {
    super.initState();
    _pickupController = widget.pickupController ?? TextEditingController();
    _dropoffController = widget.dropoffController ?? TextEditingController();
    _mapController = widget.mapController;

    // Debounced listeners for live address changes
    _pickupController.addListener(() {
      _debouncePickup?.cancel();
      _debouncePickup = Timer(
        const Duration(milliseconds: 500),
        _updatePickupLatLngLive,
      );
    });
    _dropoffController.addListener(() {
      _debounceDropoff?.cancel();
      _debounceDropoff = Timer(
        const Duration(milliseconds: 500),
        _updateDropoffLatLngLive,
      );
    });
  }

  @override
  void dispose() {
    _pickupController.removeListener(_updatePickupLatLngLive);
    _dropoffController.removeListener(_updateDropoffLatLngLive);
    _debouncePickup?.cancel();
    _debounceDropoff?.cancel();

    if (widget.pickupController == null) _pickupController.dispose();
    if (widget.dropoffController == null) _dropoffController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _updatePickupLatLngLive() async {
    final text = _pickupController.text.trim();
    if (text.isEmpty) return;

    try {
      final latLng = await GeocodingService.getLatLngFromAddress(text);
      if (latLng != null) {
        _pickupLatLng = latLng;
        await _updateRouteAndFare(sendMarkers: true);
        await _panTo(latLng);
      }
    } catch (e) {
      _logger.e('Pickup update failed: $e');
    }
  }

  Future<void> _updateDropoffLatLngLive() async {
    final text = _dropoffController.text.trim();
    if (text.isEmpty) return;

    try {
      final latLng = await GeocodingService.getLatLngFromAddress(text);
      if (latLng != null) {
        _dropoffLatLng = latLng;
        await _updateRouteAndFare(sendMarkers: true);
        await _panTo(latLng);
      }
    } catch (e) {
      _logger.e('Dropoff update failed: $e');
    }
  }

  Future<void> _panTo(LatLng? pos) async {
    if (pos == null) return;
    try {
      await (_mapController ?? widget.mapController)?.animateCamera(
        CameraUpdate.newLatLngZoom(pos, 15),
      );
    } catch (e) {
      _logger.e('Map pan failed: $e');
    }
  }

  Future<void> _updateRouteAndFare({bool sendMarkers = true}) async {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), () async {
      if (_pickupLatLng == null || _dropoffLatLng == null) return;

      setState(() => _isLoadingRoute = true);

      try {
        final routePoints = await MapService().getRoute(
          _pickupLatLng!,
          _dropoffLatLng!,
        );
        final result = await MapService().getRateAndEtaFromCoords(
          _pickupLatLng!,
          _dropoffLatLng!,
          _selectedRideType!,
        );

        setState(() {
          _fare = result['total'];
          _eta = result['etaMinutes'];
          _distanceKm = result['distanceKm'];

          _polylines = {
            Polyline(
              polylineId: const PolylineId('route'),
              points: routePoints,
              color: Colors.blue,
              width: 5,
            ),
          };

          if (sendMarkers) {
            _markers = {
              Marker(
                markerId: const MarkerId('pickup'),
                position: _pickupLatLng!,
              ),
              Marker(
                markerId: const MarkerId('dropoff'),
                position: _dropoffLatLng!,
              ),
            };
          }
        });

        widget.onFareUpdated?.call(
          _fare!,
          _eta!,
          _distanceKm!,
          routePoints,
          pickup: _pickupLatLng,
          dropoff: _dropoffLatLng,
        );

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

        await (_mapController ?? widget.mapController)?.animateCamera(
          CameraUpdate.newLatLngBounds(bounds, 50),
        );
      } catch (e) {
        _logger.e('Failed to update route/fare: $e');
        if (context.mounted) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Route error: $e')));
        }
      } finally {
        setState(() => _isLoadingRoute = false);
      }
    });
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
        if (!mounted) return;
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
      child: Column(
        children: [
          SizedBox(
            height: 250,
            child: GoogleMap(
              initialCameraPosition: CameraPosition(
                target: widget.currentLocation ?? const LatLng(0, 0),
                zoom: 12,
              ),
              polylines: _polylines,
              markers: _markers,
              onMapCreated: (controller) {
                _mapController = controller;
              },
              myLocationEnabled: true,
              myLocationButtonEnabled: true,
              zoomControlsEnabled: false,
            ),
          ),
          Expanded(
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
                  // Pickup Address Field
                  TextFormField(
                    controller: _pickupController,
                    decoration: const InputDecoration(
                      labelText: 'Pickup Location',
                      prefixIcon: Icon(Icons.my_location),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Dropoff Address Field
                  TextFormField(
                    controller: _dropoffController,
                    decoration: const InputDecoration(
                      labelText: 'Dropoff Location',
                      prefixIcon: Icon(Icons.location_on),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Ride Type Dropdown
                  DropdownButtonFormField<String>(
                    initialValue: _selectedRideType,
                    decoration: const InputDecoration(labelText: 'Ride Type'),
                    items: const [
                      DropdownMenuItem(
                        value: 'Economy',
                        child: Text('Economy'),
                      ),
                      DropdownMenuItem(
                        value: 'Premium',
                        child: Text('Premium'),
                      ),
                      DropdownMenuItem(value: 'Luxury', child: Text('Luxury')),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedRideType = value;
                        _updateRouteAndFare(sendMarkers: false);
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  // Payment Method Dropdown
                  DropdownButtonFormField<String>(
                    initialValue: _selectedPaymentMethod,
                    decoration: const InputDecoration(
                      labelText: 'Payment Method',
                    ),
                    items: const [
                      DropdownMenuItem(value: 'Cash', child: Text('Cash')),
                      DropdownMenuItem(value: 'Card', child: Text('Card')),
                      DropdownMenuItem(value: 'Wallet', child: Text('Wallet')),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedPaymentMethod = value;
                      });
                    },
                  ),
                  const SizedBox(height: 12),
                  // Notes Field
                  TextFormField(
                    controller: _noteController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Additional Notes',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_fare != null && _eta != null && _distanceKm != null)
                    Text(
                      'Fare: \$${_fare!.toStringAsFixed(2)}, ETA: $_eta mins, Distance: ${_distanceKm!.toStringAsFixed(2)} km',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _isLoadingRoute ? null : _requestRide,
                    child: _isLoadingRoute
                        ? const CircularProgressIndicator()
                        : const Text('Request Ride'),
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
