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

  int secondsRemaining = 30;
  bool enableResend = false;
  Timer? timer;
  bool loading = false;
  bool otpSent = false;
  String? verificationId;

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
    timer?.cancel();
    super.dispose();
  }

  @override
  void codeUpdated() {
    if (code != null && otpSent && otpController.text.length < 6) {
      otpController.text = code!;
      verifyOtp();
    }
  }

  void startTimer() {
    setState(() {
      secondsRemaining = 30;
      enableResend = false;
    });

    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (secondsRemaining == 0) {
        setState(() => enableResend = true);
        t.cancel();
      } else {
        setState(() => secondsRemaining--);
      }
    });
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

  /// ✅ Confirmation dialog before sending OTP
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
                onPressed: () => Navigator.pop(context, false),
                child: const Text("Edit"),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
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

    final confirmed = await _confirmPhoneNumber(formattedPhone);
    if (!confirmed) return;

    try {
      setState(() {
        loading = true;
        otpSent = false;
      });

      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: formattedPhone,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (PhoneAuthCredential cred) async {
          await verifyOtp(autoCredential: cred); // ✅ unified flow
        },
        verificationFailed: (FirebaseAuthException e) {
          _showError(_mapFirebaseError(e.code, e.message));
        },
        codeSent: (String id, int? token) {
          setState(() {
            verificationId = id;
            otpSent = true;
          });
          startTimer(); // ✅ unified resend flow
        },
        codeAutoRetrievalTimeout: (String id) => verificationId = id,
      );
    } catch (e) {
      _showError("OTP sending failed: $e");
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> verifyOtp({PhoneAuthCredential? autoCredential}) async {
    if (autoCredential == null &&
        (verificationId == null || otpController.text.trim().length != 6)) {
      return _showError("Please enter the full 6-digit OTP.");
    }

    try {
      setState(() => loading = true);

      final credential =
          autoCredential ??
          PhoneAuthProvider.credential(
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
        route = '/dashboard'; // ✅ Matches main.dart auto-login
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
                TextFormField(
                  controller: otpController,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                    labelText: "Enter OTP",
                    counterText: "",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: enableResend ? sendOtp : null,
                  child: Text(
                    enableResend
                        ? "Resend OTP"
                        : "Resend in $secondsRemaining sec",
                  ),
                ),
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
