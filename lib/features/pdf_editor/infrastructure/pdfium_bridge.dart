/// Niskopoziomowy most do PDFium.
///
/// WSZYSTKO w tym pliku wykonuje się w isolate workera pdfrx — PDFium nie jest
/// thread-safe, więc równoległe wywołania z dwoch isolate prowadza do crashy
/// i uszkodzenia danych. Funkcje są top-level, bo muszą przejść przez granice
/// isolate jako czysty kod, bez domknięć.
///
/// Model pracy: każda operacja otwiera dokument, robi swoje i zamyka.
/// Zaden uchwyt natywny nie żyje dłużej niż jedno wywołanie — brak wycieków
/// i brak okien, w których stan natywny mógłby się rozjechac ze stanem UI.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfium_flutter/pdfium_flutter.dart';

import '../domain/reflow/reflow.dart';
import 'pdfium_geometry.dart';



const int _pageObjText = FPDF_PAGEOBJ_TEXT;
const int _saveNoIncremental = 2; // FPDF_NO_INCREMENTAL

/// Odczyt wszystkich obiektów tekstowych strony.
///
/// [params] = {'path': String, 'pageIndex': int}
List<Map<String, Object?>> readPageTextObjects(Map<String, Object?> params) {
  final path = params['path']! as String;
  final pageIndex = params['pageIndex']! as int;

  final pdfium = pdfiumBindings;
  final arena = Arena();
  FPDF_DOCUMENT doc = nullptr;
  FPDF_PAGE page = nullptr;
  FPDF_TEXTPAGE textPage = nullptr;

  try {
    doc = _openDocument(pdfium, arena, path);
    page = pdfium.FPDF_LoadPage(doc, pageIndex);
    if (page == nullptr) {
      throw PdfiumBridgeException('Nie udało się wczytać strony $pageIndex.');
    }
    textPage = pdfium.FPDFText_LoadPage(page);

    final count = pdfium.FPDFPage_CountObjects(page);
    final result = <Map<String, Object?>>[];

    for (var i = 0; i < count; i++) {
      final obj = pdfium.FPDFPage_GetObject(page, i);
      if (obj == nullptr) continue;
      if (pdfium.FPDFPageObj_GetType(obj) != _pageObjText) continue;

      final text = _readObjectText(pdfium, arena, obj, textPage);
      if (text.trim().isEmpty) continue;

      final bounds = _readBounds(pdfium, arena, obj);
      if (bounds == null) continue;

      final fontSizePtr = arena<Float>();
      final fontSize = pdfium.FPDFTextObj_GetFontSize(obj, fontSizePtr) != 0
          ? fontSizePtr.value
          : 0.0;

      var fontFamily = '';
      var isEmbedded = false;
      final font = pdfium.FPDFTextObj_GetFont(obj);
      if (font != nullptr) {
        fontFamily = _readFontFamily(pdfium, arena, font);
        isEmbedded = pdfium.FPDFFont_GetIsEmbedded(font) == 1;
      }

      result.add(<String, Object?>{
        'pageIndex': pageIndex,
        'objectIndex': i,
        'text': text,
        'left': bounds[0],
        'bottom': bounds[1],
        'right': bounds[2],
        'top': bounds[3],
        'fontSize': fontSize,
        'fontFamily': fontFamily,
        'isFontEmbedded': isEmbedded,
        'colorArgb': _readFillColor(pdfium, arena, obj),
      });
    }
    return result;
  } finally {
    if (textPage != nullptr) pdfium.FPDFText_ClosePage(textPage);
    if (page != nullptr) pdfium.FPDF_ClosePage(page);
    if (doc != nullptr) pdfium.FPDF_CloseDocument(doc);
    arena.releaseAll();
  }
}

