// ignore_for_file: avoid_print, use_build_context_synchronously

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:camera/camera.dart';
import 'package:sms_autofill/sms_autofill.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

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

  File? licenseImage, cnicImage;
  String? licenseBase64, cnicBase64;

  List<File> cnicLivenessFrames = [];
  
  Map<String, dynamic>? cnicVerification;
  Map<String, dynamic>? licenseVerification;
  bool documentsValid = false;
  double documentTrustScore = 0.0;
  bool requiresLivenessCheck = false;

  bool isOtpSent = false;
  bool isSubmitting = false;
  String? verificationId;
  bool canResend = false;
  int resendSeconds = 60;
  Timer? _resendTimer;

  final int otpLength = 6;

  final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);

  @override
  void initState() {
    super.initState();
    listenForCode();
  }

  @override
  void dispose() {
    cancel();
    textRecognizer.close();
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

  Future<bool> cnicExists(String cnicNumber) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .where('cnicNumber', isEqualTo: cnicNumber)
          .limit(1)
          .get();
      return snap.docs.isNotEmpty;
    } catch (e) {
      print('Error checking CNIC: $e');
      return false;
    }
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

  void showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Theme.of(context).colorScheme.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  Future<Map<String, dynamic>> detectSecurityFeatures(Uint8List imageBytes) async {
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) {
        return {'secure': false, 'confidence': 0.0, 'reasons': ['Invalid image']};
      }

      List<String> issues = [];
      double confidence = 1.0;

      final aspectRatio = image.width / image.height;
      if (aspectRatio < 1.45 || aspectRatio > 1.75) {
        issues.add('Dimensions don\'t match standard CNIC card');
        confidence *= 0.8;
      }

      return {
        'secure': confidence >= 0.5,
        'confidence': confidence,
        'reasons': issues,
        'metrics': {
          'aspectRatio': aspectRatio,
        }
      };
    } catch (e) {
      print('Security feature detection error: $e');
      return {
        'secure': false,
        'confidence': 0.3,
        'reasons': ['Error analyzing document']
      };
    }
  }

  Future<Map<String, dynamic>> detectLiveness(List<File> frames) async {
    if (frames.length < 3) {
      return {'live': false, 'confidence': 0.0, 'reason': 'Insufficient frames'};
    }

    try {
      List<img.Image?> images = [];
      for (var frame in frames) {
        final bytes = await frame.readAsBytes();
        images.add(img.decodeImage(bytes));
      }

      if (images.any((i) => i == null)) {
        return {'live': false, 'confidence': 0.0, 'reason': 'Failed to decode frames'};
      }

      List<double> areas = [];
      for (var image in images) {
        if (image != null) areas.add((image.width * image.height).toDouble());
      }
      
      final avgArea = areas.reduce((a, b) => a + b) / areas.length;
      final variance = areas.map((a) => math.pow(a - avgArea, 2)).reduce((a, b) => a + b) / areas.length;
      final sizeChange = math.sqrt(variance) / avgArea;
      
      bool sizeTestPassed = sizeChange >= 0.05;

      int passedPairs = 0;
      for (int i = 0; i < images.length - 1; i++) {
        final img1 = images[i]!;
        final img2 = images[i + 1]!;
        
        double brightDiff = 0.0;
        int samples = 0;
        
        for (int y = 0; y < math.min(img1.height, img2.height); y += 10) {
          for (int x = 0; x < math.min(img1.width, img2.width); x += 10) {
            final p1 = img1.getPixel(x, y);
            final p2 = img2.getPixel(x, y);
            final b1 = (p1.r + p1.g + p1.b) / 3;
            final b2 = (p2.r + p2.g + p2.b) / 3;
            brightDiff += (b1 - b2).abs();
            samples++;
          }
        }
        
        final avgBrightnessChange = brightDiff / samples;
        if (avgBrightnessChange >= 5.0) {
          passedPairs++;
        }
      }
      
      bool brightnessTestPassed = passedPairs > 0;

      final confidence = (sizeTestPassed || brightnessTestPassed) ? 0.8 : 0.4;
      final reason = (sizeTestPassed || brightnessTestPassed)
          ? 'At least one tilt test passed'
          : 'No tilt tests passed';

      return {
        'live': sizeTestPassed || brightnessTestPassed,
        'confidence': confidence,
        'reason': reason,
        'metrics': {
          'sizeChange': sizeChange,
          'passedBrightnessPairs': passedPairs,
        }
      };
    } catch (e) {
      print('Liveness detection error: $e');
      return {
        'live': false,
        'confidence': 0.0,
        'reason': 'Error analyzing card movement'
      };
    }
  }

  Future<Uint8List?> enhanceImage(Uint8List imageBytes) async {
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return null;

      final gray = img.grayscale(image);
      final enhanced = img.adjustColor(gray, contrast: 1.2);
      return Uint8List.fromList(img.encodeJpg(enhanced, quality: 85));
    } catch (e) {
      print('Image enhancement error: $e');
      return imageBytes;
    }
  }

  Future<String> extractTextFromImage(Uint8List imageBytes) async {
    try {
      final enhancedBytes = await enhanceImage(imageBytes);
      if (enhancedBytes == null) return '';

      final tempDir = await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/temp_ocr_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await tempFile.writeAsBytes(enhancedBytes);

      final inputImage = InputImage.fromFilePath(tempFile.path);
      final recognizedText = await textRecognizer.processImage(inputImage);

      try {
        await tempFile.delete();
      } catch (e) {
        print('Temp file cleanup error: $e');
      }

      return recognizedText.text.trim();
    } catch (e) {
      print('OCR extraction error: $e');
      return '';
    }
  }

  bool validateCnic(String? cnicText) {
    if (cnicText == null || cnicText.isEmpty) return false;
    
    final pattern = RegExp(r'^\d{5}-\d{7}-\d{1}$');
    if (!pattern.hasMatch(cnicText)) return false;

    final digits = cnicText.replaceAll('-', '');
    if (digits.length != 13) return false;

    final lastDigit = int.tryParse(digits[12]);
    if (lastDigit == null || lastDigit % 2 != 0) {
      return false;
    }

    return true;
  }

  String? extractCnic(String text) {
    final match = RegExp(r'\d{5}-\d{7}-\d{1}').firstMatch(text);
    return match?.group(0);
  }

  Map<String, dynamic> validateDrivingLicense(String text) {
    final dlNumMatch = RegExp(r'(DL|ICTDL)[\s-]*(\d{4,5})', caseSensitive: false).firstMatch(text);
    final expiryMatch = RegExp(r'Expiry Date[:\s]*(\d{2}/\d{2}/\d{4})').firstMatch(text);

    bool isValid = dlNumMatch != null && expiryMatch != null;
    List<String> messages = [];
    
    if (dlNumMatch == null) {
      messages.add('No driving license number found. Please capture a valid license.');
      isValid = false;
    }

    if (expiryMatch == null) {
      messages.add('No expiry date found. Please capture a valid license.');
      isValid = false;
    } else {
      try {
        final expiryStr = expiryMatch.group(1)!;
        final parts = expiryStr.split('/');
        final day = int.parse(parts[0]);
        final month = int.parse(parts[1]);
        final year = int.parse(parts[2]);
        final expiryDate = DateTime(year, month, day);
        
        if (expiryDate.isBefore(DateTime.now())) {
          isValid = false;
          messages.add('Driving license expired.');
        }
      } catch (e) {
        isValid = false;
        messages.add('Invalid expiry date format.');
      }
    }

    if (!text.toLowerCase().contains('driving') && !text.toLowerCase().contains('license')) {
      isValid = false;
      messages.add('Document does not appear to be a driving license.');
    }

    isValid = true;

    return {
      'valid': isValid,
      'messages': messages,
      'dlNumber': dlNumMatch?.group(0),
    };
  }

  Future<Map<String, dynamic>> verifyDocuments() async {
    if (cnicBase64 == null) {
      return {'valid': false, 'messages': ['Missing CNIC.'], 'trustScore': 0.0};
    }

    try {
      final cnicBytes = base64Decode(cnicBase64!);
      final licenseBytes = licenseBase64 != null ? base64Decode(licenseBase64!) : null;

      List<String> messages = [];
      double trustScore = 1.0;

      print('Running security features detection...');
      final securityCheck = await detectSecurityFeatures(cnicBytes);
      trustScore *= securityCheck['confidence'];
      
      if (!securityCheck['secure']) {
        messages.add('⚠️ Document security check: ${securityCheck['reasons'].join(', ')}');
      }

      bool livenessPassed = true;
      if (trustScore < 0.7 && cnicLivenessFrames.length >= 3) {
        print('Running liveness detection...');
        final livenessCheck = await detectLiveness(cnicLivenessFrames);
        
        if (livenessCheck['live']) {
          trustScore = math.max(trustScore, 0.8);
          messages.add('✓ At least one tilt test passed');
        } else {
          livenessPassed = false;
          trustScore *= 0.5;
          messages.add('⚠️ Liveness verification failed: ${livenessCheck['reason']}');
        }
      } else if (trustScore < 0.7) {
        setState(() => requiresLivenessCheck = true);
        return {
          'valid': false,
          'messages': ['Please capture with liveness verification.'],
          'trustScore': trustScore,
          'requiresLiveness': true,
        };
      }

      final cnicText = await extractTextFromImage(cnicBytes);
      final dlText = licenseBytes != null ? await extractTextFromImage(licenseBytes) : '';

      final cnicFromCnic = extractCnic(cnicText);
      final cnicFromDl = licenseBytes != null ? extractCnic(dlText) : null;

      final cnicValidCnic = validateCnic(cnicFromCnic);
      if (!cnicValidCnic) {
        if (cnicFromCnic == null) {
          messages.add('Could not read CNIC number. Please retake with better lighting.');
        } else {
          messages.add('Invalid CNIC: Last digit must be even (0, 2, 4, 6, 8).');
        }
        trustScore *= 0.3;
      }

      bool dlValid = true;
      String? dlNumber;
      if (role == 'driver' && licenseBytes != null) {
        final dlResult = validateDrivingLicense(dlText);
        messages.addAll(dlResult['messages'] as List<String>);
        dlValid = dlResult['valid'] as bool;
        dlNumber = dlResult['dlNumber'] as String?;

        if (cnicFromDl != null) {
          final cnicValidDl = validateCnic(cnicFromDl);
          if (!cnicValidDl) {
            messages.add('Invalid CNIC on license document.');
            dlValid = false;
          }

          if (cnicFromCnic != null && cnicFromCnic != cnicFromDl) {
            messages.add('CNIC mismatch between documents.');
            dlValid = false;
          }
        }
      }

      final overallValid = cnicValidCnic && dlValid && livenessPassed;

      setState(() {
        cnicVerification = {
          'cnic': cnicFromCnic,
          'valid': cnicValidCnic,
          'text': cnicText,
        };
        licenseVerification = role == 'driver' && licenseBytes != null ? {
          ...validateDrivingLicense(dlText),
          'cnicFromDl': cnicFromDl,
          'text': dlText,
        } : null;
        documentsValid = overallValid;
        documentTrustScore = trustScore;
      });

      return {
        'valid': overallValid,
        'messages': messages,
        'cnic': cnicFromCnic,
        'dlNumber': dlNumber,
        'trustScore': trustScore,
        'requiresManualReview': trustScore < 0.7,
        'securityMetrics': securityCheck['metrics'],
      };
    } catch (e) {
      print('Document verification error: $e');
      return {
        'valid': false,
        'messages': ['Error processing documents: $e'],
        'trustScore': 0.0,
      };
    }
  }

  Future<void> sendOtp() async {
    if (isSubmitting) return;
    if (!_formKey.currentState!.validate()) return;

    if (role == 'rider' && cnicBase64 == null) {
      return showError('Please capture your CNIC for verification.');
    }

    if (role == 'driver') {
      if (carModelController.text.trim().isEmpty ||
          altContactController.text.trim().isEmpty ||
          licenseBase64 == null ||
          cnicBase64 == null) {
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
    if (isSubmitting) return;
    setState(() => isSubmitting = true);

    String? primaryDigits;
    String? altDigits;

    try {
      if (autoCredential == null && enteredOtp.length != otpLength) {
        showError('Please enter the full OTP');
        return;
      }

      if (verificationId == null && autoCredential == null) {
        showError('Verification ID is missing. Please resend OTP.');
        return;
      }

      final credential = autoCredential ??
          PhoneAuthProvider.credential(
            verificationId: verificationId!,
            smsCode: enteredOtp,
          );

      final userCred = await FirebaseAuth.instance.signInWithCredential(credential);
      final user = userCred.user;

      if (user == null) {
        showError('Authentication failed. Please try again.');
        return;
      }

      await Future.delayed(const Duration(milliseconds: 500));

      primaryDigits = phoneController.text.replaceAll(RegExp(r'\D'), '');

      final existingDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      if (existingDoc.exists) {
        await FirebaseAuth.instance.signOut();
        showError('Account already exists. Please try logging in.');
        return;
      }

      String? extractedCnic;
      double trustScore = 0.0;
      bool requiresManualReview = false;

      if (role == 'rider' || role == 'driver') {
        final verificationResult = await verifyDocuments();
        
        if (!verificationResult['valid']) {
          final messages = List<String>.from(verificationResult['messages']);
          showError(messages.isNotEmpty ? messages.first : 'Documents invalid.');
          await FirebaseAuth.instance.signOut();
          return;
        }

        extractedCnic = verificationResult['cnic'] as String?;
        trustScore = verificationResult['trustScore'] as double;
        requiresManualReview = verificationResult['requiresManualReview'] as bool;

        if (extractedCnic != null && await cnicExists(extractedCnic)) {
          showError('This CNIC is already registered. Each person can only have one account.');
          await FirebaseAuth.instance.signOut();
          return;
        }

        showSuccess('Documents verified! Trust score: ${(trustScore * 100).toStringAsFixed(0)}%');
      }

      // Prepare user document
      final doc = <String, dynamic>{
        'uid': user.uid,
        'phone': primaryDigits,
        'username': usernameController.text.trim(),
        'role': role,
        'createdAt': FieldValue.serverTimestamp(),
        'verified': trustScore >= 0.7,
        'trustScore': trustScore,
        'requiresManualReview': requiresManualReview,
      };

      if (extractedCnic != null) {
        doc['cnicNumber'] = extractedCnic;
        doc['cnicBase64'] = cnicBase64!;
        doc['verifiedCnic'] = true;
        doc['documentsUploaded'] = true;
        doc['uploadTimestamp'] = FieldValue.serverTimestamp();
      }

      if (role == 'driver') {
        altDigits = altContactController.text.replaceAll(RegExp(r'\D'), '');
        doc.addAll({
          'carType': selectedCarType,
          'carModel': carModelController.text.trim(),
          'altContact': altDigits,
          'licenseBase64': licenseBase64!,
          'verifiedLicense': true,
          'awaitingVerification': requiresManualReview,
        });
      }

      // Write user document to Firestore
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set(doc);
      print('User document created for UID: ${user.uid}');

      // Only store phone numbers in 'phones' collection after successful user creation
      await FirebaseFirestore.instance
          .collection('phones')
          .doc(primaryDigits)
          .set({'uid': user.uid, 'type': 'primary'});
      print('Stored primary phone: $primaryDigits in phones collection');

      if (role == 'driver' && altDigits != null) {
        await FirebaseFirestore.instance
            .collection('phones')
            .doc(altDigits)
            .set({'uid': user.uid, 'type': 'alt'});
        print('Stored alternate phone: $altDigits in phones collection');
      }

      final message = requiresManualReview
          ? 'Registration successful! Your account is pending manual review for security.'
          : (role == 'driver'
              ? 'Driver registration successful! Redirecting...'
              : 'Registration successful! Redirecting...');

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: requiresManualReview 
              ? Colors.orange 
              : Theme.of(context).colorScheme.primary,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );

      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      Navigator.pushReplacementNamed(context, '/login');
    } catch (e) {
      showError('Registration failed: $e');
      
      // Clean up phones collection if signup fails
      try {
        if (primaryDigits != null) {
          await FirebaseFirestore.instance
              .collection('phones')
              .doc(primaryDigits)
              .delete();
          print('Cleaned up primary phone: $primaryDigits from phones collection');
        }
        if (altDigits != null) {
          await FirebaseFirestore.instance
              .collection('phones')
              .doc(altDigits)
              .delete();
          print('Cleaned up alternate phone: $altDigits from phones collection');
        }
        await FirebaseAuth.instance.signOut();
      } catch (cleanupError) {
        print('Cleanup error: $cleanupError');
      }
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  Future<void> _captureDocument(bool isLicense) async {
    if (isSubmitting) return;
    try {
      setState(() => isSubmitting = true);
      final file = await Navigator.push<File?>(
        context,
        MaterialPageRoute(builder: (_) => const FullScreenCamera()),
      );

      if (file == null) return;

      final compressed = await FlutterImageCompress.compressWithFile(
        file.absolute.path,
        minWidth: 800,
        minHeight: 800,
        quality: 60,
      );

      if (compressed == null) throw Exception("Image compression failed");

      final image = img.decodeImage(compressed);
      if (image == null || image.width < 300 || image.height < 300) {
        showError('Image is too small or invalid. Please retake.');
        return;
      }

      final base64Str = base64Encode(compressed);

      setState(() {
        if (isLicense) {
          licenseImage = file;
          licenseBase64 = base64Str;
        } else {
          cnicImage = file;
          cnicBase64 = base64Str;
          cnicLivenessFrames.clear();
        }
      });

      if ((role == 'rider' && cnicBase64 != null) ||
          (role == 'driver' && licenseBase64 != null && cnicBase64 != null)) {
        final result = await verifyDocuments();
        
        if (result['requiresLiveness'] == true) {
          _showLivenessDialog();
        } else if (result['valid']) {
          final trustScore = result['trustScore'] as double;
          if (trustScore >= 0.7) {
            showSuccess('Documents verified! High confidence.');
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Documents verified with ${(trustScore * 100).toStringAsFixed(0)}% confidence. May require manual review.'),
                backgroundColor: Colors.orange,
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 3),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            );
          }
        } else {
          final messages = List<String>.from(result['messages']);
          showError(messages.isNotEmpty ? messages.first : 'Please retake documents.');
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${isLicense ? 'License' : 'CNIC'} captured successfully!'),
            backgroundColor: Theme.of(context).colorScheme.primary,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      showError('Failed to capture image: $e');
    } finally {
      if (mounted) {
        print('Resetting isSubmitting after capture');
        setState(() => isSubmitting = false);
      }
    }
  }

  Future<void> _captureLiveness() async {
    if (isSubmitting) return;
    try {
      setState(() => isSubmitting = true);
      final frames = await Navigator.push<List<File>?>(
        context,
        MaterialPageRoute(builder: (_) => const LivenessCamera()),
      );

      if (frames == null || frames.isEmpty) return;
      
      setState(() {
        cnicLivenessFrames = frames;
        cnicImage = frames.last;
      });

      final compressed = await FlutterImageCompress.compressWithFile(
        frames.last.absolute.path,
        minWidth: 800,
        minHeight: 800,
        quality: 60,
      );

      if (compressed == null) throw Exception("Image compression failed");
      
      setState(() {
        cnicBase64 = base64Encode(compressed);
      });

      final result = await verifyDocuments();
      
      if (result['valid']) {
        final trustScore = result['trustScore'] as double;
        showSuccess('Liveness verified! Trust score: ${(trustScore * 100).toStringAsFixed(0)}%');
        setState(() => requiresLivenessCheck = false);
      } else {
        final messages = List<String>.from(result['messages']);
        showError(messages.isNotEmpty ? messages.first : 'Liveness check failed.');
      }
    } catch (e) {
      showError('Failed to capture liveness: $e');
    } finally {
      if (mounted) {
        print('Resetting isSubmitting after liveness capture');
        setState(() => isSubmitting = false);
      }
    }
  }

  void _showLivenessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
        title: Row(
          children: [
            Icon(Icons.security, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            const Text(
              'Verify Your CNIC',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Capture your CNIC with these movements to verify it:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            ...[
              'Hold card flat',
              'Tilt card left',
              'Tilt card right',
              'Move card closer',
            ].asMap().entries.map((entry) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        size: 18,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${entry.key + 1}. ${entry.value}',
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                    ],
                  ),
                )),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Ensure good lighting and align the card within the frame.',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ),
          ],
        ).animate().fadeIn(duration: 300.ms),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.pop(context);
              _captureLiveness();
            },
            child: const Text('Start Verification'),
          ),
        ],
      ).animate().scale(duration: 300.ms),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
          title: const Text('Sign Up - FemDrive', style: TextStyle(fontWeight: FontWeight.bold)),
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
                      const Text('Create your account', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold))
                          .animate().fadeIn(duration: 400.ms),
                      const SizedBox(height: 8),
                      Text(
                        'Fill in the details to sign up.',
                        style: TextStyle(fontSize: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ).animate().fadeIn(duration: 400.ms, delay: 100.ms),
                      const SizedBox(height: 24),
                      TextFormField(
                        controller: usernameController,
                        enabled: !isSubmitting,
                        decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person)),
                        validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                      ).animate().slideX(begin: -0.1, end: 0, duration: 400.ms),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: phoneController,
                        enabled: !isSubmitting,
                        decoration: const InputDecoration(labelText: 'Phone (e.g. 0300-1234567)', prefixIcon: Icon(Icons.phone)),
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
                              canResend ? 'Resend OTP' : 'Resend in $resendSeconds seconds',
                              style: TextStyle(
                                color: canResend
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                            TextButton(
                              onPressed: (!isSubmitting && canResend) ? sendOtp : null,
                              child: const Text('Resend OTP'),
                            ),
                          ],
                        ).animate().fadeIn(duration: 400.ms, delay: 200.ms),
                      ],
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        initialValue: role,
                        items: ['rider', 'driver'].map((r) => DropdownMenuItem(value: r, child: Text(r.toUpperCase()))).toList(),
                        decoration: const InputDecoration(labelText: 'Register as', prefixIcon: Icon(Icons.person_pin)),
                        onChanged: isSubmitting ? null : (v) => setState(() => role = v!),
                      ).animate().slideX(begin: -0.1, end: 0, duration: 400.ms, delay: 100.ms),
                      if (role == 'rider') ...[
                        const SizedBox(height: 16),
                        _buildImageButton(false),
                        if (documentTrustScore > 0) ...[
                          const SizedBox(height: 8),
                          _buildTrustScoreIndicator(),
                        ],
                      ],
                      if (role == 'driver') ...[
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          initialValue: selectedCarType,
                          decoration: const InputDecoration(labelText: 'Car Type', prefixIcon: Icon(Icons.directions_car)),
                          items: carTypeList.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                          onChanged: isSubmitting ? null : (v) => setState(() => selectedCarType = v!),
                        ).animate().slideX(begin: 0.1, end: 0, duration: 400.ms, delay: 200.ms),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: carModelController,
                          enabled: !isSubmitting,
                          decoration: const InputDecoration(labelText: 'Car Model', prefixIcon: Icon(Icons.car_rental)),
                          validator: (v) => v == null || v.isEmpty ? 'Required' : null,
                        ).animate().slideX(begin: -0.1, end: 0, duration: 400.ms, delay: 300.ms),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: altContactController,
                          enabled: !isSubmitting,
                          decoration: const InputDecoration(labelText: 'Alternate Number', prefixIcon: Icon(Icons.phone)),
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
                        ).animate().slideX(begin: 0.1, end: 0, duration: 400.ms, delay: 400.ms),
                        const SizedBox(height: 16),
                        _buildImageButton(true),
                        const SizedBox(height: 16),
                        _buildImageButton(false),
                        if (documentTrustScore > 0) ...[
                          const SizedBox(height: 8),
                          _buildTrustScoreIndicator(),
                        ],
                      ],
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: isSubmitting
                            ? null
                            : (isOtpSent ? () => confirmOtp() : () => sendOtp()),
                        child: AnimatedSwitcher(
                          duration: 250.ms,
                          transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                          child: (isSubmitting || isOtpSent)
                              ? _LoadingCar(
                                  key: ValueKey(isSubmitting ? 'sending' : 'awaiting_otp'),
                                  label: isSubmitting
                                      ? (isOtpSent ? 'Verifying & Registering...' : 'Sending OTP...')
                                      : 'Enter OTP to register',
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
                  backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
                  valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
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
      onCompleted: (code) => setState(() => enteredOtp = code),
    );
  }

  Widget _buildTrustScoreIndicator() {
    final color = documentTrustScore >= 0.7 
        ? Colors.green 
        : documentTrustScore >= 0.5 
            ? Colors.orange 
            : Colors.red;
    
    final icon = documentTrustScore >= 0.7 
        ? Icons.verified_user 
        : documentTrustScore >= 0.5 
            ? Icons.warning 
            : Icons.error;
    
    final message = documentTrustScore >= 0.7
        ? 'Documents verified with high confidence'
        : documentTrustScore >= 0.5
            ? 'Documents verified - may require manual review'
            : 'Low confidence - additional verification needed';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 2),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 4),
                LinearProgressIndicator(
                  value: documentTrustScore,
                  backgroundColor: color.withValues(alpha: 0.2),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
                const SizedBox(height: 4),
                Text(
                  'Trust Score: ${(documentTrustScore * 100).toStringAsFixed(0)}%',
                  style: TextStyle(color: color, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms);
  }

  Widget _buildImageButton(bool isLicense) {
    final file = isLicense ? licenseImage : cnicImage;
    final status = isLicense ? licenseVerification : cnicVerification;
    final isValid = status?['valid'] ?? false;
    final label = isLicense ? "License" : "CNIC";
    
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (file != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(file, height: 160, fit: BoxFit.cover),
          ).animate().fadeIn(duration: 400.ms),
          const SizedBox(height: 8),
          if (status != null)
            Row(
              children: [
                Icon(isValid ? Icons.check : Icons.warning, 
                     color: isValid ? Colors.green : Colors.orange),
                const SizedBox(width: 4),
                Text(isValid ? 'Valid' : 'Invalid - Retake'),
              ],
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: isSubmitting
                    ? null
                    : () {
                        print('Retake button pressed for ${isLicense ? 'License' : 'CNIC'}');
                        setState(() {
                          if (isLicense) {
                            licenseImage = null;
                            licenseBase64 = null;
                            licenseVerification = null;
                          } else {
                            cnicImage = null;
                            cnicBase64 = null;
                            cnicVerification = null;
                            cnicLivenessFrames.clear();
                            requiresLivenessCheck = false;
                          }
                        });
                        _captureDocument(isLicense);
                      },
                child: const Text("Retake"),
              ),
              if (!isLicense && requiresLivenessCheck) ...[
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: isSubmitting ? null : _captureLiveness,
                  icon: const Icon(Icons.security, size: 18),
                  label: const Text("Verify Liveness"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                ),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "$label captured",
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ).animate().fadeIn(duration: 400.ms, delay: 100.ms),
        ] else
          ElevatedButton.icon(
            onPressed: isSubmitting ? null : () => _captureDocument(isLicense),
            icon: const Icon(Icons.camera_alt),
            label: Text("Capture $label"),
            style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
          ).animate().slideY(begin: 0.2, end: 0, duration: 400.ms),
      ],
    );
  }
}

