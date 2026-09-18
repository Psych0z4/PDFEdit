// Spike — czy da sie powiekszyc w pionie caly wiersz tabeli.
//
// Dwa scenariusze, bo prawdziwe PDF-y rysuja tabele na dwa sposoby:
//
//  A. Siatka z OSOBNYCH obiektow (linie poziome + pionowe, albo prostokat
//     na komorke). Teza: wystarcza transformacje afiniczne — przesuniecie
//     linii ponizej i rozciagniecie linii pionowych. Zadnej odbudowy.
//
//  B. Cala siatka jako JEDEN zlozony obiekt PATH. Tu transformacja rozciagnie
//     wszystkie wiersze naraz, wiec trzeba odczytac segmenty i odbudowac
//     sciezke z przesunietymi wspolrzednymi.
//
// Uruchomienie: dart run tool/spike_row.dart

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

late final PDFium pdfium;

// Tabela: 3 wiersze, kazdy 40 pt. Powiekszamy srodkowy o 20 pt.
const tableLeft = 60.0;
const tableRight = 300.0;
const rowTop = 730.0;
const rowHeight = 40.0;
const growBy = 20.0;
const grownRow = 1; // 0-indeksowany, srodkowy

double ruleY(int index) => rowTop - rowHeight * index;

void main() {
  pdfium = getPdfium();
  final config = calloc<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final dir = Directory.systemTemp.createTempSync('pdf_row');

  try {
    print('=== SCENARIUSZ A: siatka z osobnych obiektow ===');
    final a1 = '${dir.path}/a_before.pdf';
    final a2 = '${dir.path}/a_after.pdf';
    _buildSeparateGrid(a1);
    print('przed:');
    _describe(a1);
    final okA = _growRowByTransform(a1, a2);
    print('po (wiersz $grownRow wyzszy o $growBy pt):');
    _describe(a2);
    print(okA ? '>>> A: DZIALA, same transformacje\n' : '>>> A: nie powiodlo sie\n');

    print('=== SCENARIUSZ B: cala siatka jako jeden PATH ===');
    final b1 = '${dir.path}/b_before.pdf';
    final b2 = '${dir.path}/b_after.pdf';
    _buildCompositeGrid(b1);
    print('przed:');
    _dumpSegments(b1);
    final okB = _growRowByRebuild(b1, b2);
    print('po odbudowie:');
    _dumpSegments(b2);
    print(okB ? '>>> B: DZIALA przez odbudowe sciezki' : '>>> B: nie powiodlo sie');
  } finally {
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}

// --- scenariusz A -----------------------------------------------------------

void _buildSeparateGrid(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);

    // 4 linie poziome (granice 3 wierszy).
    for (var i = 0; i <= 3; i++) {
      final y = ruleY(i);
      final line = pdfium.FPDFPageObj_CreateNewPath(tableLeft, y);
      pdfium.FPDFPath_LineTo(line, tableRight, y);
      _strokeStyle(line);
      pdfium.FPDFPage_InsertObject(page, line);
    }
    // 2 linie pionowe na calej wysokosci tabeli.
    for (final x in [tableLeft, tableRight]) {
      final line = pdfium.FPDFPageObj_CreateNewPath(x, ruleY(3));
      pdfium.FPDFPath_LineTo(line, x, ruleY(0));
      _strokeStyle(line);
      pdfium.FPDFPage_InsertObject(page, line);
    }
    // Tekst w kazdym wierszu.
    final fontName = 'Helvetica'.toNativeUtf8(allocator: arena).cast<Char>();
    final font = pdfium.FPDFText_LoadStandardFont(doc, fontName);
    for (var i = 0; i < 3; i++) {
      final obj = pdfium.FPDFPageObj_CreateTextObj(doc, font, 11);
      pdfium.FPDFText_SetText(obj, _wide(arena, 'Wiersz $i'));
      _place(arena, obj, tableLeft + 6, ruleY(i) - 26);
      pdfium.FPDFPageObj_SetFillColor(obj, 0, 0, 0, 255);
      pdfium.FPDFPage_InsertObject(page, obj);
    }

    pdfium.FPDFPage_GenerateContent(page);
    pdfium.FPDF_ClosePage(page);
    _save(doc, path);
    pdfium.FPDF_CloseDocument(doc);
  } finally {
    arena.releaseAll();
  }
}

