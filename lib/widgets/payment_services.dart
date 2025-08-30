import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:logger/logger.dart';

class PaymentService {
  final _firestore = FirebaseFirestore.instance;
  final _logger = Logger();

  Future<bool> processPayment({
    required String rideId,
    required double amount,
    required String paymentMethod,
    required String userId,
  }) async {
    try {
      if (paymentMethod == 'Cash') {
        await _firestore.collection('rides').doc(rideId).update({
          'paymentStatus': 'pending_driver_confirmation',
          'paymentMethod': paymentMethod,
          'amount': amount,
        });
        return true;
      } else {
        // Simulated payment gateway
        await Future.delayed(const Duration(seconds: 2));

        await _firestore.collection('rides').doc(rideId).update({
          'paymentStatus': 'completed',
          'paymentMethod': paymentMethod,
          'amount': amount,
          'paymentTimestamp': FieldValue.serverTimestamp(),
        });

        // Credit driver
        final ride = await _firestore.collection('rides').doc(rideId).get();
        final driverId = ride.data()?['driverId'] as String?;
        if (driverId != null) {
          await _firestore.collection('users').doc(driverId).update({
            'earnings': FieldValue.increment(amount * 0.8),
          });
        }

        // Store receipt
        await _firestore.collection('receipts').doc(rideId).set({
          'rideId': rideId,
          'userId': userId,
          'driverId': driverId,
          'amount': amount,
          'method': paymentMethod,
          'timestamp': FieldValue.serverTimestamp(),
        });

        return true;
      }
    } catch (e) {
      _logger.e('Payment processing failed: $e');
      rethrow;
    }
  }

  Future<bool> confirmCashPayment({
    required String rideId,
    required String driverId,
  }) async {
    try {
      await _firestore.collection('rides').doc(rideId).update({
        'paymentStatus': 'completed',
        'paymentTimestamp': FieldValue.serverTimestamp(),
      });

      final amount =
          (await _firestore.collection('rides').doc(rideId).get())
                  .data()!['amount']
              as double;

      await _firestore.collection('users').doc(driverId).update({
        'earnings': FieldValue.increment(amount * 0.8),
      });

      // Record receipt
      await _firestore.collection('receipts').doc(rideId).set({
        'rideId': rideId,
        'driverId': driverId,
        'amount': amount,
        'method': 'Cash',
        'timestamp': FieldValue.serverTimestamp(),
      });

      return true;
    } catch (e) {
      _logger.e('Cash payment confirmation failed: $e');
      rethrow;
    }
  }

  Map<String, dynamic> calculateFareBreakdown({
    required double distanceKm,
    required String rideType,
  }) {
    double baseFare, perKmRate;

    switch (rideType) {
      case 'Economy':
        baseFare = 2.0;
        perKmRate = 0.5;
        break;
      case 'Premium':
        baseFare = 5.0;
        perKmRate = 1.0;
        break;
      case 'XL':
        baseFare = 7.0;
        perKmRate = 1.5;
        break;
      case 'Electric':
        baseFare = 4.0;
        perKmRate = 0.8;
        break;
      default:
        baseFare = 2.0;
        perKmRate = 0.5;
    }

    final distanceFare = double.parse(
      (distanceKm * perKmRate).toStringAsFixed(2),
    );
    final tax = double.parse(
      ((baseFare + distanceFare) * 0.1).toStringAsFixed(2),
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
