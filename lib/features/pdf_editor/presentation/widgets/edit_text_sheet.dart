import 'package:flutter/material.dart';

import '../../domain/editable_text_object.dart';
import '../../domain/pdf_engine.dart';

/// Wynik pracy w arkuszu edycji.
sealed class EditSheetResult {
  const EditSheetResult();
}

class ReplaceRequested extends EditSheetResult {
  const ReplaceRequested(this.newText);
  final String newText;
}

class DeleteRequested extends EditSheetResult {
  const DeleteRequested();
}

/// Arkusz edycji obiektu tekstowego.
///
/// Pole zawiera PELNA treść obiektu, bo tyle właśnie PDFium potrafi podmienić
/// jednym ruchem. Jesli użytkownik tapnął w konkretne słowo, jest ono wstępnie
/// zaznaczone — dzieki temu edycja jednego słowa jest wygodna, mimo ze
/// technicznie zapisujemy cały fragment.
class EditTextSheet extends StatefulWidget {
  const EditTextSheet({
    required this.target,
    required this.onCheckGlyphs,
    this.initialSelection,
    super.key,
  });

  final EditableTextObject target;
  final GlyphCoverageReport? Function(String newText) onCheckGlyphs;
  final TextRange? initialSelection;

  @override
  State<EditTextSheet> createState() => _EditTextSheetState();
}

class _EditTextSheetState extends State<EditTextSheet> {
  late final TextEditingController _controller;
  GlyphCoverageReport? _glyphReport;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.target.text);
    final selection = widget.initialSelection;
    if (selection != null) {
      _controller.selection =
          TextSelection(baseOffset: selection.start, extentOffset: selection.end);
    }
    _controller.addListener(_revalidate);
  }

  void _revalidate() {
    final report = widget.onCheckGlyphs(_controller.text);
    if (report?.riskyCharacters.toString() !=
        _glyphReport?.riskyCharacters.toString()) {
      setState(() => _glyphReport = report);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = widget.target;
    final risky = _glyphReport?.riskyCharacters ?? const <String>{};

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Edytuj tekst', style: theme.textTheme.titleMedium),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
                tooltip: 'Zamknij',
              ),
            ],
          ),
          Text(
            '${target.fontFamily.isEmpty ? "font nieznany" : target.fontFamily}'
            ' · ${target.fontSize.toStringAsFixed(1)} pt'
            '${target.isFontEmbedded ? " · font osadzony" : ""}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: null,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              labelText: 'Treść fragmentu',
            ),
          ),
          if (risky.isNotEmpty) ...[
            const SizedBox(height: 12),
            _WarningTile(
              message: 'Font tego fragmentu jest osadzony w dokumencie i może '
                  'nie zawierać znaków: ${risky.join(" ")}. Jesli po zapisie '
                  'znikna, trzeba będzie osadzic pelny font.',
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton.icon(
                onPressed: () =>
                    Navigator.of(context).pop(const DeleteRequested()),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Usuń'),
                style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.error),
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => Navigator.of(context)
                    .pop(ReplaceRequested(_controller.text)),
                child: const Text('Zatwierdź'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WarningTile extends StatelessWidget {
  const _WarningTile({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded,
              size: 20, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onTertiaryContainer, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
