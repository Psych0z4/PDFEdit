// Test integracyjny odzyskiwania polskich znakow — na kodzie produkcyjnym.
//
// Scenariusz jest dokladnie taki, jak w aplikacji:
//   1. dokument z fontem, ktory w swoim kodowaniu nie ma polskich znakow,
//   2. uzytkownik wpisuje tekst z diakrytykami,
//   3. bez naprawy  -> znaki gina,
//   4. z naprawa    -> znaki sa, a font pozostaje ten sam.
//
// Uruchomienie: dart run tool/spike_polish_roundtrip.dart

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import '../lib/features/pdf_editor/infrastructure/pdfium_bridge.dart' as bridge;

late final PDFium pdfium;

const polish = 'Zażółć gęślą jaźń ORAZ RÓWNIEŻ';

void main(List<String> args) {
  pdfium = getPdfium();
  final config = calloc<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final dir = Directory.systemTemp.createTempSync('pdf_polish');
  final src = '${dir.path}/source.pdf';

  try {
    _build(src);
    print('Katalog: ${dir.path}');
    final objects = bridge.readPageTextObjects({'path': src, 'pageIndex': 0});
    final target = objects.first;
    print('Font w dokumencie: ${target['fontFamily']}  '
        '(osadzony: ${target['isFontEmbedded']})');
    print('Wpisywany tekst:   "$polish"\n');

    for (final reencode in [false, true]) {
      final out = '${dir.path}/out_$reencode.pdf';
      final result = bridge.applyOperations({
        'sourcePath': src,
        'outputPath': out,
        'operations': [
          {
            'type': 'replace',
            'pageIndex': 0,
            'objectIndex': target['objectIndex'],
            'newText': polish,
            'reflowMode': 'none',
            'reencodeFont': reencode,
          }
        ],
        'minScale': 0.6,
      });

      final after = bridge.readPageTextObjects({'path': out, 'pageIndex': 0});
      final text = after.isEmpty ? '(brak tekstu)' : after.first['text'];
      final font = after.isEmpty ? '?' : after.first['fontFamily'];

      final probe = bridge.probeGlyphSupport({
        'path': out,
        'pageIndex': 0,
        'objectIndex': after.first['objectIndex'],
        'text': polish,
      });
      final missing = (probe['unsupported']! as List).cast<String>()..sort();

      print('--- ${reencode ? "Z NAPRAWA kodowania" : "BEZ naprawy"} ---');
      print('  tekst w pliku:   "$text"');
      print('  font w pliku:    $font');
      print('  brakujace glify: ${missing.isEmpty ? "(zadnych)" : missing.join(" ")}');
      print('  rozmiar pliku:   ${(File(out).lengthSync() / 1024).toStringAsFixed(0)} KB');
      for (final w in (result['warnings']! as List)) {
        print('  ostrzezenie: $w');
      }
      print('  >>> ${missing.isEmpty ? "WSZYSTKIE ZNAKI OBSLUGIWANE" : "znaki nadal gina"}');
      print('');
    }
    // Trzeci przypadek: font, ktory polskie znaki JUZ obsluguje.
    // Naprawa powinna byc wtedy operacja pusta — bez podmiany obiektu
    // i bez rozdymania pliku.
    if (args.isNotEmpty && File(args.first).existsSync()) {
      final ok = '${dir.path}/already_ok.pdf';
      _buildWithCidFont(ok, File(args.first).readAsBytesSync());
      final sizeBefore = File(ok).lengthSync();

      final objs = bridge.readPageTextObjects({'path': ok, 'pageIndex': 0});
      final out = '${dir.path}/already_ok_out.pdf';
      bridge.applyOperations({
        'sourcePath': ok,
        'outputPath': out,
        'operations': [
          {
            'type': 'replace',
            'pageIndex': 0,
            'objectIndex': objs.first['objectIndex'],
            'newText': polish,
            'reflowMode': 'none',
            'reencodeFont': true,
          }
        ],
        'minScale': 0.6,
      });
      final after = bridge.readPageTextObjects({'path': out, 'pageIndex': 0});
      final sizeAfter = File(out).lengthSync();
      final growth = sizeAfter / sizeBefore;

      print('--- NAPRAWA GDY FONT I TAK DZIALA ---');
      print('  tekst w pliku:   "${after.first['text']}"');
      print('  rozmiar przed:   ${(sizeBefore / 1024).toStringAsFixed(0)} KB');
      print('  rozmiar po:      ${(sizeAfter / 1024).toStringAsFixed(0)} KB');
      print('  przyrost:        ${growth.toStringAsFixed(2)}x');
      final textOk = after.first['text'] == polish;
      final noBloat = growth < 1.5;
      print('  >>> ${textOk && noBloat ? "OK: tekst poprawny, plik sie nie rozdal" : "PROBLEM"}');
    }
  } finally {
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}

/// Dokument z fontem CID, ktory polskie znaki juz obsluguje.
void _buildWithCidFont(String path, List<int> fontBytes) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);
    final data = arena<Uint8>(fontBytes.length);
    data.asTypedList(fontBytes.length).setAll(0, fontBytes);
    final font = pdfium.FPDFText_LoadFont(
        doc, data, fontBytes.length, FPDF_FONT_TRUETYPE, 1);
    final obj = pdfium.FPDFPageObj_CreateTextObj(doc, font, 12);
    pdfium.FPDFText_SetText(obj, _wide(arena, 'Tekst poczatkowy'));
    final m = arena<FS_MATRIX>();
    m.ref
      ..a = 1
      ..b = 0
      ..c = 0
      ..d = 1
      ..e = 60
      ..f = 700;
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

void _build(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);
    final font = pdfium.FPDFText_LoadStandardFont(
        doc, 'Helvetica'.toNativeUtf8(allocator: arena).cast<Char>());
    final obj = pdfium.FPDFPageObj_CreateTextObj(doc, font, 12);
    pdfium.FPDFText_SetText(obj, _wide(arena, 'Tekst poczatkowy'));
    final m = arena<FS_MATRIX>();
    m.ref
      ..a = 1
      ..b = 0
      ..c = 0
      ..d = 1
      ..e = 60
      ..f = 700;
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
