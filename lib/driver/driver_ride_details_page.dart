import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_animate/flutter_animate.dart';
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

final riderInfoProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>?, String>((ref, riderId) async {
  try {
    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(riderId)
        .get()
        .timeout(const Duration(seconds: 5));
    return snap.data();
  } catch (e) {
    debugPrint('Rider info error: $e');
    return null;
  }
});

final messagesProvider =
    StreamProvider.family<List<Map<String, dynamic>>, String>((ref, rideId) {
  return DriverService().listenMessages(rideId);
});

final _auth = FirebaseAuth.instance;

class DriverRideDetailsPage extends ConsumerStatefulWidget {
  final String rideId;
  const DriverRideDetailsPage({super.key, required this.rideId});
  @override
  ConsumerState<DriverRideDetailsPage> createState() => _DriverRideDetailsPageState();
}

class _DriverRideDetailsPageState extends ConsumerState<DriverRideDetailsPage> {
  final _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  void _openContactRiderSheet({
    required BuildContext context,
    required Map<String, dynamic> rideData,
    required String? riderId,
  }) {
    if (riderId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rider ID unavailable')),
      );
      return;
    }
    // Mark messages as read when opening chat
    ref.read(driverDashboardProvider.notifier).markMessagesAsRead(widget.rideId, _auth.currentUser!.uid);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        final messages = ref.watch(messagesProvider(widget.rideId));
        final riderInfo = ref.watch(riderInfoProvider(riderId));
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
                riderInfo.when(
                  data: (info) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${rideData[AppFields.pickup] ?? '-'} → ${rideData[AppFields.dropoff] ?? '-'}',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Fare: \$${rideData[AppFields.fare] is num ? (rideData[AppFields.fare] as num).toStringAsFixed(2) : '--'}',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      Text(
                        'Rider: ${info?[AppFields.username] ?? 'Unknown'}',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      Text(
                        'Phone: ${info?[AppFields.phone] ?? 'N/A'}',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const Divider(height: 20),
                    ],
                  ).animate().fadeIn(duration: 300.ms),
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => const Text('Failed to load rider info'),
                ),
                Expanded(
                  child: messages.when(
                    data: (list) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (_scrollController.hasClients) {
                          _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
                        }
                      });
                      return ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        itemCount: list.length,
                        itemBuilder: (ctx, i) {
                          final msg = list[i];
                          final mine = msg[AppFields.senderId] == _auth.currentUser?.uid;
                          final rawTs = msg[AppFields.timestamp];
                          final timestamp = rawTs is Timestamp
                              ? rawTs.toDate()
                              : rawTs is int
                                  ? DateTime.fromMillisecondsSinceEpoch(rawTs)
                                  : null;

                          return Align(
                            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                              padding: const EdgeInsets.all(12),
                              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                              decoration: BoxDecoration(
                                color: mine
                                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.8)
                                    : Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(12).copyWith(
                                  topLeft: mine ? const Radius.circular(12) : Radius.zero,
                                  topRight: mine ? Radius.zero : const Radius.circular(12),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    msg[AppFields.text] ?? '',
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                  if (timestamp != null)
                                    Text(
                                      timestamp.toString().substring(11, 16),
                                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                                    ),
                                  if (msg[AppFields.read] == true && mine)
                                    Text(
                                      'Read',
                                      style: TextStyle(fontSize: 10, color: Colors.blue.shade300),
                                    ),
                                ],
                              ),
                            ),
                          ).animate().slideY(begin: 0.2, end: 0, duration: 200.ms);
                        },
                      );
                    },
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(child: Text('Failed to load messages: $e')),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _messageController,
                        decoration: InputDecoration(
                          hintText: 'Write a message…',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FloatingActionButton(
                      mini: true,
                      onPressed: () async {
                        final t = _messageController.text.trim();
                        if (t.isEmpty) return;
                        try {
                          await ref.read(driverDashboardProvider.notifier).sendMessage(
                                widget.rideId,
                                t,
                                _auth.currentUser!.uid,
                              );
                          _messageController.clear();
                          // ignore: use_build_context_synchronously
                          FocusScope.of(context).unfocus();
                        } catch (e) {
                          // ignore: use_build_context_synchronously
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Failed to send message: $e')),
                          );
                        }
                      },
                      child: const Icon(Icons.send),
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

            // --- paste-ready replacement for the whole `return Scaffold(...)` block ---
            return Scaffold(
              appBar: AppBar(
                title: Text(
                  'Ride: ${liveStatus.toUpperCase()}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              // 👇 Only the map page; info/chat is opened from "Contact rider"
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
