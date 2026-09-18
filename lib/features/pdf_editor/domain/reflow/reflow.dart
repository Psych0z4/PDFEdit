/// Reflow — dopasowanie układu po zmianie treści tekstu.
///
/// Warstwa celowo oddzielona od silnika PDF: strategie dostają geometrię
/// i funkcję mierzącą, a zwracają *plan*. Wykonaniem zajmuje się implementacja
/// [PdfEngine]. Dzięki temu logikę layoutu da się czytać i rozwijać bez
/// znajomości PDFium.
library;

/// Sposób dopasowania tekstu po edycji.
enum ReflowMode {
  /// Bez zmian — tekst zostaje dokładnie tak, jak zwrócił go PDFium.
  none,

  /// Tylko proporcjonalne zmniejszenie do oryginalnej szerokości.
  fitInPlace,

  /// Wybiera strategię na podstawie tego, co uda się rozpoznać na stronie:
  /// komórka tabeli → łamanie w komórce, zwykły tekst → łamanie
  /// z przesunięciem treści poniżej, brak rozpoznania → zmniejszenie.
  auto,
}

/// Prostokąt w przestrzeni PDF (origin w lewym dolnym rogu).
class LayoutBox {
  const LayoutBox({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
  });

  final double left;
  final double right;
  final double top;
  final double bottom;

  double get width => right - left;
  double get height => top - bottom;
}

/// Metryki fontu potrzebne do pionowego rozmieszczenia wierszy.
class FontMetrics {
  const FontMetrics({required this.ascent, required this.descent});

  /// Maksymalne wzniesienie nad linią bazową, w punktach.
  final double ascent;

  /// Maksymalne zejście pod linię bazową, jako wartość dodatnia.
  final double descent;

  double get lineHeight => ascent + descent;
}

/// Gotowy plan rozmieszczenia tekstu.
class ReflowPlan {
  const ReflowPlan({
    required this.lines,
    required this.leading,
    required this.scale,
    required this.baselineShift,
    this.shiftContentBelow = 0,
    this.warnings = const [],
  });

  /// Wiersze do wyrysowania. Pierwszy trafia do istniejącego obiektu,
  /// kolejne wymagają nowych obiektów tekstowych.
  final List<String> lines;

  /// Odstęp między liniami bazowymi, w punktach PDF.
  final double leading;

  /// Współczynnik skalowania obiektu (1.0 = bez zmian).
  final double scale;

  /// Przesunięcie pierwszej linii bazowej. Dodatnie = w górę.
  final double baselineShift;

  /// O ile przesunąć w dół treść leżącą poniżej edytowanego fragmentu.
  /// Zero oznacza, że nic poza samym fragmentem nie jest ruszane.
  final double shiftContentBelow;

  final List<String> warnings;

  bool get isMultiLine => lines.length > 1;

  bool get requiresTransform =>
      (scale - 1.0).abs() > 0.001 || baselineShift.abs() > 0.001;

  static ReflowPlan single(String text) => ReflowPlan(
        lines: [text],
        leading: 0,
        scale: 1,
        baselineShift: 0,
      );
}

/// Pomiar szerokości tekstu prawdziwymi metrykami fontu.
///
/// Implementacja robi to przez chwilowe ustawienie treści na obiekcie
/// i odczytanie jego bboxa — publiczne API PDFium nie ma mapowania
/// Unicode na glify, więc nie da się zmierzyć tekstu "na sucho".
typedef MeasureWidth = double Function(String text);

/// Szerokość dostępna dla wiersza o podanym numerze (liczonym od zera).
///
/// Dzięki temu, że szerokość jest funkcją numeru wiersza, a nie stałą, tekst
/// potrafi opłynąć przeszkodę: wiersze na wysokości obrazka są węższe,
/// a te poniżej wracają do pełnej szerokości kolumny.
typedef LineWidth = double Function(int lineIndex);

