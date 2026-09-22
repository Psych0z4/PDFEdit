// Spike — czy osadzenie fontu zastepczego naprawia polskie znaki.
//
// Sprawdza pelny lancuch, bo kazde ogniwo moze zawiesc osobno:
//  1. czy FPDFText_LoadFont przyjmie plik TTF jako font CID (Identity-H),
//  2. czy polskie znaki faktycznie sie renderuja,
//  3. czy po zapisie i ponownym otwarciu tekst da sie ODCZYTAC — czyli czy
//     PDFium wygenerowalo poprawne ToUnicode. Bez tego dokument wyglada
//     dobrze, ale nie da sie w nim szukac ani kopiowac tekstu.
//  4. ile taki font dodaje do rozmiaru pliku.
//
// Uruchomienie: dart run tool/spike_fallback_font.dart <sciezka-do.ttf>

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

import '../lib/features/pdf_editor/infrastructure/pdfium_glyphs.dart';

late final PDFium pdfium;

const polish = 'Zażółć gęślą jaźń ORAZ RÓWNIEŻ';

void main(List<String> args) {
  if (args.isEmpty) {
    print('Uzycie: dart run tool/spike_fallback_font.dart <plik.ttf>');
    return;
  }
  final fontFile = File(args.first);
  if (!fontFile.existsSync()) {
    print('Brak pliku: ${args.first}');
    return;
  }

  pdfium = getPdfium();
  final config = calloc<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final dir = Directory.systemTemp.createTempSync('pdf_fallback');
  final arena = Arena();

  try {
    final fontBytes = fontFile.readAsBytesSync();
    print('Font: ${fontFile.path.split(RegExp(r"[\\\\/]")).last}  '
        '${fontBytes.length} B');

    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);

    // --- 1. zaladowanie fontu z pliku ---
    final data = arena<Uint8>(fontBytes.length);
    data.asTypedList(fontBytes.length).setAll(0, fontBytes);
    final font = pdfium.FPDFText_LoadFont(
        doc, data, fontBytes.length, FPDF_FONT_TRUETYPE, 1);
    print('\n1. FPDFText_LoadFont (CID): ${font == nullptr ? "NULL — PORAZKA" : "ok"}');
    if (font == nullptr) return;

    final obj = pdfium.FPDFPageObj_CreateTextObj(doc, font, 14);
    pdfium.FPDFPageObj_SetFillColor(obj, 0, 0, 0, 255);
    final m = arena<FS_MATRIX>();
    m.ref
      ..a = 1
      ..b = 0
      ..c = 0
      ..d = 1
      ..e = 60
      ..f = 700;
    pdfium.FPDFPageObj_SetMatrix(obj, m);
    pdfium.FPDFPage_InsertObject(page, obj);

    // --- 2. pokrycie znakow ---
    final missing = findUnsupportedCharacters(
      pdfium: pdfium,
      arena: arena,
      document: doc,
      page: page,
      textObject: obj,
      text: polish,
    );
    print('2. Brakujace glify w "$polish":');
    print('   ${missing.isEmpty ? "(zadnych — pelne pokrycie)" : missing.join(" ")}');

    // --- 3. zapis i odczyt ---
    pdfium.FPDFText_SetText(obj, _wide(arena, polish));
    pdfium.FPDFPage_GenerateContent(page);
    pdfium.FPDF_ClosePage(page);

    final out = '${dir.path}/fallback.pdf';
    _save(doc, out);
    pdfium.FPDF_CloseDocument(doc);

    final size = File(out).lengthSync();
    final readBack = _readText(arena, out);
    print('3. Tekst po ponownym otwarciu: "$readBack"');
    print('   ${readBack == polish ? "ZGODNY — ToUnicode poprawne" : "NIEZGODNY — tekst nie do odczytania"}');

    // --- 4. koszt rozmiaru ---
    print('4. Rozmiar PDF z osadzonym fontem: ${(size / 1024).toStringAsFixed(0)} KB');

    print('\nWYNIK: ${missing.isEmpty && readBack == polish ? "font zastepczy DZIALA w pelni" : "font zastepczy ma problemy"}');
  } finally {
    arena.releaseAll();
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}

String _readText(Arena arena, String path) {
  final doc = pdfium.FPDF_LoadDocument(
      path.toNativeUtf8(allocator: arena).cast<Char>(), nullptr);
  if (doc == nullptr) return '(nie udalo sie otworzyc)';
  final page = pdfium.FPDF_LoadPage(doc, 0);
  final textPage = pdfium.FPDFText_LoadPage(page);

  final count = pdfium.FPDFText_CountChars(textPage);
  final buffer = arena<Uint16>(count + 1);
  pdfium.FPDFText_GetText(textPage, 0, count, buffer.cast<UnsignedShort>());
  final units = buffer.asTypedList(count + 1);
  final end = units.indexOf(0);
  final text = String.fromCharCodes(end >= 0 ? units.sublist(0, end) : units);

  pdfium.FPDFText_ClosePage(textPage);
  pdfium.FPDF_ClosePage(page);
  pdfium.FPDF_CloseDocument(doc);
  return text;
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
