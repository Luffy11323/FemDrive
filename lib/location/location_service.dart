import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
// ignore: unused_import
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';

class LocationService {
  StreamSubscription<Position>? _positionSub;

  /// Starts live location tracking for a ride participant
  Future<void> startTracking(String role, String rideId) async {
    final hasPermission = await _checkPermission();
    if (!hasPermission) throw 'Location permission denied';

    _positionSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10, // minimum distance in meters before callback
          ),
        ).listen((position) {
          _updateLiveLocation(role, rideId, position);
          _logLocation(role, rideId, position);
        });
  }

  /// Stops tracking
  Future<void> stop() async {
    await _positionSub?.cancel();
    _positionSub = null;
  }

  /// Check location permission
  Future<bool> _checkPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return permission != LocationPermission.denied &&
        permission != LocationPermission.deniedForever;
  }

  /// Update current lat/lng for driver or rider
  Future<void> _updateLiveLocation(
    String role,
    String rideId,
    Position pos,
  ) async {
    final doc = FirebaseFirestore.instance.collection('rides').doc(rideId);
    await doc.update({
      '${role}Lat': pos.latitude,
      '${role}Lng': pos.longitude,
      '${role}Ts': FieldValue.serverTimestamp(),
    });
  }

  /// Log location into subcollection (optional but useful for tracking history)
  Future<void> _logLocation(String role, String rideId, Position pos) async {
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
  }
}
