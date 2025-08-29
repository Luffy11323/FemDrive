import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/foundation.dart';

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
            if (kDebugMode) {
              print('Location tracking error: $e');
            }
          },
        );
  }

  Future<void> stop() async {
    await _positionSub?.cancel();
    _positionSub = null;
    if (kDebugMode) {
      print('Location tracking stopped');
    }
  }

  Future<bool> _checkPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  Future<void> _updateLiveLocation(
    String role,
    String rideId,
    Position pos,
  ) async {
    try {
      final doc = FirebaseFirestore.instance.collection('rides').doc(rideId);
      await doc.update({
        '${role}Lat': pos.latitude,
        '${role}Lng': pos.longitude,
        '${role}Ts': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('Error updating live location: $e');
      }
    }
  }

  Future<void> _logLocation(String role, String rideId, Position pos) async {
    try {
      final subcollection = role == 'driver' ? 'locations' : 'riderLocations';
      await FirebaseFirestore.instance
          .collection('rides')
          .doc(rideId)
          .collection(subcollection)
          .add({
            'lat': pos.latitude,
            'lng': pos.longitude,
            'ts': FieldValue.serverTimestamp(),
          });
    } catch (e) {
      if (kDebugMode) {
        print('Error logging location: $e');
      }
    }
  }
}
