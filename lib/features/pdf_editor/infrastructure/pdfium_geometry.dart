/// Rozpoznawanie układu strony na podstawie tego, co jest na niej narysowane.
///
/// Kluczowa decyzja: linie czytamy z SEGMENTÓW ścieżek, a nie z bboxów
/// obiektów. Wiele generatorów PDF rysuje całą siatkę tabeli jako jeden
/// obiekt — wtedy jego bbox to cała tabela i granice pojedynczej komórki
/// są z niego nie do odczytania.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:pdfium_flutter/pdfium_flutter.dart';

import '../domain/reflow/reflow.dart';

/// Odcinek prosty odczytany ze ścieżki — kandydat na krawędź komórki.
class PageRule {
  const PageRule({
    required this.vertical,
    required this.position,
    required this.from,
    required this.to,
  });

  /// True dla linii pionowej.
  final bool vertical;

  /// X dla linii pionowej, Y dla poziomej.
  final double position;

  /// Zakres wzdłuż linii: Y dla pionowej, X dla poziomej.
  final double from;
  final double to;

  bool spans(double value) => from <= value && to >= value;
}

/// Dowolny obiekt strony sprowadzony do prostokąta.
class PageObject {
  const PageObject({
    required this.index,
    required this.type,
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
  });

  final int index;
  final int type;
  final double left;
  final double bottom;
  final double right;
  final double top;

  double get width => right - left;
  double get height => top - bottom;
  double get centerY => (bottom + top) / 2;

  bool get isImage =>
      type == FPDF_PAGEOBJ_IMAGE ||
      type == FPDF_PAGEOBJ_FORM ||
      type == FPDF_PAGEOBJ_SHADING;

  /// Czy obiekt zachodzi na pas poziomy [bandBottom]..[bandTop].
  bool overlapsBand(double bandBottom, double bandTop) =>
      bottom < bandTop && top > bandBottom;
}

/// Obiekt tekstowy widziany od strony geometrii.
class TextBlock {
  const TextBlock({
    required this.index,
    required this.left,
    required this.bottom,
    required this.right,
    required this.top,
    required this.baselineY,
    required this.fontSize,
  });

  final int index;
  final double left;
  final double bottom;
  final double right;
  final double top;
  final double baselineY;
  final double fontSize;

  double get centerX => (left + right) / 2;
  double get centerY => (bottom + top) / 2;
}

/// Wynik rozpoznania kolumny, w której leży edytowany tekst.
class ColumnInfo {
  const ColumnInfo({
    required this.left,
    required this.right,
    required this.leading,
  });

  final double left;

  /// Prawa granica kolumny bez uwzględniania przeszkód — te liczone są
  /// osobno, dla każdego wiersza z osobna.
  final double right;

  /// Interlinia odczytana z sąsiednich wierszy, null gdy nie do ustalenia.
  final double? leading;

  double get width => right - left;
}

/// Geometria jednej strony.
class PageGeometry {
  PageGeometry({
    required this.rules,
    required this.objects,
    required this.texts,
    required this.pageWidth,
    required this.pageHeight,
  });

  final List<PageRule> rules;
  final List<PageObject> objects;
  final List<TextBlock> texts;
  final double pageWidth;
  final double pageHeight;

  /// Margines, poniżej którego nie przesuwamy treści — strefa stopki.
  double get bottomSafeMargin => pageHeight * 0.06;

