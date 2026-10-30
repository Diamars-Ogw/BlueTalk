import 'dart:async';

/// Journal de bord de l'application : connexions, coupures (avec leur cause),
/// transferts de fichiers. Gardé en mémoire (les 500 derniers évènements) et
/// consultable depuis l'écran « Journal » pour comprendre ce qui s'est passé.
class Diagnostics {
  Diagnostics._();

  static final Diagnostics instance = Diagnostics._();

  static const int _max = 500;

  final List<String> _lines = [];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  List<String> get lines => List.unmodifiable(_lines);

  static void log(String message) => instance._add(message);

  void _add(String message) {
    final t = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    _lines.add('${two(t.hour)}:${two(t.minute)}:${two(t.second)}  $message');
    if (_lines.length > _max) _lines.removeRange(0, _lines.length - _max);
    if (!_changes.isClosed) _changes.add(null);
  }

  void clear() {
    _lines.clear();
    if (!_changes.isClosed) _changes.add(null);
  }

  String dump() => _lines.join('\n');
}
