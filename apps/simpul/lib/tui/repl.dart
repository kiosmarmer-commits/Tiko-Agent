import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tiko_tui/tiko_tui.dart';

import 'commands.dart';

/// Simpul vault TUI (Hermes-parity): binds [TuiCommands] to the shared
/// [TuiSession] engine from `tiko_tui` (raw-mode editing, history,
/// autocomplete, multiline, ANSI colouring with a line-mode fallback).
Future<void> runTui(String vault) async {
  final historyPath = Platform.environment['SIMPUL_HISTORY'] ??
      p.join(vault, '.simpul', 'tui-history.txt');
  final commands = TuiCommands(vault: vault);
  final session = TuiSession(
    handler: commands.run,
    completer: commands.complete,
    historyStore: TuiHistoryStore(historyPath),
    banner: [
      'Simpul TUI \u2014 vault: $vault',
      '/help untuk bantuan, /quit untuk keluar.',
    ],
    prompt: 'simpul> ',
  );
  await session.run();
}
