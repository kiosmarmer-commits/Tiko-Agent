/// Model hasil pemilihan lampiran (C2 Chat-UX). Dipisah agar stub, web,
/// dan pemanggil memakai satu tipe yang sama tanpa dependensi platform.
class PickedAttachment {
  PickedAttachment({
    required this.name,
    required this.mime,
    required this.dataBase64,
  });

  final String name;
  final String mime;
  final String dataBase64;
}

/// Ditampilkan apa adanya lewat SnackBar — pesan bahasa Indonesia yang
/// menyebut batas (jumlah/ukuran/mime).
class AttachmentPickerException implements Exception {
  AttachmentPickerException(this.message);
  final String message;

  @override
  String toString() => message;
}
