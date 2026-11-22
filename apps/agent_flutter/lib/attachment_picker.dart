/// Lampiran chat (C2 Chat-UX). Pemilih file aktif di Web via `dart:html`;
/// platform tanpa dialog native (desktop tanpa plugin) gagal jujur lewat
/// stub — pengguna diarahkan ke referensi `@file:` dari P3.
library;

export 'attachment_picker_model.dart';
export 'attachment_picker_stub.dart'
    if (dart.library.js_interop) 'attachment_picker_web.dart';