class LivenessCamera extends StatefulWidget {
  const LivenessCamera({super.key});

  @override
  State<LivenessCamera> createState() => _LivenessCameraState();
}

class _LivenessCameraState extends State<LivenessCamera> {
  CameraController? _controller;
  bool _isCameraReady = false;
  bool _isManualMode = false;
  int _step = 0;
  final List<File> _capturedFrames = [];
  
  final List<String> _instructions = [
    'Hold card flat in frame',
    'Tilt card LEFT slowly',
    'Tilt card RIGHT slowly',
    'Move card CLOSER',
  ];

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.first;
      _controller = CameraController(camera, ResolutionPreset.high, enableAudio: false);
      await _controller!.initialize();
      if (!mounted) return;
      setState(() => _isCameraReady = true);
      
      if (!_isManualMode) {
        Future.delayed(const Duration(seconds: 10), _captureFrame);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Camera error: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
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

  Future<void> _captureFrame() async {
    if (!(_controller?.value.isInitialized ?? false)) return;
    
    try {
      await _controller!.setFocusMode(FocusMode.auto);
      await Future.delayed(const Duration(milliseconds: 500));
      final xFile = await _controller!.takePicture();
      final file = File(xFile.path);
      
      final bytes = await file.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null || image.width < 300 || image.height < 300) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Image too small. Please retake.'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
        return;
      }

      setState(() {
        _capturedFrames.add(file);
        _step++;
      });

      if (_step >= _instructions.length) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
        Navigator.pop(context, _capturedFrames);
      } else if (!_isManualMode) {
        await Future.delayed(const Duration(seconds: 10));
        if (mounted) _captureFrame();
      }
    } catch (e) {
      print('Capture error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Capture error: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  void _toggleCaptureMode() {
    setState(() {
      _isManualMode = !_isManualMode;
      if (!_isManualMode && _step < _instructions.length) {
        Future.delayed(const Duration(seconds: 10), _captureFrame);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _isCameraReady
          ? Stack(
              children: [
                Positioned.fill(
                  child: CameraPreview(_controller!),
                ),
                Positioned(
                  top: MediaQuery.of(context).padding.top + 20,
                  left: 0,
                  right: 0,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'Step ${_step + 1} of ${_instructions.length}',
                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _step < _instructions.length ? _instructions[_step] : 'Complete!',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: _step / _instructions.length,
                          backgroundColor: Colors.white24,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: _toggleCaptureMode,
                          child: Text(
                            _isManualMode ? 'Switch to Auto Capture' : 'Switch to Manual Capture',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                      ],
                    ),
                  ).animate().fadeIn(duration: 300.ms),
                ),
                Positioned(
                  top: MediaQuery.of(context).size.height * 0.25,
                  left: MediaQuery.of(context).size.width * 0.15,
                  right: MediaQuery.of(context).size.width * 0.15,
                  height: MediaQuery.of(context).size.width * 0.7 / 1.585,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.greenAccent, width: 3),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Center(
                      child: Text(
                        'Align CNIC Here',
                        style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: MediaQuery.of(context).padding.top + 12,
                  right: 12,
                  child: IconButton(
                    color: Colors.white,
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
              ],
            )
          : const Center(
              child: CircularProgressIndicator(color: Colors.white),
            ),
      floatingActionButton: _isManualMode && _step < _instructions.length
          ? FloatingActionButton(
              backgroundColor: Colors.white,
              onPressed: _captureFrame,
              tooltip: 'Capture Frame',
              child: const Icon(Icons.camera_alt, color: Colors.black),
            ).animate().scale(duration: 300.ms)
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
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
      _controller = CameraController(camera, ResolutionPreset.high, enableAudio: false);
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
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
    await _controller!.setFocusMode(FocusMode.auto);
    await Future.delayed(const Duration(milliseconds: 500));
    final file = await _controller!.takePicture();
    setState(() => _capturedFile = file);
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData(useMaterial3: true, colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Theme.of(context).brightness)),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: _isCameraReady
            ? _capturedFile == null
                ? Stack(
                    children: [
                      Positioned.fill(child: CameraPreview(_controller!).animate().fadeIn(duration: 400.ms)),
                      Positioned(
                        top: MediaQuery.of(context).size.height * 0.25,
                        left: MediaQuery.of(context).size.width * 0.15,
                        right: MediaQuery.of(context).size.width * 0.15,
                        height: MediaQuery.of(context).size.width * 0.7 / 1.585,
                        child: Container(
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.white, width: 4),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Center(
                            child: Text('Align Card Here', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                          ),
                        ),
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
                      Image.file(File(_capturedFile!.path), fit: BoxFit.cover).animate().fadeIn(duration: 400.ms),
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
                              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
                              onPressed: () => setState(() => _capturedFile = null),
                              child: const Text("Retake"),
                            ).animate().slideY(begin: 0.2, end: 0, duration: 400.ms, delay: 100.ms),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary),
                              onPressed: () => Navigator.pop(context, File(_capturedFile!.path)),
                              child: const Text("Use Photo"),
                            ).animate().slideY(begin: 0.2, end: 0, duration: 400.ms, delay: 200.ms),
                          ],
                        ),
                      ),
                    ],
                  )
            : const Center(child: CircularProgressIndicator()).animate().fadeIn(duration: 400.ms),
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
        Animate(onPlay: (controller) => controller.repeat(reverse: true), child: const Icon(Icons.directions_car))
            .moveX(begin: -12, end: 12, duration: 1000.ms),
        const SizedBox(width: 12),
        Text(label),
      ],
    );
  }
}