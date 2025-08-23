import 'dart:async';
// ignore: unused_import
import 'dart:convert';
import 'dart:io';
// ignore: unnecessary_import
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:camera/camera.dart';
import 'package:sms_autofill/sms_autofill.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';

/// FemDrive – Production-grade signup with:
/// - Rider & Driver roles
/// - Centralized driver validation
/// - Phone OTP (FirebaseAuth)
/// - Firestore profile write
/// - Firebase Storage upload for license & birth certificate (no Base64 in DB)
/// - Resend timer + SMS Autofill
class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

/// Simple OTP input. You can swap with a package like `pin_code_fields` for richer UI.
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
        final digits = value.replaceAll(RegExp(r'\D'), '');
        if (digits.length == widget.length) {
          widget.onCompleted(digits);
        }
      },
    );
  }
}

class _SignUpPageState extends State<SignUpPage> with CodeAutoFill {
  final _formKey = GlobalKey<FormState>();

  // Controllers
  final phoneController = TextEditingController();
  final usernameController = TextEditingController();
  final carModelController = TextEditingController();
  final altContactController = TextEditingController();

  // Role & vehicle
  String role = 'rider';
  String selectedCarType = 'Ride X';
  final carTypeList = const ['Ride X', 'Ride mini', 'Bike'];

  // Document files (kept locally until upload)
  File? licenseImage;
  File? birthCertificateImage;

