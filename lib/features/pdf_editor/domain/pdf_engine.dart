import '../../../core/result.dart';
import 'document_capability.dart';
import 'edit_operation.dart';
import 'editable_text_object.dart';

/// Wynik zastosowania zestawu operacji edycyjnych.
class EditApplyResult {
  const EditApplyResult({
    required this.outputPath,
    this.warnings = const [],
  });

  final String outputPath;

  /// Ostrzeżenia, których nie da się wyrazić jako błąd — np. tekst nie mieści
  /// się w oryginalnym obszarze, albo font prawdopodobnie nie ma glifu.
  final List<String> warnings;
}

/// Abstrakcja silnika PDF.
///
/// Cała aplikacja rozmawia wyłącznie z tym interfejsem. Poza katalogiem
/// `infrastructure/` nie ma ani jednego importu `pdfium_*` — dzięki temu
/// wymiana silnika (np. na komercyjny z prawdziwym reflow) sprowadza się do
/// dopisania jednej klasy.
abstract class PdfEngine {
  /// Rozpoznaje, czy dokument ma edytowalną warstwę tekstową (detekcja skanu).
  Future<Result<DocumentCapability>> inspect(String path, {int samplePages = 5});

  /// Wszystkie obiekty tekstowe strony wraz z geometrią i stylem.
  Future<Result<List<EditableTextObject>>> textObjectsOnPage(String path, int pageIndex);

  /// Wymiary strony w punktach PDF.
  Future<Result<PageSize>> pageSize(String path, int pageIndex);

  /// Sprawdza, których znaków [newText] font obiektu nie potrafi narysować.
  ///
  /// Wynik jest pewny, nie heurystyczny: każdy znak jest renderowany
  /// i porównywany ze wzorcem brakującego glifu.
  Future<Result<GlyphCoverageReport>> checkGlyphCoverage({
    required String path,
    required EditableTextObject target,
    required String newText,
  });

  /// Stosuje operacje do [sourcePath] i zapisuje wynik do [outputPath].
  ///
  /// Nigdy nie modyfikuje pliku źródłowego w miejscu — każda zmiana tworzy
  /// nową rewizję, co daje darmowe undo/redo i chroni oryginał użytkownika.
  Future<Result<EditApplyResult>> applyOperations({
    required String sourcePath,
    required String outputPath,
    required List<EditOperation> operations,
  });
}

class PageSize {
  const PageSize(this.width, this.height);
  final double width;
  final double height;
}

class GlyphCoverageReport {
  const GlyphCoverageReport({required this.unsupported});

  static const ok = GlyphCoverageReport(unsupported: {});

  /// Znaki, dla których font nie ma glifu. Po zapisie nie pojawią się
  /// w dokumencie wcale albo wyjdą jako pusty prostokąt.
  final Set<String> unsupported;

  bool get hasProblems => unsupported.isNotEmpty;
}
