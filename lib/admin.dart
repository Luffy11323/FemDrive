import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
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

      bool isAdminFromClaims = false;
      bool isAdminFromFirestore = false;

      try {
        final token = await user.getIdTokenResult();
        isAdminFromClaims = token.claims?['admin'] == true;
      } catch (e) {
        if (kDebugMode) {
          print('Error checking custom claims: $e');
        }
      }

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
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Logout'),
            ),
          ],
        ),
      );

      if (shouldLogout == true) {
        await FirebaseAuth.instance.signOut();
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
            border: OutlineInputBorder(
              borderRadius: BorderRadius.all(Radius.circular(12)),
            ),
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
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text("Reject"),
          ),
        ],
      ),
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
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ),
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            currentTab == 0
                ? 'Driver Verifications'
                : currentTab == 1
                ? 'Driver Logs'
                : 'Emergency Reports',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          actions: [
            if (currentUserData != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Chip(
                  label: Text(
                    currentUserData?['username'] ?? 'Admin',
                    style: const TextStyle(fontSize: 14),
                  ),
                  avatar: const Icon(Icons.person, size: 20),
                ),
              ),
            IconButton(
              onPressed: _logout,
              icon: const Icon(Icons.logout),
              tooltip: 'Logout',
            ),
          ],
        ),
        body: loading
            ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Checking admin permissions...'),
                  ],
                ),
              )
            : !isAdmin
            ? _buildAccessDeniedView()
            : AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: currentTab == 0
                    ? _buildPendingView()
                    : currentTab == 1
                    ? _buildLogsView()
                    : _buildEmergencyLogsView(),
              ),
        bottomNavigationBar: isAdmin
            ? NavigationBar(
                selectedIndex: currentTab,
                onDestinationSelected: (index) =>
                    setState(() => currentTab = index),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.verified_user_outlined),
                    selectedIcon: Icon(Icons.verified_user),
                    label: 'Verifications',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.history_outlined),
                    selectedIcon: Icon(Icons.history),
                    label: 'Logs',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.warning_amber_outlined),
                    selectedIcon: Icon(Icons.warning),
                    label: 'Emergencies',
                  ),
                ],
              )
            : null,
      ),
    );
  }

  Widget _buildAccessDeniedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.lock_outline,
            size: 64,
            color: Colors.red,
          ).animate().fadeIn(duration: 600.ms),
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
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('Logout'),
          ).animate().slideY(begin: 0.2, end: 0, duration: 400.ms),
          const SizedBox(height: 8),
          TextButton(
            onPressed: checkAdminStatus,
            child: const Text('Retry Permission Check'),
          ),
        ],
      ),
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
            ).animate().fadeIn(duration: 600.ms),
          );
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final drivers = snapshot.data!.docs;
        if (drivers.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.check_circle, color: Colors.green, size: 48),
                const SizedBox(height: 16),
                const Text('No pending drivers'),
              ],
            ).animate().fadeIn(duration: 600.ms),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(8),
          itemCount: drivers.length,
          itemBuilder: (context, index) {
            final doc = drivers[index];
            final data = doc.data() as Map<String, dynamic>;

            return Card(
              margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Username: ${data['username'] ?? 'N/A'}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                        Chip(
                          label: const Text('PENDING'),
                          backgroundColor: Colors.orange,
                          labelStyle: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
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
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () =>
                                showImageDialog(data['licenseUrl'], 'License'),
                            icon: const Icon(Icons.description),
                            label: const Text('View License'),
                            style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => showImageDialog(
                              data['birthCertificateUrl'],
                              'CNIC',
                            ),
                            icon: const Icon(Icons.badge),
                            label: const Text('View CNIC'),
                            style: OutlinedButton.styleFrom(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
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
                        const SizedBox(width: 8),
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
            ).animate().slideX(
              begin: 0.1 * (index % 2 == 0 ? 1 : -1),
              end: 0,
              duration: 400.ms,
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
            ).animate().fadeIn(duration: 600.ms),
          );
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final logs = snapshot.data!.docs;
        if (logs.isEmpty) {
          return const Center(
            child: Text('No logs available'),
          ).animate().fadeIn(duration: 600.ms);
        }

        return ListView.builder(
          padding: const EdgeInsets.all(8),
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
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
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
            ).animate().fadeIn(duration: 400.ms, delay: (100 * index).ms);
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
            ).animate().fadeIn(duration: 600.ms),
          );
        }

        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final logs = snapshot.data!.docs;
        if (logs.isEmpty) {
          return const Center(
            child: Text('No emergency reports found.'),
          ).animate().fadeIn(duration: 600.ms);
        }

        return ListView.builder(
          padding: const EdgeInsets.all(8),
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
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
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
            ).animate().fadeIn(duration: 400.ms, delay: (100 * index).ms);
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
