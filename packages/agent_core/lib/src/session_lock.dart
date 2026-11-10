/// At most one active task per session key (AGD-05).
class SessionLock {
  final _busy = <String>{};

  bool tryAcquire(String sessionKey) {
    if (_busy.contains(sessionKey)) return false;
    _busy.add(sessionKey);
    return true;
  }

  void release(String sessionKey) => _busy.remove(sessionKey);

  bool isBusy(String sessionKey) => _busy.contains(sessionKey);
}
