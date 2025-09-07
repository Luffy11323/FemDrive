// ignore_for_file: avoid_print, use_build_context_synchronously

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:camera/camera.dart';
import 'package:sms_autofill/sms_autofill.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class OtpInputField extends StatefulWidget {
  final int length;
  final void Function(String) onCompleted;
  final bool enabled;
  const OtpInputField({
    super.key,
    this.length = 6,
    required this.onCompleted,
    this.enabled = true,
  });

  @override
  State<OtpInputField> createState() => _OtpInputFieldState();
}

class _OtpInputFieldState extends State<OtpInputField> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      enabled: widget.enabled,
      controller: _controller,
      keyboardType: TextInputType.number,
      maxLength: widget.length,
      textAlign: TextAlign.center,
      style: const TextStyle(letterSpacing: 20, fontSize: 20),
      decoration: InputDecoration(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        counterText: "",
        prefixIcon: const Icon(Icons.lock),
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainer,
      ),
      onChanged: (value) {
        if (value.length == widget.length) {
          widget.onCompleted(value);
        }
      },
    ).animate().fadeIn(duration: 400.ms);
  }
}

class _SignUpPageState extends State<SignUpPage> with CodeAutoFill {
  final _formKey = GlobalKey<FormState>();

  final phoneController = TextEditingController();
  final usernameController = TextEditingController();
  final carModelController = TextEditingController();
  final altContactController = TextEditingController();
  String enteredOtp = "";

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

  final int otpLength = 6;

  @override
  void initState() {
    super.initState();
    listenForCode();
  }

  @override
  void dispose() {
    cancel();
    phoneController.dispose();
    usernameController.dispose();
    carModelController.dispose();
    altContactController.dispose();
    _resendTimer?.cancel();
    super.dispose();
  }

  @override
  void codeUpdated() {
    final received = code ?? '';
    if (received.isEmpty) return;

    final clean = received.replaceAll(RegExp(r'\D'), '');
    setState(() => enteredOtp = clean);

    if (clean.length >= otpLength) {
      confirmOtp();
    }
  }

  void startResendTimer() {
    _resendTimer?.cancel();
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
        .collection('phones')
        .doc(digitsOnly)
        .get();
    return snap.exists;
  }

