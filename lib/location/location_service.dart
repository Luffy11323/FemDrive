import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:workmanager/workmanager.dart';
import 'package:logger/logger.dart';
import 'package:femdrive/driver/driver_services.dart';

class LocationService {
  StreamSubscription<Position>? _positionSub;
  final _logger = Logger();

  String? _driverId;
  String? _activeRideId;
  bool _bgInitialized = false;
  bool _isTracking = false;

  /// 🔹 Foreground-only tracking (legacy Geolocator, keeps your old logic intact)
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
              "📍 FG Tracking $role for ride $rideId: ${position.latitude}, ${position.longitude}",
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
    _logger.i("🛑 Stopped foreground tracking $role for ride $rideId");

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

    // 🆕 Stop background task (instead of bg.BackgroundGeolocation.stop)
    if (_isTracking) {
      await Workmanager().cancelAll();
      _isTracking = false;
      _logger.i("🛑 Background tracking stopped");
    }
  }

  /// 🔹 Initialize background tracking (once, at app startup or driver login)
  Future<void> initBackgroundTracking(String driverId) async {
    if (_bgInitialized) return;
    _driverId = driverId;

    // 🆕 Initialize Workmanager background job handler
    await Workmanager().initialize(
      callbackDispatcher,
      isInDebugMode: false,
    );

    _bgInitialized = true;
    _logger.i("✅ Background tracking initialized for driver $driverId");
  }

  /// 🆕 Background tracking using WorkManager
  Future<void> startBackground() async {
    if (_isTracking || _driverId == null) return;

    await Workmanager().registerPeriodicTask(
      "driverTrackingTask",
      "updateLocationTask",
      frequency: const Duration(minutes: 15), // Android’s minimum interval
      existingWorkPolicy: ExistingWorkPolicy.keep,
      inputData: {"driverId": _driverId!},
    );

    _isTracking = true;
    _logger.i("🚀 Background tracking started via WorkManager");
  }

  Future<void> setActiveRide(String? rideId) async {
    _activeRideId = rideId;
    _logger.i("🎯 Active ride set to: $rideId");
  }

  // 🔹 Presence writer: always online/offline for nearby markers
  Future<void> _updatePresence(double lat, double lng, int ts) async {
    if (_driverId == null) return;
    final ref = FirebaseDatabase.instance.ref('drivers_online/$_driverId');
    await ref.set({'lat': lat, 'lng': lng, 'updatedAt': ts});
    ref.onDisconnect().remove();
  }

  // 🔹 Active ride node: live tracking for a specific ride
  Future<void> _updateRide(
    double lat,
    double lng,
    int ts,
    String rideId,
  ) async {
    final ref = FirebaseDatabase.instance.ref('ridesLive/$rideId');
    await ref.update({'driverLat': lat, 'driverLng': lng, 'driverTs': ts});
  }

  /// 🔹 Foreground (Geolocator) helpers
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
}

/// 🧠 Background location logic (runs every 15 minutes)
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    final driverId = inputData?['driverId'];
    if (driverId == null) return Future.value(true);

    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final ts = DateTime.now().millisecondsSinceEpoch;
      final ref = FirebaseDatabase.instance.ref('drivers_online/$driverId');
      await ref.set({'lat': pos.latitude, 'lng': pos.longitude, 'updatedAt': ts});
      ref.onDisconnect().remove();

      print("📍 BG Location update: ${pos.latitude}, ${pos.longitude} ($driverId)");
    } catch (e) {
      print("⚠️ BG update failed: $e");
    }

    return Future.value(true);
  });
}
