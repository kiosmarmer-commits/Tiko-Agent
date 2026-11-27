// Hermes parity: `agent/transcript_repair.py` (adaptasi) — perbaikan
// transcript sebelum dikirim ke provider.
//
// Transcript hasil crash/restore/edit manual bisa MALFORMED dan sebagian
// besar provider menolak request dengan 400:
//   * hasil tool (`role: 'tool'`) tanpa tool call pendahulunya (orphan);
//   * tool call asisten tanpa hasil yang berpasangan (unpaired call);
//   * pesan kosong tanpa konten maupun tool call.
// Alih-alih membiarkan turn gagal permanen, transcript dinormalisasi
// fail-closed: bagian yatim dibuang, bagian utuh dipertahankan apa adanya.
// Fungsi ini MURNI (tanpa I/O) dan never-raises.

import 'models.dart';

/// Perbaiki [messages] menjadi transcript valid untuk provider:
///   1. buang pesan `tool` yang `toolCallId`-nya tidak pernah dipanggil
///      oleh asisten mana pun (orphan result);
///   2. buang tool call asisten yang tidak punya hasil berpasangan
///      (unpaired call) — pasangan call/result tetap utuh;
///   3. buang pesan plain yang kontennya kosong;
///   4. pertahankan urutan pesan sisanya tanpa perubahan lain.
List<ChatMessage> repairTranscript(List<ChatMessage> messages) {
  // Kumpulan call id yang pernah dipanggil (urutan tidak penting untuk
  // pencocokan, hanya keanggotaan).
  final calledIds = <String>{};
  final resultIds = <String>{};
  for (final m in messages) {
    if (m.role == 'assistant' && m.toolCalls != null) {
      for (final c in m.toolCalls!) {
        if (c.id.isNotEmpty) calledIds.add(c.id);
      }
    }
    if (m.role == 'tool' && (m.toolCallId ?? '').isNotEmpty) {
      resultIds.add(m.toolCallId!);
    }
  }

  final repaired = <ChatMessage>[];
  for (final m in messages) {
    if (m.role == 'tool') {
      final id = m.toolCallId ?? '';
      // Orphan result: tidak ada call pendahulunya, atau call-nya sendiri
      // dibuang karena unpaired — buang juga supaya pasangan konsisten.
      if (id.isEmpty || !calledIds.contains(id) || !resultIds.contains(id)) {
        continue;
      }
      repaired.add(m);
      continue;
    }
    if (m.role == 'assistant' && m.toolCalls != null && m.toolCalls!.isNotEmpty) {
      final paired = m.toolCalls!
          .where((c) => c.id.isNotEmpty && resultIds.contains(c.id))
          .toList();
      if (paired.isEmpty && m.content.trim().isEmpty) {
        // Asisten yang hanya berisi tool calls tanpa satu pun hasil dan
        // tanpa teks: tidak membawa informasi yang bisa dipertahankan.
        continue;
      }
      if (paired.length == m.toolCalls!.length) {
        repaired.add(m);
      } else {
        repaired.add(
          ChatMessage(
            role: 'assistant',
            content: m.content,
            toolCalls: paired,
            name: m.name,
            images: m.images,
          ),
        );
      }
      continue;
    }
    if (m.content.trim().isEmpty && (m.images == null || m.images!.isEmpty)) {
      // Pesan plain kosong (bukan tool) — biasanya sisa crash.
      continue;
    }
    repaired.add(m);
  }
  return repaired;
}
