import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _formKey = GlobalKey<FormState>();
  final picker = ImagePicker();

  final phoneController = TextEditingController();
  final otpController = TextEditingController();
  final usernameController = TextEditingController();
  final carModelController = TextEditingController();
  final altContactController = TextEditingController();

  String role = 'rider';
  String selectedCarType = 'Ride X';
  final carTypeList = ['Ride X', 'Ride mini', 'Bike'];

  File? licenseImage, birthCertificateImage;
  String? licenseBase64, birthCertBase64;

  bool isOtpSent = false;
  bool isSubmitting = false;
  String? verificationId;
  bool canResend = false;
  int resendSeconds = 60;
  Timer? _resendTimer;

  @override
  void dispose() {
    phoneController.dispose();
    otpController.dispose();
    usernameController.dispose();
    carModelController.dispose();
    altContactController.dispose();
    _resendTimer?.cancel();
    super.dispose();
  }

  void startResendTimer() {
    setState(() {
      canResend = false;
      resendSeconds = 60;
    });
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (resendSeconds == 0) {
        timer.cancel();
        setState(() => canResend = true);
      } else {
        setState(() => resendSeconds--);
      }
    });
  }

  Future<void> pickImage(ImageSource source, bool isLicense) async {
    final picked = await picker.pickImage(source: source);
    if (picked != null) {
      final file = File(picked.path);
      final base64Str = await compressAndEncode(file);
      setState(() {
        if (isLicense) {
          licenseImage = file;
          licenseBase64 = base64Str;
        } else {
          birthCertificateImage = file;
          birthCertBase64 = base64Str;
        }
      });
    }
  }

  Future<String> compressAndEncode(File file) async {
    final originalBytes = await file.readAsBytes();
    final decoded = img.decodeImage(originalBytes);
    final resized = img.copyResize(decoded!, width: 600);
    final compressed = img.encodeJpg(resized, quality: 70);
    return base64Encode(compressed);
  }

  Future<bool> phoneNumberExists(String phone) async {
    final digitsOnly = phone.replaceAll(RegExp(r'\D'), '');
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .where('phone', isEqualTo: digitsOnly)
        .limit(1)
        .get();
    return snap.docs.isNotEmpty;
  }

  Future<void> sendOtp() async {
    final digitsOnly = phoneController.text.replaceAll(RegExp(r'\D'), '');
    if (digitsOnly.length != 11) {
      showError('Phone must be 11 digits.');
      return;
    }

    if (await phoneNumberExists(digitsOnly)) {
      showError('Phone number already in use.');
      return;
    }

    final formatted = '+92${digitsOnly.substring(1)}';

    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: formatted,
      timeout: const Duration(seconds: 60),
      verificationCompleted: (_) {},
      verificationFailed: (e) => showError('OTP failed: ${e.message}'),
      codeSent: (id, _) {
        setState(() {
          verificationId = id;
          isOtpSent = true;
        });
        startResendTimer();
      },
      codeAutoRetrievalTimeout: (id) => verificationId = id,
    );
  }

  Future<void> confirmOtp() async {
    if (!_formKey.currentState!.validate()) return;

    final digitsOnly = phoneController.text.replaceAll(RegExp(r'\D'), '');
    if (role == 'driver' &&
        (licenseBase64 == null || birthCertBase64 == null)) {
      showError('Please upload license and birth certificate.');
      return;
    }

    setState(() => isSubmitting = true);

    try {
      final credential = PhoneAuthProvider.credential(
        verificationId: verificationId!,
        smsCode: otpController.text.trim(),
      );

      final userCred = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );
      final user = userCred.user;
      if (user == null) throw Exception('Sign-in failed');

      final doc = {
        'uid': user.uid,
        'phone': digitsOnly,
        'username': usernameController.text.trim(),
        'role': role,
        'createdAt': FieldValue.serverTimestamp(),
        'verified': role == 'rider',
        if (role == 'driver') ...{
          'carType': selectedCarType,
          'carModel': carModelController.text.trim(),
          'altContact': altContactController.text.trim(),
          'licenseBase64': licenseBase64,
          'birthCertificateBase64': birthCertBase64,
          'verified': false,
        },
      };

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set(doc);
      if (mounted) Navigator.pushReplacementNamed(context, '/login');
    } catch (e) {
      showError('Verification failed: $e');
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  void showError(String msg) {
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
      appBar: AppBar(title: const Text('Sign Up - FemDrive')),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Form(
              key: _formKey,
              child: ListView(
                children: [
                  TextFormField(
                    controller: usernameController,
                    decoration: const InputDecoration(labelText: 'Username'),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: phoneController,
                    decoration: const InputDecoration(
                      labelText: 'Phone (e.g. 0300-1234567)',
                    ),
                    keyboardType: TextInputType.phone,
                    inputFormatters: [PhoneNumberHyphenFormatter()],
                    validator: (v) {
                      final digits = v?.replaceAll(RegExp(r'\D'), '') ?? '';
                      if (digits.length != 11) return 'Must be 11 digits';
                      return null;
                    },
                  ),
                  const SizedBox(height: 10),
                  if (isOtpSent) ...[
                    TextFormField(
                      controller: otpController,
                      decoration: const InputDecoration(labelText: 'Enter OTP'),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 10),
                    if (!canResend)
                      Text('Resend in $resendSeconds seconds')
                    else
                      TextButton(
                        onPressed: sendOtp,
                        child: const Text('Resend OTP'),
                      ),
                  ],
                  DropdownButtonFormField<String>(
                    value: role,
                    items: ['rider', 'driver']
                        .map(
                          (r) => DropdownMenuItem(
                            value: r,
                            child: Text(r.toUpperCase()),
                          ),
                        )
                        .toList(),
                    decoration: const InputDecoration(labelText: 'Register as'),
                    onChanged: (v) => setState(() => role = v!),
                  ),
                  if (role == 'driver') ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      value: selectedCarType,
                      decoration: const InputDecoration(labelText: 'Car Type'),
                      items: carTypeList
                          .map(
                            (t) => DropdownMenuItem(value: t, child: Text(t)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => selectedCarType = v!),
                    ),
                    TextFormField(
                      controller: carModelController,
                      decoration: const InputDecoration(labelText: 'Car Model'),
                      validator: (v) =>
                          v == null || v.isEmpty ? 'Required' : null,
                    ),
                    TextFormField(
                      controller: altContactController,
                      decoration: const InputDecoration(
                        labelText: 'Alt Contact',
                      ),
                      validator: (v) =>
                          v == null || v.isEmpty ? 'Required' : null,
                    ),
                    ElevatedButton(
                      onPressed: () => pickImage(ImageSource.gallery, true),
                      child: Text(
                        licenseImage == null
                            ? "Upload License"
                            : licenseImage!.path,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () => pickImage(ImageSource.gallery, false),
                      child: Text(
                        birthCertificateImage == null
                            ? "Upload Birth Cert."
                            : birthCertificateImage!.path,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: isSubmitting
                        ? null
                        : isOtpSent
                        ? confirmOtp
                        : sendOtp,
                    child: isSubmitting
                        ? const CircularProgressIndicator()
                        : Text(isOtpSent ? 'Verify & Register' : 'Send OTP'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PhoneNumberHyphenFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    String digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length <= 4) return TextEditingValue(text: digits);
    return TextEditingValue(
      text: '${digits.substring(0, 4)}-${digits.substring(4)}',
      selection: TextSelection.collapsed(offset: digits.length + 1),
    );
  }
}
