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

  String formatPhoneNumber(String input) {
    final digits = input.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 11 || !digits.startsWith('03')) {
      throw Exception("Must be 11 digits starting with 03");
    }
    return '+92${digits.substring(1)}';
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

  String _mapFirebaseError(FirebaseAuthException e) {
    switch (e.code) {
      case 'invalid-phone-number':
        return 'The phone number format is incorrect.';
      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';
      case 'session-expired':
        return 'OTP session expired. Please request again.';
      case 'invalid-verification-code':
        return 'The OTP entered is incorrect.';
      default:
        return e.message ?? 'An unexpected authentication error occurred.';
    }
  }

  Future<void> sendOtp() async {
    if (!_formKey.currentState!.validate()) return;

    if (role == 'driver') {
      if (carModelController.text.trim().isEmpty ||
          altContactController.text.trim().isEmpty ||
          licenseBase64 == null ||
          birthCertBase64 == null) {
        return showError('Please fill all driver details and upload images.');
      }
    }

    try {
      final formatted = formatPhoneNumber(phoneController.text);

      if (await phoneNumberExists(formatted.replaceAll('+92', '0'))) {
        return showError('This phone number is already registered.');
      }

      final confirmed = await _confirmNumberDialog(formatted);
      if (!confirmed && mounted) {
        FocusScope.of(context).requestFocus(FocusNode());
        FocusScope.of(context).requestFocus(FocusNode());
        FocusScope.of(context).requestFocus(FocusNode());
        FocusScope.of(context).requestFocus(FocusNode());
        FocusScope.of(context).requestFocus(FocusNode());
        phoneController.selection = TextSelection.fromPosition(
          TextPosition(offset: phoneController.text.length),
        );
        return;
      }

      setState(() => isSubmitting = true);

      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: formatted,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (PhoneAuthCredential credential) async {
          await FirebaseAuth.instance.signInWithCredential(credential);
          await confirmOtp(autoCredential: credential);
        },
        verificationFailed: (FirebaseAuthException e) {
          showError(_mapFirebaseError(e));
        },
        codeSent: (id, _) {
          setState(() {
            verificationId = id;
            isOtpSent = true;
          });
          startResendTimer();
        },
        codeAutoRetrievalTimeout: (id) => verificationId = id,
      );
    } on FirebaseAuthException catch (e) {
      showError(_mapFirebaseError(e));
    } catch (e) {
      showError('Unexpected error: $e');
    } finally {
      setState(() => isSubmitting = false);
    }
  }

  Future<void> confirmOtp({PhoneAuthCredential? autoCredential}) async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => isSubmitting = true);

    try {
      final credential =
          autoCredential ??
          PhoneAuthProvider.credential(
            verificationId: verificationId!,
            smsCode: otpController.text.trim(),
          );

      final userCred = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );
      final user = userCred.user;
      if (user == null) throw Exception('Sign-in failed');

      final digitsOnly = phoneController.text.replaceAll(RegExp(r'\D'), '');

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
    } on FirebaseAuthException catch (e) {
      showError(_mapFirebaseError(e));
    } catch (e) {
      showError('Verification failed: $e');
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  Future<bool> _confirmNumberDialog(String formatted) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Confirm Number'),
            content: Text('Is this number correct?\n$formatted'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Edit'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Yes'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  String _truncateFileName(String path) {
    final fileName = path.split('/').last;
    return fileName.length > 15 ? '${fileName.substring(0, 12)}...' : fileName;
  }

  @override
  Widget build(BuildContext context) {
    final fieldDecoration = const InputDecoration(
      labelStyle: TextStyle(height: 1.2),
      border: OutlineInputBorder(),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Sign Up - FemDrive')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: ListView(
            children: [
              const SizedBox(height: 10),
              TextFormField(
                controller: usernameController,
                decoration: fieldDecoration.copyWith(labelText: 'Username'),
                validator: (v) => v == null || v.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: phoneController,
                decoration: fieldDecoration.copyWith(
                  labelText: 'Phone (e.g. 0300-1234567)',
                ),
                keyboardType: TextInputType.phone,
                inputFormatters: [PhoneNumberHyphenFormatter()],
                validator: (v) {
                  try {
                    formatPhoneNumber(v ?? '');
                    return null;
                  } catch (e) {
                    return e.toString().replaceAll('Exception: ', '');
                  }
                },
              ),
              if (isOtpSent) ...[
                const SizedBox(height: 15),
                TextFormField(
                  controller: otpController,
                  decoration: fieldDecoration.copyWith(labelText: 'Enter OTP'),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 10),
                canResend
                    ? TextButton(
                        onPressed: sendOtp,
                        child: const Text('Resend OTP'),
                      )
                    : Text('Resend in $resendSeconds seconds'),
              ],
              const SizedBox(height: 15),
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
                decoration: fieldDecoration.copyWith(labelText: 'Register as'),
                onChanged: (v) => setState(() => role = v!),
              ),
              if (role == 'driver') ...[
                const SizedBox(height: 15),
                DropdownButtonFormField<String>(
                  value: selectedCarType,
                  decoration: fieldDecoration.copyWith(labelText: 'Car Type'),
                  items: carTypeList
                      .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                      .toList(),
                  onChanged: (v) => setState(() => selectedCarType = v!),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: carModelController,
                  decoration: fieldDecoration.copyWith(labelText: 'Car Model'),
                  validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: altContactController,
                  decoration: fieldDecoration.copyWith(
                    labelText: 'Alternate Number',
                  ),
                  keyboardType: TextInputType.phone,
                  inputFormatters: [PhoneNumberHyphenFormatter()],
                  validator: (v) {
                    try {
                      formatPhoneNumber(v ?? '');
                      return null;
                    } catch (e) {
                      return e.toString().replaceAll('Exception: ', '');
                    }
                  },
                ),
                const SizedBox(height: 10),
                ElevatedButton(
                  onPressed: () => pickImage(ImageSource.gallery, true),
                  child: Text(
                    licenseImage == null
                        ? "Upload License"
                        : _truncateFileName(licenseImage!.path),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 10),
                ElevatedButton(
                  onPressed: () => pickImage(ImageSource.gallery, false),
                  child: Text(
                    birthCertificateImage == null
                        ? "Upload Birth Certificate"
                        : _truncateFileName(birthCertificateImage!.path),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              const SizedBox(height: 25),
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
    );
  }
}

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