  /// Komórka, w której leży obiekt: najbliższe linie z każdej strony.
  ///
  /// Zwraca null, gdy brakuje choćby jednej krawędzi albo gdy wynikowy
  /// prostokąt jest bezsensownie mały — wtedy lepiej nie łamać tekstu,
  /// niż łamać na podstawie zgadywania.
  LayoutBox? detectCell(TextBlock target) {
    double? left, right, top, bottom;

    for (final rule in rules) {
      if (rule.vertical) {
        if (!rule.spans(target.centerY)) continue;
        if (rule.position <= target.centerX) {
          left = _larger(left, rule.position);
        } else {
          right = _smaller(right, rule.position);
        }
      } else {
        if (!rule.spans(target.centerX)) continue;
        if (rule.position <= target.centerY) {
          bottom = _larger(bottom, rule.position);
        } else {
          top = _smaller(top, rule.position);
        }
      }
    }

    if (left == null || right == null || top == null || bottom == null) {
      return null;
    }
    final box = LayoutBox(left: left, right: right, top: top, bottom: bottom);
    if (box.width < target.fontSize || box.height < target.fontSize) return null;
    return box;
  }

  /// Kolumna tekstu, do której należy obiekt.
  ///
  /// Rozpoznajemy ją po wierszach o tej samej lewej krawędzi i tym samym
  /// rozmiarze fontu. To najprostszy sygnał, który działa dla zwykłego tekstu
  /// i nie myli się na układach wielokolumnowych.
  ColumnInfo? detectColumn(TextBlock target) {
    final siblings = _siblings(target);
    final right = _columnRight(target, siblings);
    if (right - target.left < target.fontSize * 3) return null;

    return ColumnInfo(
      left: target.left,
      right: right,
      leading: _detectLeading(target, siblings),
    );
  }

  List<TextBlock> _siblings(TextBlock target) => texts
      .where((t) =>
          t.index != target.index &&
          (t.left - target.left).abs() < 2.5 &&
          (t.fontSize - target.fontSize).abs() < 0.6)
      .toList();

  /// Prawa krawędź kolumny, bez przeszkód.
  ///
  /// Najdłuższy z sąsiednich wierszy bloku pokazuje, dokąd sięga kolumna.
  /// Gdy wierszy brak, zakładamy margines symetryczny do lewego.
  double _columnRight(TextBlock target, List<TextBlock> siblings) {
    final nearby = siblings
        .where((t) =>
            (t.baselineY - target.baselineY).abs() < target.fontSize * 12)
        .toList();

    if (nearby.length >= 2) {
      final widest = nearby.map((t) => t.right).reduce(_max);
      return _max(widest, target.right);
    }
    return pageWidth - target.left;
  }

  /// Prawa granica dostępna dla pojedynczego wiersza tekstu.
  ///
  /// To jest miejsce, w którym tekst opływa obrazek: wiersze na wysokości
  /// obrazka są węższe, a te poniżej niego wracają do pełnej szerokości
  /// kolumny. Pas [bandBottom]..[bandTop] to wysokość konkretnego wiersza.
  double rightBoundaryAt({
    required TextBlock target,
    required ColumnInfo column,
    required Set<int> movingWithText,
    required double bandBottom,
    required double bandTop,
  }) {
    var right = column.right;

    for (final obj in objects) {
      if (obj.index == target.index) continue;
      // Obiekty, które i tak zjadą razem z tekstem, nie są przeszkodą.
      if (movingWithText.contains(obj.index)) continue;
      if (_isPageBackground(obj)) continue;
      if (!obj.overlapsBand(bandBottom, bandTop)) continue;
      // Interesuje nas tylko to, co stoi na drodze w prawo.
      if (obj.right <= target.left) continue;
      if (obj.left <= target.left) continue;

      // Linie siatki mają zerową szerokość i nie są przeszkodą dla tekstu
      // inaczej niż przez detectCell — tutaj liczą się bryły: obrazki,
      // formularze i inne bloki tekstu.
      if (obj.type == FPDF_PAGEOBJ_PATH && obj.width < 2) continue;

      if (obj.left < right) right = obj.left;
    }

    for (final rule in rules) {
      if (!rule.vertical) continue;
      if (rule.to < bandBottom || rule.from > bandTop) continue;
      if (rule.position > target.left && rule.position < right) {
        right = rule.position;
      }
    }

    return right;
  }

