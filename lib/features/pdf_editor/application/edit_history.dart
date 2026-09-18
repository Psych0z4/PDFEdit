/// Historia rewizji dokumentu.
///
/// PDFium nie ma własnego stosu undo, więc nie udajemy, ze ma. Kazda
/// zatwierdzona zmiana zapisuje nowy plik rewizji, a undo/redo to przesuwanie
/// kursora po tej liscie. Proste, odporne na bledy i chroni oryginał.
class EditHistory {
  EditHistory(String initialRevisionPath)
      : _revisions = <String>[initialRevisionPath];

  final List<String> _revisions;
  int _cursor = 0;
  int _nextRevisionId = 1;

  String get currentPath => _revisions[_cursor];

  bool get canUndo => _cursor > 0;
  bool get canRedo => _cursor < _revisions.length - 1;
  bool get hasUnsavedChanges => _cursor > 0;

  /// Numer nadawany kolejnemu plikowi rewizji. Rośnie monotonicznie, żeby
  /// po cofnięciu i nowej edycji nie nadpisac pliku z porzuconej gałęzi.
  int reserveRevisionId() => _nextRevisionId++;

  void push(String revisionPath) {
    if (_cursor < _revisions.length - 1) {
      _revisions.removeRange(_cursor + 1, _revisions.length);
    }
    _revisions.add(revisionPath);
    _cursor = _revisions.length - 1;
  }

  String undo() {
    if (canUndo) _cursor--;
    return currentPath;
  }

  String redo() {
    if (canRedo) _cursor++;
    return currentPath;
  }
}
