import 'dart:io';

import '../../../core/result.dart';

enum ConversionFormat { txt, jpg, png, docx, pdf }

/// Gdzie fizycznie wykonuje się konwersja.
///
/// Rozroznienie jest czescia kontraktu, bo ma konsekwencje dla prywatnosci:
/// [local] nigdy nie wypuszcza dokumentu z urzadzenia.
enum ConversionLocality { local, remote }

class ConversionRequest {
  const ConversionRequest({
    required this.source,
    required this.target,
    required this.outputDirectory,
  });

  final File source;
  final ConversionFormat target;
  final Directory outputDirectory;
}

class ConversionDescriptor {
  const ConversionDescriptor({
    required this.target,
    required this.locality,
    required this.available,
  });

  final ConversionFormat target;
  final ConversionLocality locality;

  /// False oznacza, ze konwersja jest zaprojektowana, ale jeszcze nie
  /// zaimplementowana. UI ma to pokazac wprost, a nie udawac, ze dziala.
  final bool available;
}

/// Warstwa konwersji.
///
/// Wydzielona od samego poczatku, bo czesc konwersji (PDF -> DOCX, DOCX -> PDF)
/// nie da się sensownie zrobić lokalnie i będzie wymagac backendu. Interfejs
/// jest wspolny, zmienia się tylko implementacja.
abstract class ConversionService {
  List<ConversionDescriptor> get supported;

  Future<Result<File>> convert(ConversionRequest request);
}
