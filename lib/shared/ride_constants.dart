// lib/shared/ride_constants.dart
class AppPaths {
  static const ridesCollection = 'rides'; // Firestore
  static const ridesLive = 'ridesLive'; // RTDB live status/eta
  static const driverNotifications =
      'driver_notifications'; // RTDB offers per driver
  static const driversOnline = 'drivers_online'; // RTDB presence grid
  static const driverLocations = 'driverLocations'; // RTDB live lat/lng
  static const messages = 'messages';
}

class AppFields {
  static const status = 'status';
  static const riderId = 'riderId';
  static const driverId = 'driverId';
  static const pickup = 'pickup';
  static const dropoff = 'dropoff';
  static const pickupLat = 'pickupLat';
  static const pickupLng = 'pickupLng';
  static const dropoffLat = 'dropoffLat';
  static const dropoffLng = 'dropoffLng';
  static const fare = 'fare';
  static const counterFare = 'counterFare';
  static const acceptedAt = 'acceptedAt';
  static const arrivingAt = 'arrivingAt';
  static const startedAt = 'startedAt';
  static const completedAt = 'completedAt';
  static const cancelledAt = 'cancelledAt';
  static const createdAt = 'createdAt';
  static const updatedAt = 'updatedAt';
  static const lat = 'lat';
  static const lng = 'lng';
  static const etaSecs = 'etaSecs';
  static const geohash = 'geohash';
  static const rideId = 'rideId';
  static const type = 'type';
  static const timestamp = 'timestamp';
  static const driversOnline = 'drivers_online';
  static const driverLocations = 'driverLocations';
  static const ridesLive = 'ridesLive';
  // ignore: constant_identifier_names
  static const trip_shares = 'trip_shares';
  static const ridesCollection = 'rides';
  static const locationsCollection = 'locations';
  static const read = 'read';
}

class RideStatus {
  static const pending = 'pending';
  static const searching = 'searching';
  static const accepted = 'accepted';
  static const arriving = 'arriving';
  static const started = 'started';
  static const onTrip = 'onTrip'; // alias of started if you prefer
  static const completed = 'completed';
  static const cancelled = 'cancelled';

  static const ongoingSet = <String>{accepted, arriving, started, onTrip};
}

class OfferType {
  static const rideAccepted = 'ride_accepted';
  static const counterFare = 'counter_fare';
  static const rideDeclined = 'ride_declined';
  static const statusUpdate = 'status_update';
  static const rideCompleted = 'ride_completed';
}
