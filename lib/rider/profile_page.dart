import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import './user_service.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final us = UserService();
  final _displayNameController = TextEditingController();
  final _phoneController = TextEditingController();
  bool loading = false;

  @override
  void dispose() {
    _displayNameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  void _saveProfile() async {
    if (_displayNameController.text.isEmpty || _phoneController.text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Complete all fields')));
      return;
    }

    setState(() => loading = true);
    try {
      await us.updateProfile({
        'username': _displayNameController.text.trim(),
        'phone': _phoneController.text.trim(),
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Profile updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile & Settings')),
      body: StreamBuilder(
        stream: us.userStream(),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Text(
                'Error: ${snap.error}',
                style: const TextStyle(color: Colors.red),
              ),
            );
          }

          final doc = snap.data!;
          _displayNameController.text = doc['username'];
          _phoneController.text = doc['phone'];
          final role = doc['role'] as String;
          final verified =
              (doc.data() as Map<String, dynamic>?)?.containsKey(
                'licenseUrl',
              ) ??
              false;
          final statusBadge = verified
              ? Row(
                  children: const [
                    Icon(Icons.verified, color: Colors.green),
                    SizedBox(width: 4),
                    Text('Verified'),
                  ],
                )
              : Row(
                  children: const [
                    Icon(Icons.hourglass_top, color: Colors.orange),
                    SizedBox(width: 4),
                    Text('Pending'),
                  ],
                );

          return Padding(
            padding: const EdgeInsets.all(16),
            child: ListView(
              children: [
                Center(
                  child: CircleAvatar(
                    radius: 40,
                    backgroundColor: Theme.of(context).colorScheme.secondary,
                    child: Text(doc['username'][0].toUpperCase()),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _displayNameController,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _phoneController,
                  decoration: const InputDecoration(labelText: 'Phone'),
                ),
                const SizedBox(height: 20),
                ListTile(
                  leading: Icon(
                    role == 'driver' ? Icons.directions_car : Icons.person,
                  ),
                  title: Text(
                    'Role: ${role[0].toUpperCase()}${role.substring(1)}',
                  ),
                ),
                const SizedBox(height: 10),
                if (role == 'driver')
                  ListTile(
                    leading: const Icon(Icons.document_scanner),
                    title: statusBadge,
                    subtitle: verified
                        ? const Text('Docs verified')
                        : const Text('Awaiting approval'),
                  ),
                const SizedBox(height: 20),
                loading
                    ? const Center(child: CircularProgressIndicator())
                    : ElevatedButton(
                        onPressed: _saveProfile,
                        child: const Text('Save Changes'),
                      ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  icon: const Icon(Icons.logout),
                  label: const Text('Logout'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                  ),
                  onPressed: () {
                    FirebaseAuth.instance.signOut();
                    Navigator.popUntil(context, (r) => r.isFirst);
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
