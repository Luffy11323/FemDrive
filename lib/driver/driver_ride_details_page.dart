import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'driver_services.dart'
    show
        driverDashboardProvider,
        AppFields,
        RideStatus,
        DriverMapWidget,
        FeedbackDialog,
        DriverService,
        ridesLiveStream; // now exported by driver_services.dart

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

final riderInfoProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, riderId) async {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(riderId)
          .get();
      return snap.data();
    });

final _auth = FirebaseAuth.instance;

class DriverRideDetailsPage extends ConsumerStatefulWidget {
  final String rideId;

  const DriverRideDetailsPage({super.key, required this.rideId});

  @override
  ConsumerState<DriverRideDetailsPage> createState() =>
      _DriverRideDetailsPageState();
}

class _DriverRideDetailsPageState extends ConsumerState<DriverRideDetailsPage> {
  final _messageController = TextEditingController();

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
        if (doc == null || doc.id != widget.rideId) {
          return const Scaffold(body: Center(child: Text(RideStrings.noRide)));
        }

        final data = doc.data();
        if (data == null) {
          return const Scaffold(body: Center(child: Text(RideStrings.noRide)));
        }

        final riderId = data[AppFields.riderId] as String?;
        final riderInfo = riderId != null
            ? ref.watch(riderInfoProvider(riderId))
            : const AsyncValue.data(null);

        // Wrap UI with RTDB live status
        return StreamBuilder<Map<String, dynamic>?>(
          stream: ridesLiveStream(widget.rideId),
          builder: (context, snap) {
            final live = snap.data;
            final liveStatus =
                (live?['status'] as String?) ??
                (data[AppFields.status] as String?) ??
                RideStatus.inProgress;

            final isCompleted = liveStatus == RideStatus.completed;
            final isCancelled = liveStatus == RideStatus.cancelled;

            // Auto-close on terminal states (optional)
            if (isCompleted || isCancelled) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (Navigator.of(context).canPop()) Navigator.of(context).pop();
              });
            }

            return Scaffold(
              appBar: AppBar(
                title: Text(
                  'Ride: ${liveStatus.toUpperCase()}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              body: Column(
                children: [
                  Expanded(
                    child: DriverMapWidget(
                      rideData: {...data, 'rideId': widget.rideId},
                      onMapCreated: (_) {},
                      onStatusChange: (newStatus) {
                        ref
                            .read(driverDashboardProvider.notifier)
                            .updateStatus(widget.rideId, newStatus);
                      },
                      onComplete: () => _showCompletionDialog(
                        context,
                        widget.rideId,
                        riderId,
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
                              'From: ${data[AppFields.pickup] ?? '-'}',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                            Text(
                              'To: ${data[AppFields.dropoff] ?? '-'}',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                            Text(
                              'Fare: \$${data[AppFields.fare] is num ? (data[AppFields.fare] as num).toStringAsFixed(2) : '--'}',
                              style: Theme.of(context).textTheme.bodyLarge,
                            ),
                            riderInfo.when(
                              data: (info) => Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Rider Name: ${info?[AppFields.username] ?? '-'}',
                                  ),
                                  Text(
                                    'Rider Phone: ${info?[AppFields.phone] ?? '-'}',
                                  ),
                                ],
                              ),
                              loading: () => const CircularProgressIndicator(),
                              error: (e, _) =>
                                  Text('Failed to load rider info: $e'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (!isCompleted) _buildMessagingSection(),
                ],
              ),
              floatingActionButton: isCompleted
                  ? null
                  : _CancelRideButton(rideId: widget.rideId),
            );
          },
        );
      },
    );
  }

  Widget _buildMessagingSection() {
    final messages = ref.watch(messagesProvider(widget.rideId));
    return Expanded(
      child: Column(
        children: [
          Expanded(
            child: messages.when(
              data: (list) => ListView.builder(
                itemCount: list.length,
                itemBuilder: (ctx, i) {
                  final msg = list[i];
                  return ListTile(
                    title: Text(msg[AppFields.text]),
                    subtitle: Text(
                      msg[AppFields.senderId] == _auth.currentUser?.uid
                          ? 'You'
                          : 'Rider',
                    ),
                  );
                },
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) =>
                  Center(child: Text('Failed to load messages: $e')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: const InputDecoration(labelText: 'Message'),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: () {
                    if (_messageController.text.trim().isNotEmpty) {
                      ref
                          .read(driverDashboardProvider.notifier)
                          .sendMessage(
                            widget.rideId,
                            _messageController.text.trim(),
                          );
                      _messageController.clear();
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
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
                  riderId: riderId!,
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

final messagesProvider =
    StreamProvider.family<List<Map<String, dynamic>>, String>((ref, rideId) {
      return DriverService().listenMessages(rideId);
    });

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
