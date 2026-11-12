import 'package:uuid/uuid.dart';

/// Simple trace_id for a single user task (AGD-07).
class TraceContext {
  TraceContext({String? traceId}) : traceId = traceId ?? const Uuid().v4();
  final String traceId;
  final List<String> spans = [];

  void span(String name) =>
      spans.add('${DateTime.now().toUtc().toIso8601String()} $name');

  Map<String, Object?> toJson() => {'trace_id': traceId, 'spans': spans};
}
