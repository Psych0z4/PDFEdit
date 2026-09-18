// Dart nie pozwala na prywatne nazwy parametrow nazwanych, więc pola
// prywatne muszą byc przypisywane w liscie inicjalizacyjnej.
// ignore_for_file: prefer_initializing_formals

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/failures.dart';
import '../../../shared/services/document_picker_service.dart';
import '../../../shared/services/file_storage_service.dart';
import '../../../shared/services/share_service.dart';
import '../domain/document_capability.dart';
import '../domain/edit_operation.dart';
import '../domain/editable_text_object.dart';
import '../domain/pdf_engine.dart';
import 'edit_history.dart';

enum EditorStatus { idle, loading, ready, error }

/// Tryb pracy edytora.
enum EditorMode {
  /// Przegladanie i wybór istniejącego tekstu.
  select,

  /// Nastepne tapnięcie wstawia nowy tekst w tym miejscu.
  addText,
}

class EditorController extends ChangeNotifier {
  EditorController({
    required PdfEngine engine,
    required FileStorageService storage,
    required DocumentPickerService picker,
    required ShareService share,
  })  : _engine = engine,
        _storage = storage,
        _picker = picker,
        _share = share;

  final PdfEngine _engine;
  final FileStorageService _storage;
  final DocumentPickerService _picker;
  final ShareService _share;

  EditorStatus _status = EditorStatus.idle;
  EditorMode _mode = EditorMode.select;
  AppFailure? _failure;
  String? _notice;
  bool _busy = false;

  Directory? _sessionDir;
  EditHistory? _history;
  DocumentCapability? _capability;
  String _displayName = 'dokument.pdf';

  int _currentPage = 1;
  List<EditableTextObject> _pageObjects = const [];
  EditableTextObject? _selected;

  EditorStatus get status => _status;
  EditorMode get mode => _mode;
  AppFailure? get failure => _failure;
  String? get notice => _notice;
  bool get busy => _busy;
  String get displayName => _displayName;
  DocumentCapability? get capability => _capability;
  List<EditableTextObject> get pageObjects => _pageObjects;
  EditableTextObject? get selected => _selected;
  int get currentPage => _currentPage;

  String? get currentPath => _history?.currentPath;
  bool get canUndo => _history?.canUndo ?? false;
  bool get canRedo => _history?.canRedo ?? false;
  bool get hasUnsavedChanges => _history?.hasUnsavedChanges ?? false;
  bool get canEditText => _capability?.canEditText ?? false;
  bool get isScanned => _capability?.isScanned ?? false;

  /// Importuje wskazany dokument do prywatnego katalogu aplikacji i otwiera go.
  Future<void> openPicked(PickedDocument picked) async {
    _status = EditorStatus.loading;
    _failure = null;
    notifyListeners();

    try {
      await _disposeSession();

      final sessionId = DateTime.now().microsecondsSinceEpoch.toString();
      final dir = await _storage.createSession(sessionId);
      final revision0 = File(_storage.revisionPath(dir, 0));
      await picked.copyTo(revision0);

      _sessionDir = dir;
      _displayName = picked.name;
      _history = EditHistory(revision0.path);
      _currentPage = 1;
      _selected = null;

      final inspection = await _engine.inspect(revision0.path);
      final capability = inspection.valueOrNull;
      if (capability == null) {
        _status = EditorStatus.error;
        _failure = inspection.failureOrNull;
        notifyListeners();
        return;
      }

      _capability = capability;
      _status = EditorStatus.ready;
      notifyListeners();

      if (capability.canEditText) {
        await _loadPageObjects();
      }
    } catch (e) {
      _status = EditorStatus.error;
      _failure = DocumentOpenFailure('Nie udało się otworzyć dokumentu.', cause: e);
      notifyListeners();
    }
  }

  Future<void> changePage(int pageNumber) async {
    if (pageNumber == _currentPage) return;
    _currentPage = pageNumber;
    _selected = null;
    notifyListeners();
    if (canEditText) await _loadPageObjects();
  }

  void setMode(EditorMode mode) {
    _mode = mode;
    if (mode == EditorMode.addText) _selected = null;
    notifyListeners();
  }

  void clearNotice() {
    _notice = null;
    notifyListeners();
  }

  void clearSelection() {
    _selected = null;
    notifyListeners();
  }

  /// Wybór obiektu tekstowego pod punktem w przestrzeni strony PDF.
  ///
  /// [tolerance] powiększa obszar trafienia — palec nie jest kursorem myszy.
  void selectAt(double x, double y, {double tolerance = 4}) {
    EditableTextObject? hit;
    for (final obj in _pageObjects) {
      if (obj.containsPoint(x, y)) {
        hit = obj;
        break;
      }
    }
    hit ??= _pageObjects
        .where((o) => o.containsPointWithTolerance(x, y, tolerance))
        .fold<EditableTextObject?>(null, (best, o) {
      if (best == null) return o;
      return o.width * o.height < best.width * best.height ? o : best;
    });

    _selected = hit;
    notifyListeners();
  }

