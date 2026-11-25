import 'package:flutter/material.dart';

/// Komponen status bersama untuk seluruh halaman: loading, error, dan empty.
/// Dipakai agar gaya pesan, tombol retry, dan tampilan kosong konsisten
/// antarhalaman. Semua token warna berasal dari Material colorScheme supaya
/// bebas dari ketergantungan tema aplikasi dan aman untuk high contrast.
abstract final class StatusViews {
  /// Banner loading ramping berisi indikator progres + label opsional.
  /// Sertakan [Semantics] agar screen reader mengumumkan status memuat.
  static Widget loadingBanner(
    BuildContext context, {
    String label = 'Memuat\u2026',
  }) {
    return Semantics(
      liveRegion: true,
      label: label,
      container: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Banner error dengan ikon, pesan, dan tombol "Coba lagi" bila [onRetry]
  /// diisi. Ditandai [Semantics] liveRegion supaya screen reader membacakan
  /// pesan error seketika.
  static Widget errorBanner(
    BuildContext context,
    String message, {
    VoidCallback? onRetry,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer.withValues(alpha: 0.35),
          border: Border(left: BorderSide(color: colorScheme.error, width: 3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 16, color: colorScheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: TextStyle(color: colorScheme.error)),
            ),
            if (onRetry != null)
              TextButton(
                key: const ValueKey('status_views_retry'),
                onPressed: onRetry,
                child: const Text('Coba lagi'),
              ),
          ],
        ),
      ),
    );
  }

  /// Tampilan kosong terpusat: ikon + pesan + detail opsional + aksi opsional.
  static Widget empty(
    BuildContext context, {
    required String message,
    String? detail,
    IconData icon = Icons.inbox_outlined,
    Widget? action,
  }) {
    final hintColor = Theme.of(context).hintColor;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              container: true,
              child: Icon(icon, size: 36, color: hintColor),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: hintColor),
            ),
            if (detail != null) const SizedBox(height: 6),
            if (detail != null)
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(color: hintColor, fontSize: 12),
              ),
            if (action != null) const SizedBox(height: 12),
            if (action != null) action,
          ],
        ),
      ),
    );
  }
}
