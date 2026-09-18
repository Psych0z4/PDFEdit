import 'package:flutter/material.dart';

import '../../../app/di.dart';
import '../../../shared/services/document_picker_service.dart';
import '../../pdf_editor/application/editor_controller.dart';
import '../../pdf_editor/presentation/pdf_editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _opening = false;
  String? _error;

  Future<void> _openPdf() async {
    setState(() {
      _opening = true;
      _error = null;
    });

    final picked = await locator<DocumentPickerService>().pickPdf();
    final document = picked.valueOrNull;

    if (!mounted) return;
    setState(() => _opening = false);

    if (picked.failureOrNull != null) {
      setState(() => _error = picked.failureOrNull!.message);
      return;
    }
    if (document == null) return; // użytkownik anulowal

    final controller = locator<EditorController>();
    await controller.openPicked(document);

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PdfEditorScreen(controller: controller),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.edit_document,
                      size: 64, color: theme.colorScheme.primary),
                  const SizedBox(height: 24),
                  Text(
                    'Edytor PDF',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Otwórz dokument, tapnij w tekst i zmień jego treść. '
                    'Zmiany zapisują się do nowego pliku — oryginał zostaje nietknięty.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: _opening ? null : _openPdf,
                    icon: _opening
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.folder_open),
                    label: Text(_opening ? 'Otwieram...' : 'Otwórz PDF'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
