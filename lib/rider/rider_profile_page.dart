import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import '../theme.dart';

final riderProfileProvider = StreamProvider<DocumentSnapshot<Object?>?>((ref) {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return Stream.value(null); // return null when not logged in
  return FirebaseFirestore.instance
      .collection('users')
      .doc(user.uid)
      .snapshots();
});

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
  bool _isLoading = false;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _homeController.dispose();
    _workController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile(Map<String, dynamic> data) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _logger.w('No user logged in');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to save profile')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .update(data);
      setState(() => _isEditing = false);
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated successfully')),
      );
    } catch (e) {
      _logger.e('Failed to save profile: $e');
      ScaffoldMessenger.of(
        // ignore: use_build_context_synchronously
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save profile: $e')));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(riderProfileProvider);

    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: femLightTheme.colorScheme,
        cardTheme: femLightTheme.cardTheme,
        elevatedButtonTheme: femLightTheme.elevatedButtonTheme,
      ),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Rider Profile'),
          actions: [
            IconButton(
              icon: Icon(_isEditing ? Icons.save : Icons.edit),
              onPressed: () {
                if (_isEditing) {
                  _saveProfile({
                    'username': _nameController.text.trim(),
                    'phone': _phoneController.text.trim(),
                    'savedLocations': {
                      'home': _homeController.text.trim(),
                      'work': _workController.text.trim(),
                    },
                  });
                } else {
                  setState(() => _isEditing = true);
                }
              },
            ),
          ],
        ),
        body: profileAsync.when(
          data: (doc) {
            if (!doc!.exists) {
              return const Center(child: Text('Profile not found'));
            }
            final data = doc.data() as Map<String, dynamic>;
            _nameController.text = data['username'] ?? '';
            _phoneController.text = data['phone'] ?? '';
            _homeController.text = data['savedLocations']?['home'] ?? '';
            _workController.text = data['savedLocations']?['work'] ?? '';

            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Personal Information',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _nameController,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                              border: OutlineInputBorder(),
                            ),
                            enabled: _isEditing,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _phoneController,
                            decoration: const InputDecoration(
                              labelText: 'Phone Number',
                              border: OutlineInputBorder(),
                            ),
                            enabled: _isEditing,
                            keyboardType: TextInputType.phone,
                          ),
                        ],
                      ),
                    ),
                  ).animate().fadeIn(duration: 400.ms),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Saved Locations',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _homeController,
                            decoration: const InputDecoration(
                              labelText: 'Home Address',
                              border: OutlineInputBorder(),
                            ),
                            enabled: _isEditing,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _workController,
                            decoration: const InputDecoration(
                              labelText: 'Work Address',
                              border: OutlineInputBorder(),
                            ),
                            enabled: _isEditing,
                          ),
                        ],
                      ),
                    ),
                  ).animate().fadeIn(duration: 400.ms),
                  if (_isLoading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    ),
                ],
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Error loading profile: $e'),
                ElevatedButton(
                  onPressed: () => ref.refresh(riderProfileProvider),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