  /// Interlinia jako mediana odstępów między kolejnymi wierszami bloku.
  double? _detectLeading(TextBlock target, List<TextBlock> siblings) {
    final baselines = <double>[
      target.baselineY,
      ...siblings.map((t) => t.baselineY),
    ]..sort();

    final deltas = <double>[];
    for (var i = 1; i < baselines.length; i++) {
      final d = baselines[i] - baselines[i - 1];
      // Odrzucamy odstępy nierealistyczne dla tego samego bloku tekstu.
      if (d > target.fontSize * 0.8 && d < target.fontSize * 3) deltas.add(d);
    }
    if (deltas.isEmpty) return null;
    deltas.sort();
    return deltas[deltas.length ~/ 2];
  }

  /// Obiekty, które trzeba przesunąć, gdy edytowany tekst urośnie o wiersz.
  ///
  /// Bierzemy wszystko, co leży poniżej i mieści się w tej samej kolumnie —
  /// także obrazki, bo one też muszą zrobić miejsce. Sąsiednia kolumna
  /// i strefa stopki zostają nietknięte.
  Set<int> objectsBelow(TextBlock target, ColumnInfo column) {
    final result = <int>{};
    for (final obj in objects) {
      if (obj.index == target.index) continue;
      if (obj.top >= target.bottom) continue;
      if (obj.centerY < bottomSafeMargin) continue;
      if (_isPageBackground(obj)) continue;
      final overlapsColumn = obj.left < column.right && obj.right > column.left;
      if (overlapsColumn) result.add(obj.index);
    }
    return result;
  }

  /// Ile miejsca w pionie da się odzyskać bez wchodzenia w stopkę.
  double freeSpaceBelow(TextBlock target, Set<int> moving) {
    var lowest = target.bottom;
    for (final obj in objects) {
      if (!moving.contains(obj.index)) continue;
      if (obj.bottom < lowest) lowest = obj.bottom;
    }
    return lowest - bottomSafeMargin;
  }

  /// Tło strony albo ramka wokół całej zawartości — takich nie ruszamy
  /// i nie traktujemy jako przeszkody.
  bool _isPageBackground(PageObject obj) =>
      obj.width > pageWidth * 0.9 && obj.height > pageHeight * 0.5;
}

/// Buduje geometrię strony: linie ze ścieżek, obiekty i bloki tekstu.
PageGeometry readPageGeometry(PDFium pdfium, Arena arena, FPDF_PAGE page) {
  final rules = <PageRule>[];
  final objects = <PageObject>[];
  final texts = <TextBlock>[];

  final count = pdfium.FPDFPage_CountObjects(page);
  for (var i = 0; i < count; i++) {
    final obj = pdfium.FPDFPage_GetObject(page, i);
    if (obj == nullptr) continue;
    final type = pdfium.FPDFPageObj_GetType(obj);
    final bounds = _bounds(pdfium, arena, obj);
    if (bounds == null) continue;

    objects.add(PageObject(
      index: i,
      type: type,
      left: bounds[0],
      bottom: bounds[1],
      right: bounds[2],
      top: bounds[3],
    ));

    if (type == FPDF_PAGEOBJ_PATH) {
      _collectRules(pdfium, arena, obj, rules);
    } else if (type == FPDF_PAGEOBJ_TEXT) {
      final matrix = arena<FS_MATRIX>();
      final hasMatrix = pdfium.FPDFPageObj_GetMatrix(obj, matrix) != 0;
      final baseline = hasMatrix ? matrix.ref.f : bounds[1];
      final verticalScale =
          hasMatrix && matrix.ref.d != 0 ? matrix.ref.d.abs() : 1.0;

      final sizePtr = arena<Float>();
      final size = pdfium.FPDFTextObj_GetFontSize(obj, sizePtr) != 0
          ? sizePtr.value * verticalScale
          : bounds[3] - bounds[1];

      texts.add(TextBlock(
        index: i,
        left: bounds[0],
        bottom: bounds[1],
        right: bounds[2],
        top: bounds[3],
        baselineY: baseline,
        fontSize: size,
      ));
    }
  }

  return PageGeometry(
    rules: rules,
    objects: objects,
    texts: texts,
    pageWidth: pdfium.FPDF_GetPageWidthF(page),
    pageHeight: pdfium.FPDF_GetPageHeightF(page),
  );
}