/// Zlicza obiekty tekstowe w próbce stron — podstawa detekcji skanu.
///
/// [params] = {'path': String, 'samplePages': int}
Map<String, Object?> inspectDocument(Map<String, Object?> params) {
  final path = params['path']! as String;
  final samplePages = params['samplePages']! as int;

  final pdfium = pdfiumBindings;
  final arena = Arena();
  FPDF_DOCUMENT doc = nullptr;

  try {
    doc = _openDocument(pdfium, arena, path);
    final pageCount = pdfium.FPDF_GetPageCount(doc);
    final pagesToScan = pageCount < samplePages ? pageCount : samplePages;

    var textObjectCount = 0;
    for (var p = 0; p < pagesToScan; p++) {
      final page = pdfium.FPDF_LoadPage(doc, p);
      if (page == nullptr) continue;
      final count = pdfium.FPDFPage_CountObjects(page);
      for (var i = 0; i < count; i++) {
        final obj = pdfium.FPDFPage_GetObject(page, i);
        if (obj != nullptr && pdfium.FPDFPageObj_GetType(obj) == _pageObjText) {
          textObjectCount++;
        }
      }
      pdfium.FPDF_ClosePage(page);
    }

    return <String, Object?>{
      'pageCount': pageCount,
      'textObjectCount': textObjectCount,
    };
  } finally {
    if (doc != nullptr) pdfium.FPDF_CloseDocument(doc);
    arena.releaseAll();
  }
}

/// Wymiary strony w punktach PDF.
///
/// [params] = {'path': String, 'pageIndex': int}
Map<String, Object?> readPageSize(Map<String, Object?> params) {
  final path = params['path']! as String;
  final pageIndex = params['pageIndex']! as int;

  final pdfium = pdfiumBindings;
  final arena = Arena();
  FPDF_DOCUMENT doc = nullptr;
  FPDF_PAGE page = nullptr;

  try {
    doc = _openDocument(pdfium, arena, path);
    page = pdfium.FPDF_LoadPage(doc, pageIndex);
    if (page == nullptr) {
      throw PdfiumBridgeException('Nie udało się wczytać strony $pageIndex.');
    }
    return <String, Object?>{
      'width': pdfium.FPDF_GetPageWidthF(page),
      'height': pdfium.FPDF_GetPageHeightF(page),
    };
  } finally {
    if (page != nullptr) pdfium.FPDF_ClosePage(page);
    if (doc != nullptr) pdfium.FPDF_CloseDocument(doc);
    arena.releaseAll();
  }
}

/// Stosuje operacje edycyjne i zapisuje wynik jako nowy plik.
///
/// [params] = {
///   'sourcePath': String,
///   'outputPath': String,
///   'operations': lista map operacji,
///   'minScale': double,
/// }
Map<String, Object?> applyOperations(Map<String, Object?> params) {
  final sourcePath = params['sourcePath']! as String;
  final outputPath = params['outputPath']! as String;
  final operations =
      (params['operations']! as List).cast<Map<String, Object?>>();
  final minScale = params['minScale']! as double;

  final pdfium = pdfiumBindings;
  final arena = Arena();
  final warnings = <String>[];
  FPDF_DOCUMENT doc = nullptr;

  try {
    doc = _openDocument(pdfium, arena, sourcePath);

    final byPage = <int, List<Map<String, Object?>>>{};
    for (final op in operations) {
      byPage.putIfAbsent(op['pageIndex']! as int, () => []).add(op);
    }

    for (final entry in byPage.entries) {
      final page = pdfium.FPDF_LoadPage(doc, entry.key);
      if (page == nullptr) {
        throw PdfiumBridgeException(
            'Nie udało się wczytać strony ${entry.key}.');
      }
      try {
        final ops = entry.value;

        // Kolejność ma znaczenie: usuwanie przesuwa indeksy pozostałych
        // obiektów, więc idzie na końcu i od największego indeksu w dół.
        for (final op in ops.where((o) => o['type'] == 'replace')) {
          _applyReplace(pdfium, arena, doc, page, op, minScale, warnings);
        }
        for (final op in ops.where((o) => o['type'] == 'insert')) {
          _applyInsert(pdfium, arena, doc, page, op, warnings);
        }
        final deletes = ops.where((o) => o['type'] == 'delete').toList()
          ..sort((a, b) =>
              (b['objectIndex']! as int).compareTo(a['objectIndex']! as int));
        for (final op in deletes) {
          _applyDelete(pdfium, page, op, warnings);
        }

        if (pdfium.FPDFPage_GenerateContent(page) == 0) {
          throw PdfiumBridgeException(
              'PDFium nie zdołał zregenerować treści strony ${entry.key}.');
        }
      } finally {
        pdfium.FPDF_ClosePage(page);
      }
    }

    _saveDocument(pdfium, doc, outputPath);
    return <String, Object?>{'outputPath': outputPath, 'warnings': warnings};
  } finally {
    if (doc != nullptr) pdfium.FPDF_CloseDocument(doc);
    arena.releaseAll();
  }
}

