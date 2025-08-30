// location_service.dart
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:logger/logger.dart';
import 'package:femdrive/driver/driver_services.dart';

class LocationService {
  StreamSubscription<Position>? _positionSub;
  final _logger = Logger();

  Future<void> startTracking(String role, String rideId) async {
    final hasPermission = await _checkPermission();
    if (!hasPermission) throw Exception('Location permission denied');

    _positionSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          ),
        ).listen(
          (position) {
            _logger.i(
              "Tracking $role for ride $rideId: ${position.latitude}, ${position.longitude}",
            );
            _updateLiveLocation(role, rideId, position);
            _logLocation(role, rideId, position);
          },
          onError: (e) {
            _logger.e("Location tracking error: $e");
          },
        );
  }

  Future<void> stop(String role, String rideId) async {
    await _positionSub?.cancel();
    _positionSub = null;
    _logger.i("Stopped tracking $role for ride $rideId");

    // Clean up live location from Realtime DB after ride
    try {
      final ref = FirebaseDatabase.instance.ref(
        '${AppPaths.ridesCollection}/$rideId',
      );
      await ref.update({
        '${role}Lat': null,
        '${role}Lng': null,
        '${role}Ts': null,
      });
    } catch (e) {
      _logger.w("Cleanup failed: $e");
    }
  }

  Future<bool> _checkPermission({Function()? onPermissionDenied}) async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await Geolocator.openLocationSettings();
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        onPermissionDenied?.call();
        return false;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      return false;
    }
    return true;
  }

  Future<void> _updateLiveLocation(
    String role,
    String rideId,
    Position pos,
  ) async {
    try {
      final ref = FirebaseDatabase.instance.ref(
        '${AppPaths.ridesCollection}/$rideId',
      );
      await ref.update({
        '${role}Lat': pos.latitude,
        '${role}Lng': pos.longitude,
        '${role}Ts': ServerValue.timestamp,
      });
    } catch (e) {
      _logger.e("Realtime DB update failed: $e");
    }
  }

  Future<void> _logLocation(String role, String rideId, Position pos) async {
    try {
      // unify subcollection for both driver & rider
      await FirebaseFirestore.instance
          .collection(AppPaths.ridesCollection)
          .doc(rideId)
          .collection('locations')
          .add({
            'role': role,
            AppFields.lat: pos.latitude,
            AppFields.lng: pos.longitude,
            AppFields.timestamp: FieldValue.serverTimestamp(),
          });
    } catch (e) {
      _logger.e("Firestore log failed: $e");
    }
  }
}
