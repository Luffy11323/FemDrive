import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sms_autofill/sms_autofill.dart';

/// Same hyphen formatting as signup page
class PhoneNumberHyphenFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digitsOnly = newValue.text.replaceAll(RegExp(r'\D'), '');
    String formatted = '';
    if (digitsOnly.length <= 4) {
      formatted = digitsOnly;
    } else {
      formatted = digitsOnly.substring(0, 4);
      if (digitsOnly.length > 4) {
        formatted += '-${digitsOnly.substring(4)}';
      }
    }
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with CodeAutoFill {
  final _formKey = GlobalKey<FormState>();
  final phoneController = TextEditingController();
  final otpController = TextEditingController();

  bool loading = false;
  bool otpSent = false;
  bool canResend = false;
  int countdown = 60;
  String? verificationId;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    listenForCode();
  }

  @override
  void dispose() {
    cancel();
    phoneController.dispose();
    otpController.dispose();
    _timer?.cancel();
    super.dispose();
  }

  @override
  void codeUpdated() {
    if (code != null && otpSent) {
      otpController.text = code!;
      verifyOtp();
    }
  }

  String? _validatePakistaniPhone(String? input) {
    if (input == null || input.trim().isEmpty) {
      return "Phone number is required.";
    }
    final digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 11 || !digits.startsWith('03')) {
      return "Must be 11 digits starting with 03 (e.g. 0300-1234567).";
    }
    return null;
  }

  String _formatPakistaniPhone(String input) {
    final digits = input.replaceAll(RegExp(r'\D'), '');
    return '+92${digits.substring(1)}';
  }

  String _mapFirebaseError(String code, [String? message]) {
    switch (code) {
      case 'invalid-verification-code':
        return "The OTP you entered is incorrect.";
      case 'too-many-requests':
        return "Too many OTP attempts. Please wait before trying again.";
      case 'session-expired':
        return "Your OTP has expired. Please request a new one.";
      case 'invalid-phone-number':
        return "Invalid Pakistani phone number format.";
      case 'network-request-failed':
        return "No internet connection. Please check and try again.";
      default:
        return message ?? "Something went wrong. Please try again.";
    }
  }

  void _startResendTimer() {
    setState(() {
      countdown = 60;
      canResend = false;
    });
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (countdown <= 0) {
        timer.cancel();
        setState(() => canResend = true);
      } else {
        setState(() => countdown--);
      }
    });
  }

  /// ✅ New confirmation dialog
  Future<bool> _confirmPhoneNumber(String formattedPhone) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text("Confirm your number"),
            content: Text(
              "We will send an OTP to:\n$formattedPhone",
              style: const TextStyle(fontSize: 16),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false), // Edit
                child: const Text("Edit"),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true), // Yes
                child: const Text("Yes"),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> sendOtp() async {
    if (!_formKey.currentState!.validate()) return;

    final formattedPhone = _formatPakistaniPhone(phoneController.text);

    /// Ask user to confirm before sending OTP
    final confirmed = await _confirmPhoneNumber(formattedPhone);
    if (!confirmed && mounted) {
      // Move focus back to phone input if user wants to edit
      FocusScope.of(context).requestFocus(FocusNode());
      await Future.delayed(const Duration(milliseconds: 100));
      // ignore: use_build_context_synchronously
      FocusScope.of(context).requestFocus(FocusNode());
      return;
    }

    try {
      setState(() {
        loading = true;
        otpSent = false;
      });

      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: formattedPhone,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (PhoneAuthCredential cred) async {
          await FirebaseAuth.instance.signInWithCredential(cred);
          await _handlePostLogin();
        },
        verificationFailed: (FirebaseAuthException e) {
          _showError(_mapFirebaseError(e.code, e.message));
        },
        codeSent: (String id, int? token) {
          setState(() {
            verificationId = id;
            otpSent = true;
          });
          _startResendTimer();
        },
        codeAutoRetrievalTimeout: (String id) => verificationId = id,
      );
    } catch (e) {
      _showError("OTP sending failed: $e");
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> verifyOtp() async {
    if (verificationId == null || otpController.text.trim().length < 6) {
      return _showError("Enter a valid 6-digit OTP.");
    }

    try {
      setState(() => loading = true);

      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId!,
        smsCode: otpController.text.trim(),
      );

      await FirebaseAuth.instance.signInWithCredential(credential);
      await _handlePostLogin();
    } on FirebaseAuthException catch (e) {
      _showError(_mapFirebaseError(e.code, e.message));
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _handlePostLogin() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return _showError("User not found.");

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    if (!doc.exists) return _showError("User profile not found.");

    final data = doc.data()!;
    final role = data['role'];
    final isVerified = data['verified'] == true;

    if (role == 'driver' && !isVerified) {
      await FirebaseAuth.instance.signOut();
      return _showError("Your account is pending admin approval.");
    }

    String route;
    switch (role) {
      case 'admin':
        route = '/admin';
        break;
      case 'driver':
        route = '/driver-dashboard';
        break;
      case 'rider':
        route = '/rider-dashboard';
        break;
      default:
        return _showError("Invalid role: $role");
    }

    if (!mounted) return;
    Navigator.pushReplacementNamed(context, route);
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  @override
  Widget build(BuildContext context) {
    final fieldDecoration = const InputDecoration(
      labelStyle: TextStyle(height: 1.2),
      border: OutlineInputBorder(),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Login - FemDrive')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              const SizedBox(height: 10),
              TextFormField(
                controller: phoneController,
                decoration: fieldDecoration.copyWith(
                  labelText: 'Phone (e.g. 0300-1234567)',
                ),
                keyboardType: TextInputType.phone,
                inputFormatters: [PhoneNumberHyphenFormatter()],
                validator: _validatePakistaniPhone,
                enabled: !otpSent,
              ),
              if (otpSent) ...[
                const SizedBox(height: 15),
                PinFieldAutoFill(
                  controller: otpController,
                  decoration: BoxLooseDecoration(
                    gapSpace: 12,
                    strokeColorBuilder: FixedColorBuilder(Color(0xFFC9A0DC)),
                    bgColorBuilder: FixedColorBuilder(Colors.white),
                  ),
                  codeLength: 6,
                ),
                const SizedBox(height: 10),
                canResend
                    ? TextButton(
                        onPressed: sendOtp,
                        child: const Text('Resend OTP'),
                      )
                    : Text('Resend in $countdown seconds'),
              ],
              const SizedBox(height: 25),
              ElevatedButton(
                onPressed: loading
                    ? null
                    : otpSent
                    ? verifyOtp
                    : sendOtp,
                child: loading
                    ? const CircularProgressIndicator()
                    : Text(otpSent ? 'Verify OTP' : 'Send OTP'),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => Navigator.pushNamed(context, '/signup'),
                child: const Text("Don't have an account? Sign Up"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
