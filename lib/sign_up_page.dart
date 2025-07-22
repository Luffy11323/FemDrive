import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:logger/logger.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final _formKey = GlobalKey<FormState>();
  final picker = ImagePicker();
  final logger = Logger();

  String role = 'rider';
  File? licenseImage;
  File? birthCertificateImage;
  String? licenseBase64;
  String? birthCertBase64;
  bool isSubmitting = false;
  String? suggestedUsername;

  final usernameController = TextEditingController();
  final emailController = TextEditingController();
  final phoneController = TextEditingController();
  final passwordController = TextEditingController();
  final carModelController = TextEditingController();
  final altContactController = TextEditingController();

  final carTypeList = ['Ride X', 'Ride mini', 'Bike'];
  String selectedCarType = 'Ride X';

  @override
  void dispose() {
    usernameController.dispose();
    emailController.dispose();
    phoneController.dispose();
    passwordController.dispose();
    carModelController.dispose();
    altContactController.dispose();
    super.dispose();
  }

  Future<String> compressAndEncode(File file) async {
    final originalBytes = await file.readAsBytes();
    final decoded = img.decodeImage(originalBytes);
    final resized = img.copyResize(decoded!, width: 600);
    final compressed = img.encodeJpg(resized, quality: 70);
    return base64Encode(compressed);
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

  Future<bool> checkUsernameExists(String username) async {
    final result = await FirebaseFirestore.instance
        .collection('users')
        .where('username', isEqualTo: username)
        .get();
    return result.docs.isNotEmpty;
  }

  Future<String?> getAvailableUsername(String base) async {
    String username = base;
    int counter = 1;
    while (counter < 100) {
      final query = await FirebaseFirestore.instance
          .collection('users')
          .where('username', isEqualTo: username)
          .get();
      if (query.docs.isEmpty) return username;
      username = "$base$counter";
      counter++;
    }
    return null;
  }

  Future<bool> isEmailTaken(String email) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .where('email', isEqualTo: email)
        .get();
    return snapshot.docs.isNotEmpty;
  }

  Future<void> submitForm() async {
    if (isSubmitting || !_formKey.currentState!.validate()) return;

    if (role == 'driver' &&
        (licenseBase64 == null || birthCertBase64 == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please upload required documents.')),
      );
      return;
    }
    final phone = phoneController.text.trim();

    if (await phoneNumberExists(phone) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Phone number already in use.')),
      );
      return;
    }

    setState(() => isSubmitting = true);

    try {
      final rawUsername = usernameController.text.trim();
      final cleaned = rawUsername.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      final valid = RegExp(r'^[a-z0-9._-]+$').hasMatch(cleaned);

      if (!valid) {
        final suggestion = await getAvailableUsername(cleaned);
        setState(() => suggestedUsername = suggestion);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Invalid username. Suggested: $suggestion"),
              action: SnackBarAction(
                label: 'Use it',
                onPressed: () => usernameController.text = suggestion ?? '',
              ),
            ),
          );
          return;
        }
      }

      final exists = await checkUsernameExists(cleaned);
      if (exists) {
        final suggestion = await getAvailableUsername(cleaned);
        setState(() => suggestedUsername = suggestion);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text("Username taken. Suggested: $suggestion"),
              action: SnackBarAction(
                label: 'Use it',
                onPressed: () => usernameController.text = suggestion ?? '',
              ),
            ),
          );
          return;
        }
      }

      final email = emailController.text.trim();
      final alreadyUsed = await isEmailTaken(email);

      if (alreadyUsed) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Email is already registered. Try another.'),
            ),
          );
        }
        return;
      }

      final password = passwordController.text.trim();
      logger.i("📝 Signing up with email: $email");

      UserCredential authResult;
      try {
        authResult = await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );
      } on FirebaseAuthException catch (e) {
        String message = "Signup failed";
        switch (e.code) {
          case 'email-already-in-use':
            message = 'This email is already in use. Try logging in.';
            break;
          case 'invalid-email':
            message = 'The email address is invalid.';
            break;
          case 'weak-password':
            message = 'The password is too weak. Try a stronger one.';
            break;
          case 'operation-not-allowed':
            message = 'Email/password accounts are not enabled.';
            break;
          default:
            message = e.message ?? 'An unknown error occurred.';
        }

        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(message)));
        }

        setState(() => isSubmitting = false);
        return;
      }

      await authResult.user?.sendEmailVerification();

      await Future.delayed(const Duration(seconds: 10));
      await FirebaseAuth.instance.currentUser?.reload();
      var user = FirebaseAuth.instance.currentUser;

      if (user == null || user.uid != authResult.user!.uid) {
        await Future.delayed(const Duration(seconds: 5));
        await FirebaseAuth.instance.currentUser?.reload();
        user = FirebaseAuth.instance.currentUser;
      }

      if (user == null) throw Exception("User session not established");

      final uid = user.uid;
      final docData = {
        'username': cleaned,
        'email': email,
        'phone': phoneController.text.trim(),
        'role': role,
        'createdAt': FieldValue.serverTimestamp(),
        if (role == 'driver') ...{
          'carType': selectedCarType,
          'carModel': carModelController.text.trim(),
          'altContact': altContactController.text.trim(),
          'licenseBase64': licenseBase64,
          'birthCertificateBase64': birthCertBase64,
          'verified': false,
        } else ...{
          'verified': true,
        },
      };

      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .set(docData);

      if (mounted) {
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text("Verify Your Email"),
            content: const Text(
              "We've sent a verification link to your email. Please verify it before logging in.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("OK"),
              ),
            ],
          ),
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Account created successfully')),
          );
        }
        if (mounted) {
          Navigator.pushReplacementNamed(context, '/login_page');
        }
      }
    } catch (e, st) {
      logger.e("Signup failed", error: e, stackTrace: st);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Error: ${e.toString()}")));
      }
    } finally {
      if (mounted) setState(() => isSubmitting = false);
    }
  }

  Future<bool> phoneNumberExists(String phone) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('users')
        .where('phone', isEqualTo: phone)
        .limit(1)
        .get();

    return snapshot.docs.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Your FemDrive Account')),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(18),
            child: Form(
              key: _formKey,
              child: ListView(
                children: [
                  TextFormField(
                    controller: usernameController,
                    decoration: const InputDecoration(labelText: 'Username'),
                    validator: (_) => null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: emailController,
                    decoration: const InputDecoration(labelText: 'Email'),
                    keyboardType: TextInputType.emailAddress,
                    validator: (value) {
                      if (value == null || value.isEmpty) return 'Required';
                      final pattern = RegExp(r'^[\w\.-]+@[\w\.-]+\.\w+$');
                      if (!pattern.hasMatch(value)) {
                        return 'Invalid email format';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: phoneController,
                    inputFormatters: [PhoneNumberHyphenFormatter()],
                    decoration: const InputDecoration(
                      labelText: 'Phone (e.g., 0300-1234567)',
                    ),
                    keyboardType: TextInputType.phone,
                    validator: (v) {
                      final pattern = RegExp(r'^03[0-9]{2}-[0-9]{7}$');
                      if (v == null || v.isEmpty) return 'Required';
                      if (!pattern.hasMatch(v)) return 'Invalid format';
                      final digitsOnly = v.replaceAll(RegExp(r'\D'), '');
                      if (digitsOnly.length != 11) {
                        return 'Phone must be 11 digits';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: passwordController,
                    decoration: const InputDecoration(labelText: 'Password'),
                    obscureText: true,
                    validator: (v) {
                      if (v == null || v.length < 6) return 'Min 6 characters';
                      if (!RegExp(r'[0-9]').hasMatch(v)) {
                        return 'Include a digit';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: role,
                    decoration: const InputDecoration(labelText: 'Register as'),
                    items: ['rider', 'driver']
                        .map(
                          (r) => DropdownMenuItem(
                            value: r,
                            child: Text(r.toUpperCase()),
                          ),
                        )
                        .toList(),
                    onChanged: (val) => setState(() => role = val!),
                  ),
                  if (role == 'driver') ...[
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: selectedCarType,
                      decoration: const InputDecoration(labelText: 'Car Type'),
                      items: carTypeList
                          .map(
                            (c) => DropdownMenuItem(value: c, child: Text(c)),
                          )
                          .toList(),
                      onChanged: (val) =>
                          setState(() => selectedCarType = val!),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: carModelController,
                      decoration: const InputDecoration(
                        labelText: 'Car Name & Model',
                      ),
                      validator: (v) => v!.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: altContactController,
                      decoration: const InputDecoration(
                        labelText: 'Alternate Contact',
                      ),
                      keyboardType: TextInputType.phone,
                      validator: (v) => v!.isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    const Text("Upload Driving License:"),
                    ElevatedButton(
                      onPressed: () => pickImage(ImageSource.gallery, true),
                      child: Text(
                        licenseImage == null
                            ? "Choose File"
                            : "📎 ${licenseImage!.path.split('/').last}",
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text("Upload Birth Certificate / CNIC:"),
                    ElevatedButton(
                      onPressed: () => pickImage(ImageSource.gallery, false),
                      child: Text(
                        birthCertificateImage == null
                            ? "Choose File"
                            : "📎 ${birthCertificateImage!.path.split('/').last}",
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: isSubmitting ? null : submitForm,
                    child: isSubmitting
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text("Sign Up"),
                  ),
                ],
              ),
            ),
          ),
          if (isSubmitting)
            Positioned.fill(
              child: Container(
                color: Colors.black38,
                child: const Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

// ✅ Auto-dash formatter: e.g., 03001234567 → 0300-1234567
class PhoneNumberHyphenFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    String digitsOnly = newValue.text.replaceAll('-', '');
    if (digitsOnly.length <= 4) {
      return TextEditingValue(
        text: digitsOnly,
        selection: TextSelection.collapsed(offset: digitsOnly.length),
      );
    }
    final part1 = digitsOnly.substring(0, 4);
    final part2 = digitsOnly.substring(4);
    final formatted = '$part1-$part2';
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
