// Regresja detekcji pokrycia znakow — na kodzie produkcyjnym.
//
// Uruchamiane na foncie Helvetica z kodowaniem WinAnsi, o ktorym wiadomo
// dokladnie co zawiera, wiec oczekiwania sa twarde:
//   - 'o' z kreska (U+00F3) JEST w WinAnsi        -> obslugiwany
//   - pozostale polskie diakrytyki NIE sa         -> brak glifu
//   - waskie litery 'l', 'i' MUSZA byc uznane za obslugiwane
//     (regresja: wczesniej wypelnialy cala bitmape i heurystyka rogu
//      raportowala je falszywie jako brakujace)
//
// Uruchomienie: dart run tool/spike_glyph_coverage.dart

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import '../lib/features/pdf_editor/infrastructure/pdfium_glyphs.dart';

late final PDFium pdfium;

void main() {
  pdfium = getPdfium();
  final config = calloc<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);
    final font = pdfium.FPDFText_LoadStandardFont(
        doc, 'Helvetica'.toNativeUtf8(allocator: arena).cast<Char>());
    final probe = pdfium.FPDFPageObj_CreateTextObj(doc, font, 20);
    pdfium.FPDFPage_InsertObject(page, probe);

    // true = font powinien umiec narysowac ten znak
    const expected = <String, bool>{
      'A': true, 'o': true, 'l': true, 'i': true, 'M': true, 'j': true,
      'ó': true, 'Ó': true,
      'ł': false, 'ą': false, 'ę': false, 'ś': false,
      'ż': false, 'ź': false, 'ć': false, 'ń': false,
    };

    final missing = findUnsupportedCharacters(
      pdfium: pdfium,
      arena: arena,
      document: doc,
      page: page,
      textObject: probe,
      text: expected.keys.join(),
    );

    var failures = 0;
    for (final entry in expected.entries) {
      final supported = !missing.contains(entry.key);
      final ok = supported == entry.value;
      if (!ok) failures++;
      final code = entry.key.codeUnitAt(0).toRadixString(16).toUpperCase();
      print('  "${entry.key}" (U+${code.padLeft(4, "0")})  '
          '${supported ? "obslugiwany" : "BRAK GLIFU"}'
          '${ok ? "" : "   <-- NIEZGODNE Z OCZEKIWANIEM"}');
    }

    print('');
    print(failures == 0
        ? 'WYNIK: ${expected.length}/${expected.length} — detekcja zgodna z WinAnsi'
        : 'WYNIK: $failures niezgodnosci');

    pdfium.FPDF_ClosePage(page);
    pdfium.FPDF_CloseDocument(doc);
  } finally {
    arena.releaseAll();
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}
