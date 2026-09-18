// Faza 0 — weryfikacja rdzenia.
//
// Sprawdza na zywym PDFium, czy:
//  1. da sie stworzyc dokument z tekstem i go zapisac,
//  2. FPDFText_SetText faktycznie podmienia tresc ISTNIEJACEGO obiektu,
//  3. FPDFPageObj_GetBounds przelicza sie po zmianie tekstu (to zalozenie
//     stoi za caloscia Tier A reflow, a naglowek PDFium o tym milczy),
//  4. zapis przez FPDF_SaveAsCopy daje plik, w ktorym zmiana jest trwala.
//
// Uruchomienie: dart run tool/spike.dart

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

  final dir = Directory.systemTemp.createTempSync('pdf_spike');
  final original = '${dir.path}/original.pdf';
  final edited = '${dir.path}/edited.pdf';

  try {
    _step('1. Tworze PDF z tekstem "Jan Kowalski mieszka w Warszawie."');
    _createDocument(original);
    print('   zapisany, ${File(original).lengthSync()} B');

    _step('2. Czytam obiekty tekstowe z zapisanego pliku');
    final before = _readObjects(original);
    for (final o in before) {
      print('   [${o.index}] "${o.text}"  szerokosc=${o.width.toStringAsFixed(2)}');
    }
    if (before.isEmpty) {
      print('   BLAD: brak obiektow tekstowych');
      return;
    }

    _step('3. Podmieniam "Warszawie" -> "Krakowie" (FPDFText_SetText)');
    final target = before.first;
    final newText = target.text.replaceAll('Warszawie', 'Krakowie');
    final measured = _replaceText(original, edited, 0, target.index, newText);
    print('   szerokosc przed: ${measured.before.toStringAsFixed(2)}');
    print('   szerokosc po:    ${measured.after.toStringAsFixed(2)}');

    final recomputed = (measured.before - measured.after).abs() > 0.01;
    print(recomputed
        ? '   >>> GetBounds PRZELICZYL sie po SetText — Tier A reflow wykonalny'
        : '   >>> GetBounds NIE przeliczyl sie — Tier A wymaga innego pomiaru');

    _step('4. Czytam zapisany plik ponownie');
    final after = _readObjects(edited);
    for (final o in after) {
      print('   [${o.index}] "${o.text}"');
    }

    final ok = after.any((o) => o.text.contains('Krakowie'));
    print('');
    print(ok
        ? 'WYNIK: edycja istniejacego tekstu DZIALA i jest trwala w zapisanym PDF.'
        : 'WYNIK: edycja NIE zostala zapisana.');
  } finally {
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}

void _step(String label) => print('\n$label');

class _TextObject {
  _TextObject(this.index, this.text, this.width);
  final int index;
  final String text;
  final double width;
}

class _Measured {
  _Measured(this.before, this.after);
  final double before;
  final double after;
}

void _createDocument(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);

    final fontName = 'Helvetica'.toNativeUtf8(allocator: arena).cast<Char>();
    final font = pdfium.FPDFText_LoadStandardFont(doc, fontName);
    final obj = pdfium.FPDFPageObj_CreateTextObj(doc, font, 14);

    pdfium.FPDFText_SetText(
        obj, _wide(arena, 'Jan Kowalski mieszka w Warszawie.'));

    final matrix = arena<FS_MATRIX>();
    matrix.ref
      ..a = 1
      ..b = 0
      ..c = 0
      ..d = 1
      ..e = 60
      ..f = 700;
    pdfium.FPDFPageObj_SetMatrix(obj, matrix);
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

List<_TextObject> _readObjects(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_LoadDocument(
        path.toNativeUtf8(allocator: arena).cast<Char>(), nullptr);
    if (doc == nullptr) {
      print('   BLAD otwarcia: ${pdfium.FPDF_GetLastError()}');
      return [];
    }
    final page = pdfium.FPDF_LoadPage(doc, 0);
    final textPage = pdfium.FPDFText_LoadPage(page);

    final out = <_TextObject>[];
    final count = pdfium.FPDFPage_CountObjects(page);
    for (var i = 0; i < count; i++) {
      final obj = pdfium.FPDFPage_GetObject(page, i);
      if (pdfium.FPDFPageObj_GetType(obj) != FPDF_PAGEOBJ_TEXT) continue;

      final size = pdfium.FPDFTextObj_GetText(obj, textPage, nullptr, 0);
      final buf = arena<Uint16>(size ~/ 2);
      pdfium.FPDFTextObj_GetText(obj, textPage, buf.cast<FPDF_WCHAR>(), size);
      final units = buf.asTypedList(size ~/ 2);
      final end = units.indexOf(0);
      final text =
          String.fromCharCodes(end >= 0 ? units.sublist(0, end) : units);

      out.add(_TextObject(i, text, _width(arena, obj)));
    }

    pdfium.FPDFText_ClosePage(textPage);
    pdfium.FPDF_ClosePage(page);
    pdfium.FPDF_CloseDocument(doc);
    return out;
  } finally {
    arena.releaseAll();
  }
}

_Measured _replaceText(
    String src, String dst, int pageIndex, int objectIndex, String newText) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_LoadDocument(
        src.toNativeUtf8(allocator: arena).cast<Char>(), nullptr);
    final page = pdfium.FPDF_LoadPage(doc, pageIndex);
    final obj = pdfium.FPDFPage_GetObject(page, objectIndex);

    final before = _width(arena, obj);
    final ok = pdfium.FPDFText_SetText(obj, _wide(arena, newText));
    if (ok == 0) print('   UWAGA: FPDFText_SetText zwrocil false');
    final after = _width(arena, obj);

    pdfium.FPDFPage_GenerateContent(page);
    pdfium.FPDF_ClosePage(page);
    _save(doc, dst);
    pdfium.FPDF_CloseDocument(doc);

    return _Measured(before, after);
  } finally {
    arena.releaseAll();
  }
}

double _width(Arena arena, FPDF_PAGEOBJECT obj) {
  final l = arena<Float>(), b = arena<Float>(), r = arena<Float>(), t = arena<Float>();
  if (pdfium.FPDFPageObj_GetBounds(obj, l, b, r, t) == 0) return -1;
  return r.value - l.value;
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

  if (pdfium.FPDF_SaveAsCopy(doc, fw, 2) == 0) {
    print('   BLAD zapisu');
  }
  calloc.free(fw);
  callable.close();
  file.closeSync();
}