  void showError(String msg) {
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

  Future<void> sendOtp() async {
    if (isSubmitting) return; // guard
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    if (role == 'driver') {
      if (carModelController.text.trim().isEmpty ||
          altContactController.text.trim().isEmpty ||
          licenseBase64 == null ||
          birthCertBase64 == null) {
        return showError('Please fill all driver details and capture images.');
      }
    }

    try {
      final formatted = formatPhoneNumber(phoneController.text);

      if (await phoneNumberExists(formatted.replaceAll('+92', '0'))) {
        return showError('This phone number is already registered.');
      }

      setState(() => isSubmitting = true);
      await Future.delayed(const Duration(milliseconds: 100));

      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: formatted,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (PhoneAuthCredential credential) async {
          await FirebaseAuth.instance.signInWithCredential(credential);
          await confirmOtp(autoCredential: credential);
        },
        verificationFailed: (FirebaseAuthException e) {
          showError(e.message ?? 'Verification failed.');
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
    } catch (e) {
      showError('Unexpected error: $e');
    } finally {
      setState(() => isSubmitting = false);
    }
  }

  Future<void> confirmOtp({PhoneAuthCredential? autoCredential}) async {
    if (isSubmitting) return; // guard
    FocusScope.of(context).unfocus();
    setState(() => isSubmitting = true);

    try {
      if (autoCredential == null && enteredOtp.length != otpLength) {
        showError('Please enter the full OTP');
        return;
      }

      if (verificationId == null && autoCredential == null) {
        showError('Verification ID is missing. Please resend OTP.');
        return;
      }

      final credential =
          autoCredential ??
          PhoneAuthProvider.credential(
            verificationId: verificationId!,
            smsCode: enteredOtp,
          );

      final userCred = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );
      final user = userCred.user;

      if (user == null) {
        showError('Authentication failed. Please try again.');
        return;
      }

      await Future.delayed(const Duration(milliseconds: 500));

      final primaryDigits = phoneController.text.replaceAll(RegExp(r'\D'), '');

      final existingDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (existingDoc.exists) {
        await FirebaseAuth.instance.signOut();
        showError('Account already exists. Please try logging in.');
        return;
      }

      await FirebaseFirestore.instance
          .collection('phones')
          .doc(primaryDigits)
          .set({'uid': user.uid, 'type': 'primary'});

      if (role == 'driver') {
        final altDigits = altContactController.text.replaceAll(
          RegExp(r'\D'),
          '',
        );
        await FirebaseFirestore.instance
            .collection('phones')
            .doc(altDigits)
            .set({'uid': user.uid, 'type': 'alt'});
      }

      final doc = <String, dynamic>{
        'uid': user.uid,
        'phone': primaryDigits,
        'username': usernameController.text.trim(),
        'role': role,
        'createdAt': FieldValue.serverTimestamp(),
        'verified': role == 'rider',
      };

      if (role == 'driver') {
        final altDigits = altContactController.text.replaceAll(
          RegExp(r'\D'),
          '',
        );

        doc.addAll({
          'carType': selectedCarType,
          'carModel': carModelController.text.trim(),
          'altContact': altDigits,
          'licenseBase64': licenseBase64!,
          'birthCertificateBase64': birthCertBase64!,
          'documentsUploaded': true,
          'awaitingVerification': true,
          'uploadTimestamp': FieldValue.serverTimestamp(),
        });
      }

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set(doc);

      final message = role == 'driver'
          ? 'Driver registration successful! Your account is pending verification.'
          : 'Registration successful!';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Theme.of(context).colorScheme.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );

      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/login');
    } catch (e) {
      showError('Registration failed: $e');
    } finally {
      if (mounted) {
        setState(() => isSubmitting = false);
      }
    }
  }

