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
  GlyphCoverageReport checkGlyphCoverage(
      EditableTextObject target, String newText) {
    // Publiczne API PDFium nie udostępnia mapowania Unicode -> glif
    // (FPDFFont_GetGlyphWidth przyjmuje indeks glifu, nie kod znaku), więc
    // pełnej weryfikacji zrobić się nie da. Heurystyka: font osadzony jest
    // zwykle subsetem, więc znaki, których nie było w oryginalnej treści,
    // mogą nie mieć glifu.
    if (!target.isFontEmbedded) {
      return const GlyphCoverageReport(riskyCharacters: {});
    }
    final existing = target.text.toLowerCase().split('').toSet();
    final risky = <String>{};
    for (final char in newText.split('')) {
      if (char.trim().isEmpty) continue;
      if (!existing.contains(char.toLowerCase())) {
        risky.add(char);
      }
    }
    return GlyphCoverageReport(riskyCharacters: risky);
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
