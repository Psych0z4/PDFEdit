import 'dart:ui';

import 'package:pdfrx/pdfrx.dart';

import '../domain/editable_text_object.dart';

/// Przelicza miedzy przestrzenią wyświetlania strony a przestrzenią PDF.
///
/// PDF ma początek układu w lewym DOLNYM rogu i jednostkę równą punktowi
/// typograficznemu; Flutter ma początek w lewym GORNYM rogu i jednostkę
/// w pikselach logicznych. Cala ta zamiana żyje w jednym miejscu.
class PageCoordinateMapper {
  const PageCoordinateMapper({
    required this.displaySize,
    required this.pageWidth,
    required this.pageHeight,
  });

  factory PageCoordinateMapper.forPage(PdfPage page, Size displaySize) =>
      PageCoordinateMapper(
        displaySize: displaySize,
        pageWidth: page.width,
        pageHeight: page.height,
      );

  final Size displaySize;
  final double pageWidth;
  final double pageHeight;

  /// Punkt dotyku -> współrzędne strony PDF.
  Offset toPdf(Offset local) => Offset(
        local.dx / displaySize.width * pageWidth,
        pageHeight - local.dy / displaySize.height * pageHeight,
      );

  /// Bounding box obiektu -> prostokat do narysowania na ekranie.
  Rect toDisplayRect(EditableTextObject object) {
    final scaleX = displaySize.width / pageWidth;
    final scaleY = displaySize.height / pageHeight;
    return Rect.fromLTRB(
      object.left * scaleX,
      (pageHeight - object.top) * scaleY,
      object.right * scaleX,
      (pageHeight - object.bottom) * scaleY,
    );
  }

  /// Tolerancja trafienia w punktach PDF, odpowiadająca [displayTolerance]
  /// pikselom na ekranie. Dzieki temu obszar dotyku jest stale wygodny
  /// niezależnie od poziomu zoomu.
  double toleranceInPdfUnits(double displayTolerance) =>
      displayTolerance / displaySize.width * pageWidth;
}
