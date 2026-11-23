import 'models.dart';

/// F2 (docs/15 §3) — edit-loop guard: setelah `patch_file` sukses,
/// satu-satunya tool yang boleh dieksekusi berikutnya adalah `verify_project`.
/// Guard baru lepas setelah `verify_project` berjalan tanpa error.
/// Eksekusi tool lain ditahan fail-closed: model menerima ToolResult error
/// yang menjelaskan langkah wajib, bukan hasil eksekusi nyata.
class EditLoopGuard {
  /// Tool yang memicu guard ketika berhasil dijalankan.
  static const editTool = 'patch_file';

  /// Tool yang diminta untuk memverifikasi hasil edit.
  static const requiredTool = 'verify_project';

  bool _pending = false;

  /// True bila ada edit yang menunggu verifikasi.
  bool get pendingVerify => _pending;

  /// Mengecek satu call sebelum dieksekusi. Mengembalikan ToolResult error
  /// bila call harus ditahan, null bila boleh jalan.
  ToolResult? intercept(ToolCall call) {
    if (!_pending || call.name == requiredTool) return null;
    return ToolResult(
      callId: call.id,
      content: 'edit_loop guard: "$call.name" ditahan — setelah "$editTool" '
          'wajib jalankan "$requiredTool" (sukses) sebelum tool lain. '
          'Periksa/test hasil edit lalu panggil "$requiredTool".',
      isError: true,
    );
  }

  void observe(String toolName, bool isError) {
    if (toolName == editTool) {
      _pending = !isError;
    } else if (toolName == requiredTool && !isError) {
      _pending = false;
    }
  }

  void reset() => _pending = false;
}
