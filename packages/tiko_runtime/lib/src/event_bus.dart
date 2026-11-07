import 'dart:async';

/// Shared runtime events for CLI / API / UI (PRD event bus).
class TikoEvent {
  TikoEvent(this.type, this.data, {DateTime? at}) : at = at ?? DateTime.now().toUtc();
  final String type;
  final Map<String, dynamic> data;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'type': type,
        'at': at.toIso8601String(),
        ...data,
      };
}

class EventBus {
  final _ctrl = StreamController<TikoEvent>.broadcast();
  final _buffer = <TikoEvent>[];
  static const maxBuffer = 200;
  Stream<TikoEvent> get stream => _ctrl.stream;

  List<Map<String, dynamic>> recent({int limit = 50}) =>
      _buffer.reversed.take(limit).map((e) => e.toJson()).toList();

  void emit(String type, [Map<String, dynamic>? data]) {
    if (_ctrl.isClosed) return;
    final ev = TikoEvent(type, data ?? {});
    _buffer.add(ev);
    if (_buffer.length > maxBuffer) _buffer.removeAt(0);
    _ctrl.add(ev);
  }

  Future<void> close() => _ctrl.close();
}
