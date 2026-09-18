import 'package:get_it/get_it.dart';

import '../features/conversions/domain/conversion_service.dart';
import '../features/conversions/infrastructure/local_conversion_service.dart';
import '../features/pdf_editor/application/editor_controller.dart';
import '../features/pdf_editor/domain/pdf_engine.dart';
import '../features/pdf_editor/infrastructure/pdfium_pdf_engine.dart';
import '../shared/services/document_picker_service.dart';
import '../shared/services/file_storage_service.dart';
import '../shared/services/share_service.dart';

final locator = GetIt.instance;

/// Rejestracja zależności.
///
/// Reszta aplikacji widzi wyłącznie interfejsy ([PdfEngine],
/// [ConversionService]) — konkretne implementacje są podstawiane tylko tutaj.
void setupDependencies() {
  locator
    ..registerLazySingleton<FileStorageService>(FileStorageService.new)
    ..registerLazySingleton<DocumentPickerService>(DocumentPickerService.new)
    ..registerLazySingleton<ShareService>(ShareService.new)
    ..registerLazySingleton<PdfEngine>(PdfiumPdfEngine.new)
    ..registerLazySingleton<ConversionService>(LocalConversionService.new)
    ..registerLazySingleton<EditorController>(
      () => EditorController(
        engine: locator<PdfEngine>(),
        storage: locator<FileStorageService>(),
        picker: locator<DocumentPickerService>(),
        share: locator<ShareService>(),
      ),
    );
}
