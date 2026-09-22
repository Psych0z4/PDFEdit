import 'dart:async';

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
/// Pole zawiera PEŁNĄ treść obiektu, bo tyle właśnie PDFium potrafi podmienić
/// jednym ruchem. Jeśli użytkownik tapnął w konkretne słowo, jest ono wstępnie
/// zaznaczone — dzięki temu edycja jednego słowa jest wygodna, mimo że
/// technicznie zapisujemy cały fragment.
class EditTextSheet extends StatefulWidget {
  const EditTextSheet({
    required this.target,
    required this.onCheckGlyphs,
    this.initialSelection,
    super.key,
  });

  final EditableTextObject target;

  /// Sprawdzenie pokrycia znaków. Wywołanie schodzi do PDFium, więc jest
  /// asynchroniczne i wywoływane z opóźnieniem po zakończeniu pisania.
  final Future<GlyphCoverageReport?> Function(String newText) onCheckGlyphs;

  final TextRange? initialSelection;

  @override
  State<EditTextSheet> createState() => _EditTextSheetState();
}

class _EditTextSheetState extends State<EditTextSheet> {
  static const _debounce = Duration(milliseconds: 350);

  late final TextEditingController _controller;
  Timer? _timer;
  GlyphCoverageReport? _report;
  bool _checking = false;

  /// Rośnie przy każdym sprawdzeniu — pozwala odrzucić wynik, który wrócił
  /// już po kolejnej zmianie tekstu.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.target.text);
    final selection = widget.initialSelection;
    if (selection != null) {
      _controller.selection = TextSelection(
        baseOffset: selection.start,
        extentOffset: selection.end,
      );
    }
    _controller.addListener(_scheduleCheck);
  }

  void _scheduleCheck() {
    _timer?.cancel();
    _timer = Timer(_debounce, _runCheck);
  }

  Future<void> _runCheck() async {
    final id = ++_requestId;
    final text = _controller.text;
    setState(() => _checking = true);

    final report = await widget.onCheckGlyphs(text);

    if (!mounted || id != _requestId) return;
    setState(() {
      _report = report;
      _checking = false;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = widget.target;
    final unsupported = _report?.unsupported ?? const <String>{};
    final hasProblems = unsupported.isNotEmpty;

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
              if (_checking)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
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
            '${target.isFontEmbedded ? " · osadzony w dokumencie" : ""}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: null,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Treść fragmentu',
              errorText: hasProblems ? 'Font nie zawiera części znaków' : null,
            ),
          ),
          if (hasProblems) ...[
            const SizedBox(height: 12),
            _MissingGlyphsWarning(characters: unsupported),
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
                style: hasProblems
                    ? FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      )
                    : null,
                child: Text(hasProblems ? 'Zatwierdź mimo to' : 'Zatwierdź'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Lista znaków, których font nie potrafi narysować.
///
/// Pokazujemy konkretne znaki, a nie ogólnikowe ostrzeżenie, bo to jedyna
/// informacja, na podstawie której użytkownik może zdecydować, czy zmiana
/// ma sens.
class _MissingGlyphsWarning extends StatelessWidget {
  const _MissingGlyphsWarning({required this.characters});

  final Set<String> characters;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.report_gmailerrorred,
                  size: 20, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Font tego fragmentu nie zawiera tych znaków. '
                  'Po zapisie nie pojawią się w dokumencie:',
                  style:
                      TextStyle(color: scheme.onErrorContainer, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final char in characters)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: scheme.onErrorContainer.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    char,
                    style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
