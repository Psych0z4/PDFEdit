import 'package:pdfrx/pdfrx.dart';

import '../../../core/failures.dart';
import '../../../core/logging.dart';
import '../../../core/result.dart';
import '../domain/document_capability.dart';
import '../domain/edit_operation.dart';
import '../domain/editable_text_object.dart';
import '../domain/pdf_engine.dart';
import 'pdfium_bridge.dart' as bridge;

/// Implementacja [PdfEngine] oparta o PDFium.
///
/// Kazde wywołanie natywne przechodzi przez `PdfrxEntryFunctions.compute`,
/// czyli ten sam isolate workera, ktorego pdfrx używa do renderowania.
/// To jedyny sposob, żeby nie wywolywac PDFium równoległe z dwoch wątków —
/// biblioteka nie jest thread-safe.
class PdfiumPdfEngine implements PdfEngine {
  PdfiumPdfEngine({this.minScale = 0.6});

  /// Dolna granica zmniejszania tekstu. Ponizej niej zamiast po cichu
  /// zmniejszać dalej, zgłaszamy ostrzeżenie.
  final double minScale;

  @override
  Future<Result<DocumentCapability>> inspect(String path,
      {int samplePages = 5}) async {
    return _guard(
      'inspect',
      () async {
        final raw = await PdfrxEntryFunctions.instance.compute(
          bridge.inspectDocument,
          <String, Object?>{'path': path, 'samplePages': samplePages},
        );
        final pageCount = raw['pageCount']! as int;
        final textObjectCount = raw['textObjectCount']! as int;

        return DocumentCapability(
          editability: textObjectCount > 0
              ? DocumentEditability.editableText
              : DocumentEditability.scannedNoTextLayer,
          pageCount: pageCount,
          textObjectCount: textObjectCount,
        );
      },
      (e) => DocumentOpenFailure('Nie udało się odczytać dokumentu.', cause: e),
    );
  }

  @override
  Future<Result<List<EditableTextObject>>> textObjectsOnPage(
      String path, int pageIndex) async {
    return _guard(
      'textObjectsOnPage',
      () async {
        final raw = await PdfrxEntryFunctions.instance.compute(
          bridge.readPageTextObjects,
          <String, Object?>{'path': path, 'pageIndex': pageIndex},
        );
        return raw.map(_toEditableTextObject).toList(growable: false);
      },
      (e) => DocumentOpenFailure('Nie udało się odczytać tekstu strony.',
          cause: e),
    );
  }

  @override
  Future<Result<PageSize>> pageSize(String path, int pageIndex) async {
    return _guard(
      'pageSize',
      () async {
        final raw = await PdfrxEntryFunctions.instance.compute(
          bridge.readPageSize,
          <String, Object?>{'path': path, 'pageIndex': pageIndex},
        );
        return PageSize(raw['width']! as double, raw['height']! as double);
      },
      (e) => DocumentOpenFailure('Nie udało się odczytać wymiarów strony.',
          cause: e),
    );
  }

  @override
  Future<Result<GlyphCoverageReport>> checkGlyphCoverage({
    required String path,
    required EditableTextObject target,
    required String newText,
  }) async {
    // Znaki, które już są w obiekcie, na pewno da się narysować — sprawdzamy
    // tylko nowe, żeby nie renderować próbek bez potrzeby.
    final existing = target.text.runes.map(String.fromCharCode).toSet();
    final candidates = newText.runes
        .map(String.fromCharCode)
        .where((c) => c.trim().isNotEmpty && !existing.contains(c))
        .toSet();
    if (candidates.isEmpty) return const Success(GlyphCoverageReport.ok);

    return _guard(
      'checkGlyphCoverage',
      () async {
        final raw = await PdfrxEntryFunctions.instance.compute(
          bridge.probeGlyphSupport,
          <String, Object?>{
            'path': path,
            'pageIndex': target.pageIndex,
            'objectIndex': target.objectIndex,
            'text': candidates.join(),
          },
        );
        return GlyphCoverageReport(
          unsupported: (raw['unsupported']! as List).cast<String>().toSet(),
        );
      },
      (e) => TextEditFailure('Nie udało się sprawdzić pokrycia znaków.', cause: e),
    );
  }

  @override
  Future<Result<EditApplyResult>> applyOperations({
    required String sourcePath,
    required String outputPath,
    required List<EditOperation> operations,
  }) async {
    if (operations.isEmpty) {
      return const Failure(
          TextEditFailure('Brak operacji do zastosowania.'));
    }
    return _guard(
      'applyOperations',
      () async {
        final raw = await PdfrxEntryFunctions.instance.compute(
          bridge.applyOperations,
          <String, Object?>{
            'sourcePath': sourcePath,
            'outputPath': outputPath,
            'operations': operations.map(_toOperationMap).toList(),
            'minScale': minScale,
          },
        );
        return EditApplyResult(
          outputPath: raw['outputPath']! as String,
          warnings: (raw['warnings']! as List).cast<String>(),
        );
      },
      (e) => TextEditFailure(_describe(e), cause: e),
    );
  }

  Map<String, Object?> _toOperationMap(EditOperation op) => switch (op) {
        ReplaceTextOperation() => <String, Object?>{
            'type': 'replace',
            'pageIndex': op.pageIndex,
            'objectIndex': op.objectIndex,
            'newText': op.newText,
            'reflowMode': op.reflowMode.name,
            'reencodeFont': op.reencodeFont,
          },
        DeleteObjectOperation() => <String, Object?>{
            'type': 'delete',
            'pageIndex': op.pageIndex,
            'objectIndex': op.objectIndex,
          },
        InsertTextOperation() => <String, Object?>{
            'type': 'insert',
            'pageIndex': op.pageIndex,
            'text': op.text,
            'x': op.x,
            'y': op.y,
            'fontSize': op.fontSize,
          },
      };

  EditableTextObject _toEditableTextObject(Map<String, Object?> raw) =>
      EditableTextObject(
        pageIndex: raw['pageIndex']! as int,
        objectIndex: raw['objectIndex']! as int,
        text: raw['text']! as String,
        left: raw['left']! as double,
        bottom: raw['bottom']! as double,
        right: raw['right']! as double,
        top: raw['top']! as double,
        fontSize: raw['fontSize']! as double,
        fontFamily: raw['fontFamily']! as String,
        isFontEmbedded: raw['isFontEmbedded']! as bool,
        colorArgb: raw['colorArgb']! as int,
      );

  Future<Result<T>> _guard<T>(
    String operation,
    Future<T> Function() body,
    AppFailure Function(Object error) onError,
  ) async {
    try {
      return Success(await body());
    } catch (e, stackTrace) {
      // Logujemy nazwę operacji i błąd — nigdy treści dokumentu.
      AppLog.error('PdfiumPdfEngine.$operation nie powiodlo się',
          error: e, stackTrace: stackTrace);
      return Failure(onError(e));
    }
  }

  String _describe(Object error) =>
      error is bridge.PdfiumBridgeException ? error.message : 'Edycja nie powiodła się.';
}
