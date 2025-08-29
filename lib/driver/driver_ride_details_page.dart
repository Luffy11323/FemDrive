import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'driver_services.dart';

class RideStrings {
  static const noRide = 'No active ride';
  static const inProgress = 'Ride in progress';
  static const cancelTitle = 'Cancel Ride';
  static const cancelMessage = 'Are you sure you want to cancel this ride?';
  static const cancelNo = 'No';
  static const cancelYes = 'Yes';
  static const cancelRide = 'Cancel Ride';
  static const rideCompleted = 'Ride Completed';
  static const confirmCompletion = 'Confirm completion & rate rider?';
  static const skipRating = 'Skip Rating';
  static const rateRider = 'Rate Rider';
  static const errorGeneric = 'Something went wrong. Please try again.';
}

class DriverRideDetailsPage extends ConsumerWidget {
  final String rideId;

  const DriverRideDetailsPage({super.key, required this.rideId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(driverDashboardProvider);

    return state.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, st) {
        final errorMessage = e is FirebaseException
            ? 'Server error: ${e.message}'
            : RideStrings.errorGeneric;
        return Scaffold(body: Center(child: Text(errorMessage)));
      },
      data: (doc) {
        if (doc == null || doc.id != rideId) {
          return const Scaffold(body: Center(child: Text(RideStrings.noRide)));
        }

        final data = doc.data();
        if (data == null) {
          return const Scaffold(body: Center(child: Text(RideStrings.noRide)));
        }

        final isCompleted = data['status'] == RideStatus.completed;

        return Scaffold(
          appBar: AppBar(
            title: Text(
              'Ride: ${data['status']?.toString().toUpperCase() ?? 'IN PROGRESS'}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          body: Column(
            children: [
              Expanded(
                child: DriverMapWidget(
                  rideData: {...data, 'rideId': rideId},
                  onMapCreated: (_) {},
                  onStatusChange: (newStatus) {
                    ref
                        .read(driverDashboardProvider.notifier)
                        .updateStatus(rideId, newStatus);
                  },
                  onComplete: () => _showCompletionDialog(
                    context,
                    rideId,
                    data['riderId'] as String?,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'From: ${data['pickup'] ?? '-'}',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        Text(
                          'To: ${data['dropoff'] ?? '-'}',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        Text(
                          'Fare: \$${data['fare'] is num ? (data['fare'] as num).toStringAsFixed(2) : '--'}',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        Text(
                          'Rider: ${data['riderId'] ?? '-'}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          floatingActionButton: isCompleted
              ? null
              : _CancelRideButton(rideId: rideId),
        );
      },
    );
  }

  void _showCompletionDialog(
    BuildContext context,
    String rideId,
    String? riderId,
  ) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text(RideStrings.rideCompleted),
        content: const Text(RideStrings.confirmCompletion),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
            child: const Text(RideStrings.skipRating),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              showDialog(
                context: context,
                builder: (_) => FeedbackDialog(
                  rideId: rideId,
                  riderId: riderId,
                  onSubmitted: () {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                  },
                ),
              );
            },
            child: const Text(RideStrings.rateRider),
          ),
        ],
      ),
    );
  }
}

class FeedbackDialog extends StatefulWidget {
  final String rideId;
  final String? riderId;
  final VoidCallback onSubmitted;

  const FeedbackDialog({
    super.key,
    required this.rideId,
    required this.onSubmitted,
    this.riderId,
  });

  @override
  State<FeedbackDialog> createState() => _FeedbackDialogState();
}

class _FeedbackDialogState extends State<FeedbackDialog> {
  final TextEditingController comment = TextEditingController();
  double rating = 4;
  bool isSubmitting = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rate This Ride'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Slider(
            min: 1,
            max: 5,
            divisions: 4,
            value: rating,
            onChanged: (v) => setState(() => rating = v),
            label: rating.toString(),
          ),
          TextField(
            controller: comment,
            decoration: const InputDecoration(labelText: 'Comments'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: isSubmitting
              ? null
              : () async {
                  if (comment.text.trim().isEmpty) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Please enter a comment')),
                      );
                    }
                    return;
                  }

                  setState(() => isSubmitting = true);
                  try {
                    final user = FirebaseAuth.instance.currentUser;
                    if (user == null) {
                      throw FirebaseAuthException(
                        code: 'no-user',
                        message: 'No authenticated user.',
                      );
                    }
                    await FirebaseFirestore.instance
                        .collection(AppPaths.ratingsCollection)
                        .add({
                          'rideId': widget.rideId,
                          'fromUid': user.uid,
                          'toUid': widget.riderId ?? '',
                          'rating': rating,
                          'comment': comment.text.trim(),
                          'createdAt': FieldValue.serverTimestamp(),
                        });

                    if (!mounted) return;
                    // ignore: use_build_context_synchronously
                    Navigator.of(context).pop();
                    widget.onSubmitted();
                    if (mounted) {
                      // ignore: use_build_context_synchronously
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Thank you for your feedback!'),
                        ),
                      );
                    }
                  } catch (e) {
                    if (mounted) {
                      // ignore: use_build_context_synchronously
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('Failed to submit feedback: $e'),
                        ),
                      );
                    }
                  } finally {
                    if (mounted) setState(() => isSubmitting = false);
                  }
                },
          child: isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(),
                )
              : const Text('Submit'),
        ),
      ],
    );
  }
}

final cancelRideProvider =
    AutoDisposeAsyncNotifierProviderFamily<_CancelRideNotifier, void, String>(
      _CancelRideNotifier.new,
    );

class _CancelRideNotifier extends AutoDisposeFamilyAsyncNotifier<void, String> {
  @override
  Future<void> build(String rideId) async {}

  Future<void> cancel(String rideId) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref.read(driverDashboardProvider.notifier).cancelRide(rideId),
    );
  }
}

class _CancelRideButton extends ConsumerWidget {
  final String rideId;
  const _CancelRideButton({required this.rideId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isCancelling = ref.watch(cancelRideProvider(rideId)).isLoading;

    return FloatingActionButton.extended(
      onPressed: isCancelling
          ? null
          : () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text(RideStrings.cancelTitle),
                  content: const Text(RideStrings.cancelMessage),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text(RideStrings.cancelNo),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text(RideStrings.cancelYes),
                    ),
                  ],
                ),
              );
              if (confirm != true) return;

              await ref
                  .read(cancelRideProvider(rideId).notifier)
                  .cancel(rideId);
              if (context.mounted) Navigator.of(context).pop();
            },
      label: isCancelling
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text(RideStrings.cancelRide),
      icon: isCancelling ? null : const Icon(Icons.cancel),
      backgroundColor: Colors.redAccent,
    );
  }
}
