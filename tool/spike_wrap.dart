// Spike Tier C — czy da sie zlamac tekst na wiersze wewnatrz komorki tabeli.
//
// Testuje trzy rzeczy, od ktorych zalezy cala funkcja:
//  1. Czy FPDFPageObj_CreateTextObj przyjmie uchwyt fontu pobrany
//     z ISTNIEJACEGO obiektu (FPDFTextObj_GetFont). Bez tego nowe wiersze
//     musialyby uzywac innego kroju niz oryginal.
//  2. Czy pomiar "przez zastosowanie" pozwala poprawnie lamac tekst
//     na zadana szerokosc.
//  3. Czy ramki tabeli (obiekty typu PATH) da sie odczytac na tyle, zeby
//     wyznaczyc realne granice komorki.
//
// Uruchomienie: dart run tool/spike_wrap.dart

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

late final PDFium pdfium;

void main() {
  pdfium = getPdfium();
  final config = calloc<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final dir = Directory.systemTemp.createTempSync('pdf_wrap');
  final source = '${dir.path}/table.pdf';
  final wrapped = '${dir.path}/wrapped.pdf';

  try {
    print('1. Tworze PDF z ramka tabeli i tekstem w komorce');
    _createTable(source);

    print('\n2. Odczytuje geometrie strony');
    _describe(source);

    print('\n3. Probuje zlamac tekst na wiersze w obrebie komorki');
    final ok = _wrapCellText(source, wrapped);

    print('\n4. Odczytuje wynik');
    _describe(wrapped);

    print('');
    print(ok
        ? 'WYNIK: lamanie wiersza z zachowaniem oryginalnego fontu DZIALA.'
        : 'WYNIK: nie udalo sie utworzyc nowego wiersza z fontem oryginalu.');
  } finally {
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}

// Komorka: x 60..260, y 690..730. Tekst startuje w 65,705.
const cellLeft = 60.0;
const cellRight = 260.0;
const cellTop = 730.0;
const cellBottom = 690.0;

void _createTable(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);

    // Ramka komorki jako sciezka — tak wygladaja tabele w prawdziwych PDF-ach.
    final border = pdfium.FPDFPageObj_CreateNewPath(cellLeft, cellBottom);
    pdfium.FPDFPath_LineTo(border, cellRight, cellBottom);
    pdfium.FPDFPath_LineTo(border, cellRight, cellTop);
    pdfium.FPDFPath_LineTo(border, cellLeft, cellTop);
    pdfium.FPDFPath_Close(border);
    pdfium.FPDFPageObj_SetStrokeColor(border, 0, 0, 0, 255);
    pdfium.FPDFPageObj_SetStrokeWidth(border, 1);
    pdfium.FPDFPath_SetDrawMode(border, 0, 1);
    pdfium.FPDFPage_InsertObject(page, border);

    final fontName = 'Helvetica'.toNativeUtf8(allocator: arena).cast<Char>();
    final font = pdfium.FPDFText_LoadStandardFont(doc, fontName);
    final obj = pdfium.FPDFPageObj_CreateTextObj(doc, font, 11);
    pdfium.FPDFText_SetText(obj, _wide(arena, 'Warszawa'));
    _place(arena, obj, 65, 705);
    pdfium.FPDFPageObj_SetFillColor(obj, 0, 0, 0, 255);
    pdfium.FPDFPage_InsertObject(page, obj);

    pdfium.FPDFPage_GenerateContent(page);
    pdfium.FPDF_ClosePage(page);
    _save(doc, path);
    pdfium.FPDF_CloseDocument(doc);
  } finally {
    arena.releaseAll();
  }
}