// --- operacje ---------------------------------------------------------------

void _applyReplace(
  PDFium pdfium,
  Arena arena,
  FPDF_DOCUMENT doc,
  FPDF_PAGE page,
  Map<String, Object?> op,
  double minScale,
  List<String> warnings,
) {
  final objectIndex = op['objectIndex']! as int;
  final newText = op['newText']! as String;
  final mode = ReflowMode.values.byName(op['reflowMode']! as String);

  final obj = pdfium.FPDFPage_GetObject(page, objectIndex);
  if (obj == nullptr || pdfium.FPDFPageObj_GetType(obj) != _pageObjText) {
    throw PdfiumBridgeException(
        'Obiekt $objectIndex nie jest obiektem tekstowym.');
  }

  // Geometrię czytamy PRZED zmianą treści — po niej bbox obiektu już nie
  // odpowiada temu, co użytkownik widział na ekranie.
  final geometry = mode == ReflowMode.auto
      ? readPageGeometry(pdfium, arena, page)
      : null;
  final before = _readBounds(pdfium, arena, obj);

  // Sedno edycji: PDFium podmienia treść istniejącego obiektu, używając jego
  // własnego fontu. Pozycja, rozmiar, kolor i macierz zostają zachowane.
  if (pdfium.FPDFText_SetText(obj, _toWideString(arena, newText)) == 0) {
    throw PdfiumBridgeException(
      'PDFium odrzucił nową treść — font tego fragmentu nie zawiera żadnego '
      'z wpisanych znaków.',
    );
  }

  if (mode == ReflowMode.none || before == null) return;

  final matrix = arena<FS_MATRIX>();
  final hasMatrix = pdfium.FPDFPageObj_GetMatrix(obj, matrix) != 0;
  // Macierz z obrotem lub pochyleniem wymagałaby transformacji współrzędnych,
  // której nie mamy — wtedy nie ryzykujemy przestawiania układu.
  final isUpright =
      hasMatrix && matrix.ref.b.abs() < 0.001 && matrix.ref.c.abs() < 0.001;

  if (mode == ReflowMode.auto && isUpright && geometry != null) {
    final target = geometry.texts.firstWhere(
      (t) => t.index == objectIndex,
      orElse: () => TextBlock(
        index: objectIndex,
        left: before[0],
        bottom: before[1],
        right: before[2],
        top: before[3],
        baselineY: matrix.ref.f,
        fontSize: before[3] - before[1],
      ),
    );

    final plan = _planAuto(
      pdfium: pdfium,
      arena: arena,
      obj: obj,
      geometry: geometry,
      target: target,
      matrix: matrix,
      text: newText,
      minScale: minScale,
    );

    if (plan != null) {
      _applyPlan(
        pdfium: pdfium,
        arena: arena,
        doc: doc,
        page: page,
        obj: obj,
        matrix: matrix,
        geometry: geometry,
        target: target,
        plan: plan,
      );
      warnings.addAll(plan.warnings);
      return;
    }
  }

  // Zapas: zmniejszenie do oryginalnej szerokości.
  final after = _readBounds(pdfium, arena, obj);
  if (after == null) return;
  final originalWidth = before[2] - before[0];
  final newWidth = after[2] - after[0];
  if (originalWidth <= 0 || newWidth <= originalWidth) return;

  final plan = FitInPlaceStrategy(minScale: minScale).plan(
    text: newText,
    originalWidth: originalWidth,
    newWidth: newWidth,
  );
  if (hasMatrix && plan.requiresTransform) {
    _scaleMatrix(pdfium, matrix, obj, plan.scale);
  }
  warnings.addAll(plan.warnings);
}

