import 'dart:developer' as developer;

/// Logger aplikacji.
///
/// Świadome ograniczenie: NIGDY nie logujemy treści dokumentu użytkownika.
/// Logujemy identyfikatory, indeksy i liczby — nigdy tekstu wyciągniętego z PDF.
class AppLog {
  const AppLog._();

  static void info(String message) => developer.log(message, name: 'pdf_editor');

  static void error(String message, {Object? error, StackTrace? stackTrace}) =>
      developer.log(message, name: 'pdf_editor', error: error, stackTrace: stackTrace);
}