void _describe(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_LoadDocument(
        path.toNativeUtf8(allocator: arena).cast<Char>(), nullptr);
    final page = pdfium.FPDF_LoadPage(doc, 0);
    final textPage = pdfium.FPDFText_LoadPage(page);

    final count = pdfium.FPDFPage_CountObjects(page);
    for (var i = 0; i < count; i++) {
      final obj = pdfium.FPDFPage_GetObject(page, i);
      final type = pdfium.FPDFPageObj_GetType(obj);
      final b = _bounds(arena, obj);

      if (type == FPDF_PAGEOBJ_TEXT) {
        print('   [$i] TEXT  "${_text(arena, obj, textPage)}"  '
            'x ${b[0].toStringAsFixed(1)}..${b[2].toStringAsFixed(1)} '
            'y ${b[1].toStringAsFixed(1)}..${b[3].toStringAsFixed(1)}');
      } else if (type == FPDF_PAGEOBJ_PATH) {
        final segments = pdfium.FPDFPath_CountSegments(obj);
        print('   [$i] PATH  segmentow=$segments  '
            'x ${b[0].toStringAsFixed(1)}..${b[2].toStringAsFixed(1)} '
            'y ${b[1].toStringAsFixed(1)}..${b[3].toStringAsFixed(1)}'
            '   <- granice komorki');
      }
    }

    pdfium.FPDFText_ClosePage(textPage);
    pdfium.FPDF_ClosePage(page);
    pdfium.FPDF_CloseDocument(doc);
  } finally {
    arena.releaseAll();
  }
}

bool _wrapCellText(String src, String dst) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_LoadDocument(
        src.toNativeUtf8(allocator: arena).cast<Char>(), nullptr);
    final page = pdfium.FPDF_LoadPage(doc, 0);

    // Znajdz obiekt tekstowy w komorce.
    FPDF_PAGEOBJECT textObj = nullptr;
    final count = pdfium.FPDFPage_CountObjects(page);
    for (var i = 0; i < count; i++) {
      final o = pdfium.FPDFPage_GetObject(page, i);
      if (pdfium.FPDFPageObj_GetType(o) == FPDF_PAGEOBJ_TEXT) {
        textObj = o;
        break;
      }
    }
    if (textObj == nullptr) return false;

    // KLUCZOWY TEST: uchwyt fontu z istniejacego obiektu.
    final font = pdfium.FPDFTextObj_GetFont(textObj);
    print('   uchwyt fontu z istniejacego obiektu: '
        '${font == nullptr ? "NULL" : "ok"}');
    if (font == nullptr) return false;

    final sizePtr = arena<Float>();
    pdfium.FPDFTextObj_GetFontSize(textObj, sizePtr);
    final fontSize = sizePtr.value;

    final origin = _origin(arena, textObj);
    final newText = 'Konstantynopol Wielkopolski Gorny nad Bystrzyca Dolna Prawa';
    const padding = 5.0;
    final maxWidth = cellRight - cellLeft - 2 * padding;

    // Pomiar "przez zastosowanie": ustawiamy kandydata i czytamy bounds.
    double measure(String s) {
      pdfium.FPDFText_SetText(textObj, _wide(arena, s));
      final b = _bounds(arena, textObj);
      return b[2] - b[0];
    }

    final lines = _breakIntoLines(newText, maxWidth, measure);
    print('   dostepna szerokosc: ${maxWidth.toStringAsFixed(1)} pt');
    print('   podzial na ${lines.length} wiersze:');
    for (final l in lines) {
      print('     "$l"  (${measure(l).toStringAsFixed(1)} pt)');
    }

    final leading = fontSize * 1.2;

    // Pierwszy wiersz zostaje w istniejacym obiekcie — zachowuje wszystko.
    pdfium.FPDFText_SetText(textObj, _wide(arena, lines.first));

    // Kolejne wiersze to NOWE obiekty z tym samym uchwytem fontu.
    for (var i = 1; i < lines.length; i++) {
      final lineObj = pdfium.FPDFPageObj_CreateTextObj(doc, font, fontSize);
      if (lineObj == nullptr) {
        print('   BLAD: CreateTextObj odrzucil uchwyt fontu z oryginalu');
        return false;
      }
      if (pdfium.FPDFText_SetText(lineObj, _wide(arena, lines[i])) == 0) {
        print('   BLAD: SetText na nowym wierszu');
        return false;
      }
      _place(arena, lineObj, origin[0], origin[1] - leading * i);
      pdfium.FPDFPageObj_SetFillColor(lineObj, 0, 0, 0, 255);
      pdfium.FPDFPage_InsertObject(page, lineObj);
    }

    pdfium.FPDFPage_GenerateContent(page);
    pdfium.FPDF_ClosePage(page);
    _save(doc, dst);
    pdfium.FPDF_CloseDocument(doc);
    return true;
  } finally {
    arena.releaseAll();
  }
}

