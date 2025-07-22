import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'driver_services.dart';

class DriverRideDetailsPage extends ConsumerStatefulWidget {
  const DriverRideDetailsPage({super.key});

  @override
  ConsumerState<DriverRideDetailsPage> createState() =>
      _DriverRideDetailsPageState();
}

class _DriverRideDetailsPageState extends ConsumerState<DriverRideDetailsPage> {
  bool _isCancelling = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(driverDashboardProvider);

    return state.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, st) {
        final errorMessage = e is FirebaseException
            ? 'Server error: ${e.message}'
            : 'Something went wrong. Please try again.';
        return Scaffold(body: Center(child: Text(errorMessage)));
      },
      data: (doc) {
        if (doc == null) {
          return const Scaffold(body: Center(child: Text('No active ride')));
        }

        final data = doc.data() as Map<String, dynamic>;
        final rideId = doc.id;
        final isCompleted = data['status'] == 'completed';

        return Scaffold(
          appBar: AppBar(title: const Text('Ride in progress')),
          body: DriverMapWidget(
            rideData: {...data, 'rideId': rideId},
            onMapCreated: (_) {},
            onStatusChange: (newStatus) {
              ref
                  .read(driverDashboardProvider.notifier)
                  .updateStatus(rideId, newStatus);
            },
            onComplete: () {
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Ride Completed'),
                  content: const Text('Confirm completion & rate rider?'),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context); // Close AlertDialog
                        Navigator.of(
                          context,
                        ).popUntil((r) => r.isFirst); // Back to home
                      },
                      child: const Text('Skip Rating'),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context); // Close AlertDialog
                        showDialog(
                          context: context,
                          builder: (_) => FeedbackDialog(
                            rideId: rideId,
                            onSubmitted: () {
                              Navigator.of(context).popUntil((r) => r.isFirst);
                            },
                          ),
                        );
                      },
                      child: const Text('Rate Rider'),
                    ),
                  ],
                ),
              );
            },
          ),
          floatingActionButton: isCompleted
              ? null
              : FloatingActionButton.extended(
                  onPressed: _isCancelling
                      ? null
                      : () async {
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Cancel Ride'),
                              content: const Text(
                                'Are you sure you want to cancel this ride?',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('No'),
                                ),
                                ElevatedButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Yes'),
                                ),
                              ],
                            ),
                          );

                          if (confirm != true) return;

                          setState(() => _isCancelling = true);
                          try {
                            await ref
                                .read(driverDashboardProvider.notifier)
                                .cancelRide(rideId);
                            ref.invalidate(
                              driverDashboardProvider,
                            ); // Reset provider
                            if (context.mounted) Navigator.of(context).pop();
                          } catch (e) {
                            final errorMsg = e is FirebaseException
                                ? 'Cancel failed: ${e.message}'
                                : 'Unable to cancel ride.';
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(errorMsg),
                                  backgroundColor: Colors.redAccent,
                                ),
                              );
                            }
                          } finally {
                            if (mounted) setState(() => _isCancelling = false);
                          }
                        },
                  label: _isCancelling
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Cancel Ride'),
                  icon: _isCancelling ? null : const Icon(Icons.cancel),
                  backgroundColor: Colors.redAccent,
                ),
        );
      },
    );
  }
}
