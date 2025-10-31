import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:fl_location/fl_location.dart' as fl;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:logger/logger.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:femdrive/driver/driver_services.dart';

class LocationService {
  StreamSubscription<geo.Position>? _positionSub;
  final _logger = Logger();

  String? _driverId;
  String? _activeRideId;
  bool _bgInitialized = false;
  bool _isTracking = false;

  /// 🔹 Foreground-only tracking (legacy Geolocator, keeps your old logic intact)
  Future<void> startTracking(String role, String rideId) async {
    final hasPermission = await _checkPermission();
    if (!hasPermission) throw Exception('Location permission denied');

    _positionSub = geo.Geolocator.getPositionStream(
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.high,
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

  /// UNCHANGED: Same parameters as original
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

    if (_isTracking) {
      await _stopBackgroundService();
    }
  }

  /// 🔹 Initialize background geolocation (once, at app startup or driver login)
  Future<void> initBackgroundTracking(String driverId) async {
    if (_bgInitialized) return;
    _driverId = driverId;

    // Save driverId to SharedPreferences for foreground service access
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('driverId', driverId);

    // Initialize foreground task
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'femdrive_location',
        channelName: 'FemDrive Location Service',
        channelDescription: 'Tracks driver location for rides and availability',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000), // Fallback interval
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _bgInitialized = true;
    _logger.i("✅ Background tracking initialized for driver $driverId");
  }

  /// UNCHANGED: Same parameters as original (no parameters)
  Future<void> startBackground() async {
    if (_isTracking) return;

    final hasPermission = await _checkPermission();
    if (!hasPermission) {
      _logger.e("Cannot start background tracking: permission denied");
      return;
    }

    try {
      // Determine interval based on ride status (5s during ride, 30s idle)
      final interval = _activeRideId != null ? 5000 : 30000;

      // Re-initialize with appropriate interval
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'femdrive_location',
          channelName: 'FemDrive Location Service',
          channelDescription: 'Tracks driver location for rides and availability',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
          showNotification: true,
          playSound: false,
        ),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(interval),
          autoRunOnBoot: true,
          autoRunOnMyPackageReplaced: true,
          allowWakeLock: true,
          allowWifiLock: true,
        ),
      );

      final notificationText = _activeRideId != null
          ? 'On active ride'
          : 'Available for rides';

      // Generate dynamic serviceId based on driverId
      final prefs = await SharedPreferences.getInstance();
      final driverId = prefs.getString('driverId') ?? 'default_driver';
      final serviceId = driverId.hashCode.abs();

      final result = await FlutterForegroundTask.startService(
        serviceId: serviceId,
        notificationTitle: 'FemDrive Active',
        notificationText: notificationText,
        callback: startLocationCallback,
      );

      // Check if result is ServiceRequestSuccess type
      if (result is ServiceRequestSuccess) {
        _isTracking = true;
        _logger.i("🚀 Background geolocation started for driver $driverId");
      } else if (result is ServiceRequestFailure) {
        _logger.e("Failed to start background service: ${result.error}");
      }
    } catch (e) {
      _logger.e("Error starting background service: $e");
    }
  }

  /// UNCHANGED: Same parameters as original
  Future<void> setActiveRide(String? rideId) async {
    _activeRideId = rideId;
    _logger.i("🎯 Active ride set to: $rideId");

    // Save to SharedPreferences for foreground service
    final prefs = await SharedPreferences.getInstance();
    if (rideId != null) {
      await prefs.setString('activeRideId', rideId);
    } else {
      await prefs.remove('activeRideId');
    }

    // Restart service with new interval if already tracking
    if (_isTracking) {
      await _stopBackgroundService();
      await startBackground();
    }
  }

  // 🔹 Internal method to stop background service
  Future<void> _stopBackgroundService() async {
    FlutterForegroundTask.stopService();
    _isTracking = false;
    _logger.i("🛑 Background geolocation stopped");

    // Clear driver presence
    if (_driverId != null) {
      try {
        final ref = FirebaseDatabase.instance.ref('drivers_online/$_driverId');
        await ref.remove();
      } catch (e) {
        _logger.w("Failed to clear driver presence: $e");
      }
    }
  }

  /// 🔹 Foreground (Geolocator) helpers
  Future<void> _updateLiveLocation(
    String role,
    String rideId,
    geo.Position pos,
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

  Future<void> _logLocation(String role, String rideId, geo.Position pos) async {
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
    bool serviceEnabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      await geo.Geolocator.openLocationSettings();
      return false;
    }

    geo.LocationPermission permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
      if (permission == geo.LocationPermission.denied) {
        onPermissionDenied?.call();
        return false;
      }
    }
    if (permission == geo.LocationPermission.deniedForever) {
      await geo.Geolocator.openAppSettings();
      return false;
    }
    return true;
  }
}

