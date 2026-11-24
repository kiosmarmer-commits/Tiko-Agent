import 'dart:io';

/// Small, capability-aware visual language shared by Tiko terminal surfaces.
/// It deliberately stays ANSI-only so the same output remains readable in
/// logs, pipes, CI and screen readers when colour is disabled.
final class TuiTheme {
  const TuiTheme({this.color = true});

  final bool color;

  static bool terminalColorAllowed() =>
      stdout.hasTerminal &&
      stdout.supportsAnsiEscapes &&
      !Platform.environment.containsKey('NO_COLOR') &&
      (Platform.environment['TERM'] ?? '') != 'dumb';

  String paint(String text, String code) =>
      color ? '\x1B[${code}m$text\x1B[0m' : text;

  String title(String text) => paint(text, '1;36');
  String section(String text) => paint(text, '1');
  String muted(String text) => paint(text, '90');
  String success(String text) => paint(text, '32');
  String warning(String text) => paint(text, '33');
  String error(String text) => paint(text, '31');
  String accent(String text) => paint(text, '36');

  List<String> panel(String heading, Iterable<String> lines, {int width = 76}) {
    final contentWidth = width - 4;
    String fit(String line) {
      final value = line.length > contentWidth
          ? '${line.substring(0, contentWidth - 1)}…'
          : line;
      return '│ ${value.padRight(contentWidth)} │';
    }

    final headingPadding = width - heading.length - 4;
    final paddedHeading = heading.padRight(
      headingPadding < 1 ? 1 : headingPadding,
    );
    return [
      '┌─ $paddedHeading─┐',
      for (final line in lines) fit(line),
      '└${'─' * (width - 2)}┘',
    ];
  }
}