/// Wybiera strategię na podstawie tego, co udało się rozpoznać na stronie.
///
/// Kolejność nie jest przypadkowa: komórka tabeli ma twarde granice, więc
/// jeśli ją widzimy, jest najpewniejszą informacją. Dopiero gdy jej nie ma,
/// schodzimy do rozpoznawania kolumny tekstu, które opiera się na heurystyce.
ReflowPlan? _planAuto({
  required PDFium pdfium,
  required Arena arena,
  required FPDF_PAGEOBJECT obj,
  required PageGeometry geometry,
  required TextBlock target,
  required Pointer<FS_MATRIX> matrix,
  required String text,
  required double minScale,
}) {
  final verticalScale = matrix.ref.d.abs();
  final sizePtr = arena<Float>();
  pdfium.FPDFTextObj_GetFontSize(obj, sizePtr);
  final rawFontSize = sizePtr.value;
  final fontSize = rawFontSize * (verticalScale == 0 ? 1 : verticalScale);
  if (fontSize <= 0) return null;

  // Pomiar "przez zastosowanie" — jedyny sposób na prawdziwe metryki fontu,
  // bo publiczne API nie mapuje Unicode na glify.
  double measure(String candidate) {
    if (candidate.isEmpty) return 0;
    if (pdfium.FPDFText_SetText(obj, _toWideString(arena, candidate)) == 0) {
      return double.infinity;
    }
    final bounds = _readBounds(pdfium, arena, obj);
    return bounds == null ? double.infinity : bounds[2] - bounds[0];
  }

  final cell = geometry.detectCell(target);
  if (cell != null) {
    return CellWrapStrategy(minScale: minScale).plan(
      text: text,
      box: cell,
      baselineY: matrix.ref.f,
      fontSize: fontSize,
      metrics: _readFontMetrics(pdfium, arena, obj, fontSize),
      measure: measure,
    );
  }

  final column = geometry.detectColumn(target);
  if (column != null) {
    final metrics = _readFontMetrics(pdfium, arena, obj, fontSize);
    final leading = column.leading ?? fontSize * 1.15;
    final moving = geometry.objectsBelow(target, column);

    // Szerokość liczona osobno dla każdego wiersza — tak tekst opływa
    // obrazek stojący z prawej strony zamiast na niego wchodzić.
    double widthForLine(int lineIndex) {
      final baseline = matrix.ref.f - leading * lineIndex;
      final right = geometry.rightBoundaryAt(
        target: target,
        column: column,
        movingWithText: moving,
        bandBottom: baseline - metrics.descent,
        bandTop: baseline + metrics.ascent,
      );
      return right - target.left;
    }

    return ParagraphFlowStrategy(minScale: minScale).plan(
      text: text,
      widthForLine: widthForLine,
      leading: leading,
      availableHeightBelow: geometry.freeSpaceBelow(target, moving),
      measure: measure,
    );
  }

  return null;
}

/// Wykonuje plan: ustawia pierwszy wiersz, przesuwa treść i dokłada resztę.
void _applyPlan({
  required PDFium pdfium,
  required Arena arena,
  required FPDF_DOCUMENT doc,
  required FPDF_PAGE page,
  required FPDF_PAGEOBJECT obj,
  required Pointer<FS_MATRIX> matrix,
  required PageGeometry geometry,
  required TextBlock target,
  required ReflowPlan plan,
}) {
  // Najpierw robimy miejsce, potem wstawiamy wiersze — dzięki temu nowe
  // wiersze od razu lądują w zwolnionej przestrzeni.
  if (plan.shiftContentBelow > 0) {
    final column = geometry.detectColumn(target);
    if (column != null) {
      for (final index in geometry.objectsBelow(target, column)) {
        final other = pdfium.FPDFPage_GetObject(page, index);
        if (other != nullptr) {
          pdfium.FPDFPageObj_Transform(
              other, 1, 0, 0, 1, 0, -plan.shiftContentBelow);
        }
      }
    }
  }

  // Pierwszy wiersz zostaje w oryginalnym obiekcie — zachowuje font, kolor
  // i wszystkie atrybuty, których nie umielibyśmy odtworzyć.
  if (pdfium.FPDFText_SetText(obj, _toWideString(arena, plan.lines.first)) ==
      0) {
    throw PdfiumBridgeException(
        'Nie udało się ustawić treści pierwszego wiersza.');
  }

  if (plan.requiresTransform) {
    matrix.ref
      ..a = matrix.ref.a * plan.scale
      ..d = matrix.ref.d * plan.scale
      ..f = matrix.ref.f + plan.baselineShift;
    pdfium.FPDFPageObj_SetMatrix(obj, matrix);
  }

  if (plan.isMultiLine) {
    _emitExtraLines(
      pdfium: pdfium,
      arena: arena,
      doc: doc,
      page: page,
      source: obj,
      plan: plan,
    );
  }
}

