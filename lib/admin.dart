import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
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

  @override
  void initState() {
    super.initState();
    checkAdminStatus();
  }

  Future<void> checkAdminStatus() async {
    final user = FirebaseAuth.instance.currentUser;
    final token = await user?.getIdTokenResult();
    final admin = token?.claims?['admin'] == true;
    setState(() {
      isAdmin = admin;
      loading = false;
    });
  }

  Future<void> updateDriverStatus(
    String uid,
    String status, {
    String? reason,
  }) async {
    final updates = {'status': status};
    if (reason != null && reason.isNotEmpty) {
      updates['rejectionReason'] = reason;
    }

    await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .update(updates);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Driver marked as $status')));
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
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!isAdmin) {
      return const Scaffold(
        body: Center(child: Text('Access Denied: Admins Only')),
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
          PopupMenuButton<int>(
            onSelected: (value) => setState(() => currentTab = value),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0, child: Text('Verifications')),
              PopupMenuItem(value: 1, child: Text('Logs')),
              PopupMenuItem(value: 2, child: Text('Emergencies')),
            ],
            icon: const Icon(Icons.menu),
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
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final drivers = snapshot.data!.docs;
        if (drivers.isEmpty) {
          return const Center(child: Text('No pending drivers'));
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
                    Text('Username: ${data['username']}'),
                    Text('Car Model: ${data['carModel'] ?? 'N/A'}'),
                    Text('Phone: ${data['phone']}'),
                    if (data.containsKey('rating'))
                      Text('Avg Rating: ${data['rating'].toStringAsFixed(1)}'),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () =>
                                showImageDialog(data['licenseUrl'], 'License'),
                            child: const Text('View License'),
                          ),
                        ),
                        Expanded(
                          child: TextButton(
                            onPressed: () => showImageDialog(
                              data['birthCertificateUrl'],
                              'CNIC',
                            ),
                            child: const Text('View CNIC'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () =>
                                updateDriverStatus(doc.id, 'approved'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                            ),
                            child: const Text('Approve'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => showRejectionDialog(doc.id),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                            ),
                            child: const Text('Reject'),
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

            return ListTile(
              leading: Icon(
                status == 'approved' ? Icons.check_circle : Icons.cancel,
                color: status == 'approved' ? Colors.green : Colors.red,
              ),
              title: Text('Driver: ${doc['driverId']}'),
              subtitle: Text('Status: $status\nReason: $reason\nAt: $dateStr'),
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

            return ListTile(
              leading: const Icon(Icons.warning, color: Colors.red),
              title: Text('Ride ID: ${data['rideId']}'),
              subtitle: Text(
                'Reported By: ${data['reportedBy']}\n'
                'Against: ${data['otherUid']}\n'
                'At: $timestamp',
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
        content: Image.network(
          url,
          errorBuilder: (_, _, _) => const Text("Image not found"),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final uri = Uri.parse(url);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri);
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
