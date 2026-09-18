/// Jednolity typ błędu aplikacji. Wszystkie warstwy zwracają go zamiast
/// rzucać surowe wyjątki z FFI czy dart:io.
sealed class AppFailure {
  const AppFailure(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => '$runtimeType: $message';
}

class FileAccessFailure extends AppFailure {
  const FileAccessFailure(super.message, {super.cause});
}

class DocumentOpenFailure extends AppFailure {
  const DocumentOpenFailure(super.message, {super.cause});
}

class PasswordRequiredFailure extends AppFailure {
  const PasswordRequiredFailure(super.message, {super.cause});
}

class TextEditFailure extends AppFailure {
  const TextEditFailure(super.message, {super.cause});
}

class SaveFailure extends AppFailure {
  const SaveFailure(super.message, {super.cause});
}

class UnsupportedConversionFailure extends AppFailure {
  const UnsupportedConversionFailure(super.message, {super.cause});
}

class UnexpectedFailure extends AppFailure {
  const UnexpectedFailure(super.message, {super.cause});
}
