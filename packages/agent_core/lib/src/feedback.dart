class FeedbackEntry {
  FeedbackEntry({
    required this.sessionId,
    required this.rating,
    this.messageId,
    this.note,
    this.input,
    this.output,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  final String sessionId;
  final int rating; // 1 = 👍, -1 = 👎
  final int? messageId;
  final String? note;
  final String? input;
  final String? output;
  final DateTime createdAt;
}

class FeedbackStore {
  final List<FeedbackEntry> entries = [];

  void add(FeedbackEntry e) => entries.add(e);

  /// Positive examples for few-shot (SL-05).
  List<FeedbackEntry> positiveFewShot({int k = 3, String? similarTo}) {
    final list = entries
        .where((e) => e.rating > 0 && e.input != null && e.output != null)
        .toList();
    if (similarTo != null && similarTo.isNotEmpty) {
      final tokens = similarTo
          .toLowerCase()
          .split(RegExp(r'\s+'))
          .where((t) => t.length > 2)
          .toSet();
      list.sort((a, b) {
        final sa = tokens
            .intersection(
              (a.input ?? '').toLowerCase().split(RegExp(r'\s+')).toSet(),
            )
            .length;
        final sb = tokens
            .intersection(
              (b.input ?? '').toLowerCase().split(RegExp(r'\s+')).toSet(),
            )
            .length;
        return sb.compareTo(sa);
      });
    }
    return list.take(k).toList();
  }
}