/// Metryki fontu w punktach, przeliczone na rozmiar widoczny na stronie.
FontMetrics _readFontMetrics(
    PDFium pdfium, Arena arena, FPDF_PAGEOBJECT obj, double fontSize) {
  final font = pdfium.FPDFTextObj_GetFont(obj);
  if (font == nullptr) {
    return FontMetrics(ascent: fontSize * 0.75, descent: fontSize * 0.25);
  }
  final ascent = arena<Float>();
  final descent = arena<Float>();
  final hasAscent = pdfium.FPDFFont_GetAscent(font, fontSize, ascent) != 0;
  final hasDescent = pdfium.FPDFFont_GetDescent(font, fontSize, descent) != 0;

  return FontMetrics(
    ascent: hasAscent && ascent.value > 0 ? ascent.value : fontSize * 0.75,
    // PDFium zwraca descent jako wartość ujemną.
    descent: hasDescent ? descent.value.abs() : fontSize * 0.25,
  );
}

/// Tworzy obiekty tekstowe dla wierszy 2..n.
///
/// Używa uchwytu fontu pobranego z obiektu źródłowego, więc nowe wiersze mają
/// dokładnie ten sam krój — bez ponownego osadzania fontu w dokumencie.
void _emitExtraLines({
  required PDFium pdfium,
  required Arena arena,
  required FPDF_DOCUMENT doc,
  required FPDF_PAGE page,
  required FPDF_PAGEOBJECT source,
  required ReflowPlan plan,
}) {
  final font = pdfium.FPDFTextObj_GetFont(source);
  if (font == nullptr) {
    throw PdfiumBridgeException(
        'Nie udało się odczytać fontu do złożenia kolejnych wierszy.');
  }

  final sizePtr = arena<Float>();
  pdfium.FPDFTextObj_GetFontSize(source, sizePtr);
  final fontSize = sizePtr.value;

  final baseMatrix = arena<FS_MATRIX>();
  pdfium.FPDFPageObj_GetMatrix(source, baseMatrix);
  final baseX = baseMatrix.ref.e;
  final baseY = baseMatrix.ref.f;

  final r = arena<UnsignedInt>(),
      g = arena<UnsignedInt>(),
      b = arena<UnsignedInt>(),
      a = arena<UnsignedInt>();
  final hasColor = pdfium.FPDFPageObj_GetFillColor(source, r, g, b, a) != 0;

  for (var i = 1; i < plan.lines.length; i++) {
    final line = pdfium.FPDFPageObj_CreateTextObj(doc, font, fontSize);
    if (line == nullptr) {
      throw PdfiumBridgeException('Nie udało się utworzyć wiersza $i.');
    }
    if (pdfium.FPDFText_SetText(line, _toWideString(arena, plan.lines[i])) ==
        0) {
      pdfium.FPDFPageObj_Destroy(line);
      throw PdfiumBridgeException('Nie udało się ustawić treści wiersza $i.');
    }

    final m = arena<FS_MATRIX>();
    m.ref
      ..a = baseMatrix.ref.a
      ..b = baseMatrix.ref.b
      ..c = baseMatrix.ref.c
      ..d = baseMatrix.ref.d
      ..e = baseX
      ..f = baseY - plan.leading * i;
    pdfium.FPDFPageObj_SetMatrix(line, m);

    if (hasColor) {
      pdfium.FPDFPageObj_SetFillColor(line, r.value, g.value, b.value, a.value);
    }
    pdfium.FPDFPage_InsertObject(page, line);
  }
}

