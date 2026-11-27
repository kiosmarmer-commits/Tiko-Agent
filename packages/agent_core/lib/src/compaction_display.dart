/// Compaction display (Hermes parity: `agent/compaction_display.py`):
/// proyeksi pesan kompresi untuk TAMPILAN user. Riwayat model-facing
/// menyimpan carrier lengkap; proyeksi tampilan membuang carrier internal
/// (marker murni = pure handoff → tidak dirender) dan mengekstrak teks
/// ringkasan yang layak dibaca reader.
library;

import 'micro_compaction.dart';
import 'models.dart';

/// True bila pesan adalah carrier kompresi (marker ringkasan batch atau
/// micro). Pesan lain selalu false.
bool isCompactionMessage(ChatMessage m) =>
    m.content.startsWith(microSummaryPrefix);

/// Proyeksi tampilan: marker kompresi dirender sebagai bubble system berisi
/// teks ringkasan yang layak dibaca (konten autentik hasil kompresi), null
/// bila ringkasan kosong; pesan lain diteruskan apa adanya.
ChatMessage? projectCompactionMessageForDisplay(ChatMessage m) {
  if (!isCompactionMessage(m)) return m;
  final summary = compactionSummaryOf(m);
  if (summary == null) return null;
  final text = summary['summary'] as String;
  if (text.trim().isEmpty) return null;
  return ChatMessage(role: 'system', content: text);
}

/// Apa yang diceritakan sebuah carrier kompresi kepada reader:
/// `{summary, compacted_messages}` — ringkasan tanpa prefix model-facing dan
/// tag micro; `compacted_messages` null (Tiko tidak menulis recovery footer
/// berhitung). Null bila bukan pesan kompresi.
Map<String, dynamic>? compactionSummaryOf(ChatMessage m) {
  if (!isCompactionMessage(m)) return null;
  var text = m.content.substring(microSummaryPrefix.length).trim();
  if (text.startsWith(microMarkerTag)) {
    text = text.substring(microMarkerTag.length).trim();
  }
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return {'summary': text, 'compacted_messages': null};
}
