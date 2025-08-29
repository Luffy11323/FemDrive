import 'package:flutter/material.dart';
import 'package:logger/logger.dart';

class PaymentService {
  final _logger = Logger();
  final List<String> _paymentMethods = ['Cash', 'Card', 'Mobile Wallet'];

  List<String> get paymentMethods => List.unmodifiable(_paymentMethods);

  String? validatePaymentMethod(String? method) {
    if (method == null || !_paymentMethods.contains(method)) {
      _logger.w('Invalid payment method: $method');
      return 'Please select a valid payment method';
    }
    return null;
  }

  Future<void> processPayment(String method, double amount) async {
    try {
      // Placeholder for payment gateway integration (e.g., Stripe, PayPal)
      _logger.i('Processing payment of $amount with $method');
      // Simulate payment processing delay
      await Future.delayed(const Duration(seconds: 1));
      if (method == 'Cash') {
        // No further action for cash; handled on ride completion
        return;
      }
      // Add actual payment gateway logic here (e.g., Stripe API call)
      throw UnimplementedError(
        'Payment gateway integration not yet implemented',
      );
    } catch (e) {
      _logger.e('Payment processing failed: $e');
      throw Exception('Unable to process payment: $e');
    }
  }
}

class PaymentDropdown extends StatefulWidget {
  final ValueChanged<String?> onChanged;
  final String? initialValue;
  const PaymentDropdown({
    required this.onChanged,
    this.initialValue,
    super.key,
  });

  @override
  State<PaymentDropdown> createState() => _PaymentDropdownState();
}

class _PaymentDropdownState extends State<PaymentDropdown> {
  final PaymentService _paymentService = PaymentService();
  String? _selectedMethod;

  @override
  void initState() {
    super.initState();
    _selectedMethod =
        widget.initialValue ?? _paymentService.paymentMethods.first;
  }

  @override
  Widget build(BuildContext context) {
    return DropdownButton<String>(
      value: _selectedMethod,
      items: _paymentService.paymentMethods.map((method) {
        return DropdownMenuItem<String>(value: method, child: Text(method));
      }).toList(),
      onChanged: (value) {
        setState(() => _selectedMethod = value);
        widget.onChanged(value);
      },
      dropdownColor: const Color(
        0xFFF28AB2,
        // ignore: deprecated_member_use
      ).withOpacity(0.9), // Soft Rose palette
      style: TextStyle(color: Colors.white),
      underline: Container(height: 2, color: const Color(0xFFF28AB2)),
      iconEnabledColor: Colors.white,
    );
  }
}