void _scaleMatrix(PDFium pdfium, Pointer<FS_MATRIX> matrix,
    FPDF_PAGEOBJECT obj, double scale) {
  matrix.ref
    ..a = matrix.ref.a * scale
    ..b = matrix.ref.b * scale
    ..c = matrix.ref.c * scale
    ..d = matrix.ref.d * scale;
  pdfium.FPDFPageObj_SetMatrix(obj, matrix);
}

void _applyDelete(
  PDFium pdfium,
  FPDF_PAGE page,
  Map<String, Object?> op,
  List<String> warnings,
) {
  final objectIndex = op['objectIndex']! as int;
  final obj = pdfium.FPDFPage_GetObject(page, objectIndex);
  if (obj == nullptr) {
    warnings.add('Pominięto usuwanie — obiekt $objectIndex juz nie istnieje.');
    return;
  }
  if (pdfium.FPDFPage_RemoveObject(page, obj) == 0) {
    throw PdfiumBridgeException('Nie udało się usunąć obiektu $objectIndex.');
  }
  // Po RemoveObject własność obiektu przechodzi na nas — trzeba go zwolnic.
  pdfium.FPDFPageObj_Destroy(obj);
}

void _applyInsert(
  PDFium pdfium,
  Arena arena,
  FPDF_DOCUMENT doc,
  FPDF_PAGE page,
  Map<String, Object?> op,
  List<String> warnings,
) {
  final text = op['text']! as String;
  final x = op['x']! as double;
  final y = op['y']! as double;
  final fontSize = op['fontSize']! as double;

  // ZNANE OGRANICZENIE: standardowy font PDF (Helvetica) używa kodowania
  // WinAnsi, które nie zawiera polskich znaków diakrytycznych. Docelowo
  // trzeba tu osadzic pelny font Unicode przez FPDFText_LoadFont.
  final unsupported =
      text.runes.where((r) => r > 0xFF).map(String.fromCharCode).toSet();
  if (unsupported.isNotEmpty) {
    warnings.add(
      'Znaki ${unsupported.join(", ")} nie są obsługiwane przez wbudowany font '
      'Helvetica i mogą się nie pojawić.',
    );
  }

  final fontName = 'Helvetica'.toNativeUtf8(allocator: arena).cast<Char>();
  final font = pdfium.FPDFText_LoadStandardFont(doc, fontName);
  if (font == nullptr) {
    throw PdfiumBridgeException('Nie udało się wczytać fontu Helvetica.');
  }

  final obj = pdfium.FPDFPageObj_CreateTextObj(doc, font, fontSize);
  if (obj == nullptr) {
    throw PdfiumBridgeException('Nie udało się utworzyć obiektu tekstowego.');
  }

  if (pdfium.FPDFText_SetText(obj, _toWideString(arena, text)) == 0) {
    pdfium.FPDFPageObj_Destroy(obj);
    throw PdfiumBridgeException('Nie udało się ustawić treści nowego tekstu.');
  }

  final matrix = arena<FS_MATRIX>();
  matrix.ref
    ..a = 1
    ..b = 0
    ..c = 0
    ..d = 1
    ..e = x
    ..f = y;
  pdfium.FPDFPageObj_SetMatrix(obj, matrix);
  pdfium.FPDFPageObj_SetFillColor(obj, 0, 0, 0, 255);
  pdfium.FPDFPage_InsertObject(page, obj);
}

// --- zapis ------------------------------------------------------------------

