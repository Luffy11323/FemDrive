// ignore_for_file: avoid_print, use_build_context_synchronously

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:camera/camera.dart';
import 'package:sms_autofill/sms_autofill.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class OtpInputField extends StatefulWidget {
  final int length;
  final void Function(String) onCompleted;

  const OtpInputField({super.key, this.length = 6, required this.onCompleted});

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
      controller: _controller,
      keyboardType: TextInputType.number,
      maxLength: widget.length,
      textAlign: TextAlign.center,
      style: const TextStyle(letterSpacing: 30, fontSize: 20),
      decoration: const InputDecoration(
        border: OutlineInputBorder(),
        counterText: "",
      ),
      onChanged: (value) {
        if (value.length == widget.length) {
          widget.onCompleted(value);
        }
      },
    );
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
  String? licenseUrl, birthCertUrl;

  bool isOtpSent = false;
  bool isSubmitting = false;
  String? verificationId;
  bool canResend = false;
  int resendSeconds = 60;
  Timer? _resendTimer;

  // OTP controllers & focus
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
        .collection('users')
        .where('phone', isEqualTo: digitsOnly)
        .limit(1)
        .get();
    return snap.docs.isNotEmpty;
  }

  void showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
  }

  Future<void> sendOtp() async {
    if (!_formKey.currentState!.validate()) return;

    if (role == 'driver') {
      if (carModelController.text.trim().isEmpty ||
          altContactController.text.trim().isEmpty ||
          licenseUrl == null ||
          birthCertUrl == null) {
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

      final existingDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (existingDoc.exists) {
        await FirebaseAuth.instance.signOut();
        showError('Account already exists. Please try logging in.');
        return;
      }

      final primaryDigits = phoneController.text.replaceAll(RegExp(r'\D'), '');

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
          'licenseUrl': licenseUrl!,
          'birthCertificateUrl': birthCertUrl!,
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
        SnackBar(content: Text(message), backgroundColor: Colors.green),
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
    try {
      final file = await Navigator.push<File?>(
        context,
        MaterialPageRoute(builder: (_) => const FullScreenCamera()),
      );

      if (file == null) return;
      setState(() => isSubmitting = true);

      final storageRef = FirebaseStorage.instance.ref().child(
        "documents/${isLicense ? 'license' : 'birthCert'}_${DateTime.now().millisecondsSinceEpoch}.jpg",
      );

      await storageRef.putFile(file);
      final downloadUrl = await storageRef.getDownloadURL();

      setState(() {
        if (isLicense) {
          licenseImage = file;
          licenseUrl = downloadUrl;
        } else {
          birthCertificateImage = file;
          birthCertUrl = downloadUrl;
        }
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${isLicense ? 'License' : 'Birth certificate'} uploaded successfully!',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      showError('Failed to upload image: $e');
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fieldDecoration = const InputDecoration(
      labelStyle: TextStyle(height: 1.2),
      border: OutlineInputBorder(),
    );

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
                    decoration: fieldDecoration.copyWith(labelText: 'Username'),
                    validator: (v) =>
                        v == null || v.isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 15),
                  TextFormField(
                    controller: phoneController,
                    decoration: fieldDecoration.copyWith(
                      labelText: 'Phone (e.g. 0300-1234567)',
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
                  ),
                  if (isOtpSent) ...[
                    const SizedBox(height: 15),
                    _buildOtpFields(),
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
                    initialValue: role,
                    items: ['rider', 'driver']
                        .map(
                          (r) => DropdownMenuItem(
                            value: r,
                            child: Text(r.toUpperCase()),
                          ),
                        )
                        .toList(),
                    decoration: fieldDecoration.copyWith(
                      labelText: 'Register as',
                    ),
                    onChanged: (v) => setState(() => role = v!),
                  ),
                  if (role == 'driver') ...[
                    const SizedBox(height: 15),
                    DropdownButtonFormField<String>(
                      initialValue: selectedCarType,
                      decoration: fieldDecoration.copyWith(
                        labelText: 'Car Type',
                      ),
                      items: carTypeList
                          .map(
                            (t) => DropdownMenuItem(value: t, child: Text(t)),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => selectedCarType = v!),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: carModelController,
                      decoration: fieldDecoration.copyWith(
                        labelText: 'Car Model',
                      ),
                      validator: (v) =>
                          v == null || v.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: altContactController,
                      decoration: fieldDecoration.copyWith(
                        labelText: 'Alternate Number',
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
                    ),
                    const SizedBox(height: 10),
                    _buildImageButton(true),
                    const SizedBox(height: 10),
                    _buildImageButton(false),
                  ],
                  const SizedBox(height: 25),
                  ElevatedButton(
                    onPressed: isSubmitting
                        ? null
                        : isOtpSent
                        ? confirmOtp
                        : sendOtp,
                    child: isSubmitting
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: const [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 10),
                              Text("Please wait..."),
                            ],
                          )
                        : Text(isOtpSent ? 'Verify & Register' : 'Send OTP'),
                  ),
                ],
              ),
            ),
          ),
          if (isSubmitting)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(minHeight: 3),
            ),
        ],
      ),
    );
  }

  Widget _buildOtpFields() {
    return OtpInputField(
      length: otpLength,
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
                borderRadius: BorderRadius.circular(8),
                child: Image.file(file, height: 160, fit: BoxFit.cover),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  TextButton(
                    onPressed: () => _captureDocument(isLicense),
                    child: const Text("Retake"),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isLicense
                        ? "License uploaded"
                        : "Birth certificate uploaded",
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ],
          )
        else
          ElevatedButton.icon(
            onPressed: () => _captureDocument(isLicense),
            icon: const Icon(Icons.camera_alt),
            label: Text(
              isLicense ? "Capture License" : "Capture Birth Certificate",
            ),
          ),
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Camera error: $e')));
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
    if (!_isCameraReady) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: _capturedFile == null
          ? Stack(
              children: [
                Positioned.fill(child: CameraPreview(_controller!)),
                Positioned(
                  top: MediaQuery.of(context).padding.top + 12,
                  left: 12,
                  child: IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ],
            )
          : Stack(
              fit: StackFit.expand,
              children: [
                Image.file(File(_capturedFile!.path), fit: BoxFit.cover),
                Positioned(
                  top: MediaQuery.of(context).padding.top + 12,
                  left: 12,
                  child: IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                Positioned(
                  bottom: 30,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                        onPressed: () => setState(() => _capturedFile = null),
                        child: const Text("Retake"),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                        onPressed: () {
                          Navigator.pop(context, File(_capturedFile!.path));
                        },
                        child: const Text("Confirm"),
                      ),
                    ],
                  ),
                ),
              ],
            ),
      floatingActionButton: _capturedFile == null
          ? FloatingActionButton(
              onPressed: _takePicture,
              child: const Icon(Icons.camera),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}
