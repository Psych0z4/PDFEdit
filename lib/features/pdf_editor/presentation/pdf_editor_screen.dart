import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../application/editor_controller.dart';
import '../domain/editable_text_object.dart';
import 'page_coordinate_mapper.dart';
import 'widgets/add_text_dialog.dart';
import 'widgets/edit_text_sheet.dart';
import 'widgets/selection_highlight.dart';

class PdfEditorScreen extends StatefulWidget {
  const PdfEditorScreen({required this.controller, super.key});

  final EditorController controller;

  @override
  State<PdfEditorScreen> createState() => _PdfEditorScreenState();
}

class _PdfEditorScreenState extends State<PdfEditorScreen> {
  final _viewerController = PdfViewerController();
  String? _lastNotice;

  EditorController get _controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        _showNoticeIfAny();
        final path = _controller.currentPath;

        return Scaffold(
          appBar: AppBar(
            title: Text(
              _controller.displayName,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                onPressed: _controller.canUndo ? _controller.undo : null,
                icon: const Icon(Icons.undo),
                tooltip: 'Cofnij',
              ),
              IconButton(
                onPressed: _controller.canRedo ? _controller.redo : null,
                icon: const Icon(Icons.redo),
                tooltip: 'Ponów',
              ),
              PopupMenuButton<String>(
                onSelected: (value) => switch (value) {
                  'save' => _controller.saveAs(),
                  'share' => _controller.share(),
                  _ => null,
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'save', child: Text('Zapisz jako...')),
                  PopupMenuItem(value: 'share', child: Text('Udostępnij')),
                ],
              ),
            ],
          ),
          body: switch (_controller.status) {
            EditorStatus.loading =>
              const Center(child: CircularProgressIndicator()),
            EditorStatus.error => _ErrorView(
                message: _controller.failure?.message ?? 'Nieznany błąd.',
              ),
            EditorStatus.idle => const SizedBox.shrink(),
            EditorStatus.ready when path != null => Column(
                children: [
                  if (_controller.isScanned) const _ScannedBanner(),
                  Expanded(child: _buildViewer(path)),
                ],
              ),
            EditorStatus.ready => const SizedBox.shrink(),
          },
          bottomNavigationBar: _controller.status == EditorStatus.ready
              ? _buildToolbar()
              : null,
        );
      },
    );
  }

  Widget _buildViewer(String path) {
    return Stack(
      children: [
        PdfViewer.file(
          path,
          // Klucz zmienia się razem ze ścieżka rewizji, więc po kazdej
          // zatwierdzonej edycji viewer wczytuje nowy plik od zera.
          key: ValueKey(path),
          controller: _viewerController,
          params: PdfViewerParams(
            // Wlasny model interakcji: tapnięcie = wybór obiektu do edycji.
            // Natywne zaznaczanie tekstu tylko by z nim konkurowało.
            textSelectionParams: const PdfTextSelectionParams(enabled: false),
            onPageChanged: (pageNumber) {
              if (pageNumber != null) _controller.changePage(pageNumber);
            },
            pageOverlaysBuilder: _buildPageOverlays,
          ),
        ),
        if (_controller.busy)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x33000000),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  List<Widget> _buildPageOverlays(
      BuildContext context, Rect pageRect, PdfPage page) {
    // Strony obrocone wymagałyby dodatkowej transformacji współrzędnych.
    // Zamiast po cichu wstawiać edycję w złym miejscu, wyłączamy tu edycję.
    if (page.rotation != PdfPageRotation.none) {
      return const [
        Positioned(
          left: 8,
          top: 8,
          child: _RotatedPageBadge(),
        ),
      ];
    }

    final mapper = PageCoordinateMapper.forPage(page, pageRect.size);
    final selected = _controller.selected;

    return [
      Positioned.fill(
        child: PdfOverlayInteractionRegion(
          onTap: (details) {
            _handleTap(page.pageNumber, mapper, details.localPosition);
            return true;
          },
          child: const SizedBox.expand(),
        ),
      ),
      if (selected != null && selected.pageIndex == page.pageNumber - 1)
        SelectionHighlight(rect: mapper.toDisplayRect(selected)),
    ];
  }

  Future<void> _handleTap(
    int pageNumber,
    PageCoordinateMapper mapper,
    Offset localPosition,
  ) async {
    final pdfPoint = mapper.toPdf(localPosition);

    if (pageNumber != _controller.currentPage) {
      await _controller.changePage(pageNumber);
    }

    if (_controller.mode == EditorMode.addText) {
      await _promptAddText(pageNumber - 1, pdfPoint);
      return;
    }

    if (!_controller.canEditText) return;

    _controller.selectAt(
      pdfPoint.dx,
      pdfPoint.dy,
      tolerance: mapper.toleranceInPdfUnits(12),
    );

    final selected = _controller.selected;
    if (selected != null && mounted) {
      await _openEditSheet(selected, pdfPoint, mapper);
    }
  }

  Future<void> _openEditSheet(
    EditableTextObject target,
    Offset pdfPoint,
    PageCoordinateMapper mapper,
  ) async {
    final result = await showModalBottomSheet<EditSheetResult>(
      context: context,
      isScrollControlled: true,
      builder: (context) => EditTextSheet(
        target: target,
        initialSelection: _guessTappedWord(target, pdfPoint),
        onCheckGlyphs: _controller.checkGlyphs,
      ),
    );

    switch (result) {
      case ReplaceRequested(:final newText):
        await _controller.replaceSelectedText(newText);
      case DeleteRequested():
        await _controller.deleteSelected();
      case null:
        _controller.clearSelection();
    }
  }

  /// Szacuje, które słowo obiektu zostało tapnięte.
  ///
  /// PDFium nie mówi, gdzie kończy się który znak w obrębie obiektu, więc
  /// przybliżamy to proporcją szerokości. Wystarcza, żeby wstępnie zaznaczyc
  /// słowo w polu edycji — użytkownik i tak widzi cały fragment.
  TextRange? _guessTappedWord(EditableTextObject target, Offset pdfPoint) {
    if (target.width <= 0 || target.text.isEmpty) return null;
    final ratio = ((pdfPoint.dx - target.left) / target.width).clamp(0.0, 1.0);
    final approxIndex = (ratio * target.text.length).floor();

    var start = approxIndex;
    var end = approxIndex;
    while (start > 0 && target.text[start - 1].trim().isNotEmpty) {
      start--;
    }
    while (end < target.text.length && target.text[end].trim().isNotEmpty) {
      end++;
    }
    if (start >= end) return null;
    return TextRange(start: start, end: end);
  }

  Future<void> _promptAddText(int pageIndex, Offset pdfPoint) async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => const AddTextDialog(),
    );
    if (text == null || text.trim().isEmpty) {
      _controller.setMode(EditorMode.select);
      return;
    }
    await _controller.insertText(pageIndex, pdfPoint.dx, pdfPoint.dy, text);
  }

  Widget _buildToolbar() {
    final isAdding = _controller.mode == EditorMode.addText;
    return BottomAppBar(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _ToolbarButton(
            icon: Icons.touch_app_outlined,
            label: 'Wybierz',
            selected: !isAdding,
            onPressed: () => _controller.setMode(EditorMode.select),
          ),
          _ToolbarButton(
            icon: Icons.text_fields,
            label: 'Dodaj tekst',
            selected: isAdding,
            onPressed: () => _controller.setMode(EditorMode.addText),
          ),
          _ToolbarButton(
            icon: Icons.delete_outline,
            label: 'Usuń',
            selected: false,
            onPressed:
                _controller.selected == null ? null : _controller.deleteSelected,
          ),
        ],
      ),
    );
  }

  void _showNoticeIfAny() {
    final notice = _controller.notice;
    if (notice == null || notice == _lastNotice) return;
    _lastNotice = notice;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(notice), duration: const Duration(seconds: 5)),
      );
      _controller.clearNotice();
      _lastNotice = null;
    });
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = onPressed == null
        ? scheme.outline
        : selected
            ? scheme.primary
            : scheme.onSurfaceVariant;
    return TextButton(
      onPressed: onPressed,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color),
          Text(label, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }
}

class _ScannedBanner extends StatelessWidget {
  const _ScannedBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Icon(Icons.document_scanner_outlined,
              size: 20, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Ten dokument jest skanem — nie zawiera warstwy tekstowej. '
              'Edycja istniejącego tekstu wymaga OCR.',
              style:
                  TextStyle(color: scheme.onTertiaryContainer, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _RotatedPageBadge extends StatelessWidget {
  const _RotatedPageBadge();

  @override
  Widget build(BuildContext context) {
    return const IgnorePointer(
      child: Chip(
        avatar: Icon(Icons.rotate_right, size: 16),
        label: Text('Strona obrócona — edycja wyłączona',
            style: TextStyle(fontSize: 11)),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: scheme.error),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
