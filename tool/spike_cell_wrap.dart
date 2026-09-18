// Test integracyjny lamania tekstu w komorce.
//
// Wywoluje PRAWDZIWE funkcje z pdfium_bridge.dart — te same, ktorych uzywa
// aplikacja — zeby sprawdzic caly lancuch: wykrycie granic komorki,
// podzial na wiersze, zlozenie kolejnych wierszy i zapis.
//
// Uruchomienie: dart run tool/spike_cell_wrap.dart

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import '../lib/features/pdf_editor/infrastructure/pdfium_bridge.dart' as bridge;

late final PDFium pdfium;

const cellLeft = 60.0;
const cellRight = 260.0;
const cellTop = 730.0;
const cellBottom = 690.0;

void main() {
  pdfium = getPdfium();
  final config = calloc<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final dir = Directory.systemTemp.createTempSync('pdf_cell');
  final src = '${dir.path}/cell.pdf';

  try {
    _buildCell(src);
    print('Komorka: x $cellLeft..$cellRight  y $cellBottom..$cellTop  '
        '(wysokosc ${cellTop - cellBottom} pt, font 11 pt)');

    final objects = bridge.readPageTextObjects({'path': src, 'pageIndex': 0});
    print('\nPrzed edycja:');
    for (final o in objects) {
      print('   "${o['text']}"  x ${_f(o['left'])}..${_f(o['right'])}  '
          'y ${_f(o['bottom'])}..${_f(o['top'])}');
    }
    final target = objects.first;

    _scenario(
      src: src,
      dir: dir.path,
      label: 'A. Tekst wymagajacy 2 wierszy',
      objectIndex: target['objectIndex']! as int,
      newText: 'Konstantynopol Wielkopolski Gorny nad Bystrzyca',
    );

    _scenario(
      src: src,
      dir: dir.path,
      label: 'B. Tekst bardzo dlugi — 2 wiersze nie wystarcza',
      objectIndex: target['objectIndex']! as int,
      newText: 'Konstantynopol Wielkopolski Gorny nad Bystrzyca Dolna Prawa '
          'Strona Zachodnia Kolonia Pierwsza',
    );

    _scenario(
      src: src,
      dir: dir.path,
      label: 'C. Tekst krotszy — nic nie powinno sie zmienic',
      objectIndex: target['objectIndex']! as int,
      newText: 'Krakow',
    );
  } finally {
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}

void _scenario({
  required String src,
  required String dir,
  required String label,
  required int objectIndex,
  required String newText,
}) {
  final out = '$dir/${label.substring(0, 1)}.pdf';
  print('\n=== $label ===');
  print('   nowa tresc: "$newText"');

  final result = bridge.applyOperations({
    'sourcePath': src,
    'outputPath': out,
    'operations': [
      {
        'type': 'replace',
        'pageIndex': 0,
        'objectIndex': objectIndex,
        'newText': newText,
        'reflowMode': 'cellAwareWrap',
      }
    ],
    'minScale': 0.6,
  });

  final after = bridge.readPageTextObjects({'path': out, 'pageIndex': 0});
  print('   wynik: ${after.length} obiekt(ow) tekstowych');
  var allInside = true;
  for (final o in after) {
    final l = o['left']! as double;
    final r = o['right']! as double;
    final b = o['bottom']! as double;
    final t = o['top']! as double;
    final inside = l >= cellLeft - 1 &&
        r <= cellRight + 1 &&
        b >= cellBottom - 1 &&
        t <= cellTop + 1;
    if (!inside) allInside = false;
    print('     "${o['text']}"');
    print('       x ${_f(l)}..${_f(r)}  y ${_f(b)}..${_f(t)}  '
        'font ${_f(o['fontSize'])}  ${inside ? "w komorce" : "POZA KOMORKA"}');
  }

  final warnings = (result['warnings']! as List).cast<String>();
  for (final w in warnings) {
    print('   ostrzezenie: $w');
  }
  print(allInside ? '   >>> OK, wszystko miesci sie w komorce'
      : '   >>> UWAGA: tresc wychodzi poza komorke');
}

String _f(Object? v) => (v! as double).toStringAsFixed(1);

void _buildCell(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);

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
    final m = arena<FS_MATRIX>();
    m.ref
      ..a = 1
      ..b = 0
      ..c = 0
      ..d = 1
      ..e = 65
      ..f = 715;
    pdfium.FPDFPageObj_SetMatrix(obj, m);
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
  pdfium.FPDF_SaveAsCopy(doc, fw, 2);
  calloc.free(fw);
  callable.close();
  file.closeSync();
}