void _saveDocument(PDFium pdfium, FPDF_DOCUMENT doc, String outputPath) {
  final file = File(outputPath);
  file.parent.createSync(recursive: true);
  final sink = file.openSync(mode: FileMode.write);

  // Callback zapisu wykonuje się synchronicznie na tym samym wątku, na ktorym
  // wywolujemy FPDF_SaveAsCopy, więc isolateLocal jest bezpieczne i najprostsze.
  int writeBlock(Pointer<FPDF_FILEWRITE> self, Pointer<Void> data, int size) {
    try {
      sink.writeFromSync(data.cast<Uint8>().asTypedList(size));
      return 1;
    } catch (_) {
      return 0;
    }
  }

  final callable = NativeCallable<
      Int Function(Pointer<FPDF_FILEWRITE>, Pointer<Void>,
          UnsignedLong)>.isolateLocal(
    writeBlock,
    exceptionalReturn: 0,
  );
  final fileWrite = calloc<FPDF_FILEWRITE>();

  try {
    fileWrite.ref
      ..version = 1
      ..WriteBlock = callable.nativeFunction;

    if (pdfium.FPDF_SaveAsCopy(doc, fileWrite, _saveNoIncremental) == 0) {
      throw PdfiumBridgeException('PDFium nie zdołał zapisać dokumentu.');
    }
  } finally {
    calloc.free(fileWrite);
    callable.close();
    sink.closeSync();
  }
}

// --- helpery ----------------------------------------------------------------

FPDF_DOCUMENT _openDocument(PDFium pdfium, Arena arena, String path) {
  final pathPtr = path.toNativeUtf8(allocator: arena).cast<Char>();
  final doc = pdfium.FPDF_LoadDocument(pathPtr, nullptr);
  if (doc == nullptr) {
    throw PdfiumBridgeException(
      'Nie udało się otworzyć dokumentu (kod PDFium: ${pdfium.FPDF_GetLastError()}).',
    );
  }
  return doc;
}

Pointer<FPDF_WCHAR> _toWideString(Arena arena, String value) {
  final units = value.codeUnits;
  final ptr = arena<Uint16>(units.length + 1);
  for (var i = 0; i < units.length; i++) {
    ptr[i] = units[i];
  }
  ptr[units.length] = 0;
  return ptr.cast<FPDF_WCHAR>();
}

String _readObjectText(
  PDFium pdfium,
  Arena arena,
  FPDF_PAGEOBJECT obj,
  FPDF_TEXTPAGE textPage,
) {
  final size = pdfium.FPDFTextObj_GetText(obj, textPage, nullptr, 0);
  if (size <= 2) return '';
  final count = size ~/ 2;
  final buffer = arena<Uint16>(count);
  pdfium.FPDFTextObj_GetText(obj, textPage, buffer.cast<FPDF_WCHAR>(), size);
  final units = buffer.asTypedList(count);
  final end = units.indexOf(0);
  return String.fromCharCodes(end >= 0 ? units.sublist(0, end) : units);
}

List<double>? _readBounds(PDFium pdfium, Arena arena, FPDF_PAGEOBJECT obj) {
  final left = arena<Float>();
  final bottom = arena<Float>();
  final right = arena<Float>();
  final top = arena<Float>();
  if (pdfium.FPDFPageObj_GetBounds(obj, left, bottom, right, top) == 0) {
    return null;
  }
  return <double>[left.value, bottom.value, right.value, top.value];
}

String _readFontFamily(PDFium pdfium, Arena arena, FPDF_FONT font) {
  final size = pdfium.FPDFFont_GetFamilyName(font, nullptr, 0);
  if (size <= 1) return '';
  final buffer = arena<Char>(size);
  pdfium.FPDFFont_GetFamilyName(font, buffer, size);
  return buffer.cast<Utf8>().toDartString();
}

int _readFillColor(PDFium pdfium, Arena arena, FPDF_PAGEOBJECT obj) {
  final r = arena<UnsignedInt>();
  final g = arena<UnsignedInt>();
  final b = arena<UnsignedInt>();
  final a = arena<UnsignedInt>();
  if (pdfium.FPDFPageObj_GetFillColor(obj, r, g, b, a) == 0) {
    return 0xFF000000;
  }
  return (a.value << 24) | (r.value << 16) | (g.value << 8) | b.value;
}

class PdfiumBridgeException implements Exception {
  PdfiumBridgeException(this.message);
  final String message;

  @override
  String toString() => message;
}
