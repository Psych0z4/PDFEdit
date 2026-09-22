/// Sprawdzanie, czy font faktycznie potrafi narysować dany znak.
///
/// Publiczne API PDFium nie udostępnia mapowania Unicode na glify
/// (`FPDFFont_GetGlyphWidth` przyjmuje indeks glifu, nie kod znaku), więc
/// pokrycia nie da się sprawdzić wprost. Zamiast zgadywać, renderujemy
/// pojedynczy znak i porównujemy wynik ze wzorcem `.notdef`.
///
/// Wzorzec bierzemy z obszaru prywatnego Unicode, którego żaden font nie ma.
/// Zweryfikowane: dwa różne kody prywatne dają bitowo identyczny obrazek,
/// więc `.notdef` renderuje się deterministycznie i nadaje na wzorzec.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:pdfium_flutter/pdfium_flutter.dart';

/// Sygnatura wyrenderowanego znaku.
///
/// Sama liczba zamalowanych pikseli nie wystarcza — zmierzone „ó" dało 1378
/// pikseli przy wzorcu braku glifu równym 1379. Dopiero wymiary i suma
/// kontrolna rozstrzygają jednoznacznie.
class GlyphSignature {
  const GlyphSignature(this.width, this.height, this.ink, this.checksum,
      {this.reliableInk = false});

  static const empty = GlyphSignature(0, 0, 0, 0);

  final int width;
  final int height;
  final int ink;
  final int checksum;

  /// Czy liczba zamalowanych pikseli jest wiarygodna. Bez kanału alfa
  /// opieramy się na kolorze tła i pusta bitmapa nie jest dowodem.
  final bool reliableInk;

  bool get isBlank => reliableInk && ink == 0;

  @override
  bool operator ==(Object other) =>
      other is GlyphSignature &&
      other.width == width &&
      other.height == height &&
      other.ink == ink &&
      other.checksum == checksum;

  @override
  int get hashCode => Object.hash(width, height, ink, checksum);
}

/// Znaki z [text], których font obiektu [textObject] nie potrafi narysować.
///
/// Funkcja modyfikuje treść obiektu w pamięci, ale nie zapisuje dokumentu —
/// wywołujący musi zamknąć dokument bez zapisu albo przywrócić treść.
Set<String> findUnsupportedCharacters({
  required PDFium pdfium,
  required Arena arena,
  required FPDF_DOCUMENT document,
  required FPDF_PAGE page,
  required FPDF_PAGEOBJECT textObject,
  required String text,
}) {
  final candidates = <String>{};
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    // Białe znaki renderują się pusto z definicji — nie da się i nie trzeba
    // ich odróżniać od braku glifu.
    if (char.trim().isEmpty) continue;
    candidates.add(char);
  }
  if (candidates.isEmpty) return const {};

  final notdef = _signatureOf(
    pdfium: pdfium,
    arena: arena,
    document: document,
    page: page,
    textObject: textObject,
    text: _privateUseSentinel,
  );

  final unsupported = <String>{};
  for (final char in candidates) {
    final signature = _signatureOf(
      pdfium: pdfium,
      arena: arena,
      document: document,
      page: page,
      textObject: textObject,
      text: char,
    );
    if (signature.isBlank || signature == notdef) {
      unsupported.add(char);
    }
  }
  return unsupported;
}

/// Kod z obszaru prywatnego Unicode — gwarantowany brak glifu.
const _privateUseSentinel = '';

/// Skala renderowania próbki. Większa daje pewniejszą sumę kontrolną,
/// mniejsza jest szybsza; 4 to kompromis sprawdzony w praktyce.
const _probeScale = 4.0;

GlyphSignature _signatureOf({
  required PDFium pdfium,
  required Arena arena,
  required FPDF_DOCUMENT document,
  required FPDF_PAGE page,
  required FPDF_PAGEOBJECT textObject,
  required String text,
}) {
  final units = text.codeUnits;
  final buffer = arena<Uint16>(units.length + 1);
  for (var i = 0; i < units.length; i++) {
    buffer[i] = units[i];
  }
  buffer[units.length] = 0;

  // Odmowa ustawienia treści to już jednoznaczna odpowiedź: PDFium zwraca
  // false, gdy nie zdołał zakodować ani jednego znaku.
  if (pdfium.FPDFText_SetText(textObject, buffer.cast<FPDF_WCHAR>()) == 0) {
    return GlyphSignature.empty;
  }

  final bitmap = pdfium.FPDFTextObj_GetRenderedBitmap(
      document, page, textObject, _probeScale);
  if (bitmap == nullptr) return GlyphSignature.empty;

  try {
    final width = pdfium.FPDFBitmap_GetWidth(bitmap);
    final height = pdfium.FPDFBitmap_GetHeight(bitmap);
    final stride = pdfium.FPDFBitmap_GetStride(bitmap);
    final data = pdfium.FPDFBitmap_GetBuffer(bitmap);
    if (data == nullptr || width <= 0 || height <= 0 || stride <= 0) {
      return GlyphSignature.empty;
    }

    final bytes = data.cast<Uint8>().asTypedList(stride * height);
    final bytesPerPixel = stride ~/ width;
    if (bytesPerPixel <= 0) return GlyphSignature.empty;

    // Tło rozpoznajemy po kanale alfa, a NIE po kolorze lewego górnego rogu.
    // Wąskie glify ("l", "i") wypełniają całą przyciętą bitmapę, więc róg
    // bywa już literą — heurystyka rogu dawała wtedy fałszywe "brak glifu".
    final format = pdfium.FPDFBitmap_GetFormat(bitmap);
    final hasAlpha = bytesPerPixel >= 4 &&
        (format == FPDFBitmap_BGRA || format == FPDFBitmap_BGRA_Premul);

    final background = hasAlpha
        ? const <int>[]
        : <int>[for (var i = 0; i < bytesPerPixel; i++) bytes[i]];

    var ink = 0;
    var checksum = 0;
    for (var y = 0; y < height; y++) {
      final rowOffset = y * stride;
      for (var x = 0; x < width; x++) {
        final offset = rowOffset + x * bytesPerPixel;
        bool inked;
        if (hasAlpha) {
          inked = bytes[offset + 3] != 0;
        } else {
          inked = false;
          for (var c = 0; c < bytesPerPixel; c++) {
            if (bytes[offset + c] != background[c]) {
              inked = true;
              break;
            }
          }
        }
        if (inked) {
          ink++;
          checksum = (checksum * 31 + (y * width + x)) & 0x3FFFFFFF;
        }
      }
    }
    return GlyphSignature(width, height, ink, checksum, reliableInk: hasAlpha);
  } finally {
    pdfium.FPDFBitmap_Destroy(bitmap);
  }
}
