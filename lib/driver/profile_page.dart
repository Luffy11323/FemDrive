import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import '../theme.dart';

final driverProfileProvider = StreamProvider<DocumentSnapshot<Object?>?>((ref) {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return Stream.value(null);
  return FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .snapshots();
});

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});
  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  final _logger = Logger();
  final _nameController = TextEditingController();
  final _homeController = TextEditingController();
  final _workController = TextEditingController();
  final _passwordController = TextEditingController();
  final _carNumberController = TextEditingController();
  bool _isEditing = false;
  bool _isLoading = false;
  String? _localPhotoPath;
  String? _phoneNumber;
  String? _cnicNumber;
  String? _altContact;
  String? _carModel;
  String? _carType;

  @override
  void initState() {
    super.initState();
    _loadProfileImage();
  }

  Future<void> _loadProfileImage() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final dir = await getApplicationDocumentsDirectory();
      final photoPath = '${dir.path}/profile_${user.uid}.jpg';
      if (File(photoPath).existsSync()) {
        setState(() {
          _localPhotoPath = photoPath;
        });
      }
    } catch (e) {
      _logger.e('Failed to load profile image: $e');
    }
  }

  Future<void> _pickAndSavePhoto() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 85,
      );
      if (picked == null) return;

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final dir = await getApplicationDocumentsDirectory();
      final filePath = '${dir.path}/profile_${user.uid}.jpg';
      final file = File(filePath);
      await file.writeAsBytes(await picked.readAsBytes());

      setState(() => _localPhotoPath = filePath);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile picture updated'),
            duration: Duration(seconds: 2),
          ),
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

  Future<void> _saveProfile(Map<String, dynamic> data) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _logger.w('No user logged in');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please log in to save profile')),
        );
      }
      return;
    }

    // Validate name
    if (data['username'].trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Name cannot be empty')),
        );
      }
      return;
    }

    // Validate car number (if editable in the future)
    if (_carNumberController.text.trim().isNotEmpty &&
        _carNumberController.text.trim().length < 3) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Car number plate must be at least 3 characters')),
        );
      }
      return;
    }

    setState(() => _isLoading = true);
    try {
      // Update Firebase Auth displayName
      await user.updateDisplayName(data['username'].trim());

      // Update password if provided
      if (_passwordController.text.trim().isNotEmpty) {
        if (_passwordController.text.trim().length < 6) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Password must be at least 6 characters')),
            );
          }
          setState(() => _isLoading = false);
          return;
        }
        await user.updatePassword(_passwordController.text.trim());
      }

      // Prepare Firestore update data
      final updateData = {
        'username': data['username'].trim(),
        'savedLocations': {
          'home': data['savedLocations']?['home']?.trim() ?? '',
          'work': data['savedLocations']?['work']?.trim() ?? '',
        },
      };

      // Update Firestore
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update(updateData);

      setState(() {
        _isEditing = false;
        _passwordController.clear();
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile updated successfully'),
            duration: Duration(seconds: 2),
            backgroundColor: Colors.green,
          ),
        );
      }
    } on FirebaseAuthException catch (e) {
      _logger.e('Auth error: ${e.code} - ${e.message}');
      if (mounted) {
        String errorMessage = 'Failed to save profile';
        if (e.code == 'requires-recent-login') {
          errorMessage = 'Please log out and log in again to change password';
        } else if (e.code == 'weak-password') {
          errorMessage = 'Password is too weak';
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage)),
        );
      }
    } catch (e) {
      _logger.e('Failed to save profile: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save profile: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _homeController.dispose();
    _workController.dispose();
    _passwordController.dispose();
    _carNumberController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(driverProfileProvider);
    final imageFile = _localPhotoPath != null ? File(_localPhotoPath!) : null;

    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: femLightTheme.colorScheme,
        cardTheme: femLightTheme.cardTheme,
        elevatedButtonTheme: femLightTheme.elevatedButtonTheme,
      ),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Driver Profile'),
          actions: [
            if (_isEditing)
              TextButton(
                onPressed: () {
                  setState(() {
                    _isEditing = false;
                    _passwordController.clear();
                  });
                  ref.invalidate(driverProfileProvider);
                },
                child: const Text('Cancel'),
              ),
            IconButton(
              icon: Icon(_isEditing ? Icons.save : Icons.edit),
              onPressed: _isLoading
                  ? null
                  : () {
                      if (_isEditing) {
                        _saveProfile({
                          'username': _nameController.text,
                          'savedLocations': {
                            'home': _homeController.text,
                            'work': _workController.text,
                          },
                        });
                      } else {
                        setState(() => _isEditing = true);
                      }
                    },
            ),
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () async {
                final shouldLogout = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Logout'),
                    content: const Text('Are you sure you want to logout?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Logout'),
                      ),
                    ],
                  ),
                );
                if (shouldLogout == true) {
                  await FirebaseAuth.instance.signOut();
                  // ignore: use_build_context_synchronously
                  if (mounted) Navigator.of(context).pop();
                }
              },
            ),
          ],
        ),
        body: profileAsync.when(
          data: (doc) {
            if (doc == null || !doc.exists) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.error_outline, size: 64, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text('Profile not found'),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () => ref.refresh(driverProfileProvider),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              );
            }
            final data = doc.data() as Map<String, dynamic>;

            if (!_isEditing) {
              _nameController.text = data['username'] ?? '';
              _homeController.text = data['savedLocations']?['home'] ?? '';
              _workController.text = data['savedLocations']?['work'] ?? '';
            }

            _phoneNumber = data['phone'] ?? '';
            _cnicNumber = data['cnicNumber'] ?? '';
            _altContact = data['altContact'] ?? '';
            // Handle vehicle as either a map or string
            _carModel = data['vehicle'] is Map
                ? data['vehicle']['model'] ?? data['vehicle']['make'] ?? ''
                : data['vehicle']?.toString() ?? '';
            _carNumberController.text = data['vehicle'] is Map
                ? data['vehicle']['plateNumber'] ?? ''
                : '';
            _carType = data['vehicle'] is Map
                ? data['vehicle']['type'] ?? ''
                : '';

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: _isEditing ? _pickAndSavePhoto : null,
                    child: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        Hero(
                          tag: 'profile_image',
                          child: CircleAvatar(
                            radius: 60,
                            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                            backgroundImage: imageFile != null && imageFile.existsSync()
                                ? FileImage(imageFile)
                                : null,
                            child: imageFile == null
                                ? Icon(
                                    Icons.person,
                                    size: 60,
                                    color: Theme.of(context).colorScheme.onPrimaryContainer,
                                  )
                                : null,
                          ),
                        ),
                        if (_isEditing)
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.7),
                                  blurRadius: 4,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
                          ),
                      ],
                    ),
                  ).animate().fadeIn(duration: 400.ms).scale(delay: 100.ms),
                  const SizedBox(height: 8),
                  if (_isEditing)
                    Text(
                      'Tap to change photo',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ).animate().fadeIn(),
                  const SizedBox(height: 24),
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.person_outline,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Personal Information',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _nameController,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.person),
                            ),
                            enabled: _isEditing,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: TextEditingController(text: _phoneNumber),
                            decoration: const InputDecoration(
                              labelText: 'Phone Number',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.phone),
                            ),
                            enabled: false,
                            keyboardType: TextInputType.phone,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: TextEditingController(text: _altContact),
                            decoration: const InputDecoration(
                              labelText: 'Alternate Contact',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.phone_android),
                            ),
                            enabled: false,
                            keyboardType: TextInputType.phone,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: TextEditingController(text: _cnicNumber),
                            decoration: const InputDecoration(
                              labelText: 'CNIC Number',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.card_membership),
                            ),
                            enabled: false,
                          ),
                          if (_isEditing) ...[
                            const SizedBox(height: 12),
                            TextField(
                              controller: _passwordController,
                              obscureText: true,
                              decoration: const InputDecoration(
                                labelText: 'New Password (optional)',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.lock),
                                helperText: 'Leave empty to keep current password',
                              ),
                              enabled: _isEditing,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1, end: 0),
                  const SizedBox(height: 16),
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.directions_car_outlined,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Vehicle Information',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: TextEditingController(text: _carType),
                            decoration: const InputDecoration(
                              labelText: 'Car Type',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.directions_car),
                            ),
                            enabled: false,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: TextEditingController(text: _carModel),
                            decoration: const InputDecoration(
                              labelText: 'Car Model',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.car_repair),
                            ),
                            enabled: false,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _carNumberController,
                            decoration: const InputDecoration(
                              labelText: 'Car Number Plate',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.local_offer),
                            ),
                            enabled: false,
                          ),
                        ],
                      ),
                    ),
                  ).animate().fadeIn(duration: 400.ms, delay: 100.ms).slideY(begin: 0.1, end: 0),
                  const SizedBox(height: 16),
                  Card(
                    elevation: 2,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.location_on_outlined,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Saved Locations',
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _homeController,
                            decoration: const InputDecoration(
                              labelText: 'Home Address',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.home),
                            ),
                            enabled: _isEditing,
                            maxLines: 2,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _workController,
                            decoration: const InputDecoration(
                              labelText: 'Work Address',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.work),
                            ),
                            enabled: _isEditing,
                            maxLines: 2,
                          ),
                        ],
                      ),
                    ),
                  ).animate().fadeIn(duration: 400.ms, delay: 200.ms).slideY(begin: 0.1, end: 0),
                  if (_isLoading)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(
                            'Saving profile...',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, stack) {
            _logger.e('Profile error: $e', error: e, stackTrace: stack);
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.error_outline, size: 64, color: Colors.red),
                  const SizedBox(height: 16),
                  Text('Error loading profile', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    e.toString(),
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () => ref.refresh(driverProfileProvider),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}