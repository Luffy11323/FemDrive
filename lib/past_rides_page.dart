import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import 'theme.dart';
import 'main.dart'; // <-- Needed for userDocProvider

// Rider's ride history
final pastRidesProvider = StreamProvider<QuerySnapshot<Map<String, dynamic>>?>((
  ref,
) {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return Stream.value(null);
  return FirebaseFirestore.instance
      .collection('rides')
      .where('riderId', isEqualTo: user.uid)
      .orderBy('completedAt', descending: true)
      .snapshots();
});

// Driver's ride history
final driverPastRidesProvider =
    StreamProvider<QuerySnapshot<Map<String, dynamic>>?>((ref) {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return Stream.value(null);
      return FirebaseFirestore.instance
          .collection('rides')
          .where('driverId', isEqualTo: user.uid)
          .orderBy('completedAt', descending: true)
          .snapshots();
    });

class PastRidesPage extends ConsumerWidget {
  const PastRidesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final logger = Logger();

    // First, wait for user doc to load
    final userDocAsync = ref.watch(userDocProvider);

    return Theme(
      data: Theme.of(context).copyWith(
        colorScheme: femLightTheme.colorScheme,
        cardTheme: femLightTheme.cardTheme,
      ),
      child: Scaffold(
        appBar: AppBar(title: const Text('Ride History')),
        body: userDocAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Failed to load user info: $e')),
          data: (userDoc) {
            if (userDoc == null) {
              return const Center(child: Text('User info not available'));
            }

            final userData = userDoc.data() as Map<String, dynamic>?;
            final isDriver = userData?['role'] == 'driver';

            final ridesAsync = isDriver
                ? ref.watch(driverPastRidesProvider)
                : ref.watch(pastRidesProvider);

            return ridesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) {
                logger.e('Error loading rides: $e');
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('Error loading rides: $e'),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: () => ref.refresh(
                          isDriver
                              ? driverPastRidesProvider
                              : pastRidesProvider,
                        ),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                );
              },
              data: (snapshot) {
                if (snapshot == null || snapshot.docs.isEmpty) {
                  return const Center(
                    child: Text(
                      'No past rides found',
                      style: TextStyle(fontSize: 16),
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    // ignore: unused_result
                    ref.refresh(
                      isDriver ? driverPastRidesProvider : pastRidesProvider,
                    );
                    // Wait a short duration so RefreshIndicator shows properly
                    await Future.delayed(const Duration(milliseconds: 500));
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: snapshot.docs.length,
                    itemBuilder: (context, index) {
                      final ride = snapshot.docs[index].data();
                      final fare = (ride['fare'] as num?)?.toDouble() ?? 0.0;
                      final completedAt = (ride['completedAt'] as Timestamp?)
                          ?.toDate();
                      final status = (ride['status'] ?? 'unknown').toString();

                      return Card(
                        child: ListTile(
                          title: Text('${ride['pickup']} → ${ride['dropoff']}'),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Fare: \$${fare.toStringAsFixed(2)}'),
                              Text('Status: ${status.toUpperCase()}'),
                              if (completedAt != null)
                                Text(
                                  'Completed: ${_formatDateTime(completedAt)}',
                                ),
                              Text(
                                'Distance: ${(ride['distanceKm'] ?? 0).toStringAsFixed(2)} km',
                              ),
                            ],
                          ),
                          onTap: () {
                            showDialog(
                              context: context,
                              builder: (_) => AlertDialog(
                                title: const Text('Ride Receipt'),
                                content: SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Ride ID: ${snapshot.docs[index].id}',
                                      ),
                                      Text('From: ${ride['pickup']}'),
                                      Text('To: ${ride['dropoff']}'),
                                      Text(
                                        'Fare: \$${fare.toStringAsFixed(2)}',
                                      ),
                                      Text('Status: ${status.toUpperCase()}'),
                                      if (completedAt != null)
                                        Text(
                                          'Completed: ${_formatDateTime(completedAt)}',
                                        ),
                                      Text(
                                        'Distance: ${(ride['distanceKm'] ?? 0).toStringAsFixed(2)} km',
                                      ),
                                      Text(
                                        'Ride Type: ${ride['rideType'] ?? 'Unknown'}',
                                      ),
                                      Text(
                                        'Payment: ${ride['paymentMethod'] ?? 'Unknown'}',
                                      ),
                                    ],
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('Close'),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ).animate().fadeIn(
                        duration: 400.ms,
                        delay: (100 * index).ms,
                      );
                    },
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${_twoDigits(dt.month)}-${_twoDigits(dt.day)} '
        '${_twoDigits(dt.hour)}:${_twoDigits(dt.minute)}';
  }

  String _twoDigits(int n) => n.toString().padLeft(2, '0');
}
