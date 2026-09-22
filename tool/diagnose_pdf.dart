// Diagnostyka polskich znakow w konkretnym pliku PDF.
//
// Odpowiada na pytanie: dlaczego dokument POKAZUJE polskie znaki, a przy
// edycji ich nie da sie wpisac. Dla kazdego fontu uzytego na stronie
// sprawdza osobno:
//
//   - czy font w ogole zawiera glify polskich znakow,
//   - czy da sie je WPISAC przez FPDFText_SetText (to zawodzi najczesciej),
//   - czy naprawa kodowania (przeladowanie jako font CID) pomaga,
//   - ile danych fontu dokument udostepnia.
//
// NIE wypisuje tresci dokumentu — tylko nazwy fontow i zbiory znakow.
//
// Uruchomienie: dart run tool/diagnose_pdf.dart <plik.pdf> [numer-strony]

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import '../lib/features/pdf_editor/infrastructure/pdfium_glyphs.dart';

late final PDFium pdfium;

const polishChars = 'ąćęłńóśźżĄĆĘŁŃÓŚŹŻ';

void main(List<String> args) {
  if (args.isEmpty) {
    print('Uzycie: dart run tool/diagnose_pdf.dart <plik.pdf> [numer-strony]');
    return;
  }
  final path = args.first;
  if (!File(path).existsSync()) {
    print('Nie znaleziono pliku: $path');
    return;
  }
  final pageNumber = args.length > 1 ? int.tryParse(args[1]) ?? 1 : 1;

  pdfium = getPdfium();
  final config = calloc<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final arena = Arena();
  try {
    final doc = pdfium.FPDF_LoadDocument(
        path.toNativeUtf8(allocator: arena).cast<Char>(), nullptr);
    if (doc == nullptr) {
      print('Nie udalo sie otworzyc dokumentu '
          '(kod PDFium: ${pdfium.FPDF_GetLastError()}).');
      return;
    }

    final pageCount = pdfium.FPDF_GetPageCount(doc);
    print('Plik: ${path.split(RegExp(r"[\\/]")).last}');
    print('Stron: $pageCount, analizuje strone $pageNumber\n');

    final page = pdfium.FPDF_LoadPage(doc, pageNumber - 1);
    if (page == nullptr) {
      print('Nie udalo sie wczytac strony $pageNumber.');
      return;
    }
    final textPage = pdfium.FPDFText_LoadPage(page);

    // Grupujemy obiekty po foncie — diagnoza dotyczy fontu, nie fragmentu.
    final seen = <String, _FontReport>{};
    final count = pdfium.FPDFPage_CountObjects(page);

    for (var i = 0; i < count; i++) {
      final obj = pdfium.FPDFPage_GetObject(page, i);
      if (obj == nullptr) continue;
      if (pdfium.FPDFPageObj_GetType(obj) != FPDF_PAGEOBJ_TEXT) continue;

      final font = pdfium.FPDFTextObj_GetFont(obj);
      if (font == nullptr) continue;

      final name = _fontName(arena, font);
      final embedded = pdfium.FPDFFont_GetIsEmbedded(font) == 1;
      final key = '$name|$embedded';

      final text = _objectText(arena, obj, textPage);
      final polishInDoc = text.split('').where(polishChars.contains).toSet();

      final report = seen.putIfAbsent(
          key,
          () => _FontReport(
                name: name,
                embedded: embedded,
                dataSize: _fontDataSize(arena, font),
              ));
      report.objectCount++;
      report.polishInDocument.addAll(polishInDoc);
      report.probeObject ??= obj;
    }

    if (seen.isEmpty) {
      print('Na tej stronie nie ma obiektow tekstowych — to moze byc skan.');
      return;
    }

    for (final report in seen.values) {
      _analyse(arena, doc, page, report);
    }

    print('\n=== PODSUMOWANIE ===');
    for (final r in seen.values) {
      print('  ${r.name}: ${r.verdict}');
    }

    pdfium.FPDFText_ClosePage(textPage);
    pdfium.FPDF_ClosePage(page);
    pdfium.FPDF_CloseDocument(doc);
  } finally {
    arena.releaseAll();
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}

class _FontReport {
  _FontReport({
    required this.name,
    required this.embedded,
    required this.dataSize,
  });

  final String name;
  final bool embedded;
  final int dataSize;
  int objectCount = 0;
  final Set<String> polishInDocument = {};
  FPDF_PAGEOBJECT? probeObject;
  String verdict = 'nie sprawdzono';
}

void _analyse(
    Arena arena, FPDF_DOCUMENT doc, FPDF_PAGE page, _FontReport report) {
  print('=== Font: ${report.name} ===');
  print('  osadzony w dokumencie: ${report.embedded ? "tak" : "nie"}');
  print('  fragmentow na stronie: ${report.objectCount}');
  print('  dane fontu dostepne:   '
      '${report.dataSize > 0 ? "${(report.dataSize / 1024).toStringAsFixed(0)} KB" : "NIE"}');
  print('  polskie znaki UZYTE w dokumencie tym fontem: '
      '${report.polishInDocument.isEmpty ? "(brak)" : (report.polishInDocument.toList()..sort()).join(" ")}');

  final probe = report.probeObject;
  if (probe == null) {
    report.verdict = 'brak obiektu do sprawdzenia';
    return;
  }

  // Czy da sie te znaki WPISAC.
  final missing = findUnsupportedCharacters(
    pdfium: pdfium,
    arena: arena,
    document: doc,
    page: page,
    textObject: probe,
    text: polishChars,
  );
  final writable = polishChars.split('').where((c) => !missing.contains(c)).toSet();
  print('  polskie znaki MOZLIWE do wpisania: '
      '${writable.isEmpty ? "(zadne)" : (writable.toList()..sort()).join(" ")}');
  print('  niemozliwe do wpisania: '
      '${missing.isEmpty ? "(zadne)" : (missing.toList()..sort()).join(" ")}');

  if (missing.isEmpty) {
    report.verdict = 'OK — wszystkie polskie znaki da sie wpisac';
    print('  >>> ${report.verdict}\n');
    return;
  }

  // Czy naprawa kodowania pomoze.
  if (report.dataSize <= 0) {
    report.verdict = 'BRAK DANYCH FONTU — naprawa niemozliwa, trzeba innego fontu';
    print('  >>> ${report.verdict}\n');
    return;
  }

  final data = arena<Uint8>(report.dataSize);
  final sizeOut = arena<Size>();
  final font = pdfium.FPDFTextObj_GetFont(probe);
  pdfium.FPDFFont_GetFontData(font, data, report.dataSize, sizeOut);

  var reloaded = pdfium.FPDFText_LoadFont(
      doc, data, report.dataSize, FPDF_FONT_TRUETYPE, 1);
  reloaded = reloaded != nullptr
      ? reloaded
      : pdfium.FPDFText_LoadFont(doc, data, report.dataSize, FPDF_FONT_TYPE1, 1);

  if (reloaded == nullptr) {
    report.verdict = 'PDFium nie przyjal pliku tego fontu — naprawa niemozliwa';
    print('  >>> ${report.verdict}\n');
    return;
  }

  final sizePtr = arena<Float>();
  pdfium.FPDFTextObj_GetFontSize(probe, sizePtr);
  final test = pdfium.FPDFPageObj_CreateTextObj(doc, reloaded, sizePtr.value);
  pdfium.FPDFPage_InsertObject(page, test);

  final afterFix = findUnsupportedCharacters(
    pdfium: pdfium,
    arena: arena,
    document: doc,
    page: page,
    textObject: test,
    text: polishChars,
  );

  print('  po naprawie kodowania niemozliwe: '
      '${afterFix.isEmpty ? "(zadne)" : (afterFix.toList()..sort()).join(" ")}');

  report.verdict = afterFix.isEmpty
      ? 'NAPRAWIALNY — przycisk "Odzyskaj te znaki" zadziala'
      : afterFix.length < missing.length
          ? 'CZESCIOWO naprawialny'
          : 'NAPRAWA NIE POMAGA — font naprawde nie ma tych glifow';
  print('  >>> ${report.verdict}\n');
}

String _fontName(Arena arena, FPDF_FONT font) {
  final size = pdfium.FPDFFont_GetBaseFontName(font, nullptr, 0);
  if (size <= 1) return '(bez nazwy)';
  final buffer = arena<Char>(size);
  pdfium.FPDFFont_GetBaseFontName(font, buffer, size);
  return buffer.cast<Utf8>().toDartString();
}

int _fontDataSize(Arena arena, FPDF_FONT font) {
  final out = arena<Size>();
  if (pdfium.FPDFFont_GetFontData(font, nullptr, 0, out) == 0) return 0;
  return out.value;
}

String _objectText(Arena arena, FPDF_PAGEOBJECT obj, FPDF_TEXTPAGE textPage) {
  final size = pdfium.FPDFTextObj_GetText(obj, textPage, nullptr, 0);
  if (size <= 2) return '';
  final count = size ~/ 2;
  final buffer = arena<Uint16>(count);
  pdfium.FPDFTextObj_GetText(obj, textPage, buffer.cast<FPDF_WCHAR>(), size);
  final units = buffer.asTypedList(count);
  final end = units.indexOf(0);
  return String.fromCharCodes(end >= 0 ? units.sublist(0, end) : units);
}
