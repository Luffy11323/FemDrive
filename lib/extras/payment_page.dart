import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:logger/logger.dart';
import 'package:flutter/material.dart';

class PaymentPage extends StatelessWidget {
  const PaymentPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Methods')),
      body: Center(child: Text('Payment methods go here')),
    );
  }
}

class PaymentService {
  final _firestore = FirebaseFirestore.instance;
  final _logger = Logger();

  Map<String, dynamic> calculateFareBreakdown({
    required double distanceKm,
    required String rideType,
  }) {
    double baseFare = 50;
    double perKm = 20;
    double multiplier = rideType == 'Premium' ? 1.5 : 1.0;
    return {
      'base': baseFare,
      'distance': distanceKm * perKm,
      'total': (baseFare + distanceKm * perKm) * multiplier,
    };
  }

  bool _validateEasyPaisa(String account) {
    final regex = RegExp(r'^03[0-4][0-9]{8}$');
    return regex.hasMatch(account);
  }

  bool _validateJazzCash(String account) {
    final regex = RegExp(r'^03[0-9]{9}$');
    return regex.hasMatch(account);
  }

  Future<bool> validatePaymentMethod({
    required String paymentMethod,
    required String account,
  }) async {
    if (paymentMethod == 'EasyPaisa' && !_validateEasyPaisa(account)) {
      _logger.w('Invalid EasyPaisa account: $account');
      throw Exception(
        'Invalid EasyPaisa account. Must be an 11-digit mobile number starting with 03',
      );
    }
    if (paymentMethod == 'JazzCash' && !_validateJazzCash(account)) {
      _logger.w('Invalid JazzCash account: $account');
      throw Exception(
        'Invalid JazzCash account. Must be an 11-digit mobile number starting with 03',
      );
    }
    if (paymentMethod == 'Card') {
      final regex = RegExp(r'^\d{16}$');
      if (!regex.hasMatch(account)) {
        _logger.w('Invalid card number: $account');
        throw Exception('Invalid card number. Must be 16 digits');
      }
    }
    return true;
  }

  Future<bool> processPayment({
    required String rideId,
    required double amount,
    required String paymentMethod,
    required String userId,
  }) async {
    try {
      final userDoc = await _firestore.collection('users').doc(userId).get();
      final paymentMethods = (userDoc.data()?['paymentMethods'] as List?) ?? [];
      final method = paymentMethods.firstWhere(
        (m) => m['type'] == paymentMethod,
        orElse: () => null,
      );
      if (method == null) {
        throw Exception('Payment method not found for user');
      }
      await validatePaymentMethod(
        paymentMethod: paymentMethod,
        account: method['account'],
      );

      if (paymentMethod == 'Cash') {
        await _firestore.collection('rides').doc(rideId).update({
          'paymentStatus': 'pending_driver_confirmation',
          'paymentMethod': paymentMethod,
          'amount': amount,
        });
        return true;
      } else {
        await Future.delayed(const Duration(seconds: 2));
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
            'earnings': FieldValue.increment(amount * 0.8),
          });
        }

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
}