  /// Sprawdza ryzyko brakujących glifów zanim użytkownik zatwierdzi zmiane.
  GlyphCoverageReport? previewGlyphRisk(String newText) {
    final target = _selected;
    if (target == null) return null;
    return _engine.checkGlyphCoverage(target, newText);
  }

  Future<void> replaceSelectedText(String newText) async {
    final target = _selected;
    if (target == null) return;
    if (newText == target.text) {
      _selected = null;
      notifyListeners();
      return;
    }
    await _applyAndCommit([
      ReplaceTextOperation(
        pageIndex: target.pageIndex,
        objectIndex: target.objectIndex,
        newText: newText,
      ),
    ]);
  }

  Future<void> deleteSelected() async {
    final target = _selected;
    if (target == null) return;
    await _applyAndCommit([
      DeleteObjectOperation(
        pageIndex: target.pageIndex,
        objectIndex: target.objectIndex,
      ),
    ]);
  }

  /// Wstawia nowy tekst w podanym punkcie strony PDF.
  Future<void> insertText(int pageIndex, double x, double y, String text) async {
    final path = currentPath;
    if (path == null || text.trim().isEmpty) return;

    final size = await _engine.pageSize(path, pageIndex);
    final page = size.valueOrNull;
    final clampedX = page == null ? x : x.clamp(0.0, page.width);
    final clampedY = page == null ? y : y.clamp(0.0, page.height);

    await _applyAndCommit([
      InsertTextOperation(
        pageIndex: pageIndex,
        text: text,
        x: clampedX,
        y: clampedY,
      ),
    ]);
    _mode = EditorMode.select;
    notifyListeners();
  }

  Future<void> undo() async {
    final history = _history;
    if (history == null || !history.canUndo) return;
    history.undo();
    _selected = null;
    notifyListeners();
    await _loadPageObjects();
  }

  Future<void> redo() async {
    final history = _history;
    if (history == null || !history.canRedo) return;
    history.redo();
    _selected = null;
    notifyListeners();
    await _loadPageObjects();
  }

  Future<void> saveAs() async {
    final path = currentPath;
    if (path == null) return;
    _setBusy(true);
    try {
      final bytes = await File(path).readAsBytes();
      final suggested = _suggestedExportName();
      final result = await _picker.saveAs(bytes, suggested);
      result.fold(
        (saved) => _notice = saved ? 'Zapisano jako $suggested.' : null,
        (failure) => _failure = failure,
      );
    } finally {
      _setBusy(false);
    }
  }

  Future<void> share() async {
    final path = currentPath;
    if (path == null) return;
    _setBusy(true);
    try {
      final staged =
          await _storage.stageForExport(File(path), _suggestedExportName());
      final result = await _share.sharePdf(staged, subject: _displayName);
      result.fold((_) {}, (failure) => _failure = failure);
    } catch (e) {
      _failure = UnexpectedFailure('Nie udało się udostępnić dokumentu.', cause: e);
    } finally {
      _setBusy(false);
    }
  }

  String _suggestedExportName() {
    final base = p.basenameWithoutExtension(_displayName);
    return '$base-edytowany.pdf';
  }

  Future<void> _applyAndCommit(List<EditOperation> operations) async {
    final history = _history;
    final dir = _sessionDir;
    if (history == null || dir == null) return;

    _setBusy(true);
    try {
      final outputPath =
          _storage.revisionPath(dir, history.reserveRevisionId());
      final result = await _engine.applyOperations(
        sourcePath: history.currentPath,
        outputPath: outputPath,
        operations: operations,
      );

      await result.fold(
        (applied) async {
          history.push(applied.outputPath);
          _selected = null;
          if (applied.warnings.isNotEmpty) {
            _notice = applied.warnings.join('\n');
          }
          await _loadPageObjects();
        },
        (failure) async {
          _failure = failure;
          // Nieudana operacja zostawia po sobie plik-wydmuszkę — sprzątamy.
          final orphan = File(outputPath);
          if (orphan.existsSync()) orphan.deleteSync();
        },
      );
    } finally {
      _setBusy(false);
    }
  }

  Future<void> _loadPageObjects() async {
    final path = currentPath;
    if (path == null) return;
    final result = await _engine.textObjectsOnPage(path, _currentPage - 1);
    result.fold(
      (objects) => _pageObjects = objects,
      (failure) {
        _pageObjects = const [];
        _failure = failure;
      },
    );
    notifyListeners();
  }

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }

  Future<void> _disposeSession() async {
    final dir = _sessionDir;
    if (dir != null) await _storage.disposeSession(dir);
    _sessionDir = null;
    _history = null;
    _capability = null;
    _pageObjects = const [];
    _selected = null;
  }

  @override
  void dispose() {
    final dir = _sessionDir;
    if (dir != null) {
      // Katalog roboczy nie powinien przetrwać sesji edycji.
      _storage.disposeSession(dir);
    }
    super.dispose();
  }
}