  Future<void> _captureDocument(bool isLicense) async {
    if (isSubmitting) return; // guard
    try {
      final file = await Navigator.push<File?>(
        context,
        MaterialPageRoute(builder: (_) => const FullScreenCamera()),
      );

      if (file == null) return;
      setState(() => isSubmitting = true);

      final compressed = await FlutterImageCompress.compressWithFile(
        file.absolute.path,
        minWidth: 800,
        minHeight: 800,
        quality: 60,
      );

      if (compressed == null) throw Exception("Image compression failed");
      final base64Str = base64Encode(compressed);

      setState(() {
        if (isLicense) {
          licenseImage = file;
          licenseBase64 = base64Str;
        } else {
          birthCertificateImage = file;
          birthCertBase64 = base64Str;
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${isLicense ? 'License' : 'Birth certificate'} captured successfully!',
          ),
          backgroundColor: Theme.of(context).colorScheme.primary,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } catch (e) {
      showError('Failed to capture image: $e');
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
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
            'Sign Up - FemDrive',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          centerTitle: true,
        ),
        body: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
              child: Form(
                key: _formKey,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Create your account',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ).animate().fadeIn(duration: 400.ms),
                      const SizedBox(height: 8),
                      Text(
                        'Fill in the details to sign up.',
                        style: TextStyle(
                          fontSize: 16,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ).animate().fadeIn(duration: 400.ms, delay: 100.ms),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: usernameController,
                        enabled: !isSubmitting,
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person),
                        ),
                        validator: (v) =>
                            v == null || v.isEmpty ? 'Required' : null,
                      ).animate().slideX(begin: -0.1, end: 0, duration: 400.ms),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: phoneController,
                        enabled: !isSubmitting, // <—
                        decoration: const InputDecoration(
                          labelText: 'Phone (e.g. 0300-1234567)',
                          prefixIcon: Icon(Icons.phone),
                        ),
                        keyboardType: TextInputType.phone,
                        validator: (v) {
                          if (v == null || v.isEmpty) return 'Required';
                          try {
                            formatPhoneNumber(v);
                            return null;
                          } catch (e) {
                            return e.toString().replaceAll('Exception: ', '');
                          }
                        },
                      ).animate().slideX(begin: 0.1, end: 0, duration: 400.ms),
                      if (isOtpSent) ...[
                        const SizedBox(height: 16),
                        _buildOtpFields(),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              canResend
                                  ? 'Resend OTP'
                                  : 'Resend in $resendSeconds seconds',
                              style: TextStyle(
                                color: canResend
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            TextButton(
                              onPressed: (!isSubmitting && canResend)
                                  ? sendOtp
                                  : null,
                              child: const Text('Resend OTP'),
                            ),
                          ],
                        ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
                      ],
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: role,
                        items: ['rider', 'driver']
                            .map(
                              (r) => DropdownMenuItem(
                                value: r,
                                child: Text(r.toUpperCase()),
                              ),
                            )
                            .toList(),
                        decoration: const InputDecoration(
                          labelText: 'Register as',
                          prefixIcon: Icon(Icons.person_pin),
                        ),
                        onChanged: isSubmitting
                            ? null
                            : (v) => setState(() => role = v!),
                      ).animate().slideX(
                        begin: -0.1,
                        end: 0,
                        duration: 400.ms,
                        delay: 100.ms,
                      ),
                      if (role == 'driver') ...[
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: selectedCarType,
                          decoration: const InputDecoration(
                            labelText: 'Car Type',
                            prefixIcon: Icon(Icons.directions_car),
                          ),
                          items: carTypeList
                              .map(
                                (t) =>
                                    DropdownMenuItem(value: t, child: Text(t)),
                              )
                              .toList(),
                          onChanged: isSubmitting
                              ? null
                              : (v) => setState(() => selectedCarType = v!),
                        ).animate().slideX(
                          begin: 0.1,
                          end: 0,
                          duration: 400.ms,
                          delay: 200.ms,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: carModelController,
                          enabled: !isSubmitting,
                          decoration: const InputDecoration(
                            labelText: 'Car Model',
                            prefixIcon: Icon(Icons.car_rental),
                          ),
                          validator: (v) =>
                              v == null || v.isEmpty ? 'Required' : null,
                        ).animate().slideX(
                          begin: -0.1,
                          end: 0,
                          duration: 400.ms,
                          delay: 300.ms,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: altContactController,
                          enabled: !isSubmitting,
                          decoration: const InputDecoration(
                            labelText: 'Alternate Number',
                            prefixIcon: Icon(Icons.phone),
                          ),
                          keyboardType: TextInputType.phone,
                          validator: (v) {
                            if (v == null || v.isEmpty) return 'Required';
                            try {
                              formatPhoneNumber(v);
                              return null;
                            } catch (e) {
                              return e.toString().replaceAll('Exception: ', '');
                            }
                          },
                        ).animate().slideX(
                          begin: 0.1,
                          end: 0,
                          duration: 400.ms,
                          delay: 400.ms,
                        ),
                        const SizedBox(height: 16),
                        _buildImageButton(true),
                        const SizedBox(height: 16),
                        _buildImageButton(false),
                      ],
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: isSubmitting
                            ? null
                            : (isOtpSent
                                  ? () => confirmOtp()
                                  : () => sendOtp()),
                        child: AnimatedSwitcher(
                          duration: 250.ms,
                          transitionBuilder: (child, anim) =>
                              FadeTransition(opacity: anim, child: child),
                          child: (isSubmitting || isOtpSent)
                              ? _LoadingCar(
                                  key: ValueKey(
                                    isSubmitting ? 'loading' : 'awaiting_otp',
                                  ),
                                  label: isSubmitting
                                      ? (isOtpSent
                                            ? 'Verifying & Registering...'
                                            : 'Sending OTP...')
                                      : 'Verify & Register', // when isOtpSent && !isSubmitting
                                )
                              : const Text('Send OTP', key: ValueKey('idle')),
                        ),
                      ).animate().slideY(begin: 0.2, end: 0, duration: 400.ms),
                    ],
                  ),
                ),
              ),
            ),
            if (isSubmitting)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(
                  minHeight: 4,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainer,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    Theme.of(context).colorScheme.primary,
                  ),
                ),
              ).animate().fadeIn(duration: 300.ms),
          ],
        ),
      ),
    );
  }

  Widget _buildOtpFields() {
    return OtpInputField(
      length: otpLength,
      enabled: !isSubmitting,
      onCompleted: (code) {
        setState(() => enteredOtp = code);
      },
    );
  }

  Widget _buildImageButton(bool isLicense) {
    final file = isLicense ? licenseImage : birthCertificateImage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (file != null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(file, height: 160, fit: BoxFit.cover),
              ).animate().fadeIn(duration: 400.ms),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: isSubmitting
                        ? null
                        : () => _captureDocument(isLicense),
                    child: const Text("Retake"),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isLicense
                        ? "License captured"
                        : "Birth certificate captured",
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ).animate().fadeIn(duration: 400.ms, delay: 100.ms),
            ],
          )
        else
          ElevatedButton.icon(
            onPressed: isSubmitting ? null : () => _captureDocument(isLicense),
            icon: const Icon(Icons.camera_alt),
            label: Text(
              isLicense ? "Capture License" : "Capture Birth Certificate",
            ),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(double.infinity, 48),
            ),
          ).animate().slideY(begin: 0.2, end: 0, duration: 400.ms),
      ],
    );
  }
}

