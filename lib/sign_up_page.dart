import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:camera/camera.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image/image.dart' as img;

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _formKey = GlobalKey<FormState>();

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

  late List<CameraDescription> _cameras;

  @override
  void initState() {
    super.initState();
    _initCameras();
  }

  Future<void> _initCameras() async {
    try {
      _cameras = await availableCameras();
    } catch (e) {
      showError("Camera initialization failed: $e");
    }
  }

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

  /// New Camera + Cropper method
  Future<void> _captureAndCrop(bool isLicense) async {
    final capturedFile = await Navigator.push<File?>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            DocumentCaptureScreen(isLicense: isLicense, cameras: _cameras),
      ),
    );

    if (capturedFile == null) return;

    final cropped = await ImageCropper().cropImage(
      sourcePath: capturedFile.path,
      aspectRatio: const CropAspectRatio(ratioX: 4, ratioY: 3),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: isLicense ? 'Crop License' : 'Crop Birth Cert',
          initAspectRatio: CropAspectRatioPreset.ratio4x3,
          lockAspectRatio: false,
        ),
        IOSUiSettings(title: isLicense ? 'Crop License' : 'Crop Birth Cert'),
      ],
    );

    if (cropped == null) return;

    final bytes = await File(cropped.path).readAsBytes();
    final base64 = await compressAndEncodeBytes(bytes);

    setState(() {
      if (isLicense) {
        licenseImage = File(cropped.path);
        licenseBase64 = base64;
      } else {
        birthCertificateImage = File(cropped.path);
        birthCertBase64 = base64;
      }
    });
  }

  Future<String> compressAndEncodeBytes(List<int> bytes) async {
    final decoded = img.decodeImage(Uint8List.fromList(bytes));
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
        return showError('Please fill all driver details and capture images.');
      }
    }

    try {
      final formatted = formatPhoneNumber(phoneController.text);

      if (await phoneNumberExists(formatted.replaceAll('+92', '0'))) {
        return showError('This phone number is already registered.');
      }

      final confirmed = await _confirmNumberDialog(formatted);
      if (!confirmed) return;

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

  // ignore: unused_element
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
                initialValue: role,
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
                  initialValue: selectedCarType,
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
                _buildImageCaptureField(true),
                const SizedBox(height: 10),
                _buildImageCaptureField(false),
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

  Widget _buildImageCaptureField(bool isLicense) {
    final file = isLicense ? licenseImage : birthCertificateImage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (file != null)
          Column(
            children: [
              Image.file(file, height: 150, fit: BoxFit.cover),
              Row(
                children: [
                  TextButton(
                    onPressed: () => _captureAndCrop(isLicense),
                    child: const Text("Retake"),
                  ),
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: () => _viewImage(file),
                    child: const Text("View"),
                  ),
                ],
              ),
            ],
          )
        else
          ElevatedButton(
            onPressed: () => _captureAndCrop(isLicense),
            child: Text(
              isLicense ? "Capture License" : "Capture Birth Certificate",
            ),
          ),
      ],
    );
  }

  void _viewImage(File file) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(),
          body: Center(child: Image.file(file)),
        ),
      ),
    );
  }
}

class DocumentCaptureScreen extends StatefulWidget {
  final bool isLicense;
  final List<CameraDescription> cameras;

  const DocumentCaptureScreen({
    super.key,
    required this.isLicense,
    required this.cameras,
  });

  @override
  State<DocumentCaptureScreen> createState() => _DocumentCaptureScreenState();
}

class _DocumentCaptureScreenState extends State<DocumentCaptureScreen> {
  CameraController? _controller;
  bool _isReady = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    _controller = CameraController(
      widget.cameras.first,
      ResolutionPreset.high,
      enableAudio: false,
    );
    await _controller!.initialize();
    if (!mounted) return;
    setState(() => _isReady = true);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _captureImage() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final picture = await _controller!.takePicture();
    if (!mounted) return;
    Navigator.pop(context, File(picture.path));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: !_isReady
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                CameraPreview(_controller!),
                Positioned.fill(
                  child: CustomPaint(painter: DocumentFramePainter()),
                ),
                Positioned(
                  bottom: 40,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FloatingActionButton(
                        backgroundColor: Colors.white,
                        onPressed: _captureImage,
                        child: const Icon(
                          Icons.camera_alt,
                          color: Colors.black,
                          size: 28,
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(
                  top: 40,
                  left: 0,
                  right: 0,
                  child: Text(
                    widget.isLicense
                        ? "Align your LICENSE in the frame"
                        : "Align your BIRTH CERTIFICATE in the frame",
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ),
              ],
            ),
    );
  }
}

class DocumentFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      size.width * 0.1,
      size.height * 0.25,
      size.width * 0.8,
      size.height * 0.4,
    );

    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    canvas.drawRect(rect, borderPaint);

    final cornerPaint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 4;

    const cornerLength = 20.0;
    canvas.drawLine(
      rect.topLeft,
      rect.topLeft + const Offset(cornerLength, 0),
      cornerPaint,
    );
    canvas.drawLine(
      rect.topLeft,
      rect.topLeft + const Offset(0, cornerLength),
      cornerPaint,
    );
    canvas.drawLine(
      rect.topRight,
      rect.topRight - const Offset(cornerLength, 0),
      cornerPaint,
    );
    canvas.drawLine(
      rect.topRight,
      rect.topRight + const Offset(0, cornerLength),
      cornerPaint,
    );
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft + const Offset(cornerLength, 0),
      cornerPaint,
    );
    canvas.drawLine(
      rect.bottomLeft,
      rect.bottomLeft - const Offset(0, cornerLength),
      cornerPaint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight - const Offset(cornerLength, 0),
      cornerPaint,
    );
    canvas.drawLine(
      rect.bottomRight,
      rect.bottomRight - const Offset(0, cornerLength),
      cornerPaint,
    );
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
