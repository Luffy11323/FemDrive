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
        await Future.delayed(const Duration(seconds: 2)); // Mock API delay
        await _firestore.collection('rides').doc(rideId).update({
          'paymentStatus': 'completed',
          'paymentMethod': paymentMethod,
          'amount': amount,
          'paymentTimestamp': FieldValue.serverTimestamp(),
        });

        final ride = await _firestore.collection('rides').doc(rideId).get();
        final driverId = ride.data()?['driverId'] as String?;
        if (driverId != null) {
          await _firestore.collection('users').doc(driverId).update({
            'earnings': FieldValue.increment(amount * 0.8), // 80% to driver
          });
        }
        return true;
      }
    } catch (e) {
      _logger.e('Payment processing failed: $e');
      throw Exception('Failed to process payment: $e');
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
      return true;
    } catch (e) {
      _logger.e('Cash payment confirmation failed: $e');
      throw Exception('Failed to confirm cash payment: $e');
    }
  }

  Map<String, dynamic> calculateFareBreakdown({
    required double distanceKm,
    required String rideType,
  }) {
    double baseFare;
    double perKmRate;

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

    final distanceFare = distanceKm * perKmRate;
    final tax = (baseFare + distanceFare) * 0.1; // 10% tax
    final total = baseFare + distanceFare + tax;

    return {
      'baseFare': baseFare,
      'distanceFare': distanceFare,
      'tax': tax,
      'total': total,
    };
  }
}
