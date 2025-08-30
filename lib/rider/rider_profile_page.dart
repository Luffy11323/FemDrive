import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';

class RiderProfilePage extends ConsumerStatefulWidget {
  const RiderProfilePage({super.key});
  @override
  ConsumerState<RiderProfilePage> createState() => _RiderProfilePageState();
}

class _RiderProfilePageState extends ConsumerState<RiderProfilePage> {
  final _logger = Logger();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _homeController = TextEditingController();
  final _workController = TextEditingController();
  bool _isEditing = false;
  String? _localPhotoPath;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();
    final data = doc.data();
    if (data != null) {
      setState(() {
        _nameController.text = data['username'] ?? '';
        _phoneController.text = data['phone'] ?? '';
        _homeController.text = data['savedLocations']?['home'] ?? '';
        _workController.text = data['savedLocations']?['work'] ?? '';
      });
    }

    // Prepare local file path for profile photo
    final dir = await getApplicationDocumentsDirectory();
    _localPhotoPath = '${dir.path}/profile_${user.uid}.jpg';
    if (!File(_localPhotoPath!).existsSync()) {
      _localPhotoPath = null; // No photo yet
    }
    setState(() {});
  }

  Future<void> _pickAndSavePhoto() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final dir = await getApplicationDocumentsDirectory();
      final filePath = '${dir.path}/profile_${user.uid}.jpg';
      final file = File(filePath);
      await file.writeAsBytes(await picked.readAsBytes());

      setState(() => _localPhotoPath = filePath);
    } catch (e) {
      _logger.e('Photo save failed: $e');
    }
  }

  Future<void> _saveProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Name cannot be empty')));
      return;
    }

    if (_phoneController.text.isNotEmpty && _phoneController.text.length < 10) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid phone number')),
      );
      return;
    }

    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update(
        {
          'username': _nameController.text.trim(),
          'phone': _phoneController.text.trim(),
          'savedLocations': {
            'home': _homeController.text.trim(),
            'work': _workController.text.trim(),
          },
        },
      );
      setState(() => _isEditing = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated successfully')),
      );
    } catch (e) {
      _logger.e('Failed to save profile: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save profile: $e')));
    } finally {}
  }

  @override
  Widget build(BuildContext context) {
    final imageFile = _localPhotoPath != null ? File(_localPhotoPath!) : null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rider Profile'),
        actions: [
          IconButton(
            icon: Icon(_isEditing ? Icons.save : Icons.edit),
            onPressed: () =>
                _isEditing ? _saveProfile() : setState(() => _isEditing = true),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              // ignore: use_build_context_synchronously
              if (mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            GestureDetector(
              onTap: _isEditing ? _pickAndSavePhoto : null,
              child: CircleAvatar(
                radius: 45,
                backgroundImage: imageFile != null && imageFile.existsSync()
                    ? FileImage(imageFile)
                    : null,
                child: imageFile == null
                    ? const Icon(Icons.person, size: 45)
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            // Personal info & saved locations cards remain unchanged
          ],
        ),
      ),
    );
  }
}
