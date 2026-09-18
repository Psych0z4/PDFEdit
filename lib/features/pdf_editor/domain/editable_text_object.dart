/// Obiekt tekstowy PDF — najmniejsza jednostka, którą PDFium potrafi edytować.
///
/// Uwaga: PDF nie zna pojęcia "słowo" ani "akapit". Jeden obiekt tekstowy to
/// fragment content streamu — czasem cała linia, czasem kilka liter, czasem
/// pół akapitu. Granularność edycji jest więc narzucona przez plik, nie przez nas.
class EditableTextObject {
  const EditableTextObject({
    required this.pageIndex,
    required this.objectIndex,
    required this.text,
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
    required this.fontSize,
    required this.fontFamily,
    required this.isFontEmbedded,
    required this.colorArgb,
  });

  final int pageIndex;

  /// Indeks obiektu na stronie. Stabilny dopóki nie usuniemy innego obiektu —
  /// dlatego po każdej operacji usunięcia lista jest wczytywana od nowa.
  final int objectIndex;

  final String text;

  /// Współrzędne w przestrzeni strony PDF (origin w lewym dolnym rogu, punkty).
  final double left;
  final double bottom;
  final double right;
  final double top;

  final double fontSize;
  final String fontFamily;

  /// Font osadzony w dokumencie jest najczęściej subsetem — zawiera tylko te
  /// glify, które w dokumencie wystąpiły. To źródło problemu z polskimi znakami.
  final bool isFontEmbedded;

  final int colorArgb;

  double get width => right - left;
  double get height => top - bottom;

  bool containsPoint(double x, double y) =>
      x >= left && x <= right && y >= bottom && y <= top;

  /// Powiększony obszar trafienia — palec nie jest kursorem myszy.
  bool containsPointWithTolerance(double x, double y, double tolerance) =>
      x >= left - tolerance &&
      x <= right + tolerance &&
      y >= bottom - tolerance &&
      y <= top + tolerance;
}
