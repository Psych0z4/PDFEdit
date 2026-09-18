import 'reflow/reflow.dart';


/// Operacja edycji do wykonania na dokumencie.
///
/// Operacje są danymi (nie domknięciami), bo przechodzą przez granicę isolate
/// do workera PDFium.
sealed class EditOperation {
  const EditOperation({required this.pageIndex});

  final int pageIndex;
}

/// Podmiana treści istniejącego obiektu tekstowego (FPDFText_SetText).
class ReplaceTextOperation extends EditOperation {
  const ReplaceTextOperation({
    required super.pageIndex,
    required this.objectIndex,
    required this.newText,
    this.reflowMode = ReflowMode.auto,
  });

  final int objectIndex;
  final String newText;

  /// Jak dopasować tekst, gdy po zmianie nie mieści się w oryginalnym miejscu.
  final ReflowMode reflowMode;
}

/// Usunięcie obiektu ze strony (FPDFPage_RemoveObject) — realne usunięcie
/// contentu, nie zamalowanie białym prostokątem.
class DeleteObjectOperation extends EditOperation {
  const DeleteObjectOperation({
    required super.pageIndex,
    required this.objectIndex,
  });

  final int objectIndex;
}

/// Dodanie nowego obiektu tekstowego w podanym punkcie strony.
class InsertTextOperation extends EditOperation {
  const InsertTextOperation({
    required super.pageIndex,
    required this.text,
    required this.x,
    required this.y,
    this.fontSize = 12.0,
  });

  final String text;

  /// Współrzędne w przestrzeni strony PDF (origin w lewym dolnym rogu).
  final double x;
  final double y;
  final double fontSize;
}
