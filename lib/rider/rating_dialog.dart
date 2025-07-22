import 'package:flutter/material.dart';

class RatingDialog extends StatefulWidget {
  final Function(int rating, String comment) onSubmit;
  const RatingDialog({required this.onSubmit, super.key});

  @override
  State<RatingDialog> createState() => _RatingDialogState();
}

class _RatingDialogState extends State<RatingDialog> {
  int rating = 0;
  final commentCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rate Your Driver'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(5, (i) {
              return IconButton(
                icon: Icon(
                  i < rating ? Icons.star : Icons.star_border,
                  color: Colors.amber,
                ),
                onPressed: () => setState(() => rating = i + 1),
              );
            }),
          ),
          TextField(
            controller: commentCtrl,
            decoration: const InputDecoration(labelText: 'Comment'),
            maxLines: 2,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Skip'),
        ),
        ElevatedButton(
          onPressed: () {
            widget.onSubmit(rating, commentCtrl.text.trim());
            Navigator.pop(context);
          },
          child: const Text('Submit'),
        ),
      ],
    );
  }
}