class FullScreenCamera extends StatefulWidget {
  const FullScreenCamera({super.key});

  @override
  State<FullScreenCamera> createState() => _FullScreenCameraState();
}

class _FullScreenCameraState extends State<FullScreenCamera> {
  CameraController? _controller;
  XFile? _capturedFile;
  bool _isCameraReady = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.first;
      _controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await _controller!.initialize();
      if (!mounted) return;
      setState(() => _isCameraReady = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Camera error: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _takePicture() async {
    if (!(_controller?.value.isInitialized ?? false)) return;
    final file = await _controller!.takePicture();
    setState(() {
      _capturedFile = file;
    });
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
          ),
        ),
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _isCameraReady
            ? _capturedFile == null
                  ? Stack(
                      children: [
                        Positioned.fill(
                          child: CameraPreview(
                            _controller!,
                          ).animate().fadeIn(duration: 400.ms),
                        ),
                        Positioned(
                          top: MediaQuery.of(context).padding.top + 12,
                          left: 12,
                          child: IconButton(
                            color: Colors.white,
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(context),
                            tooltip: 'Close',
                          ),
                        ),
                      ],
                    )
                  : Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(
                          File(_capturedFile!.path),
                          fit: BoxFit.cover,
                        ).animate().fadeIn(duration: 400.ms),
                        Positioned(
                          top: MediaQuery.of(context).padding.top + 12,
                          left: 12,
                          child: IconButton(
                            color: Colors.white,
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(context),
                            tooltip: 'Close',
                          ),
                        ),
                        Positioned(
                          bottom: 30,
                          left: 16,
                          right: 16,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                            children: [
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.error,
                                ),
                                onPressed: () =>
                                    setState(() => _capturedFile = null),
                                child: const Text("Retake"),
                              ).animate().slideY(
                                begin: 0.2,
                                end: 0,
                                duration: 400.ms,
                                delay: 100.ms,
                              ),
                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Theme.of(
                                    context,
                                  ).colorScheme.primary,
                                ),
                                onPressed: () => Navigator.pop(
                                  context,
                                  File(_capturedFile!.path),
                                ),
                                child: const Text("Use Photo"),
                              ).animate().slideY(
                                begin: 0.2,
                                end: 0,
                                duration: 400.ms,
                                delay: 200.ms,
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
            : const Center(
                child: CircularProgressIndicator(),
              ).animate().fadeIn(duration: 400.ms),
        floatingActionButton: _capturedFile == null && _isCameraReady
            ? FloatingActionButton(
                backgroundColor: Colors.white,
                onPressed: _takePicture,
                tooltip: 'Capture Photo',
                child: const Icon(Icons.camera_alt, color: Colors.black),
              ).animate().scale(duration: 300.ms)
            : null,
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
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
