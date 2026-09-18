// Test integracyjny reflow na kodzie produkcyjnym.
//
// Strona odwzorowuje dwa realne przypadki naraz:
//  - tabela narysowana jako JEDEN zlozony obiekt PATH (tak robi wiekszosc
//    generatorow PDF) — bbox obiektu to cala tabela, wiec granice komorki
//    da sie odczytac tylko z segmentow sciezki,
//  - akapit zwyklego tekstu, pod ktorym jest dalsza tresc i stopka.
//
// Uruchomienie: dart run tool/spike_layout.dart

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import '../lib/features/pdf_editor/infrastructure/pdfium_bridge.dart' as bridge;

late final PDFium pdfium;

const colX = [60.0, 260.0, 460.0];
const rowY = [690.0, 730.0, 770.0];
const cell = (left: 60.0, right: 260.0, bottom: 690.0, top: 730.0);

const bodyLeft = 60.0;
const bodyBaselines = [600.0, 586.0, 572.0, 558.0];
const footerBaseline = 30.0;
const imageRect = (left: 200.0, bottom: 578.0, width: 120.0, height: 44.0);

void main() {
  pdfium = getPdfium();
  final config = calloc<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final dir = Directory.systemTemp.createTempSync('pdf_layout');
  final src = '${dir.path}/page.pdf';

  try {
    _buildPage(src);
    final objects = bridge.readPageTextObjects({'path': src, 'pageIndex': 0});
    print('Stan wyjsciowy:');
    for (final o in objects) {
      print('   [${o['objectIndex']}] "${o['text']}"  '
          'x ${_f(o['left'])}..${_f(o['right'])}  y ${_f(o['bottom'])}..${_f(o['top'])}');
    }

    final cellObj = objects.firstWhere((o) => o['text'] == 'Warszawa');
    final bodyObj = objects.firstWhere((o) => (o['text']! as String).startsWith('Drugi'));

    _run(
      src: src,
      out: '${dir.path}/cell.pdf',
      label: 'KOMORKA TABELI (siatka jako jeden PATH)',
      objectIndex: cellObj['objectIndex']! as int,
      newText: 'Konstantynopol Wielkopolski Gorny nad Bystrzyca',
      checkCell: true,
    );

    _run(
      src: src,
      out: '${dir.path}/body.pdf',
      label: 'ZWYKLY TEKST (oczekiwane: nowy wiersz + przesuniecie reszty)',
      objectIndex: bodyObj['objectIndex']! as int,
      newText: 'Drugi wiersz akapitu zostal znacznie wydluzony i powinien '
          'zajac dwa wiersze zamiast zostac sciśniety do jednego',
      checkCell: false,
    );
    _run(
      src: src,
      out: '${dir.path}/image.pdf',
      label: 'TEKST OBOK OBRAZKA (oczekiwane: zawiniecie przed obrazkiem)',
      objectIndex: objects
          .firstWhere((o) => (o['text']! as String).startsWith('Pierwszy'))['objectIndex']! as int,
      newText: 'Pierwszy wiersz akapitu ktory jest teraz duzo dluzszy i musi '
          'ominac obrazek stojacy po prawej stronie strony',
      checkCell: false,
      imageGuard: true,
    );
  } finally {
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}

void _run({
  required String src,
  required String out,
  required String label,
  required int objectIndex,
  required String newText,
  required bool checkCell,
  bool imageGuard = false,
}) {
  print('\n=== $label ===');
  final result = bridge.applyOperations({
    'sourcePath': src,
    'outputPath': out,
    'operations': [
      {
        'type': 'replace',
        'pageIndex': 0,
        'objectIndex': objectIndex,
        'newText': newText,
        'reflowMode': 'auto',
      }
    ],
    'minScale': 0.6,
  });

  final after = bridge.readPageTextObjects({'path': out, 'pageIndex': 0});
  var problems = 0;

  for (final o in after) {
    final text = o['text']! as String;
    final l = o['left']! as double;
    final r = o['right']! as double;
    final b = o['bottom']! as double;
    final t = o['top']! as double;

    var note = '';
    if (checkCell && !text.startsWith('Pierwszy') &&
        !text.startsWith('Drugi') && !text.startsWith('Trzeci') &&
        !text.startsWith('Czwarty') && !text.startsWith('Stopka') &&
        text != 'Naglowek') {
      final inside = l >= cell.left - 0.5 && r <= cell.right + 0.5 &&
          b >= cell.bottom - 0.5 && t <= cell.top + 0.5;
      if (!inside) {
        problems++;
        note = '   <-- POZA KOMORKA';
      } else {
        final marginTop = cell.top - t;
        final marginBottom = b - cell.bottom;
        note = '   marginesy: gora ${_n(marginTop)} dol ${_n(marginBottom)}';
      }
    }
    print('   "$text"');
    print('     x ${_n(l)}..${_n(r)}  y ${_n(b)}..${_n(t)}  '
        'font ${_n(o['fontSize']! as double)}$note');
  }

  if (imageGuard) {
    final imgLeft = imageRect.left;
    final imgBottom = imageRect.bottom;
    final imgTop = imageRect.bottom + imageRect.height;
    var collisions = 0;
    for (final o in after) {
      final r = o['right']! as double;
      final b = o['bottom']! as double;
      final t = o['top']! as double;
      final overlapsImageBand = b < imgTop && t > imgBottom;
      if (overlapsImageBand && r > imgLeft + 0.5) {
        collisions++;
        print('   KOLIZJA z obrazkiem: "${o['text']}" siega do ${_n(r)}');
      }
    }
    // Dowod, ze szerokosc liczona jest per wiersz: ponizej obrazka wiersz
    // moze byc szerszy niz jego lewa krawedz.
    final widerBelow = after.any((o) {
      final r = o['right']! as double;
      final t = o['top']! as double;
      return t <= imgBottom && r > imgLeft + 0.5;
    });
    print(collisions == 0
        ? '   >>> OK: zaden wiersz nie wchodzi na obrazek (lewa krawedz ${_n(imgLeft)})'
        : '   >>> BLAD: $collisions wierszy wchodzi na obrazek');
    print(widerBelow
        ? '   >>> OK: wiersz ponizej obrazka korzysta z pelnej szerokosci kolumny'
        : '   >>> UWAGA: zaden wiersz ponizej obrazka nie przekroczyl jego krawedzi');
  }

  for (final w in (result['warnings']! as List)) {
    print('   [i] $w');
  }
  if (checkCell) {
    print(problems == 0
        ? '   >>> OK: cala tresc w komorce'
        : '   >>> BLAD: $problems fragmentow poza komorka');
  }
}

String _f(Object? v) => (v! as double).toStringAsFixed(1);
String _n(double v) => v.toStringAsFixed(1);

void _buildPage(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);

    // Siatka tabeli jako JEDEN obiekt — najtrudniejszy przypadek detekcji.
    final grid = pdfium.FPDFPageObj_CreateNewPath(colX[0], rowY[0]);
    pdfium.FPDFPath_LineTo(grid, colX[2], rowY[0]);
    for (var i = 1; i < rowY.length; i++) {
      pdfium.FPDFPath_MoveTo(grid, colX[0], rowY[i]);
      pdfium.FPDFPath_LineTo(grid, colX[2], rowY[i]);
    }
    for (final x in colX) {
      pdfium.FPDFPath_MoveTo(grid, x, rowY[0]);
      pdfium.FPDFPath_LineTo(grid, x, rowY[2]);
    }
    pdfium.FPDFPageObj_SetStrokeColor(grid, 0, 0, 0, 255);
    pdfium.FPDFPageObj_SetStrokeWidth(grid, 1);
    pdfium.FPDFPath_SetDrawMode(grid, 0, 1);
    pdfium.FPDFPage_InsertObject(page, grid);

    final fontName = 'Helvetica'.toNativeUtf8(allocator: arena).cast<Char>();
    final font = pdfium.FPDFText_LoadStandardFont(doc, fontName);

    void text(String value, double x, double y, double size) {
      final obj = pdfium.FPDFPageObj_CreateTextObj(doc, font, size);
      pdfium.FPDFText_SetText(obj, _wide(arena, value));
      final m = arena<FS_MATRIX>();
      m.ref
        ..a = 1
        ..b = 0
        ..c = 0
        ..d = 1
        ..e = x
        ..f = y;
      pdfium.FPDFPageObj_SetMatrix(obj, m);
      pdfium.FPDFPageObj_SetFillColor(obj, 0, 0, 0, 255);
      pdfium.FPDFPage_InsertObject(page, obj);
    }

    text('Naglowek', 65, 745, 11);
    text('Warszawa', 65, 705, 11);

    text('Pierwszy wiersz akapitu w kolumnie tekstu strony', bodyLeft,
        bodyBaselines[0], 11);
    text('Drugi wiersz akapitu', bodyLeft, bodyBaselines[1], 11);
    text('Trzeci wiersz akapitu ktory jest dosc dlugi', bodyLeft,
        bodyBaselines[2], 11);
    text('Czwarty wiersz akapitu konczy blok tekstu', bodyLeft,
        bodyBaselines[3], 11);

    text('Stopka - strona 1', bodyLeft, footerBaseline, 9);

    // Obrazek po prawej stronie dwoch pierwszych wierszy akapitu.
    final bitmap = pdfium.FPDFBitmap_Create(80, 40, 0);
    pdfium.FPDFBitmap_FillRect(bitmap, 0, 0, 80, 40, 0xFF3D5AFE);
    final image = pdfium.FPDFPageObj_NewImageObj(doc);
    final pages = arena<FPDF_PAGE>();
    pages[0] = page;
    pdfium.FPDFImageObj_SetBitmap(pages, 1, image, bitmap);
    final im = arena<FS_MATRIX>();
    im.ref
      ..a = imageRect.width
      ..b = 0
      ..c = 0
      ..d = imageRect.height
      ..e = imageRect.left
      ..f = imageRect.bottom;
    pdfium.FPDFPageObj_SetMatrix(image, im);
    pdfium.FPDFPage_InsertObject(page, image);
    pdfium.FPDFBitmap_Destroy(bitmap);

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