/// 🧠 Foreground service callback (runs in background isolate)
@pragma('vm:entry-point')
void startLocationCallback() {
  FlutterForegroundTask.setTaskHandler(LocationTaskHandler());
}

/// 🧠 Task handler for background location updates
class LocationTaskHandler extends TaskHandler {
  final _logger = Logger();
  StreamSubscription<fl.Location>? _locationSub;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _logger.i("🚀 Foreground location service started");

    // Subscribe to motion-based stream (triggers on movement >10m)
    _locationSub = fl.FlLocation.getLocationStream(
      distanceFilter: 10,
      accuracy: fl.LocationAccuracy.high,
    ).listen((location) async {
      try {
        // Get stored driver and ride info
        final prefs = await SharedPreferences.getInstance();
        final driverId = prefs.getString('driverId');
        final activeRideId = prefs.getString('activeRideId');

        if (driverId == null) {
          _logger.w("No driverId found, skipping location update");
          return;
        }

        final ts = DateTime.now().millisecondsSinceEpoch;
        final lat = location.latitude;
        final lng = location.longitude;

        _logger.i("📍 BG Location update: $lat,$lng");

        // Update driver presence (always)
        final refPresence = FirebaseDatabase.instance.ref('drivers_online/$driverId');
        await refPresence.set({'lat': lat, 'lng': lng, 'updatedAt': ts});
        refPresence.onDisconnect().remove();

        // Update active ride if exists
        if (activeRideId != null && activeRideId.isNotEmpty) {
          final refRide = FirebaseDatabase.instance.ref('ridesLive/$activeRideId');
          await refRide.update({'driverLat': lat, 'driverLng': lng, 'driverTs': ts});
        }

        // Log to Firestore for audit trail
        await FirebaseFirestore.instance
            .collection('drivers')
            .doc(driverId)
            .collection('bg_locations')
            .add({
          'lat': lat,
          'lng': lng,
          'timestamp': FieldValue.serverTimestamp(),
        });

        // Update notification
        final notificationText = activeRideId != null
            ? 'On active ride • ${DateTime.now().toString().substring(11, 19)}'
            : 'Available • ${DateTime.now().toString().substring(11, 19)}';

        FlutterForegroundTask.updateService(
          notificationTitle: 'FemDrive Active',
          notificationText: notificationText,
        );
      } catch (e) {
        _logger.e("⚠️ Background location update failed: $e");
      }
    });
  }

  @override
  void onRepeatEvent(DateTime timestamp) async {
    // Fallback: Minimal check every 30s if stream is idle
    _logger.d("Fallback repeat event triggered (stream should handle updates)");
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool byAppReboot) async {
    await _locationSub?.cancel();
    _locationSub = null;
    _logger.i("🛑 Foreground location service stopped");
  }
}
class RiderLocationService {
  static final RiderLocationService instance = RiderLocationService._internal();
  RiderLocationService._internal();

  final _logger = Logger();
  StreamSubscription<geo.Position>? _positionSub;

  bool _isActive = false;
  bool _isBgInitialized = false;
  String? _riderId;

  /// 🔹 Initialize foreground service once after login
  Future<void> init(String riderId) async {
    if (_isBgInitialized) return;
    _riderId = riderId;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('riderId', riderId);

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'femdrive_rider_loc',
        channelName: 'Rider Background Location',
        channelDescription: 'Tracks rider presence during trips',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _isBgInitialized = true;
    _logger.i("✅ RiderLocationService initialized for $riderId");
  }

  /// 🔹 Foreground-only location updates (lightweight)
  Future<void> startForegroundUpdates() async {
    if (_isActive) return;
    if (!await _checkPermission()) return;

    _isActive = true;
    _positionSub = geo.Geolocator.getPositionStream(
      locationSettings: const geo.LocationSettings(
        accuracy: geo.LocationAccuracy.best,
        distanceFilter: 20,
      ),
    ).listen((pos) async {
      await _updatePresence(pos.latitude, pos.longitude);
    }, onError: (e) {
      _logger.e("Rider location stream error: $e");
    });
  }

  Future<void> stopForegroundUpdates() async {
    await _positionSub?.cancel();
    _positionSub = null;
    _isActive = false;
    _logger.i("🛑 Rider foreground updates stopped");
  }

