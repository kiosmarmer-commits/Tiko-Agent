import 'attachment_picker_model.dart';

/// Fallback non-web (C2 Chat-UX): dialog pemilih file native membutuhkan
/// plugin tambahan yang belum ada di proyek ini. Gagal jujur — pengguna
/// diarahkan ke referensi `@file:` (P3) yang sudah bekerja di semua channel.
Future<List<PickedAttachment>> pickChatAttachments() async {
  throw UnsupportedError(
    'Pemilih file belum didukung di platform ini; tempel referensi '
    '@file:<path> di pesan untuk menyertakan file dari workspace daemon.',
  );
}
