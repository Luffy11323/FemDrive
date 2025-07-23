import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sms_autofill/sms_autofill.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with CodeAutoFill {
  final phoneController = TextEditingController();
  final otpController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool loading = false;
  bool otpSent = false;
  bool canResend = false;
  int countdown = 60;
  String? verificationId;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    listenForCode(); // start SMS autofill listener
  }

  @override
  void dispose() {
    _timer?.cancel();
    cancel(); // stop SMS autofill listener
    super.dispose();
  }

  @override
  void codeUpdated() {
    if (code != null && otpSent) {
      otpController.text = code!;
      verifyOtp();
    }
  }

  void startTimer() {
    countdown = 60;
    canResend = false;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() {
        countdown--;
        if (countdown <= 0) {
          t.cancel();
          canResend = true;
        }
      });
    });
  }

  Future<void> sendOtp() async {
    if (!_formKey.currentState!.validate()) return;
    final phone = phoneController.text.replaceAll('-', '');
    setState(() {
      loading = true;
      otpSent = false;
    });

    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: '+92$phone',
      timeout: const Duration(seconds: 60),
      verificationCompleted: (cred) async {
        await FirebaseAuth.instance.signInWithCredential(cred);
        await _handlePostLogin();
      },
      verificationFailed: (e) {
        _showError('Verification failed: ${e.message}');
      },
      codeSent: (id, _) {
        setState(() {
          verificationId = id;
          otpSent = true;
        });
        startTimer();
      },
      codeAutoRetrievalTimeout: (id) {
        verificationId = id;
      },
    );

    setState(() => loading = false);
  }

  Future<void> verifyOtp() async {
    final code = otpController.text.trim();
    if (verificationId == null || code.length < 6) {
      return _showError("Enter valid OTP");
    }
    setState(() => loading = true);
    try {
      final cred = PhoneAuthProvider.credential(
        verificationId: verificationId!,
        smsCode: code,
      );
      await FirebaseAuth.instance.signInWithCredential(cred);
      await _handlePostLogin();
    } catch (e) {
      _showError("Login failed: $e");
    } finally {
      setState(() => loading = false);
    }
  }

  Future<void> _handlePostLogin() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return _showError("User not found");

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final data = doc.data();
    if (data == null) return _showError("Profile missing");

    final isVerified = data['verified'] == true;
    final role = data['role'];

    if (role == 'driver' && !isVerified) {
      await FirebaseAuth.instance.signOut();
      return _showError("Pending admin approval.");
    }

    String route = '/dashboard';
    if (role == 'admin') {
      route = '/admin';
    } else if (role == 'driver') {
      route = '/driver-dashboard';
    } else if (role == 'rider') {
      route = '/rider-dashboard';
    } else {
      return _showError("Invalid role: $role");
    }

    if (!mounted) return;
    Navigator.pushReplacementNamed(context, route);
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text("Message"),
        backgroundColor: Theme.of(context).colorScheme.primary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              TextFormField(
                controller: phoneController,
                decoration: const InputDecoration(
                  labelText: 'Phone (e.g. 0300-1234567)',
                ),
                keyboardType: TextInputType.phone,
                validator: (v) {
                  final pattern = RegExp(r'^03\d{2}-\d{7}$');
                  if (v == null || !pattern.hasMatch(v)) return 'Invalid phone';
                  return null;
                },
                enabled: !otpSent,
              ),
              if (otpSent) ...[
                const SizedBox(height: 12),
                PinFieldAutoFill(
                  controller: otpController,
                  decoration: BoxLooseDecoration(
                    gapSpace: 12,
                    strokeColorBuilder: FixedColorBuilder(Color(0xFFC9A0DC)),
                    bgColorBuilder: FixedColorBuilder(Colors.white),
                  ),
                  currentCode: '',
                  codeLength: 6,
                ),
              ],
              const SizedBox(height: 20),
              if (loading) ...[
                const Center(child: CircularProgressIndicator()),
              ] else if (!otpSent) ...[
                ElevatedButton(
                  onPressed: sendOtp,
                  child: const Text('Send OTP'),
                ),
              ] else ...[
                ElevatedButton(
                  onPressed: verifyOtp,
                  child: const Text('Verify OTP'),
                ),
                const SizedBox(height: 8),
                canResend
                    ? TextButton(
                        onPressed: sendOtp,
                        child: const Text('Resend OTP'),
                      )
                    : Text('Resend in $countdown sec'),
              ],
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