  /// 🔹 Start background service (runs isolated)
  Future<void> startBackground() async {
    if (_isActive) return;
    if (!await _checkPermission()) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final riderId = prefs.getString('riderId') ?? 'unknown_rider';
      final serviceId = riderId.hashCode.abs();

      final result = await FlutterForegroundTask.startService(
        serviceId: serviceId,
        notificationTitle: 'FemDrive Active',
        notificationText: 'Tracking your ride location safely',
        callback: startRiderLocationCallback,
      );

      if (result is ServiceRequestSuccess) {
        _isActive = true;
        _logger.i("🚀 Rider background service started for $riderId");
      } else if (result is ServiceRequestFailure) {
        _logger.e("Failed to start background service: ${result.error}");
      }
    } catch (e) {
      _logger.e("Rider background start failed: $e");
    }
  }

  Future<void> stopBackground() async {
    await FlutterForegroundTask.stopService();
    _isActive = false;
    _logger.i("🛑 Rider background service stopped");

    // Clear rider presence
    if (_riderId != null) {
      try {
        await FirebaseDatabase.instance
            .ref('riders_online/$_riderId')
            .remove();
      } catch (e) {
        _logger.w("Failed to clear rider presence: $e");
      }
    }
  }

  Future<void> _updatePresence(double lat, double lng) async {
    if (_riderId == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;

    try {
      final ref = FirebaseDatabase.instance.ref('riders_online/$_riderId');
      await ref.set({'lat': lat, 'lng': lng, 'updatedAt': now});
      ref.onDisconnect().remove();

      await FirebaseFirestore.instance
          .collection('riders')
          .doc(_riderId)
          .collection('locations')
          .add({
        'lat': lat,
        'lng': lng,
        'timestamp': FieldValue.serverTimestamp(),
      });

      _logger.d("📍 Rider presence updated: $lat, $lng");
    } catch (e) {
      _logger.e("Failed to update rider presence: $e");
    }
  }

  Future<bool> _checkPermission() async {
    bool enabled = await geo.Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      await geo.Geolocator.openLocationSettings();
      return false;
    }

    geo.LocationPermission permission = await geo.Geolocator.checkPermission();
    if (permission == geo.LocationPermission.denied) {
      permission = await geo.Geolocator.requestPermission();
      if (permission == geo.LocationPermission.denied) return false;
    }
    if (permission == geo.LocationPermission.deniedForever) {
      await geo.Geolocator.openAppSettings();
      return false;
    }
    return true;
  }
}

/// 🧠 Background isolate for rider tracking
@pragma('vm:entry-point')
void startRiderLocationCallback() {
  FlutterForegroundTask.setTaskHandler(RiderLocationTaskHandler());
}

class RiderLocationTaskHandler extends TaskHandler {
  final _logger = Logger();
  StreamSubscription<fl.Location>? _stream;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _logger.i("🚀 Rider background tracking started");

    _stream = fl.FlLocation.getLocationStream(
      distanceFilter: 20,
      accuracy: fl.LocationAccuracy.high,
    ).listen((loc) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final riderId = prefs.getString('riderId');
        if (riderId == null) return;

        final lat = loc.latitude;
        final lng = loc.longitude;
        final ts = DateTime.now().millisecondsSinceEpoch;

        final ref = FirebaseDatabase.instance.ref('riders_online/$riderId');
        await ref.set({'lat': lat, 'lng': lng, 'updatedAt': ts});
        ref.onDisconnect().remove();

        await FirebaseFirestore.instance
            .collection('riders')
            .doc(riderId)
            .collection('bg_locations')
            .add({
          'lat': lat,
          'lng': lng,
          'timestamp': FieldValue.serverTimestamp(),
        });

        FlutterForegroundTask.updateService(
          notificationTitle: 'FemDrive Active',
          notificationText:
              'Sharing live location • ${DateTime.now().toString().substring(11, 19)}',
        );

        _logger.d("📍 Rider BG update $lat,$lng");
      } catch (e) {
        _logger.e("Rider BG update failed: $e");
      }
    });
  }

  /// 🕒 Called periodically (every 30s or whatever repeat interval you set)
  /// Useful as a safety net if stream stalls — just logs for now.
  @override
  void onRepeatEvent(DateTime timestamp) async {
    _logger.d("⏱️ RiderLocationTaskHandler repeat event at $timestamp");
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool byAppReboot) async {
    await _stream?.cancel();
    _stream = null;
    _logger.i("🛑 Rider background tracking stopped");
  }
}
