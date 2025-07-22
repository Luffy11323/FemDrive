import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool loading = false;

  Future<void> loginUser() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => loading = true);

    final email = emailController.text.trim();
    final password = passwordController.text.trim();

    if (kDebugMode) {
      print('🔐 Attempting login with email: $email');
    }

    try {
      final result = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (kDebugMode) {
        print('✅ Firebase Auth login successful');
      }

      final user = result.user;

      if (user == null) throw Exception("User object is null after login.");

      if (kDebugMode) {
        print('👤 Logged in user UID: ${user.uid}');
      }

      if (!user.emailVerified) {
        if (kDebugMode) {
          print('📧 Email not verified — sending verification link...');
        }
        await user.sendEmailVerification();
        throw Exception(
          'Email not verified. A new verification link has been sent.',
        );
      }

      if (kDebugMode) {
        print('📥 Fetching user document from Firestore...');
      }
      final userDoc = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();

      final data = userDoc.data();

      if (data == null) {
        throw Exception("⚠️ User profile not found in Firestore.");
      }

      final isVerified = data['verified'] == true;
      final role = data['role'] ?? 'rider';

      if (kDebugMode) {
        print('👁️ Admin verification status: $isVerified');
      }
      if (kDebugMode) {
        print('🎭 User role: $role');
      }

      if (!isVerified) {
        await FirebaseAuth.instance.signOut();
        throw Exception("Account pending admin approval. Please wait.");
      }

      if (!mounted) return;

      String? route;
      if (role == 'admin') {
        route = '/admin_driver_verification';
      } else if (role == 'driver') {
        route = '/driver_dashboard';
      } else if (role == 'rider') {
        route = '/rider_dashboard';
      }

      if (route != null) {
        if (kDebugMode) {
          print('🚀 Navigating to: $route');
        }
        Navigator.pushReplacementNamed(context, route);
      }
    } on FirebaseAuthException catch (e) {
      if (kDebugMode) {
        print('❌ FirebaseAuthException: ${e.code} | ${e.message}');
      }
      String message;
      switch (e.code) {
        case 'user-not-found':
          message = 'No account found for this email.';
          break;
        case 'wrong-password':
          message = 'Incorrect password.';
          break;
        case 'invalid-email':
          message = 'Invalid email format.';
          break;
        default:
          message = 'Login failed: ${e.message}';
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (kDebugMode) {
        print('❌ Other Exception: $e');
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: emailController,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter your email';
                  }
                  final emailRegex = RegExp(r'^[\w\.-]+@[\w\.-]+\.\w+$');
                  if (!emailRegex.hasMatch(value.trim())) {
                    return 'Invalid email format';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: passwordController,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
                validator: (v) =>
                    v == null || v.length < 6 ? 'Minimum 6 characters' : null,
              ),
              const SizedBox(height: 20),
              loading
                  ? const CircularProgressIndicator()
                  : ElevatedButton(
                      onPressed: loginUser,
                      child: const Text('Login'),
                    ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () {
                  Navigator.pushNamed(context, '/signup');
                },
                child: const Text("Don't have an account? Sign up"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
