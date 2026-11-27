// Hermes parity: `agent/message_sanitization.py` — sanitasi pesan dan
// payload tool sebelum request dikirim: perbaiki karakter yang membuat
// serialisasi JSON SDK provider crash atau ditolak endpoint ketat, plus
// strip blok think basi dari model byte-level (stale thinking).
//
// Deviasi sadar dari Hermes:
// - Hermes memutasi dict wire in-place (shallow/deep, marker DB); Tiko
//   bekerja pada [ChatMessage] ter-tipe dan mengembalikan daftar BARU —
//   identik input => list sama dikembalikan (prompt-cache safe).
// - Hermes men-coerce nama tool replay; dispatch live Tiko memakai nama
//   registry apa adanya, jadi [coerceToolName] hanya untuk nama toolcall
//   tersimpan/replay dan nama pesan tool, bukan definisi tool hidup.

import 'models.dart';

final String _thinkOpen = '${String.fromCharCode(0x3C)}think>';
final String _thinkClose = '${String.fromCharCode(0x3C)}/think>';

/// Strip blok think (multiline, non-greedy) — thinking basi model
/// byte-level tidak boleh mencapai wire provider non-thinking.
final RegExp _thinkBlockRegex = RegExp(
  RegExp.escape(_thinkOpen) + r'[\s\S]*?' + RegExp.escape(_thinkClose),
  multiLine: true,
);

/// Lone surrogate (invalid UTF-8) — tiap kejadian diganti U+FFFD.
final RegExp _loneSurrogateRegex = RegExp(
  '[\\uD800-\\uDBFF](?![\\uDC00-\\uDFFF])'
  '|(?<![\\uD800-\\uDBFF])[\\uDC00-\\uDFFF]',
);

/// Sanitasi teks model/provider:
///   1. normalisasi CRLF dan lone CR ke LF;
///   2. strip blok think;
///   3. buang karakter kontrol kecuali LF dan TAB (termasuk DEL);
///   4. ganti lone surrogate dengan U+FFFD.
String sanitizeModelText(String text) {
  if (text.isEmpty) return text;
  var out = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  out = out.replaceAll(_thinkBlockRegex, '');
  final buf = StringBuffer();
  for (var i = 0; i < out.length; i++) {
    final c = out.codeUnitAt(i);
    if (c == 0x0A || c == 0x09) {
      buf.writeCharCode(c);
      continue;
    }
    if (c < 0x20 || c == 0x7F) continue;
    buf.writeCharCode(c);
  }
  var result = buf.toString();
  if (result.contains(_loneSurrogateRegex)) {
    result = result.replaceAllMapped(_loneSurrogateRegex, (_) => '\uFFFD');
  }
  return result;
}

final RegExp _validToolNameRegex = RegExp(r'^[A-Za-z0-9_-]{1,64}$');
final RegExp _invalidToolNameChars = RegExp(r'[^A-Za-z0-9_-]');
final RegExp _underscoreRuns = RegExp(r'_+');
final RegExp _edgeUnderscores = RegExp(r'^_+|_+$');

/// Hermes `coerce_tool_name`: paksa nama tool REPLAY ke
/// `^[A-Za-z0-9_-]{1,64}$`. Nama valid kembali identitas (prompt-cache
/// safe); invalid dilipat ke `_`, dipotong 64; kosong/seluruhnya invalid
/// ke [fallback]. Deterministik.
String coerceToolName(Object? name, {String fallback = 'invalid_tool_call'}) {
  if (name is! String) return fallback;
  if (_validToolNameRegex.hasMatch(name)) return name;
  final coerced = name
      .trim()
      .replaceAll(_invalidToolNameChars, '_')
      .replaceAll(_underscoreRuns, '_')
      .replaceAll(_edgeUnderscores, '');
  final cut = coerced.length > 64 ? coerced.substring(0, 64) : coerced;
  return cut.isEmpty ? fallback : cut;
}

/// Sanitasi daftar pesan untuk wire: terapkan [sanitizeModelText] ke
/// `content` dan `name`, serta [coerceToolName] + sanitasi argumen string
/// pada tool call tersimpan. Nama pesan tool ikut di-coerce dengan fungsi
/// yang sama agar tetap konsisten dengan toolcall-nya. Mengembalikan list
/// yang SAMA bila tidak ada perubahan (prompt-cache safe).
List<ChatMessage> sanitizeChatMessages(List<ChatMessage> messages) {
  var changed = false;
  final out = <ChatMessage>[];
  for (final m in messages) {
    var msgChanged = false;
    final content = sanitizeModelText(m.content);
    if (content != m.content) msgChanged = true;
    final name = m.role == 'tool'
        ? coerceToolName(m.name, fallback: m.name ?? '')
        : (m.name == null ? null : sanitizeModelText(m.name!));
    if (name != m.name) msgChanged = true;
    List<ToolCall>? calls;
    if (m.toolCalls != null) {
      final sanitizedCalls = <ToolCall>[];
      for (final c in m.toolCalls!) {
        final coerced = coerceToolName(c.name, fallback: c.name);
        final args = <String, dynamic>{};
        var argsChanged = false;
        c.args.forEach((k, v) {
          if (v is String) {
            final fixed = sanitizeModelText(v);
            if (fixed != v) argsChanged = true;
            args[k] = fixed;
          } else {
            args[k] = v;
          }
        });
        if (coerced != c.name || argsChanged) {
          msgChanged = true;
          sanitizedCalls.add(ToolCall(id: c.id, name: coerced, args: args));
        } else {
          sanitizedCalls.add(c);
        }
      }
      calls = sanitizedCalls;
    }
    if (msgChanged) {
      changed = true;
      out.add(ChatMessage(
        role: m.role,
        content: content,
        toolCallId: m.toolCallId,
        toolCalls: calls,
        name: name,
        images: m.images,
      ));
    } else {
      out.add(m);
    }
  }
  return changed ? out : messages;
}