/// Dopasowanie w miejscu przez zmniejszenie.
///
/// Nie rusza żadnego innego obiektu na stronie, więc nie może rozjechać
/// układu. Kosztem jest tekst mniejszy od sąsiedniego. Ostatnia deska ratunku.
class FitInPlaceStrategy {
  const FitInPlaceStrategy({this.minScale = 0.6});

  final double minScale;

  ReflowPlan plan({
    required String text,
    required double originalWidth,
    required double newWidth,
  }) {
    if (originalWidth <= 0 || newWidth <= originalWidth) {
      return ReflowPlan.single(text);
    }

    final required = originalWidth / newWidth;
    if (required >= minScale) {
      return ReflowPlan(
        lines: [text],
        leading: 0,
        scale: required,
        baselineShift: 0,
      );
    }
    return ReflowPlan(
      lines: [text],
      leading: 0,
      scale: minScale,
      baselineShift: 0,
      warnings: const [
        'Nowy tekst jest znacznie dłuższy od oryginału i nie mieści się '
            'w jego obszarze. Zmniejszono go maksymalnie — sprawdź, czy nie '
            'nachodzi na sąsiednią treść.',
      ],
    );
  }
}

/// Łamanie tekstu na wiersze w obrębie komórki tabeli.
///
/// Komórka ma twarde granice, które potrafimy odczytać z linii narysowanych
/// na stronie, i zwykle ma zapas w pionie. Zamiast ściskać tekst w jedną
/// linię, rozkładamy go na kilka w pełnym rozmiarze i centrujemy w pionie.
///
/// Czego NIE robi: nie powiększa komórki. Jeśli blok nie mieści się nawet
/// po złamaniu, dokłada zmniejszenie — i o tym użytkownik dostaje informację.
class CellWrapStrategy {
  const CellWrapStrategy({
    this.minScale = 0.6,
    this.lineHeightFactor = 1.15,
    this.padding = 2.0,
  });

  final double minScale;
  final double lineHeightFactor;
  final double padding;

  ReflowPlan plan({
    required String text,
    required LayoutBox box,
    required double baselineY,
    required double fontSize,
    required FontMetrics metrics,
    required MeasureWidth measure,
  }) {
    final maxWidth = box.width - 2 * padding;
    final maxHeight = box.height - 2 * padding;
    if (maxWidth <= 0 || maxHeight <= 0 || fontSize <= 0) {
      return ReflowPlan.single(text);
    }

    for (final scale in _scaleSteps(minScale)) {
      // measure() mierzy przy skali 1, więc dostępną szerokość przeliczamy
      // do tamtych jednostek.
      final widthAtScale = maxWidth / scale;
      final lines = breakIntoLines(text, widthAtScale, measure);
      if (lines.any((l) => measure(l) > widthAtScale + 0.5)) continue;

      final leading = fontSize * scale * lineHeightFactor;
      final ascent = metrics.ascent * scale;
      final descent = metrics.descent * scale;
      final blockHeight = (lines.length - 1) * leading + ascent + descent;
      if (blockHeight > maxHeight) continue;

      // Wycentrowanie w pionie: liczymy, gdzie ma wylądować pierwsza linia
      // bazowa, i zwracamy różnicę wobec obecnej.
      final targetBaseline =
          box.bottom + (box.height + blockHeight) / 2 - ascent;

      return ReflowPlan(
        lines: lines,
        leading: leading,
        scale: scale,
        baselineShift: targetBaseline - baselineY,
        warnings: scale < 0.999
            ? [
                'Tekst nie zmieścił się w komórce w pełnym rozmiarze — '
                    'zmniejszono go o ${((1 - scale) * 100).round()}%.',
              ]
            : const [],
      );
    }

    return ReflowPlan(
      lines: [text],
      leading: 0,
      scale: minScale,
      baselineShift: 0,
      warnings: const [
        'Tekst nie mieści się w komórce nawet po złamaniu na wiersze. '
            'Zmniejszono go maksymalnie — sprawdź wynik przed zapisem.',
      ],
    );
  }
}