/// Rozkłada ścieżkę na odcinki proste w przestrzeni strony.
void _collectRules(
    PDFium pdfium, Arena arena, FPDF_PAGEOBJECT obj, List<PageRule> out) {
  final matrix = arena<FS_MATRIX>();
  final hasMatrix = pdfium.FPDFPageObj_GetMatrix(obj, matrix) != 0;

  double toPageX(double x, double y) =>
      hasMatrix ? matrix.ref.a * x + matrix.ref.c * y + matrix.ref.e : x;
  double toPageY(double x, double y) =>
      hasMatrix ? matrix.ref.b * x + matrix.ref.d * y + matrix.ref.f : y;

  final segmentCount = pdfium.FPDFPath_CountSegments(obj);
  double? currentX, currentY, subpathStartX, subpathStartY;

  for (var i = 0; i < segmentCount; i++) {
    final segment = pdfium.FPDFPath_GetPathSegment(obj, i);
    if (segment == nullptr) continue;

    final px = arena<Float>();
    final py = arena<Float>();
    if (pdfium.FPDFPathSegment_GetPoint(segment, px, py) == 0) continue;

    final x = toPageX(px.value, py.value);
    final y = toPageY(px.value, py.value);
    final type = pdfium.FPDFPathSegment_GetType(segment);

    if (type == FPDF_SEGMENT_LINETO && currentX != null && currentY != null) {
      _addRule(out, currentX, currentY, x, y);
    }
    // Krzywych Beziera nie traktujemy jako krawędzi — zaokrąglony róg ramki
    // nie jest granicą komórki.

    if (type == FPDF_SEGMENT_MOVETO) {
      subpathStartX = x;
      subpathStartY = y;
    }
    currentX = x;
    currentY = y;

    if (pdfium.FPDFPathSegment_GetClose(segment) != 0 &&
        subpathStartX != null &&
        subpathStartY != null) {
      _addRule(out, x, y, subpathStartX, subpathStartY);
      currentX = subpathStartX;
      currentY = subpathStartY;
    }
  }
}

void _addRule(List<PageRule> out, double x1, double y1, double x2, double y2) {
  const tolerance = 0.6;
  const minLength = 2.0;

  if ((x1 - x2).abs() <= tolerance && (y1 - y2).abs() >= minLength) {
    out.add(PageRule(
      vertical: true,
      position: (x1 + x2) / 2,
      from: y1 < y2 ? y1 : y2,
      to: y1 < y2 ? y2 : y1,
    ));
  } else if ((y1 - y2).abs() <= tolerance && (x1 - x2).abs() >= minLength) {
    out.add(PageRule(
      vertical: false,
      position: (y1 + y2) / 2,
      from: x1 < x2 ? x1 : x2,
      to: x1 < x2 ? x2 : x1,
    ));
  }
}

List<double>? _bounds(PDFium pdfium, Arena arena, FPDF_PAGEOBJECT obj) {
  final left = arena<Float>();
  final bottom = arena<Float>();
  final right = arena<Float>();
  final top = arena<Float>();
  if (pdfium.FPDFPageObj_GetBounds(obj, left, bottom, right, top) == 0) {
    return null;
  }
  return <double>[left.value, bottom.value, right.value, top.value];
}

double _max(double a, double b) => a > b ? a : b;
double? _larger(double? current, double candidate) =>
    current == null || candidate > current ? candidate : current;
double? _smaller(double? current, double candidate) =>
    current == null || candidate < current ? candidate : current;
