// dart:html dipilih sadar (C2 Chat-UX): pemilih file web TANPA dependency
// baru — `package:web` belum ada di proyek ini. Dua lint di bawah adalah
// info yang disengaja dan dijelaskan di attachment_picker.dart.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'attachment_picker_model.dart';

/// Batas partisipan (C2 Chat-UX) — harus sinkron dengan allowlist daemon
/// (`HttpApiServer._parseAttachments`): maksimum 4 file, 2 MiB per file,
/// mime text/* + subset application/* + image png/jpeg/gif/webp.
const _maxFiles = 4;
const _maxBytes = 2 * 1024 * 1024;

const _accept = 'text/*,application/json,application/x-ndjson,application/yaml,'
    'application/x-yaml,application/toml,application/xml,'
    'application/javascript,application/x-sh,'
    '.md,.txt,.log,.csv,.json,.jsonl,.ndjson,.yaml,.yml,.toml,.xml,.js,'
    '.dart,.py,.go,.rs,.java,.kt,.ts,.tsx,.jsx,.sh,.c,.h,.cpp,.ini,.env,'
    'image/png,image/jpeg,image/gif,image/webp,.png,.jpg,.jpeg,.gif,.webp';

final Map<String, String> _extMime = {
  'md': 'text/plain',
  'txt': 'text/plain',
  'log': 'text/plain',
  'csv': 'text/plain',
  'json': 'application/json',
  'jsonl': 'application/x-ndjson',
  'ndjson': 'application/x-ndjson',
  'yaml': 'application/yaml',
  'yml': 'application/yaml',
  'toml': 'application/toml',
  'xml': 'application/xml',
  'js': 'application/javascript',
  'sh': 'application/x-sh',
  'dart': 'text/plain',
  'py': 'text/plain',
  'go': 'text/plain',
  'rs': 'text/plain',
  'java': 'text/plain',
  'kt': 'text/plain',
  'ts': 'text/plain',
  'tsx': 'text/plain',
  'jsx': 'text/plain',
  'c': 'text/plain',
  'h': 'text/plain',
  'cpp': 'text/plain',
  'ini': 'text/plain',
  'env': 'text/plain',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
};

bool _mimeAllowed(String mime) {
  if (mime.startsWith('image/')) {
    return const {'image/png', 'image/jpeg', 'image/gif', 'image/webp'}
        .contains(mime);
  }
  if (mime.startsWith('text/')) return true;
  return const {
    'application/json',
    'application/x-ndjson',
    'application/yaml',
    'application/x-yaml',
    'application/toml',
    'application/xml',
    'application/javascript',
    'application/x-sh',
  }.contains(mime);
}

String _mimeFor(String name, String browserType) {
  if (browserType.isNotEmpty) return browserType.toLowerCase();
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return _extMime[name.substring(dot + 1).toLowerCase()] ?? '';
}

Future<List<PickedAttachment>> pickChatAttachments() async {
  final input = html.FileUploadInputElement()
    ..multiple = true
    ..accept = _accept;
  input.click();
  await input.onChange.first;
  final files = input.files;
  if (files == null || files.isEmpty) return const [];
  if (files.length > _maxFiles) {
    throw AttachmentPickerException(
      'Maksimum $_maxFiles lampiran per pesan (dipilih ${files.length}).',
    );
  }
  final out = <PickedAttachment>[];
  for (final file in files) {
    if (file.size > _maxBytes) {
      throw AttachmentPickerException(
        '"${file.name}" terlalu besar (${file.size} byte); '
        'maksimum $_maxBytes byte (2 MiB).',
      );
    }
    final mime = _mimeFor(file.name, file.type);
    if (!_mimeAllowed(mime)) {
      throw AttachmentPickerException(
        '"${file.name}": tipe file tidak didukung. Yang didukung: teks/*.txt/'
        'md/json/yaml/toml/code, image png/jpeg/gif/webp.',
      );
    }
    out.add(PickedAttachment(
      name: file.name,
      mime: mime,
      dataBase64: base64Encode(await _readBytes(file)),
    ));
  }
  return out;
}

Future<Uint8List> _readBytes(html.File file) {
  final completer = Completer<Uint8List>();
  final reader = html.FileReader();
  reader.onLoadEnd.listen((_) {
    try {
      final result = reader.result;
      if (result is ByteBuffer) {
        completer.complete(result.asUint8List());
      } else if (result is Uint8List) {
        completer.complete(result);
      } else {
        completer.completeError(
          AttachmentPickerException('"${file.name}" gagal dibaca.'),
        );
      }
    } catch (e) {
      completer.completeError(
        AttachmentPickerException('"${file.name}" gagal dibaca: $e'),
      );
    }
  });
  reader.onError.listen((_) {
    completer.completeError(
      AttachmentPickerException('"${file.name}" gagal dibaca.'),
    );
  });
  reader.readAsArrayBuffer(file);
  return completer.future;
}
