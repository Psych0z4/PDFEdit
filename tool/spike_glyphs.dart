// Spike — czy da sie PEWNIE stwierdzic, ktore znaki font potrafi narysowac.
//
// Publiczne API PDFium nie udostepnia mapowania Unicode -> glif, wiec pokrycia
// nie da sie sprawdzic wprost. Pomysl: wyrenderowac pojedynczy znak przez
// FPDFTextObj_GetRenderedBitmap i policzyc zamalowane piksele. Zero pikseli
// albo obrazek identyczny jak dla znaku zagwarantowanie nieistniejacego
// oznacza, ze font tego znaku nie ma.
//
// Test jest rozstrzygajacy, bo uruchamiamy go na foncie Helvetica
// z kodowaniem WinAnsi, o ktorym wiadomo dokladnie co zawiera:
//   - 'o' z kreska (U+00F3) JEST w WinAnsi  -> powinno sie narysowac
//   - 'l' z kreska (U+0142) NIE jest         -> nie powinno
//
// Uruchomienie: dart run tool/spike_glyphs.dart

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart';

late final PDFium pdfium;

/// Znak z obszaru prywatnego Unicode — zaden font go nie ma.
const sentinel = '';

void main() {
  pdfium = getPdfium();
  final config = calloc<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final arena = Arena();
  try {
    final doc = pdfium.FPDF_CreateNewDocument();
    final page = pdfium.FPDFPage_New(doc, 0, 595, 842);

    final fontName = 'Helvetica'.toNativeUtf8(allocator: arena).cast<Char>();
    final font = pdfium.FPDFText_LoadStandardFont(doc, fontName);
    final probe = pdfium.FPDFPageObj_CreateTextObj(doc, font, 24);
    pdfium.FPDFPage_InsertObject(page, probe);

    final baseline = _signature(arena, doc, page, probe, sentinel);
    final baseline2 = _signature(arena, doc, page, probe, '');
    print('Wzorzec braku glifu U+E000: $baseline');
    print('Wzorzec braku glifu U+E001: $baseline2');
    print(baseline == baseline2
        ? 'Oba wzorce identyczne — .notdef renderuje sie deterministycznie.'
        : 'UWAGA: wzorce sie roznia, metoda zawodna.');

    const cases = <String, bool>{
      'A': true,
      'o': true,
      'ó': true, // ó — jest w WinAnsi
      'ł': false, // ł — nie ma w WinAnsi
      'ą': false, // ą
      'ę': false, // ę
      'ś': false, // ś
      'ż': false, // ż
      'ź': false, // ź
      'ć': false, // ć
      'ń': false, // ń
    };

    var correct = 0;
    for (final entry in cases.entries) {
      final sig = _signature(arena, doc, page, probe, entry.key);
      final supported = sig.ink > 0 && sig != baseline;
      final ok = supported == entry.value;
      if (ok) correct++;
      print('  "${entry.key}" (U+${entry.key.codeUnitAt(0).toRadixString(16).toUpperCase().padLeft(4, '0')})'
          '  $sig  ->  ${supported ? "obslugiwany" : "BRAK GLIFU"}'
          '  ${ok ? "" : "  <-- NIEZGODNE Z OCZEKIWANIEM"}');
    }

    print('\nZgodnych: $correct / ${cases.length}');
    print(correct == cases.length
        ? 'WYNIK: detekcja pokrycia znakow DZIALA i jest rozstrzygajaca.'
        : 'WYNIK: detekcja myli sie — metoda do poprawy.');

    pdfium.FPDF_ClosePage(page);
    pdfium.FPDF_CloseDocument(doc);
  } finally {
    arena.releaseAll();
    pdfium.FPDF_DestroyLibrary();
    calloc.free(config);
  }
}

/// Sygnatura wyrenderowanego znaku: wymiary, liczba zamalowanych pikseli
/// i suma kontrolna. Dwa rozne glify praktycznie nie moga dac tej samej
/// sygnatury, a dwa razy .notdef da zawsze te sama.
class GlyphSignature {
  const GlyphSignature(this.width, this.height, this.ink, this.checksum);
  final int width, height, ink, checksum;

  @override
  bool operator ==(Object other) =>
      other is GlyphSignature &&
      other.width == width &&
      other.height == height &&
      other.ink == ink &&
      other.checksum == checksum;

  @override
  int get hashCode => Object.hash(width, height, ink, checksum);

  @override
  String toString() => '${width}x$height ink=$ink sum=$checksum';
}

GlyphSignature _signature(Arena arena, FPDF_DOCUMENT doc, FPDF_PAGE page,
    FPDF_PAGEOBJECT probe, String text) {
  if (pdfium.FPDFText_SetText(probe, _wide(arena, text)) == 0) {
    // Odmowa ustawienia tresci to juz jednoznaczna odpowiedz.
    return const GlyphSignature(0, 0, 0, 0);
  }

  final bitmap = pdfium.FPDFTextObj_GetRenderedBitmap(doc, page, probe, 4);
  if (bitmap == nullptr) return const GlyphSignature(0, 0, 0, 0);

  try {
    final width = pdfium.FPDFBitmap_GetWidth(bitmap);
    final height = pdfium.FPDFBitmap_GetHeight(bitmap);
    final stride = pdfium.FPDFBitmap_GetStride(bitmap);
    final buffer = pdfium.FPDFBitmap_GetBuffer(bitmap);
    if (buffer == nullptr || width <= 0 || height <= 0) {
      return const GlyphSignature(0, 0, 0, 0);
    }

    final bytes = buffer.cast<Uint8>().asTypedList(stride * height);
    final bytesPerPixel = stride ~/ width;

    // Tlo bierzemy z lewego gornego rogu — tam na pewno nie ma glifu.
    final background = <int>[
      for (var i = 0; i < bytesPerPixel; i++) bytes[i],
    ];

    var ink = 0;
    var checksum = 0;
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final offset = y * stride + x * bytesPerPixel;
        var differs = false;
        for (var c = 0; c < bytesPerPixel; c++) {
          if (bytes[offset + c] != background[c]) differs = true;
        }
        if (differs) {
          ink++;
          checksum = (checksum * 31 + (y * width + x)) & 0x3FFFFFFF;
        }
      }
    }
    return GlyphSignature(width, height, ink, checksum);
  } finally {
    pdfium.FPDFBitmap_Destroy(bitmap);
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
