// Test integracyjny detekcji pokrycia znakow — na kodzie produkcyjnym.
//
// Wywoluje bridge.probeGlyphSupport, czyli dokladnie te funkcje, ktorej
// uzywa aplikacja. Sprawdza dwie rzeczy:
//  1. czy poprawnie rozpoznaje, ktorych polskich znakow font nie ma,
//  2. czy sondowanie NIE modyfikuje pliku uzytkownika.
//
// Uruchomienie: dart run tool/spike_glyph_probe.dart

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import '../lib/features/pdf_editor/infrastructure/pdfium_bridge.dart' as bridge;

late final PDFium pdfium;

void main() {
  pdfium = getPdfium();
  final config = calloc<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final dir = Directory.systemTemp.createTempSync('pdf_glyph');
  final path = '${dir.path}/doc.pdf';

  try {
    _build(path);
    final before = _hash(path);

    final objects = bridge.readPageTextObjects({'path': path, 'pageIndex': 0});
    final target = objects.first;
    print('Obiekt: "${target['text']}"  font=${target['fontFamily']}  '
        'osadzony=${target['isFontEmbedded']}');

    const probe = 'Zazolc gesla jazn ora ROWNIEZ';
    const polish = 'Zażółć gęślą jaźń ORAZ RÓWNIEŻ';

    for (final entry in {'bez diakrytykow': probe, 'z diakrytykami': polish}.entries) {
      final result = bridge.probeGlyphSupport({
        'path': path,
        'pageIndex': 0,
        'objectIndex': target['objectIndex'],
        'text': entry.value,
      });
      final missing = (result['unsupported']! as List).cast<String>()..sort();
      print('\n  ${entry.key}: "${entry.value}"');
      print('    brakujace glify: ${missing.isEmpty ? "(zadnych)" : missing.join(" ")}');
    }

    final after = _hash(path);
    print('\nSuma kontrolna pliku przed: $before');
    print('Suma kontrolna pliku po:    $after');
    print(before == after
        ? '>>> OK: sondowanie nie zmodyfikowalo pliku'
        : '>>> BLAD: plik zostal zmieniony!');
  } finally {
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}

String _hash(String path) =>
    sha256.convert(File(path).readAsBytesSync()).toString().substring(0, 16);

void _build(String path) {
  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);
    final fontName = 'Helvetica'.toNativeUtf8(allocator: arena).cast<Char>();
    final font = pdfium.FPDFText_LoadStandardFont(doc, fontName);
    final obj = pdfium.FPDFPageObj_CreateTextObj(doc, font, 12);
    pdfium.FPDFText_SetText(obj, _wide(arena, 'Tekst probny'));
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
