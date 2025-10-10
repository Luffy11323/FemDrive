import 'dart:convert';
import 'dart:io';
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
  final _homeController = TextEditingController();
  final _workController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isEditing = false;
  String? _localPhotoPath;
  String? _phoneNumber;
  String? _cnicNumber;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<String> _getProfileFilePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/profile_${FirebaseAuth.instance.currentUser?.uid}.json';
  }

  Future<void> _loadProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      // Load user data from local JSON file
      final profileFilePath = await _getProfileFilePath();
      final profileFile = File(profileFilePath);
      if (profileFile.existsSync()) {
        final profileData = jsonDecode(await profileFile.readAsString());
        setState(() {
          _nameController.text = profileData['username'] ?? user.displayName ?? '';
          _homeController.text = profileData['savedLocations']?['home'] ?? '';
          _workController.text = profileData['savedLocations']?['work'] ?? '';
        });
      } else {
        // Initialize with Firebase Auth displayName if no local file exists
        setState(() {
          _nameController.text = user.displayName ?? '';
        });
      }

      // Load phone number from Firebase Auth (assuming it's stored there)
      setState(() {
        _phoneNumber = user.phoneNumber ?? '';
        _cnicNumber = ''; // CNIC not stored in Firebase Auth; placeholder
      });

      // Load local profile photo
      final dir = await getApplicationDocumentsDirectory();
      final photoPath = '${dir.path}/profile_${user.uid}.jpg';
      if (File(photoPath).existsSync()) {
        setState(() {
          _localPhotoPath = photoPath;
        });
      }
    } catch (e) {
      _logger.e('Failed to load profile: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading profile: $e')),
        );
      }
    }
  }

  Future<void> _pickAndSavePhoto() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(source: ImageSource.gallery);
      if (picked == null) return;

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // Save the image to the app's documents directory
      final dir = await getApplicationDocumentsDirectory();
      final filePath = '${dir.path}/profile_${user.uid}.jpg';
      final file = File(filePath);
      await file.writeAsBytes(await picked.readAsBytes());

      setState(() => _localPhotoPath = filePath);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile picture updated')),
        );
      }
    } catch (e) {
      _logger.e('Photo save failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update photo: $e')),
        );
      }
    }
  }

  Future<void> _saveProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name cannot be empty')),
      );
      return;
    }

    try {
      // Update Firebase Auth displayName
      await user.updateDisplayName(_nameController.text.trim());

      // Save profile data to local JSON file
      final profileFilePath = await _getProfileFilePath();
      final profileFile = File(profileFilePath);
      final profileData = {
        'username': _nameController.text.trim(),
        'savedLocations': {
          'home': _homeController.text.trim(),
          'work': _workController.text.trim(),
        },
      };
      await profileFile.writeAsString(jsonEncode(profileData));

      // Update password if provided
      if (_passwordController.text.trim().isNotEmpty) {
        if (_passwordController.text.trim().length < 6) {
          // ignore: use_build_context_synchronously
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Password must be at least 6 characters')),
          );
          return;
        }
        await user.updatePassword(_passwordController.text.trim());
      }

      setState(() {
        _isEditing = false;
        _passwordController.clear(); // Clear password field after saving
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile updated successfully')),
        );
      }
    } catch (e) {
      _logger.e('Failed to save profile: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save profile: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _homeController.dispose();
    _workController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final imageFile = _localPhotoPath != null ? File(_localPhotoPath!) : null;
    final theme = Theme.of(context);

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
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: _isEditing ? _pickAndSavePhoto : null,
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  CircleAvatar(
                    radius: 60,
                    backgroundImage: imageFile != null && imageFile.existsSync()
                        ? FileImage(imageFile)
                        : null,
                    child: imageFile == null
                        ? const Icon(Icons.person, size: 60)
                        : null,
                  ),
                  if (_isEditing)
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Personal Information',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        labelText: 'Name',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        prefixIcon: const Icon(Icons.person),
                      ),
                      enabled: _isEditing,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: TextEditingController(text: _phoneNumber),
                      decoration: InputDecoration(
                        labelText: 'Phone Number',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        prefixIcon: const Icon(Icons.phone),
                      ),
                      enabled: false, // Read-only
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: TextEditingController(text: _cnicNumber),
                      decoration: InputDecoration(
                        labelText: 'CNIC Number',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        prefixIcon: const Icon(Icons.card_membership),
                      ),
                      enabled: false, // Read-only
                    ),
                    if (_isEditing) ...[
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passwordController,
                        obscureText: true,
                        decoration: InputDecoration(
                          labelText: 'New Password (optional)',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                          prefixIcon: const Icon(Icons.lock),
                        ),
                        enabled: _isEditing,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Card(
              elevation: 2,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Saved Locations',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _homeController,
                      decoration: InputDecoration(
                        labelText: 'Home Address',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        prefixIcon: const Icon(Icons.home),
                      ),
                      enabled: _isEditing,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _workController,
                      decoration: InputDecoration(
                        labelText: 'Work Address',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        prefixIcon: const Icon(Icons.work),
                      ),
                      enabled: _isEditing,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}