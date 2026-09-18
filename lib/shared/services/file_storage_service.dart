import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Zarządza prywatna przestrzenią plikowa aplikacji.
///
/// Dokumenty użytkownika są prywatne: pracujemy wyłącznie w katalogu
/// aplikacji, nigdy nie zapisujemy w przypadkowych lokalizacjach i nie
/// dotykamy pliku źródłowego użytkownika.
class FileStorageService {
  Directory? _root;

  Future<Directory> _ensureRoot() async {
    final cached = _root;
    if (cached != null) return cached;
    final base = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(base.path, 'workspace'));
    if (!root.existsSync()) root.createSync(recursive: true);
    return _root = root;
  }

  /// Tworzy katalog roboczy sesji edycji i kopiuje do niego oryginał
  /// jako rewizje 0. Od tej chwili plik zrodlowy nie jest juz dotykany.
  Future<Directory> createSession(String sessionId) async {
    final root = await _ensureRoot();
    final dir = Directory(p.join(root.path, sessionId));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);
    return dir;
  }

  String revisionPath(Directory sessionDir, int revision) =>
      p.join(sessionDir.path, 'rev_$revision.pdf');

  /// Kopiuje wskazany plik do katalogu prywatnego aplikacji.
  Future<File> importToWorkspace(File source, String sessionId) async {
    final dir = await createSession(sessionId);
    final target = File(revisionPath(dir, 0));
    await source.copy(target.path);
    return target;
  }

  Future<void> disposeSession(Directory sessionDir) async {
    if (sessionDir.existsSync()) {
      await sessionDir.delete(recursive: true);
    }
  }

  /// Przygotowuje plik pod udostepnienie z czytelna nazwa.
  Future<File> stageForExport(File revision, String displayName) async {
    final root = await _ensureRoot();
    final exportDir = Directory(p.join(root.path, 'export'));
    if (!exportDir.existsSync()) exportDir.createSync(recursive: true);
    final target = File(p.join(exportDir.path, displayName));
    if (target.existsSync()) target.deleteSync();
    return revision.copy(target.path);
  }
}
