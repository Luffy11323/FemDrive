import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:logger/logger.dart';

class PaymentService {
  final _firestore = FirebaseFirestore.instance;
  final _rtdb = FirebaseDatabase.instance.ref();
  final _logger = Logger();

  /// Convert Firestore numeric (int/double) safely to double
  double _numToDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  Future<bool> processPayment({
    required String rideId,
    required double amount,
    required String paymentMethod,
    required String userId,
  }) async {
    try {
      if (paymentMethod == 'Cash') {
        // Firestore
        await _firestore.collection('rides').doc(rideId).update({
          'paymentStatus': 'pending_driver_confirmation',
          'paymentMethod': paymentMethod,
          'amount': amount,
        });

        // RTDB mirrors (fast UI)
        await Future.wait([
          _rtdb.child('ridesLive/$rideId/payment').update({
            'status': 'pending_driver_confirmation',
            'method': paymentMethod,
            'amount': amount,
          }),
          _rtdb.child('payments/$rideId').update({
            'status': 'pending_driver_confirmation',
            'method': paymentMethod,
            'amount': amount,
            'userId': userId,
            'updatedAt': ServerValue.timestamp,
          }),
        ]);

        return true;
      } else {
        // Simulated gateway delay
        await Future.delayed(const Duration(seconds: 2));

        // Firestore: mark paid
        await _firestore.collection('rides').doc(rideId).update({
          'paymentStatus': 'completed',
          'paymentMethod': paymentMethod,
          'amount': amount,
          'paymentTimestamp': FieldValue.serverTimestamp(),
        });

        // Credit driver (if already assigned) WITH a transaction
        await _firestore.runTransaction((txn) async {
          final rideSnap = await txn.get(
            _firestore.collection('rides').doc(rideId),
          );
          if (!rideSnap.exists) return;

          final data = rideSnap.data()!;
          final driverId = data['driverId'] as String?;
          final amt = _numToDouble(data['amount']);

          if (driverId != null && amt > 0) {
            final driverRef = _firestore.collection('users').doc(driverId);
            txn.update(driverRef, {
              'earnings': FieldValue.increment(amt * 0.8),
            });
          }
        });

        // Firestore: store receipt
        final rideSnap = await _firestore.collection('rides').doc(rideId).get();
        final driverId = rideSnap.data()?['driverId'] as String?;

        await _firestore.collection('receipts').doc(rideId).set({
          'rideId': rideId,
          'userId': userId,
          'driverId': driverId,
          'amount': amount,
          'method': paymentMethod,
          'timestamp': FieldValue.serverTimestamp(),
        });

        // RTDB mirrors (fast UI + history)
        await Future.wait([
          _rtdb.child('ridesLive/$rideId/payment').update({
            'status': 'completed',
            'method': paymentMethod,
            'amount': amount,
            'timestamp': ServerValue.timestamp,
          }),
          _rtdb.child('payments/$rideId').update({
            'status': 'completed',
            'method': paymentMethod,
            'amount': amount,
            'userId': userId,
            'driverId': driverId,
            'timestamp': ServerValue.timestamp,
          }),
        ]);

        return true;
      }
    } catch (e, st) {
      _logger.e('Payment processing failed: $e', stackTrace: st);
      rethrow;
    }
  }

  Future<bool> confirmCashPayment({
    required String rideId,
    required String driverId,
  }) async {
    try {
      // Firestore: mark completed
      await _firestore.collection('rides').doc(rideId).update({
        'paymentStatus': 'completed',
        'paymentTimestamp': FieldValue.serverTimestamp(),
      });

      // Read amount defensively
      final rideSnap = await _firestore.collection('rides').doc(rideId).get();
      final amt = _numToDouble(rideSnap.data()?['amount']);

      // Credit driver (transaction)
      await _firestore.runTransaction((txn) async {
        final driverRef = _firestore.collection('users').doc(driverId);
        txn.update(driverRef, {'earnings': FieldValue.increment(amt * 0.8)});
      });

      // Firestore receipt
      await _firestore.collection('receipts').doc(rideId).set({
        'rideId': rideId,
        'driverId': driverId,
        'amount': amt,
        'method': 'Cash',
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // RTDB mirrors
      await Future.wait([
        _rtdb.child('ridesLive/$rideId/payment').update({
          'status': 'completed',
          'method': 'Cash',
          'amount': amt,
          'timestamp': ServerValue.timestamp,
        }),
        _rtdb.child('payments/$rideId').update({
          'status': 'completed',
          'method': 'Cash',
          'amount': amt,
          'driverId': driverId,
          'timestamp': ServerValue.timestamp,
        }),
      ]);

      return true;
    } catch (e, st) {
      _logger.e('Cash payment confirmation failed: $e', stackTrace: st);
      rethrow;
    }
  }

  Map<String, dynamic> calculateFareBreakdown({
    required double distanceKm,
    required String rideType,
  }) {
    double baseFare, perKmRate;

    switch (rideType) {
      case 'Ride X':
        baseFare = 20.0;
        perKmRate = 44.55;
        break;
      case 'Bike':
        baseFare = 10.0;
        perKmRate = 11.82;
        break;
      case 'Ride mini':
      default:
        baseFare = 20.0;
        perKmRate = 33.18;
        break;
    }

    final distanceFare = double.parse(
      (distanceKm * perKmRate).toStringAsFixed(2),
    );
    final tax = double.parse(
      ((baseFare + distanceFare) * 0.10).toStringAsFixed(2),
    );
    final total = double.parse(
      (baseFare + distanceFare + tax).toStringAsFixed(2),
    );

    return {
      'baseFare': baseFare,
      'distanceFare': distanceFare,
      'tax': tax,
      'total': total,
    };
  }
}
