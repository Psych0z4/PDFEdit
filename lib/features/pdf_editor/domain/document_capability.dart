/// Wynik rozpoznania, co da się z dokumentem zrobić.
enum DocumentEditability {
  /// Dokument ma warstwę tekstową — edycja istniejącego tekstu jest możliwa.
  editableText,

  /// Brak obiektów tekstowych — najprawdopodobniej skan. Edycja wymaga OCR.
  scannedNoTextLayer,

  /// Dokument otwarty, ale zabezpieczony przed modyfikacją.
  readOnly,
}

class DocumentCapability {
  const DocumentCapability({
    required this.editability,
    required this.pageCount,
    required this.textObjectCount,
  });

  final DocumentEditability editability;
  final int pageCount;

  /// Liczba obiektów tekstowych znalezionych w przeskanowanej próbce stron.
  final int textObjectCount;

  bool get canEditText => editability == DocumentEditability.editableText;
  bool get isScanned => editability == DocumentEditability.scannedNoTextLayer;
}
