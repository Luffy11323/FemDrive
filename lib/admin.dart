import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class AdminDriverVerificationPage extends StatefulWidget {
  const AdminDriverVerificationPage({super.key});

  @override
  State<AdminDriverVerificationPage> createState() =>
      _AdminDriverVerificationPageState();
}

class _AdminDriverVerificationPageState
    extends State<AdminDriverVerificationPage> {
  bool isAdmin = false;
  bool loading = true;
  int currentTab = 0; // 0: Verifications, 1: Logs, 2: Emergencies
  String? currentUserRole;
  Map<String, dynamic>? currentUserData;

  @override
  void initState() {
    super.initState();
    checkAdminStatus();
  }

  Future<void> checkAdminStatus() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        setState(() {
          isAdmin = false;
          loading = false;
        });
        return;
      }

      // Check both custom claims and Firestore document
      bool isAdminFromClaims = false;
      bool isAdminFromFirestore = false;

      // Check custom claims first
      try {
        final token = await user.getIdTokenResult();
        isAdminFromClaims = token.claims?['admin'] == true;
      } catch (e) {
        if (kDebugMode) {
          print('Error checking custom claims: $e');
        }
      }

      // Check Firestore document
      try {
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();

        if (userDoc.exists) {
          currentUserData = userDoc.data() as Map<String, dynamic>;
          currentUserRole = currentUserData?['role'];
          isAdminFromFirestore = currentUserRole == 'admin';
        }
      } catch (e) {
        if (kDebugMode) {
          print('Error checking Firestore document: $e');
        }
      }

      setState(() {
        isAdmin = isAdminFromClaims || isAdminFromFirestore;
        loading = false;
      });

      // Debug information
      if (kDebugMode) {
        print('User UID: ${user.uid}');
      }
      if (kDebugMode) {
        print('User Email: ${user.email}');
      }
      if (kDebugMode) {
        print('User Phone: ${user.phoneNumber}');
      }
      if (kDebugMode) {
        print('Custom Claims Admin: $isAdminFromClaims');
      }
      if (kDebugMode) {
        print('Firestore Role: $currentUserRole');
      }
      if (kDebugMode) {
        print('Final Admin Status: $isAdmin');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error in checkAdminStatus: $e');
      }
      setState(() {
        isAdmin = false;
        loading = false;
      });
    }
  }

  Future<void> _logout() async {
    try {
      // Show confirmation dialog
      final shouldLogout = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Logout'),
          content: const Text('Are you sure you want to logout?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('Logout'),
            ),
          ],
        ),
      );

      if (shouldLogout == true) {
        // Sign out from Firebase
        await FirebaseAuth.instance.signOut();

        // Navigate to login page and clear the navigation stack
        if (mounted) {
          Navigator.of(
            context,
          ).pushNamedAndRemoveUntil('/login', (route) => false);
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error logging out: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> updateDriverStatus(
    String uid,
    String status, {
    String? reason,
  }) async {
    try {
      final updates = {'status': status};
      if (reason != null && reason.isNotEmpty) {
        updates['rejectionReason'] = reason;
      }

      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .update(updates);

      // Log the action
      await FirebaseFirestore.instance.collection('driverApprovals').add({
        'driverId': uid,
        'status': status,
        'reason': reason ?? '',
        'timestamp': FieldValue.serverTimestamp(),
        'adminId': FirebaseAuth.instance.currentUser?.uid,
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Driver marked as $status'),
            backgroundColor: status == 'approved' ? Colors.green : Colors.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating driver status: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Widget buildBase64Image(
    String base64String, {
    double? height,
    double? width,
  }) {
    try {
      final bytes = base64Decode(base64String);
      return Image.memory(
        bytes,
        height: height,
        width: width,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            height: height ?? 100,
            width: width ?? 100,
            color: Colors.grey[300],
            child: const Icon(Icons.error),
          );
        },
      );
    } catch (e) {
      return Container(
        height: height ?? 100,
        width: width ?? 100,
        color: Colors.grey[300],
        child: const Icon(Icons.error),
      );
    }
  }

  void showRejectionDialog(String uid) {
    final reasonController = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Reject Driver"),
        content: TextField(
          controller: reasonController,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: "Enter reason for rejection",
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () {
              final reason = reasonController.text.trim();
              Navigator.pop(context);
              updateDriverStatus(uid, 'rejected', reason: reason);
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("Reject"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Checking admin permissions...'),
            ],
          ),
        ),
      );
    }

    if (!isAdmin) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Access Denied'),
          actions: [
            IconButton(
              onPressed: _logout,
              icon: const Icon(Icons.logout),
              tooltip: 'Logout',
            ),
          ],
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text(
                'Access Denied: Admins Only',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                'Current Role: ${currentUserRole ?? 'Unknown'}',
                style: const TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _logout,
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                child: const Text('Logout'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: checkAdminStatus,
                child: const Text('Retry Permission Check'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          currentTab == 0
              ? 'Driver Verifications'
              : currentTab == 1
              ? 'Driver Logs'
              : 'Emergency Reports',
        ),
        actions: [
          // Current user info
          if (currentUserData != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Center(
                child: Text(
                  '${currentUserData?['username'] ?? 'Admin'}',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),
          // Menu for switching tabs
          PopupMenuButton<int>(
            onSelected: (value) => setState(() => currentTab = value),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0, child: Text('Verifications')),
              PopupMenuItem(value: 1, child: Text('Logs')),
              PopupMenuItem(value: 2, child: Text('Emergencies')),
            ],
            icon: const Icon(Icons.menu),
          ),
          // Logout button
          IconButton(
            onPressed: _logout,
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
          ),
        ],
      ),
      body: currentTab == 0
          ? _buildPendingView()
          : currentTab == 1
          ? _buildLogsView()
          : _buildEmergencyLogsView(),
    );
  }

  Widget _buildPendingView() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .where('role', isEqualTo: 'driver')
          .where('status', isEqualTo: 'pending')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error, color: Colors.red, size: 48),
                const SizedBox(height: 16),
                Text('Error: ${snapshot.error}'),
                ElevatedButton(
                  onPressed: () => setState(() {}),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final drivers = snapshot.data!.docs;
        if (drivers.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 48),
                SizedBox(height: 16),
                Text('No pending drivers'),
              ],
            ),
          );
        }

        return ListView.builder(
          itemCount: drivers.length,
          itemBuilder: (context, index) {
            final doc = drivers[index];
            final data = doc.data() as Map<String, dynamic>;

            return Card(
              margin: const EdgeInsets.all(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Username: ${data['username'] ?? 'N/A'}',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.orange,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'PENDING',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text('Car Model: ${data['carModel'] ?? 'N/A'}'),
                    Text('Phone: ${data['phone'] ?? 'N/A'}'),
                    Text('Email: ${data['email'] ?? 'N/A'}'),
                    if (data.containsKey('rating'))
                      Text('Avg Rating: ${data['rating'].toStringAsFixed(1)}'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton.icon(
                            onPressed: () =>
                                showImageDialog(data['licenseUrl'], 'License'),
                            icon: const Icon(Icons.description),
                            label: const Text('View License'),
                          ),
                        ),
                        Expanded(
                          child: TextButton.icon(
                            onPressed: () => showImageDialog(
                              data['birthCertificateUrl'],
                              'CNIC',
                            ),
                            icon: const Icon(Icons.badge),
                            label: const Text('View CNIC'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () =>
                                updateDriverStatus(doc.id, 'approved'),
                            icon: const Icon(Icons.check),
                            label: const Text('Approve'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: () => showRejectionDialog(doc.id),
                            icon: const Icon(Icons.close),
                            label: const Text('Reject'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                              foregroundColor: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildLogsView() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('driverApprovals')
          .orderBy('timestamp', descending: true)
          .limit(50)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error, color: Colors.red, size: 48),
                const SizedBox(height: 16),
                Text('Error: ${snapshot.error}'),
                ElevatedButton(
                  onPressed: () => setState(() {}),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final logs = snapshot.data!.docs;
        if (logs.isEmpty) {
          return const Center(child: Text('No logs available'));
        }

        return ListView.builder(
          itemCount: logs.length,
          itemBuilder: (context, index) {
            final doc = logs[index].data() as Map<String, dynamic>;
            final status = doc['status'] ?? 'Unknown';
            final reason = doc['reason'] ?? '-';
            final ts = (doc['timestamp'] as Timestamp?)?.toDate();
            final dateStr = ts != null
                ? ts.toLocal().toString().split('.')[0]
                : 'Unknown';

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: Icon(
                  status == 'approved' ? Icons.check_circle : Icons.cancel,
                  color: status == 'approved' ? Colors.green : Colors.red,
                ),
                title: Text('Driver: ${doc['driverId']}'),
                subtitle: Text(
                  'Status: $status\nReason: $reason\nAt: $dateStr',
                ),
                isThreeLine: true,
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildEmergencyLogsView() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('emergencies')
          .orderBy('timestamp', descending: true)
          .limit(50)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error, color: Colors.red, size: 48),
                const SizedBox(height: 16),
                Text('Error: ${snapshot.error}'),
                ElevatedButton(
                  onPressed: () => setState(() {}),
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final logs = snapshot.data!.docs;
        if (logs.isEmpty) {
          return const Center(child: Text('No emergency reports found.'));
        }

        return ListView.builder(
          itemCount: logs.length,
          itemBuilder: (context, index) {
            final data = logs[index].data() as Map<String, dynamic>;

            final timestamp =
                (data['timestamp'] as Timestamp?)
                    ?.toDate()
                    .toLocal()
                    .toString()
                    .split('.')[0] ??
                'Unknown';

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: const Icon(Icons.warning, color: Colors.red),
                title: Text('Ride ID: ${data['rideId']}'),
                subtitle: Text(
                  'Reported By: ${data['reportedBy']}\n'
                  'Against: ${data['otherUid']}\n'
                  'At: $timestamp',
                ),
                isThreeLine: true,
              ),
            );
          },
        );
      },
    );
  }

  void showImageDialog(String url, String title) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 300,
          height: 400,
          child: Image.network(
            url,
            fit: BoxFit.contain,
            loadingBuilder: (context, child, loadingProgress) {
              if (loadingProgress == null) return child;
              return Center(
                child: CircularProgressIndicator(
                  value: loadingProgress.expectedTotalBytes != null
                      ? loadingProgress.cumulativeBytesLoaded /
                            loadingProgress.expectedTotalBytes!
                      : null,
                ),
              );
            },
            errorBuilder: (_, _, _) => const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error, size: 48, color: Colors.red),
                  SizedBox(height: 8),
                  Text("Image not found"),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              try {
                final uri = Uri.parse(url);
                if (await canLaunchUrl(uri)) {
                  await launchUrl(uri);
                } else {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Could not open URL'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error opening URL: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: const Text('Open in Browser'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
