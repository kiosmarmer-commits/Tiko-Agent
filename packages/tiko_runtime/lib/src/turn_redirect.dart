/// Interrupt-and-redirect (paritas Hermes): pesan baru yang datang saat
/// sesi sedang memproses turn tidak lagi ditolak — turn aktif dibatalkan
/// secara kooperatif (lewat [CancellationToken]), lalu pesan baru diproses
/// setelah lock sesi lepas.
class TurnRedirectCoordinator {
  TurnRedirectCoordinator({
    this.waitTimeout = const Duration(seconds: 60),
    this.pollInterval = const Duration(milliseconds: 25),
  });

  /// Batas menunggu turn lama selesai setelah dibatalkan. Turn yang terlalu
  /// lama melepas lock (tool yang mengabaikan cancellation) membuat pesan
  /// baru kembali ke jalur lama: ditolak dengan pesan sibuk.
  final Duration waitTimeout;
  final Duration pollInterval;

  /// Membatalkan turn aktif, menunggu lock sesi lepas (bounded), dan
  /// mengembalikan true bila sesi siap menerima turn baru.
  Future<bool> interruptAndWait({
    required void Function() cancelActive,
    required bool Function() isBusy,
  }) async {
    cancelActive();
    final deadline = DateTime.now().add(waitTimeout);
    while (isBusy() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
    }
    return !isBusy();
  }
}