  // OTP state
  String enteredOtp = '';
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
    listenForCode(); // sms_autofill
  }

  @override
  void dispose() {
    cancel(); // sms_autofill stop
    _resendTimer?.cancel();
    phoneController.dispose();
    usernameController.dispose();
    carModelController.dispose();
    altContactController.dispose();
    super.dispose();
  }

  // ======== SMS AutoFill hook ========
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

  // ======== Helpers ========
  void startResendTimer() {
    setState(() {
      canResend = false;
      resendSeconds = 60;
    });
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (resendSeconds == 0) {
        timer.cancel();
        if (mounted) setState(() => canResend = true);
      } else {
        if (mounted) setState(() => resendSeconds--);
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

  Future<bool> phoneNumberExists(String e164orLocal) async {
    // We store as local format (0300xxxxxxx). Normalize to local
    final local = e164orLocal.startsWith('+92')
        ? e164orLocal.replaceFirst('+92', '0')
        : e164orLocal.replaceAll(RegExp(r'\D'), '');
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .where('phone', isEqualTo: local)
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

  void showInfo(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Centralized validation for driver-only fields. Shows a single dialog if missing.
  bool validateDriverFields() {
    final missingFields = <String>[];

    if (carModelController.text.trim().isEmpty) {
      missingFields.add('Car Model');
    }

    if (altContactController.text.trim().isEmpty) {
      missingFields.add('Alternate Contact Number');
    } else {
      try {
        formatPhoneNumber(altContactController.text.trim());
      } catch (_) {
        missingFields.add('Valid Alternate Contact Number');
      }
    }

    if (licenseImage == null) {
      missingFields.add('Driving License Image');
    }
    if (birthCertificateImage == null) {
      missingFields.add('Birth Certificate Image');
    }

    if (missingFields.isNotEmpty) {
      // quick, precise hint
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Please provide: ${missingFields.first}"),
          backgroundColor: Colors.red,
        ),
      );

      // full list
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text("Incomplete Driver Details"),
          content: Text(
            "Please provide the following:\n\n${missingFields.map((f) => '• $f').join('\n')}",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("OK"),
            ),
          ],
        ),
      );
      return false;
    }
    return true;
  }

  // ======== Firebase flows ========
  Future<void> sendOtp() async {
    if (!_formKey.currentState!.validate()) return;
    if (role == 'driver' && !validateDriverFields()) return;

    final formatted = formatPhoneNumber(phoneController.text.trim());

    if (await phoneNumberExists(formatted)) {
      showError('This phone number is already registered.');
      return;
    }

    setState(() => isSubmitting = true);
    try {
      await FirebaseAuth.instance.verifyPhoneNumber(
        phoneNumber: formatted,
        timeout: const Duration(seconds: 60),
        verificationCompleted: (PhoneAuthCredential credential) async {
          // Auto-verification (test or real)
          await FirebaseAuth.instance.signInWithCredential(credential);
          await confirmOtp(autoCredential: credential);
        },
        verificationFailed: (e) =>
            showError(e.message ?? 'Verification failed.'),
        codeSent: (id, _) {
          setState(() {
            verificationId = id;
            isOtpSent = true;
          });
          startResendTimer();
          showInfo('OTP sent. Please check your messages.');
        },
        codeAutoRetrievalTimeout: (id) => verificationId = id,
      );
    } catch (e) {
      showError('Unexpected error: $e');
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  // Add this debug version to your confirmOtp method in SignUpPage
  // Replace the existing confirmOtp method with this enhanced version

  Future<void> confirmOtp({PhoneAuthCredential? autoCredential}) async {
    setState(() => isSubmitting = true);

    try {
      if (verificationId == null && autoCredential == null) {
        showError('Verification not started. Please request OTP again.');
        return;
      }

      final credential =
          autoCredential ??
          PhoneAuthProvider.credential(
            verificationId: verificationId!,
            smsCode: enteredOtp,
          );

      if (autoCredential == null && enteredOtp.length != otpLength) {
        showError('Please enter the full OTP.');
        return;
      }

      // 1️⃣ Sign in the user
      final userCred = await FirebaseAuth.instance.signInWithCredential(
        credential,
      );
      final user = userCred.user;

      if (user == null) {
        showError('Sign-in failed. Try again.');
        return;
      }

      // 2️⃣ Only now process driver images / hash
      String? licenseHash, birthCertHash;
      if (role == 'driver') {
        if (!validateDriverFields()) return;
        licenseHash = _hashFile(licenseImage!);
        birthCertHash = _hashFile(birthCertificateImage!);
      }

      // 3️⃣ Prepare Firestore document
      final doc = <String, dynamic>{
        'uid': user.uid,
        'phone': phoneController.text.replaceAll(RegExp(r'\D'), ''),
        'username': usernameController.text.trim(),
        'role': role,
        'createdAt': FieldValue.serverTimestamp(),
        'verified': role == 'rider',
      };

      if (role == 'driver') {
        doc.addAll({
          'carType': selectedCarType,
          'carModel': carModelController.text.trim(),
          'altContact': formatPhoneNumber(
            altContactController.text,
          ).replaceFirst('+92', '0'),
          'licenseImage': licenseHash,
          'birthCertificateImage': birthCertHash,
          'documentsUploaded': true,
          'uploadTimestamp': FieldValue.serverTimestamp(),
        });
      }

      // 4️⃣ Write to Firestore
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set(doc);

      showInfo('Registration completed successfully!');
      // ignore: use_build_context_synchronously
      Navigator.pushReplacementNamed(context, '/login');
    } catch (e) {
      showError('OTP verification / signup failed: $e');
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  String _hashFile(File file) {
    final bytes = file.readAsBytesSync();
    return sha256.convert(bytes).toString().substring(0, 12);
  }

  Future<File> _compressToJpeg(File input, {int quality = 60}) async {
    try {
      if (!await input.exists()) {
        throw Exception('Input file does not exist');
      }

      final bytes = await input.readAsBytes();
      if (bytes.isEmpty) {
        throw Exception('Input file is empty');
      }

      final dir = await getTemporaryDirectory();
      final outPath = p.join(
        dir.path,
        "fd_${DateTime.now().millisecondsSinceEpoch}.jpg",
      );

      // Compress with smaller dimensions and lower quality for Base64 storage
      final XFile? result = await FlutterImageCompress.compressAndGetFile(
        input.path,
        outPath,
        quality: quality, // Lower quality for smaller Base64
        format: CompressFormat.jpeg,
        keepExif: false,
        minWidth: 600, // Smaller dimensions
        minHeight: 400,
        rotate: 0,
      );

      if (result == null) {
        throw Exception('Compression failed');
      }

      final compressedFile = File(result.path);

      if (!await compressedFile.exists()) {
        throw Exception('Compressed file was not created');
      }

      final compressedBytes = await compressedFile.readAsBytes();
      if (compressedBytes.isEmpty) {
        throw Exception('Compressed file is empty');
      }

      // Check if compressed file is still too large for Base64
      final base64Size = (compressedBytes.length * 4 / 3)
          .round(); // Estimate Base64 size
      if (base64Size > 800000) {
        // Try with even lower quality
        final XFile? smallerResult =
            await FlutterImageCompress.compressAndGetFile(
              input.path,
              "${outPath}_smaller.jpg",
              quality: 40, // Much lower quality
              format: CompressFormat.jpeg,
              keepExif: false,
              minWidth: 400,
              minHeight: 300,
            );

        if (smallerResult != null) {
          return File(smallerResult.path);
        }
      }

      debugPrint(
        'Image compressed: ${bytes.length} -> ${compressedBytes.length} bytes',
      );
      debugPrint('Estimated Base64 size: $base64Size bytes');

      return compressedFile;
    } catch (e) {
      debugPrint('Image compression error: $e');
      return input;
    }
  }

  // ======== Camera capture (full-screen, preview, retake, use) ========
  Future<void> _captureDocument(bool isLicense) async {
    final file = await Navigator.push<File?>(
      context,
      MaterialPageRoute(builder: (_) => const FullScreenCamera()),
    );

    if (file == null) return;

    setState(() => isSubmitting = true);
    try {
      // Compress to JPG for consistent uploads & smaller size
      final compressed = await _compressToJpeg(file, quality: 75);

      setState(() {
        if (isLicense) {
          licenseImage = compressed;
        } else {
          birthCertificateImage = compressed;
        }
      });
    } catch (e) {
      showError('Failed to process image: $e');
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  // ======== UI ========
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
                    textInputAction: TextInputAction.next,
                    decoration: fieldDecoration.copyWith(
                      labelText: 'Username',
                      hintText: 'e.g. Ayesha Khan',
                    ),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 15),
                  TextFormField(
                    controller: phoneController,
                    textInputAction: TextInputAction.next,
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
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (canResend)
                          TextButton(
                            onPressed: isSubmitting ? null : sendOtp,
                            child: const Text('Resend OTP'),
                          )
                        else
                          Text('Resend in $resendSeconds seconds'),
                        TextButton(
                          onPressed: () async {
                            // Allow editing phone number before verifying
                            setState(() {
                              isOtpSent = false;
                              enteredOtp = '';
                              verificationId = null;
                              _resendTimer?.cancel();
                              canResend = false;
                              resendSeconds = 60;
                            });
                          },
                          child: const Text('Edit number'),
                        ),
                      ],
                    ),
                  ],

                  const SizedBox(height: 15),
                  DropdownButtonFormField<String>(
                    initialValue: role,
                    items: const [
                      DropdownMenuItem(value: 'rider', child: Text('RIDER')),
                      DropdownMenuItem(value: 'driver', child: Text('DRIVER')),
                    ],
                    decoration: fieldDecoration.copyWith(
                      labelText: 'Register as',
                    ),
                    onChanged: isSubmitting
                        ? null
                        : (v) => setState(() {
                            role = v ?? 'rider';
                          }),
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
                      onChanged: isSubmitting
                          ? null
                          : (v) => setState(
                              () => selectedCarType = v ?? selectedCarType,
                            ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: carModelController,
                      textInputAction: TextInputAction.next,
                      decoration: fieldDecoration.copyWith(
                        labelText: 'Car Model',
                        hintText: 'e.g. Toyota Corolla 2020',
                      ),
                      validator: (v) =>
                          role == 'driver' && (v == null || v.trim().isEmpty)
                          ? 'Required'
                          : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: altContactController,
                      decoration: fieldDecoration.copyWith(
                        labelText: 'Alternate Contact Number',
                        hintText: 'e.g. 0311-1234567',
                      ),
                      keyboardType: TextInputType.phone,
                      validator: (v) {
                        if (role != 'driver') return null;
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

                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: isSubmitting
                        ? null
                        : isOtpSent
                        ? confirmOtp
                        : sendOtp,
                    child: isSubmitting
                        ? Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    Colors.white,
                                  ),
                                ),
                              ),
                              SizedBox(width: 12),
                              Text(isOtpSent ? 'Verifying...' : 'Sending...'),
                            ],
                          )
                        : Text(isOtpSent ? 'Verify & Register' : 'Send OTP'),
                  ),

                  const SizedBox(height: 16),
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
                    onPressed: isSubmitting
                        ? null
                        : () => _captureDocument(isLicense),
                    child: const Text("Retake"),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isLicense
                        ? "License selected"
                        : "Birth certificate selected",
                    style: const TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            ],
          )
        else
          ElevatedButton.icon(
            onPressed: isSubmitting ? null : () => _captureDocument(isLicense),
            icon: const Icon(Icons.camera_alt),
            label: Text(
              isLicense ? "Capture License" : "Capture Birth Certificate",
            ),
          ),
      ],
    );
  }
}

// =================== Full-screen Camera ===================
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
        ResolutionPreset.high,
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
                          backgroundColor: Colors.white,
                          foregroundColor: Colors.black,
                        ),
                        onPressed: () => setState(() => _capturedFile = null),
                        child: const Text("Retake"),
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () =>
                            Navigator.pop(context, File(_capturedFile!.path)),
                        child: const Text("Use Photo"),
                      ),
                    ],
                  ),
                ),
              ],
            ),
      floatingActionButton: _capturedFile == null
          ? FloatingActionButton(
              backgroundColor: Colors.white,
              onPressed: _takePicture,
              child: const Icon(Icons.camera_alt, color: Colors.black),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}
