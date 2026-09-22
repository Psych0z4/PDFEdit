// Test regresyjny — czy zwykly akapit nie jest brany za komorke tabeli.
//
// Realna strona prawie zawsze ma linie, ktore NIE sa tabela: kreska pod
// naglowkiem, kreska nad stopka, ramka strony. Jesli wykrywanie komorki
// zlapie je jako krawedzie, to zwykly akapit dostanie strategie komorkowa:
// zostanie wycentrowany w pionie w wymyslonym pudelku i NIE przesunie
// tresci ponizej. Efekt: teksty nachodza na siebie.
//
// Ten test sprawdza, ze tak sie nie dzieje.
//
// Uruchomienie: dart run tool/spike_false_cell.dart

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import '../lib/features/pdf_editor/infrastructure/pdfium_bridge.dart' as bridge;

late final PDFium pdfium;

const pageW = 595.0;
const pageH = 842.0;
const margin = 60.0;

// Akapit: cztery wiersze co 14 pt.
const bodyBaselines = [600.0, 586.0, 572.0, 558.0];

void main() {
  pdfium = getPdfium();
  final config = calloc<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final dir = Directory.systemTemp.createTempSync('pdf_falsecell');
  final src = '${dir.path}/page.pdf';

  try {
    _build(src);
    final before = bridge.readPageTextObjects({'path': src, 'pageIndex': 0});
    print('Strona: kreska pod naglowkiem (y=700), kreska nad stopka (y=60),');
    print('ramka strony po bokach (x=40 i x=555). Zaden z tych elementow');
    print('nie jest tabela.\n');

    print('Przed edycja:');
    final positions = <String, double>{};
    for (final o in before) {
      final t = o['text']! as String;
      positions[t] = o['bottom']! as double;
      print('   "$t"  y=${(o['bottom']! as double).toStringAsFixed(1)}');
    }

    final target = before.firstWhere(
        (o) => (o['text']! as String).startsWith('Drugi'));

    var totalProblems = 0;
    for (final reencode in [false, true]) {
      totalProblems += _runCase(
        dir: dir.path,
        src: src,
        target: target,
        positions: positions,
        reencode: reencode,
      );
    }
    print('');
    print(totalProblems == 0
        ? 'WYNIK KONCOWY: uklad poprawny w obu wariantach'
        : 'WYNIK KONCOWY: $totalProblems problemow');
  } finally {
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}

/// Jeden przebieg: edycja tego samego fragmentu, z naprawa kodowania i bez.
int _runCase({
  required String dir,
  required String src,
  required Map<String, Object?> target,
  required Map<String, double> positions,
  required bool reencode,
}) {
    print('');
    print('=== ${reencode ? "Z NAPRAWA kodowania" : "BEZ naprawy"} ===');
    final out = '$dir/out_$reencode.pdf';
    final result = bridge.applyOperations({
      'sourcePath': src,
      'outputPath': out,
      'operations': [
        {
          'type': 'replace',
          'pageIndex': 0,
          'objectIndex': target['objectIndex'],
          'newText': 'Drugi wiersz akapitu zostal wydluzony na tyle, ze musi '
              'zajac dwa wiersze zamiast jednego',
          'reflowMode': 'auto',
          'reencodeFont': reencode,
        }
      ],
      'minScale': 0.6,
    });

    final after = bridge.readPageTextObjects({'path': out, 'pageIndex': 0});
    print('\nPo edycji:');
    for (final o in after) {
      print('   "${o['text']}"  '
          'y ${(o['bottom']! as double).toStringAsFixed(1)}'
          '..${(o['top']! as double).toStringAsFixed(1)}');
    }
    for (final w in (result['warnings']! as List)) {
      print('   [i] $w');
    }

    print('');
    var problems = 0;

    // 1. Nieedytowane wiersze NIE moga zostac w miejscu, jesli akapit urosl —
    //    musza zjechac, zeby zrobic miejsce.
    final third = after.firstWhere(
        (o) => (o['text']! as String).startsWith('Trzeci'));
    final thirdBottom = third['bottom']! as double;
    final movedDown = thirdBottom < positions['Trzeci wiersz akapitu']! - 1;
    if (!movedDown) {
      problems++;
      print('BLAD: "Trzeci wiersz" nie zjechal w dol '
          '(${positions['Trzeci wiersz akapitu']!.toStringAsFixed(1)} -> '
          '${thirdBottom.toStringAsFixed(1)})');
    } else {
      print('OK: tresc ponizej zjechala w dol');
    }

    // 2. Pierwszy wiersz akapitu NIE moze sie ruszyc — nie byl edytowany.
    final first = after.firstWhere(
        (o) => (o['text']! as String).startsWith('Pierwszy'));
    final drift = ((first['bottom']! as double) -
            positions['Pierwszy wiersz akapitu w kolumnie']!)
        .abs();
    if (drift > 0.5) {
      problems++;
      print('BLAD: "Pierwszy wiersz" przesunal sie o '
          '${drift.toStringAsFixed(1)} pt mimo braku edycji');
    } else {
      print('OK: nieedytowane wiersze powyzej stoja w miejscu');
    }

    // 3. Zadne dwa fragmenty nie moga na siebie nachodzic.
    final overlaps = _countOverlaps(after);
    if (overlaps > 0) {
      problems++;
      print('BLAD: $overlaps par fragmentow nachodzi na siebie');
    } else {
      print('OK: zaden fragment nie nachodzi na inny');
    }

    print(problems == 0
        ? '>>> uklad poprawny'
        : '>>> $problems problemow');
    return problems;
}

int _countOverlaps(List<Map<String, Object?>> objects) {
  var count = 0;
  for (var i = 0; i < objects.length; i++) {
    for (var j = i + 1; j < objects.length; j++) {
      final a = objects[i], b = objects[j];
      final overlapX = (a['left']! as double) < (b['right']! as double) &&
          (a['right']! as double) > (b['left']! as double);
      final overlapY = (a['bottom']! as double) < (b['top']! as double) - 1 &&
          (a['top']! as double) > (b['bottom']! as double) + 1;
      if (overlapX && overlapY) {
        count++;
        print('   nachodzi: "${a['text']}"  x  "${b['text']}"');
      }
    }
  }
  return count;
}

void _build(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, pageW, pageH);

    void line(double x1, double y1, double x2, double y2) {
      final p = pdfium.FPDFPageObj_CreateNewPath(x1, y1);
      pdfium.FPDFPath_LineTo(p, x2, y2);
      pdfium.FPDFPageObj_SetStrokeColor(p, 0, 0, 0, 255);
      pdfium.FPDFPageObj_SetStrokeWidth(p, 1);
      pdfium.FPDFPath_SetDrawMode(p, 0, 1);
      pdfium.FPDFPage_InsertObject(page, p);
    }

    // Typowe ozdobniki strony — NIE tabela.
    line(margin, 700, pageW - margin, 700); // kreska pod naglowkiem
    line(margin, 60, pageW - margin, 60); // kreska nad stopka
    line(40, 40, 40, pageH - 40); // ramka strony, lewa
    line(pageW - 40, 40, pageW - 40, pageH - 40); // ramka strony, prawa

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

    text('Naglowek dokumentu', margin, 715, 13);
    text('Pierwszy wiersz akapitu w kolumnie', margin, bodyBaselines[0], 11);
    text('Drugi wiersz akapitu', margin, bodyBaselines[1], 11);
    text('Trzeci wiersz akapitu', margin, bodyBaselines[2], 11);
    text('Czwarty wiersz akapitu', margin, bodyBaselines[3], 11);
    text('Stopka', margin, 45, 9);

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
