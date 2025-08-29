import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';
import 'package:femdrive/driver/driver_services.dart';

class LocationService {
  StreamSubscription<Position>? _positionSub;

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
            if (kDebugMode) {
              print(
                'Tracking $role location for ride $rideId: ${position.latitude}, ${position.longitude}',
              );
            }
            _updateLiveLocation(role, rideId, position);
            _logLocation(role, rideId, position);
          },
          onError: (e) {
            if (kDebugMode) print('Location tracking error: $e');
          },
        );
  }

  Future<void> stop() async {
    await _positionSub?.cancel();
    _positionSub = null;
    if (kDebugMode) print('Location tracking stopped');
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
      if (kDebugMode) print('Error updating live location: $e');
    }
  }

  Future<void> _logLocation(String role, String rideId, Position pos) async {
    try {
      final subcollection = role == 'driver' ? 'locations' : 'riderLocations';
      await FirebaseFirestore.instance
          .collection(AppPaths.ridesCollection)
          .doc(rideId)
          .collection(subcollection)
          .add({
            AppFields.lat: pos.latitude,
            AppFields.lng: pos.longitude,
            AppFields.timestamp: FieldValue.serverTimestamp(),
          });
    } catch (e) {
      if (kDebugMode) print('Error logging location: $e');
    }
  }
}