/// Zachlanny podzial na wiersze mieszczace sie w [maxWidth].
List<String> _breakIntoLines(
    String text, double maxWidth, double Function(String) measure) {
  final words = text.split(' ');
  final lines = <String>[];
  var current = '';

  for (final word in words) {
    final candidate = current.isEmpty ? word : '$current $word';
    if (measure(candidate) <= maxWidth || current.isEmpty) {
      current = candidate;
    } else {
      lines.add(current);
      current = word;
    }
  }
  if (current.isNotEmpty) lines.add(current);
  return lines;
}

void _place(Arena arena, FPDF_PAGEOBJECT obj, double x, double y) {
  final m = arena<FS_MATRIX>();
  m.ref
    ..a = 1
    ..b = 0
    ..c = 0
    ..d = 1
    ..e = x
    ..f = y;
  pdfium.FPDFPageObj_SetMatrix(obj, m);
}

List<double> _origin(Arena arena, FPDF_PAGEOBJECT obj) {
  final m = arena<FS_MATRIX>();
  pdfium.FPDFPageObj_GetMatrix(obj, m);
  return [m.ref.e, m.ref.f];
}

List<double> _bounds(Arena arena, FPDF_PAGEOBJECT obj) {
  final l = arena<Float>(),
      b = arena<Float>(),
      r = arena<Float>(),
      t = arena<Float>();
  if (pdfium.FPDFPageObj_GetBounds(obj, l, b, r, t) == 0) {
    return [0, 0, 0, 0];
  }
  return [l.value, b.value, r.value, t.value];
}

String _text(Arena arena, FPDF_PAGEOBJECT obj, FPDF_TEXTPAGE tp) {
  final size = pdfium.FPDFTextObj_GetText(obj, tp, nullptr, 0);
  if (size <= 2) return '';
  final buf = arena<Uint16>(size ~/ 2);
  pdfium.FPDFTextObj_GetText(obj, tp, buf.cast<FPDF_WCHAR>(), size);
  final units = buf.asTypedList(size ~/ 2);
  final end = units.indexOf(0);
  return String.fromCharCodes(end >= 0 ? units.sublist(0, end) : units);
}

Pointer<FPDF_WCHAR> _wide(Arena arena, String value) {
  final units = value.codeUnits;
  final ptr = arena<Uint16>(units.length + 1);
  for (var i = 0; i < units.length; i++) {
    ptr[i] = units[i];
  }
  ptr[units.length] = 0;
  return ptr.cast<FPDF_WCHAR>();
}

void _save(FPDF_DOCUMENT doc, String path) {
  final file = File(path).openSync(mode: FileMode.write);
  int writeBlock(Pointer<FPDF_FILEWRITE> self, Pointer<Void> data, int size) {
    file.writeFromSync(data.cast<Uint8>().asTypedList(size));
    return 1;
  }

  final callable = NativeCallable<
      Int Function(Pointer<FPDF_FILEWRITE>, Pointer<Void>,
          UnsignedLong)>.isolateLocal(writeBlock, exceptionalReturn: 0);
  final fw = calloc<FPDF_FILEWRITE>();
  fw.ref
    ..version = 1
    ..WriteBlock = callable.nativeFunction;
  if (pdfium.FPDF_SaveAsCopy(doc, fw, 2) == 0) print('   BLAD zapisu');
  calloc.free(fw);
  callable.close();
  file.closeSync();
}
