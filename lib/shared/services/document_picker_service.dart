import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../core/failures.dart';
import '../../core/result.dart';

/// Dokument wskazany przez użytkownika.
///
/// Celowo trzymamy [PlatformFile], a nie sciezke: na Androidzie picker zwraca
/// `content://`, które w ogole nie ma odpowiednika na dysku. Treść kopiujemy
/// strumieniem do prywatnego katalogu aplikacji.
class PickedDocument {
  const PickedDocument(this._file);

  final PlatformFile _file;

  String get name => _file.name;

  Future<void> copyTo(File target) async {
    final sink = target.openWrite();
    try {
      await sink.addStream(_file.readAsByteStream());
    } finally {
      await sink.close();
    }
  }
}

class DocumentPickerService {
  Future<Result<PickedDocument?>> pickPdf() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
        dialogTitle: 'Wybierz dokument PDF',
      );
      if (file == null) return const Success(null);
      return Success(PickedDocument(file));
    } catch (e) {
      return Failure(FileAccessFailure(
          'Nie udało się otworzyć wybranego pliku.',
          cause: e));
    }
  }

  /// "Zapisz jako" — użytkownik sam wskazuje miejsce docelowe.
  ///
  /// Zwraca false, gdy użytkownik anulowal.
  Future<Result<bool>> saveAs(Uint8List bytes, String fileName) async {
    try {
      final uri = await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'application/pdf',
        dialogTitle: 'Zapisz PDF',
      );
      return Success(uri != null);
    } catch (e) {
      return Failure(
          SaveFailure('Nie udało się zapisać dokumentu.', cause: e));
    }
  }
}