bool _growRowByTransform(String src, String dst) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_LoadDocument(
        src.toNativeUtf8(allocator: arena).cast<Char>(), nullptr);
    final page = pdfium.FPDF_LoadPage(doc, 0);

    // Wszystko ponizej dolnej krawedzi powiekszanego wiersza jedzie w dol.
    final boundary = ruleY(grownRow + 1);
    final tableTop = ruleY(0);
    final tableBottom = ruleY(3);

    final count = pdfium.FPDFPage_CountObjects(page);
    for (var i = 0; i < count; i++) {
      final obj = pdfium.FPDFPage_GetObject(page, i);
      final b = _bounds(arena, obj);
      // Klasyfikacja po proporcjach, nie po progu bezwzglednym: bbox jest
      // rozdety o grubosc obrysu, wiec "linia szerokosci 0" ma realnie 2 pt.
      final w = b[2] - b[0];
      final h = b[3] - b[1];
      final centerY = (b[1] + b[3]) / 2;
      final isVerticalRule = pdfium.FPDFPageObj_GetType(obj) == FPDF_PAGEOBJ_PATH &&
          h > w * 5 &&
          h > rowHeight * 2;

      if (isVerticalRule) {
        // Rozciagniecie w pionie = skalowanie Y zakotwiczone w gorze tabeli.
        // Czysta transformacja afiniczna, zero odbudowy sciezki.
        final k = (tableTop - tableBottom + growBy) / (tableTop - tableBottom);
        pdfium.FPDFPageObj_Transform(obj, 1, 0, 0, k, 0, tableTop * (1 - k));
      } else if (centerY <= boundary + 0.01) {
        // Linie i tekst ponizej powiekszanego wiersza — przesuniecie w dol.
        pdfium.FPDFPageObj_Transform(obj, 1, 0, 0, 1, 0, -growBy);
      }
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

// --- scenariusz B -----------------------------------------------------------

void _buildCompositeGrid(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);

    // Jedna sciezka, wiele podsciezek — tak eksportuje wieksze narzedzia.
    final grid = pdfium.FPDFPageObj_CreateNewPath(tableLeft, ruleY(0));
    pdfium.FPDFPath_LineTo(grid, tableRight, ruleY(0));
    for (var i = 1; i <= 3; i++) {
      pdfium.FPDFPath_MoveTo(grid, tableLeft, ruleY(i));
      pdfium.FPDFPath_LineTo(grid, tableRight, ruleY(i));
    }
    pdfium.FPDFPath_MoveTo(grid, tableLeft, ruleY(0));
    pdfium.FPDFPath_LineTo(grid, tableLeft, ruleY(3));
    pdfium.FPDFPath_MoveTo(grid, tableRight, ruleY(0));
    pdfium.FPDFPath_LineTo(grid, tableRight, ruleY(3));
    _strokeStyle(grid);
    pdfium.FPDFPage_InsertObject(page, grid);

    pdfium.FPDFPage_GenerateContent(page);
    pdfium.FPDF_ClosePage(page);
    _save(doc, path);
    pdfium.FPDF_CloseDocument(doc);
  } finally {
    arena.releaseAll();
  }
}

bool _growRowByRebuild(String src, String dst) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_LoadDocument(
        src.toNativeUtf8(allocator: arena).cast<Char>(), nullptr);
    final page = pdfium.FPDF_LoadPage(doc, 0);

    FPDF_PAGEOBJECT old = nullptr;
    final count = pdfium.FPDFPage_CountObjects(page);
    for (var i = 0; i < count; i++) {
      final o = pdfium.FPDFPage_GetObject(page, i);
      if (pdfium.FPDFPageObj_GetType(o) == FPDF_PAGEOBJ_PATH) {
        old = o;
        break;
      }
    }
    if (old == nullptr) return false;

    // Odczyt wszystkich segmentow.
    final segs = <({int type, double x, double y, bool close})>[];
    final segCount = pdfium.FPDFPath_CountSegments(old);
    for (var i = 0; i < segCount; i++) {
      final s = pdfium.FPDFPath_GetPathSegment(old, i);
      if (s == nullptr) return false;
      final type = pdfium.FPDFPathSegment_GetType(s);
      if (type == FPDF_SEGMENT_BEZIERTO) {
        print('   UWAGA: sciezka zawiera krzywe Beziera — odbudowa ryzykowna');
      }
      final px = arena<Float>(), py = arena<Float>();
      pdfium.FPDFPathSegment_GetPoint(s, px, py);
      segs.add((
        type: type,
        x: px.value,
        y: py.value,
        close: pdfium.FPDFPathSegment_GetClose(s) != 0,
      ));
    }

    // Kazdy punkt ponizej dolnej krawedzi powiekszanego wiersza jedzie w dol.
    final boundary = ruleY(grownRow + 1);
    double adjust(double y) => y <= boundary + 0.01 ? y - growBy : y;

    // Odczyt atrybutow graficznych, zeby odtworzyc wyglad 1:1.
    final sw = arena<Float>();
    pdfium.FPDFPageObj_GetStrokeWidth(old, sw);
    final r = arena<UnsignedInt>(),
        g = arena<UnsignedInt>(),
        b = arena<UnsignedInt>(),
        a = arena<UnsignedInt>();
    pdfium.FPDFPageObj_GetStrokeColor(old, r, g, b, a);
    final fillMode = arena<Int>(), stroke = arena<FPDF_BOOL>();
    pdfium.FPDFPath_GetDrawMode(old, fillMode, stroke);
    final lineCap = pdfium.FPDFPageObj_GetLineCap(old);
    final lineJoin = pdfium.FPDFPageObj_GetLineJoin(old);

    // Budowa nowej sciezki.
    FPDF_PAGEOBJECT? fresh;
    for (final s in segs) {
      final y = adjust(s.y);
      if (fresh == null) {
        fresh = pdfium.FPDFPageObj_CreateNewPath(s.x, y);
      } else if (s.type == FPDF_SEGMENT_MOVETO) {
        pdfium.FPDFPath_MoveTo(fresh, s.x, y);
      } else {
        pdfium.FPDFPath_LineTo(fresh, s.x, y);
      }
      if (s.close) pdfium.FPDFPath_Close(fresh);
    }
    if (fresh == null) return false;

    pdfium.FPDFPageObj_SetStrokeWidth(fresh, sw.value);
    pdfium.FPDFPageObj_SetStrokeColor(fresh, r.value, g.value, b.value, a.value);
    pdfium.FPDFPath_SetDrawMode(fresh, fillMode.value, stroke.value);
    pdfium.FPDFPageObj_SetLineCap(fresh, lineCap);
    pdfium.FPDFPageObj_SetLineJoin(fresh, lineJoin);

    pdfium.FPDFPage_RemoveObject(page, old);
    pdfium.FPDFPageObj_Destroy(old);
    pdfium.FPDFPage_InsertObject(page, fresh);

    pdfium.FPDFPage_GenerateContent(page);
    pdfium.FPDF_ClosePage(page);
    _save(doc, dst);
    pdfium.FPDF_CloseDocument(doc);
    return true;
  } finally {
    arena.releaseAll();
  }
}

