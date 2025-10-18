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
        ridesLiveStream;

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
  static const messageEmpty = 'Message cannot be empty';
  static const messageSendFailed = 'Failed to send message';
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

class _DriverRideDetailsPageState extends ConsumerState<DriverRideDetailsPage>
    with TickerProviderStateMixin {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  bool _isSending = false;

  void _openContactRiderSheet({
    required BuildContext context,
    required Map<String, dynamic> rideData,
    required String? riderId,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        final messages = ref.watch(messagesProvider(widget.rideId));
        final riderInfo = riderId != null
            ? ref.watch(riderInfoProvider(riderId))
            : const AsyncValue.data(null);

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          minChildSize: 0.35,
          maxChildSize: 0.95,
          builder: (_, controller) => Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Ride + rider quick info
                riderInfo.when(
                  data: (info) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${rideData[AppFields.pickup] ?? '-'} → ${rideData[AppFields.dropoff] ?? '-'}',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Fare: \$${rideData[AppFields.fare] is num ? (rideData[AppFields.fare] as num).toStringAsFixed(2) : '--'}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Rider: ${info?[AppFields.username] ?? '-'}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      Text(
                        'Phone: ${info?[AppFields.phone] ?? '-'}',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const Divider(height: 20),
                    ],
                  ),
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => Text(
                    'Rider info failed: $e',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                  ),
                ),

                // Messages list
                Expanded(
                  child: messages.when(
                    data: (list) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (_scrollController.hasClients) {
                          _scrollController.animateTo(
                            _scrollController.position.maxScrollExtent,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut,
                          );
                        }
                      });
                      return ListView.builder(
                        controller: _scrollController,
                        itemCount: list.length,
                        itemBuilder: (ctx, i) {
                          final msg = list[i];
                          final mine =
                              msg[AppFields.senderId] == _auth.currentUser?.uid;
                          return Align(
                            alignment: mine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: FadeTransition(
                              opacity: CurvedAnimation(
                                parent: AnimationController(
                                  duration: const Duration(milliseconds: 300),
                                  vsync: this,
                                  value: 1.0,
                                ),
                                curve: Curves.easeIn,
                              ),
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                    vertical: 4, horizontal: 8),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: mine
                                      ? Theme.of(context)
                                          .colorScheme
                                          .primary
                                          .withValues(alpha: 0.1)
                                      : Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.05),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: mine
                                      ? CrossAxisAlignment.end
                                      : CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      msg[AppFields.text] ?? '',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      _formatTimestamp(
                                          msg[AppFields.timestamp] as int?),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant
                                                .withValues(alpha: 0.6),
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(
                      child: Text(
                        'Failed to load messages: $e',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.error,
                            ),
                      ),
                    ),
                  ),
                ),

                // Composer
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        decoration: InputDecoration(
                          hintText: 'Write a message…',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          filled: true,
                          fillColor:
                              Theme.of(context).colorScheme.surfaceContainerHighest,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                        ),
                        maxLines: 3,
                        minLines: 1,
                        enabled: !_isSending,
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: _isSending
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              Icons.send,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      onPressed: _isSending
                          ? null
                          : () async {
                              final text = _messageController.text.trim();
                              if (text.isEmpty) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content:
                                          Text(RideStrings.messageEmpty)),
                                );
                                return;
                              }

                              setState(() => _isSending = true);
                              try {
                                await ref
                                    .read(driverDashboardProvider.notifier)
                                    .sendMessage(widget.rideId, text);
                                _messageController.clear();
                              } catch (e) {
                                if (mounted) {
                                  // ignore: use_build_context_synchronously
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content: Text(
                                            '${RideStrings.messageSendFailed}: $e')),
                                  );
                                }
                              } finally {
                                if (mounted) setState(() => _isSending = false);
                              }
                            },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatTimestamp(int? timestamp) {
    if (timestamp == null) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${date.hour}:${date.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
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

            if (isCompleted || isCancelled) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (Navigator.of(context).canPop()) Navigator.of(context).pop();
              });
            }

            return Scaffold(
              appBar: AppBar(
                title: Text(
                  'Ride: ${liveStatus.toUpperCase()}',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                ),
                backgroundColor: Theme.of(context).colorScheme.surface,
                elevation: 1,
              ),
              body: DriverMapWidget(
                rideData: {...data, 'rideId': widget.rideId},
                onMapCreated: (_) {},
                onStatusChange: (newStatus) {
                  ref
                      .read(driverDashboardProvider.notifier)
                      .updateStatus(widget.rideId, newStatus);
                },
                onComplete: () =>
                    _showCompletionDialog(context, widget.rideId, riderId),
                onContactRider: () => _openContactRiderSheet(
                  context: context,
                  rideData: data,
                  riderId: riderId,
                ),
              ),
            );
          },
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
        title: Text(
          RideStrings.rideCompleted,
          style: Theme.of(context).textTheme.titleLarge,
        ),
        content: Text(
          RideStrings.confirmCompletion,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
            child: Text(
              RideStrings.skipRating,
              style: Theme.of(context).textTheme.labelLarge,
            ),
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
            child: Text(
              RideStrings.rateRider,
              style: Theme.of(context).textTheme.labelLarge,
            ),
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

// ignore: unused_element
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
                  title: Text(
                    RideStrings.cancelTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  content: Text(
                    RideStrings.cancelMessage,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(
                        RideStrings.cancelNo,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(
                        RideStrings.cancelYes,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
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
      backgroundColor: Theme.of(context).colorScheme.error,
    );
  }
}