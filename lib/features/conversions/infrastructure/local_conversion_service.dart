import 'dart:io';

import '../../../core/failures.dart';
import '../../../core/result.dart';
import '../domain/conversion_service.dart';

/// Konwersje wykonywane w calosci na urzadzeniu.
///
/// Stan na teraz: zadeklarowane, ale jeszcze niezaimplementowane. Zwracamy
/// jawna porażkę zamiast pustego pliku — aplikacja nigdy nie udaje, ze cos
/// zrobiła.
class LocalConversionService implements ConversionService {
  const LocalConversionService();

  @override
  List<ConversionDescriptor> get supported => const [
        // Mozliwe lokalnie: PDFium dostarcza i ekstrakcje tekstu, i renderer.
        ConversionDescriptor(
          target: ConversionFormat.txt,
          locality: ConversionLocality.local,
          available: false,
        ),
        ConversionDescriptor(
          target: ConversionFormat.jpg,
          locality: ConversionLocality.local,
          available: false,
        ),
        ConversionDescriptor(
          target: ConversionFormat.png,
          locality: ConversionLocality.local,
          available: false,
        ),
        // Wymaga backendu (LibreOffice headless / pdf2docx) — rekonstrukcja
        // układu dokumentu jest poza zasięgiem bibliotek dostepnych na mobile.
        ConversionDescriptor(
          target: ConversionFormat.docx,
          locality: ConversionLocality.remote,
          available: false,
        ),
      ];

  @override
  Future<Result<File>> convert(ConversionRequest request) async {
    final descriptor =
        supported.where((d) => d.target == request.target).firstOrNull;

    if (descriptor == null) {
      return Failure(UnsupportedConversionFailure(
          'Konwersja do ${request.target.name.toUpperCase()} nie jest obsługiwana.'));
    }
    if (descriptor.locality == ConversionLocality.remote) {
      return Failure(UnsupportedConversionFailure(
        'Konwersja do ${request.target.name.toUpperCase()} wymaga przetwarzania '
        'po stronie serwera. Nie wysyłamy dokumentów na serwer bez Twojej zgody.',
      ));
    }
    return Failure(UnsupportedConversionFailure(
      'Konwersja do ${request.target.name.toUpperCase()} nie jest jeszcze gotowa.',
    ));
  }
}
