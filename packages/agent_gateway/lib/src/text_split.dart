/// Split long messages for Telegram 4096 limit (keep margin).
List<String> splitMessage(String text, {int maxLen = 3500}) {
  if (text.length <= maxLen) return [text];
  final parts = <String>[];
  var rest = text;
  while (rest.length > maxLen) {
    var cut = rest.lastIndexOf('\n', maxLen);
    if (cut < maxLen ~/ 2) cut = maxLen;
    parts.add(rest.substring(0, cut));
    rest = rest.substring(cut).trimLeft();
  }
  if (rest.isNotEmpty) parts.add(rest);
  return parts;
}
