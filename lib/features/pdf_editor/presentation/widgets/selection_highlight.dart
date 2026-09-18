import 'package:flutter/material.dart';

/// Rysuje ramkę wokół wybranego obiektu tekstowego.
///
/// Podświetlamy cały obiekt, a nie pojedyncze słowo, bo to jest realna
/// jednostka edycji w PDF — użytkownik powinien od razu widzieć, czego
/// dotyczy zmiana.
class SelectionHighlight extends StatelessWidget {
  const SelectionHighlight({required this.rect, super.key});

  final Rect rect;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Positioned.fromRect(
      rect: rect.inflate(2),
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            border: Border.all(color: color, width: 1.5),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}
