import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class PastRidesPage extends StatelessWidget {
  const PastRidesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      appBar: AppBar(title: const Text('Past Rides')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('rides')
            .where('riderId', isEqualTo: uid)
            .where('status', whereIn: ['completed', 'cancelled'])
            .orderBy('createdAt', descending: true)
            .snapshots(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }
          if (!snap.hasData || snap.data!.docs.isEmpty) {
            return const Center(child: Text('No past rides found.'));
          }

          final rides = snap.data!.docs;

          return ListView.builder(
            itemCount: rides.length,
            itemBuilder: (context, index) {
              final ride = rides[index];
              final pickup = ride['pickup'];
              final dropoff = ride['dropoff'];
              final fare = ride['rate'];
              final status = ride['status'];
              final time = ride['createdAt']?.toDate();

              return Card(
                margin: const EdgeInsets.all(10),
                child: ListTile(
                  leading: Icon(
                    status == 'completed' ? Icons.check_circle : Icons.cancel,
                    color: status == 'completed' ? Colors.green : Colors.red,
                  ),
                  title: Text('$pickup ➝ $dropoff'),
                  subtitle: Text(
                    time?.toLocal().toString().split('.')[0] ?? 'Unknown',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: Text('\$${fare.toStringAsFixed(2)}'),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
