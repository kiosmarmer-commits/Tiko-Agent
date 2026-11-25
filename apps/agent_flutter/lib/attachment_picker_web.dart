// `package:web` + `dart:js_interop` (C2 Chat-UX, migrasi W3C dari
// `dart:html` — pola sama dengan media embed S18): pemilih file web
// TANPA dependency wajib baru.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

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
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..multiple = true
    ..accept = _accept;
  input.click();
  await input.onChange.first;
  final files = input.files;
  if (files == null || files.length == 0) return const [];
  if (files.length > _maxFiles) {
    throw AttachmentPickerException(
      'Maksimum $_maxFiles lampiran per pesan (dipilih ${files.length}).',
    );
  }
  final out = <PickedAttachment>[];
  for (var i = 0; i < files.length; i++) {
    final file = files.item(i)!;
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

Future<Uint8List> _readBytes(web.File file) async {
  try {
    final buffer = await file.arrayBuffer().toDart;
    return buffer.toDart.asUint8List();
  } on Object {
    throw AttachmentPickerException('"${file.name}" gagal dibaca.');
  }
}
