import 'package:flutter/material.dart';

/// Proste okno wpisania nowego tekstu po wskazaniu miejsca na stronie.
class AddTextDialog extends StatefulWidget {
  const AddTextDialog({super.key});

  @override
  State<AddTextDialog> createState() => _AddTextDialogState();
}

class _AddTextDialogState extends State<AddTextDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Dodaj tekst'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Treść',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Nowy tekst używa wbudowanego fontu Helvetica, który nie zawiera '
            'polskich znaków diakrytycznych.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Anuluj'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Dodaj'),
        ),
      ],
    );
  }
}
