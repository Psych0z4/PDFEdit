// Spike — czy da sie odzyskac polskie znaki BEZ zmiany kroju.
//
// Teza: w wielu PDF-ach problemem nie jest brak glifu, tylko warstwa
// kodowania. Prosty font PDF (Type1/TrueType z WinAnsiEncoding) ma tylko
// 256 kodow znakow i "l z kreska" nie ma tam adresu, nawet jesli glif
// siedzi w pliku fontu.
//
// Jesli teza jest prawdziwa, to wystarczy wziac dane fontu z dokumentu
// (FPDFFont_GetFontData) i przeladowac je jako font CID (Identity-H),
// ktory adresuje glify bezposrednio. Krój zostaje DOKLADNIE ten sam,
// bo to ten sam plik fontu — zmienia sie tylko sposob adresowania.
//
// Uruchomienie: dart run tool/spike_font_reencode.dart [plik.ttf]

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import '../lib/features/pdf_editor/infrastructure/pdfium_glyphs.dart';

late final PDFium pdfium;

const polish = 'Zażółć gęślą jaźń';

void main(List<String> args) {
  pdfium = getPdfium();
  final config = calloc<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);

    print('=== A. Standardowy Helvetica (nieosadzony) ===');
    final helvetica = pdfium.FPDFText_LoadStandardFont(
        doc, 'Helvetica'.toNativeUtf8(allocator: arena).cast<Char>());
    _examine(arena, doc, page, helvetica, 'Helvetica');

    if (args.isNotEmpty && File(args.first).existsSync()) {
      final bytes = File(args.first).readAsBytesSync();
      final data = arena<Uint8>(bytes.length);
      data.asTypedList(bytes.length).setAll(0, bytes);

      print('\n=== B. Prawdziwy font osadzony jako PROSTY (cid=false) ===');
      final simple = pdfium.FPDFText_LoadFont(
          doc, data, bytes.length, FPDF_FONT_TRUETYPE, 0);
      _examine(arena, doc, page, simple, 'osadzony prosty');
    }

    pdfium.FPDF_ClosePage(page);
    pdfium.FPDF_CloseDocument(doc);
  } finally {
    arena.releaseAll();
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}

/// Bada font: jakie znaki obsluguje i czy przeladowanie jako CID pomaga.
void _examine(Arena arena, FPDF_DOCUMENT doc, FPDF_PAGE page, FPDF_FONT font,
    String label) {
  if (font == nullptr) {
    print('  nie udalo sie zaladowac fontu');
    return;
  }

  final probe = pdfium.FPDFPageObj_CreateTextObj(doc, font, 20);
  pdfium.FPDFPage_InsertObject(page, probe);

  final before = findUnsupportedCharacters(
    pdfium: pdfium,
    arena: arena,
    document: doc,
    page: page,
    textObject: probe,
    text: polish,
  );
  print('  [$label] brakujace glify: '
      '${before.isEmpty ? "(zadnych)" : (before.toList()..sort()).join(" ")}');
  print('  osadzony w dokumencie: ${pdfium.FPDFFont_GetIsEmbedded(font) == 1}');

  // --- proba odzyskania danych fontu ---
  final needed = pdfium.FPDFFont_GetFontData(font, nullptr, 0, nullptr);
  final sizeOut = arena<Size>();
  final probeSize = pdfium.FPDFFont_GetFontData(font, nullptr, 0, sizeOut);
  final dataSize = probeSize != 0 ? sizeOut.value : 0;
  print('  FPDFFont_GetFontData: ${dataSize > 0 ? "$dataSize B" : "niedostepne (kod $needed)"}');

  if (dataSize <= 0) {
    print('  -> nie da sie przeladowac: brak danych fontu');
    return;
  }

  final buffer = arena<Uint8>(dataSize);
  if (pdfium.FPDFFont_GetFontData(font, buffer, dataSize, sizeOut) == 0) {
    print('  -> odczyt danych fontu nie powiodl sie');
    return;
  }

  // --- przeladowanie tych samych danych jako font CID ---
  final reloaded = pdfium.FPDFText_LoadFont(
      doc, buffer, dataSize, FPDF_FONT_TRUETYPE, 1);
  if (reloaded == nullptr) {
    print('  -> przeladowanie jako CID nie powiodlo sie');
    return;
  }

  final probe2 = pdfium.FPDFPageObj_CreateTextObj(doc, reloaded, 20);
  pdfium.FPDFPage_InsertObject(page, probe2);

  final after = findUnsupportedCharacters(
    pdfium: pdfium,
    arena: arena,
    document: doc,
    page: page,
    textObject: probe2,
    text: polish,
  );
  print('  [$label + CID] brakujace glify: '
      '${after.isEmpty ? "(zadnych)" : (after.toList()..sort()).join(" ")}');

  if (before.isNotEmpty && after.isEmpty) {
    print('  >>> ODZYSKANE: ten sam plik fontu, pelne polskie znaki');
  } else if (before.isEmpty) {
    print('  >>> font i tak dzialal, przeladowanie niepotrzebne');
  } else {
    print('  >>> przeladowanie NIE pomoglo — w pliku fontu naprawde brak glifow');
  }
}
