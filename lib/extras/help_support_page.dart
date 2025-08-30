// help_center_page.dart

import 'package:flutter/material.dart';

class HelpCenterPage extends StatelessWidget {
  const HelpCenterPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Help Center')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Text(
            'Frequently Asked Questions',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 12),
          ExpansionTile(
            title: Text('How do I reset my password?'),
            children: [
              Padding(
                padding: EdgeInsets.all(8.0),
                child: Text(
                  'Go to the login screen and tap "Forgot Password".',
                ),
              ),
            ],
          ),
          ExpansionTile(
            title: Text('How do I contact support?'),
            children: [
              Padding(
                padding: EdgeInsets.all(8.0),
                child: Text('You can email us at support@femdrive.com.'),
              ),
            ],
          ),
          ExpansionTile(
            title: Text('How can I delete my account?'),
            children: [
              Padding(
                padding: EdgeInsets.all(8.0),
                child: Text(
                  'Please email us at delete@femdrive.com to request account deletion.',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