/// Łamanie zwykłego tekstu z przesunięciem treści leżącej poniżej.
///
/// To odpowiednik tego, czego oczekuje się od edytora: dłuższy tekst dostaje
/// nowy wiersz, a reszta strony zjeżdża w dół — zamiast być ściśnięty.
///
/// Świadomie NIE przelewa tekstu między sąsiednimi wierszami akapitu.
/// Sklejanie linii w jeden strumień i dzielenie go od nowa zniszczyłoby
/// układy, które tylko wyglądają jak akapit: adresy, listy, pozycje faktury.
/// Łamiemy wyłącznie edytowany fragment i robimy na niego miejsce.
class ParagraphFlowStrategy {
  const ParagraphFlowStrategy({this.minScale = 0.6});

  final double minScale;

  ReflowPlan plan({
    required String text,
    required LineWidth widthForLine,
    required double leading,
    required double availableHeightBelow,
    required MeasureWidth measure,
  }) {
    if (leading <= 0 || widthForLine(0) <= 0) return ReflowPlan.single(text);

    final lines = breakIntoFlowingLines(text, widthForLine, measure);
    if (lines.length <= 1) {
      return ReflowPlan(
        lines: lines,
        leading: leading,
        scale: 1,
        baselineShift: 0,
      );
    }

    final needed = (lines.length - 1) * leading;
    if (needed > availableHeightBelow) {
      return ReflowPlan(
        lines: [text],
        leading: 0,
        scale: minScale,
        baselineShift: 0,
        warnings: const [
          'Rozłożenie tekstu na kolejne wiersze nie zmieściłoby się na '
              'stronie, więc zamiast tego został zmniejszony.',
        ],
      );
    }

    return ReflowPlan(
      lines: lines,
      leading: leading,
      scale: 1,
      baselineShift: 0,
      shiftContentBelow: needed,
      warnings: [
        'Tekst zajął ${lines.length} wiersze — treść poniżej została '
            'przesunięta w dół.',
      ],
    );
  }
}

Iterable<double> _scaleSteps(double minScale) sync* {
  for (var s = 1.0; s >= minScale - 0.001; s -= 0.05) {
    yield s;
  }
}

/// Zachłanny podział na wiersze mieszczące się w [maxWidth].
///
/// Słowo dłuższe niż cały wiersz zostaje w swoim wierszu — rozcinanie wyrazów
/// to osobny problem i na tym etapie wolimy zgłosić, że się nie mieści.
List<String> breakIntoLines(
    String text, double maxWidth, MeasureWidth measure) {
  final words = text.split(' ');
  final lines = <String>[];
  var current = '';

  for (final word in words) {
    final candidate = current.isEmpty ? word : '$current $word';
    if (current.isEmpty || measure(candidate) <= maxWidth) {
      current = candidate;
    } else {
      lines.add(current);
      current = word;
    }
  }
  if (current.isNotEmpty) lines.add(current);
  return lines.isEmpty ? [text] : lines;
}

/// Podział na wiersze, gdy każdy wiersz może mieć inną dostępną szerokość.
///
/// To jest mechanizm opływania obrazka: dla wiersza numer i pytamy
/// [widthFor] o miejsce na jego wysokości i dopiero wtedy decydujemy,
/// ile słów się w nim zmieści.
List<String> breakIntoFlowingLines(
    String text, LineWidth widthFor, MeasureWidth measure) {
  final words = text.split(' ');
  final lines = <String>[];
  var current = '';
  var lineIndex = 0;
  var maxWidth = widthFor(0);

  for (final word in words) {
    final candidate = current.isEmpty ? word : '$current $word';
    if (current.isEmpty || measure(candidate) <= maxWidth) {
      current = candidate;
    } else {
      lines.add(current);
      current = word;
      lineIndex++;
      maxWidth = widthFor(lineIndex);
    }
  }
  if (current.isNotEmpty) lines.add(current);
  return lines.isEmpty ? [text] : lines;
}
