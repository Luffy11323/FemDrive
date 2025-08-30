import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:logger/logger.dart';
// ignore: unused_import
import 'package:femdrive/widgets/payment_services.dart';

class PaymentPage extends ConsumerStatefulWidget {
  const PaymentPage({super.key});

  @override
  ConsumerState<PaymentPage> createState() => _PaymentPageState();
}

class _PaymentPageState extends ConsumerState<PaymentPage> {
  final _logger = Logger();
  String? _selectedMethod;
  final _accountController = TextEditingController();

  Future<void> _addPaymentMethod() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null ||
        _selectedMethod == null ||
        _accountController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a method and enter account details'),
        ),
      );
      return;
    }

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update(
        {
          'paymentMethods': FieldValue.arrayUnion([
            {
              'type': _selectedMethod,
              'account': _accountController.text.trim(),
              'addedAt': FieldValue.serverTimestamp(),
            },
          ]),
        },
      );
      if (context.mounted) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Payment method added')));
        _accountController.clear();
        setState(() => _selectedMethod = null);
      }
    } catch (e) {
      _logger.e('Failed to add payment method: $e');
      if (context.mounted) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Methods')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              decoration: const InputDecoration(labelText: 'Payment Method'),
              initialValue: _selectedMethod,
              items: const [
                DropdownMenuItem(value: 'EasyPaisa', child: Text('EasyPaisa')),
                DropdownMenuItem(value: 'JazzCash', child: Text('JazzCash')),
                DropdownMenuItem(value: 'Card', child: Text('Card')),
                DropdownMenuItem(value: 'Cash', child: Text('Cash')),
              ],
              onChanged: (value) => setState(() => _selectedMethod = value),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _accountController,
              decoration: const InputDecoration(
                labelText: 'Account Number / Details',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _addPaymentMethod,
              child: const Text('Add Payment Method'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _accountController.dispose();
    super.dispose();
  }
}
