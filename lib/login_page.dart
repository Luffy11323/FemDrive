import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter/services.dart';
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
    FirebaseAuth.instance.authStateChanges().listen((user) {
      if (kDebugMode) {
        print('Auth state changed: ${user?.uid}');
      }
    });
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
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
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
          await verifyOtp(autoCredential: cred);
        },
        verificationFailed: (FirebaseAuthException e) {
          _showError(_mapFirebaseError(e.code, e.message));
        },
        codeSent: (String id, int? token) {
          setState(() {
            verificationId = id;
            otpSent = true;
          });
          startTimer();
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
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (kDebugMode) {
        print('Current user: ${user?.uid}');
      }
      if (user == null) {
        if (kDebugMode) {
          print('Error: No authenticated user found');
        }
        return _showError("User not found. Please try again.");
      }

      // Wait briefly to ensure Firestore sync
      await Future.delayed(const Duration(milliseconds: 500));

      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (kDebugMode) {
        print('Firestore doc exists: ${doc.exists}, Data: ${doc.data()}');
      }

      if (!doc.exists) {
        if (kDebugMode) {
          print('Error: User document not found');
        }
        return _showError("User profile not found. Please sign up again.");
      }

      final data = doc.data()!;
      final role = data['role'] as String? ?? 'rider';
      final isVerified = data['verified'] as bool? ?? true;
      final faceVerified = data['faceVerified'] as bool? ?? false; // NEW: Check face verification

      if (kDebugMode) {
        print('User role: $role, Verified: $isVerified, FaceVerified: $faceVerified');
      }

      // === NEW: Block login if face is not verified (admin can disable) ===
      if (!faceVerified) {
        await FirebaseAuth.instance.signOut();
        return _showError(
          "Your account is temporarily suspended. Please contact support.",
        );
      }

      // === Existing: Driver verification check ===
      if (role == 'driver' && !isVerified) {
        await FirebaseAuth.instance.signOut();
        return _showError("Your account is pending admin approval.");
      }

      // === All good — let InitialScreen handle routing ===
      if (kDebugMode) {
        print('Login successful, proceeding...');
      }

    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('Error in _handlePostLogin: $e\n$stackTrace');
      }
      _showError("Login failed: $e");
    }
  }
  
  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Theme.of(context).colorScheme.error,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Theme.of(context).brightness,
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            minimumSize: const Size(double.infinity, 48),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainer,
        ),
      ),
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Login - FemDrive',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
        ),
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sign in to your account',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ).animate().fadeIn(duration: 400.ms),
                  const SizedBox(height: 8),
                  Text(
                    'Enter your phone number to receive an OTP.',
                    style: TextStyle(
                      fontSize: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ).animate().fadeIn(duration: 400.ms, delay: 100.ms),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: phoneController,
                    decoration: const InputDecoration(
                      labelText: 'Phone (e.g. 0300-1234567)',
                      prefixIcon: Icon(Icons.phone),
                    ),
                    keyboardType: TextInputType.phone,
                    inputFormatters: [PhoneNumberHyphenFormatter()],
                    validator: _validatePakistaniPhone,
                    enabled: !otpSent && !loading,
                  ).animate().slideX(begin: -0.1, end: 0, duration: 400.ms),
                  if (otpSent) ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: otpController,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      enabled: !loading,
                      decoration: const InputDecoration(
                        labelText: 'Enter OTP',
                        prefixIcon: Icon(Icons.lock),
                        counterText: '',
                      ),
                    ).animate().slideX(begin: 0.1, end: 0, duration: 400.ms),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          enableResend
                              ? 'Resend OTP'
                              : 'Resend in $secondsRemaining sec',
                          style: TextStyle(
                            color: enableResend
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        TextButton(
                          onPressed: (!loading && enableResend)
                              ? sendOtp
                              : null,
                          child: const Text('Resend OTP'),
                        ),
                      ],
                    ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
                  ],
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: loading
                        ? null
                        : (otpSent ? () => verifyOtp() : () => sendOtp()),
                    child: AnimatedSwitcher(
                      duration: 250.ms,
                      transitionBuilder: (child, anim) =>
                          FadeTransition(opacity: anim, child: child),
                      child: (loading || otpSent)
                          ? _LoadingCar(
                              key: ValueKey(
                                loading ? 'sending' : 'awaiting_otp',
                              ),
                              label: loading
                                  ? 'Sending OTP...' // sending state
                                  : 'Enter OTP to verify', // waiting-for-otp state (fields visible)
                            )
                          : const Text('Send OTP', key: ValueKey('idle')),
                    ),
                  ),

                  const SizedBox(height: 16),
                  Center(
                    child: TextButton(
                      onPressed: () => Navigator.pushNamed(context, '/signup'),
                      child: const Text("Don't have an account? Sign Up"),
                    ).animate().fadeIn(duration: 400.ms, delay: 300.ms),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingCar extends StatelessWidget {
  final String label;
  const _LoadingCar({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Animate(
          onPlay: (controller) => controller.repeat(reverse: true),
          child: const Icon(Icons.directions_car),
        ).moveX(begin: -12, end: 12, duration: 1000.ms),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}