// --- diagnostyka ------------------------------------------------------------

void _describe(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_LoadDocument(
        path.toNativeUtf8(allocator: arena).cast<Char>(), nullptr);
    final page = pdfium.FPDF_LoadPage(doc, 0);
    final tp = pdfium.FPDFText_LoadPage(page);

    final count = pdfium.FPDFPage_CountObjects(page);
    for (var i = 0; i < count; i++) {
      final obj = pdfium.FPDFPage_GetObject(page, i);
      final b = _bounds(arena, obj);
      final type = pdfium.FPDFPageObj_GetType(obj);
      final label = type == FPDF_PAGEOBJ_TEXT
          ? 'TEXT "${_text(arena, obj, tp)}"'
          : 'PATH';
      print('   $label'.padRight(24) +
          'x ${b[0].toStringAsFixed(1)}..${b[2].toStringAsFixed(1)}  '
              'y ${b[1].toStringAsFixed(1)}..${b[3].toStringAsFixed(1)}');
    }

    pdfium.FPDFText_ClosePage(tp);
    pdfium.FPDF_ClosePage(page);
    pdfium.FPDF_CloseDocument(doc);
  } finally {
    arena.releaseAll();
  }
}

void _dumpSegments(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_LoadDocument(
        path.toNativeUtf8(allocator: arena).cast<Char>(), nullptr);
    final page = pdfium.FPDF_LoadPage(doc, 0);
    final count = pdfium.FPDFPage_CountObjects(page);

    for (var i = 0; i < count; i++) {
      final obj = pdfium.FPDFPage_GetObject(page, i);
      if (pdfium.FPDFPageObj_GetType(obj) != FPDF_PAGEOBJ_PATH) continue;
      final segCount = pdfium.FPDFPath_CountSegments(obj);
      final ys = <String>[];
      for (var s = 0; s < segCount; s++) {
        final seg = pdfium.FPDFPath_GetPathSegment(obj, s);
        final px = arena<Float>(), py = arena<Float>();
        pdfium.FPDFPathSegment_GetPoint(seg, px, py);
        ys.add('${px.value.toStringAsFixed(0)},${py.value.toStringAsFixed(0)}');
      }
      print('   PATH segmentow=$segCount: ${ys.join(" ")}');
    }

    pdfium.FPDF_ClosePage(page);
    pdfium.FPDF_CloseDocument(doc);
  } finally {
    arena.releaseAll();
  }
}

// --- helpery ----------------------------------------------------------------

void _strokeStyle(FPDF_PAGEOBJECT obj) {
  pdfium.FPDFPageObj_SetStrokeColor(obj, 0, 0, 0, 255);
  pdfium.FPDFPageObj_SetStrokeWidth(obj, 1);
  pdfium.FPDFPath_SetDrawMode(obj, 0, 1);
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

List<double> _bounds(Arena arena, FPDF_PAGEOBJECT obj) {
  final l = arena<Float>(),
      b = arena<Float>(),
      r = arena<Float>(),
      t = arena<Float>();
  if (pdfium.FPDFPageObj_GetBounds(obj, l, b, r, t) == 0) return [0, 0, 0, 0];
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
