/// Session-level taint: after reading untrusted data, high tools need explicit confirm (C-03).
class TaintTracker {
  final _taintedSessions = <String>{};

  void mark(String sessionId) => _taintedSessions.add(sessionId);
  bool isTainted(String sessionId) => _taintedSessions.contains(sessionId);
  void clear(String sessionId) => _taintedSessions.remove(sessionId);
}
