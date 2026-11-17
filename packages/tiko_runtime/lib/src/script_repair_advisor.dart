library;

import 'package:agent_core/agent_core.dart';
import 'package:agent_tools/agent_tools.dart';

/// D3 — [ScriptRepairAdvisor] berbasis LLM (jalur auxiliar).
///
/// Prompt ketat: advisor WAJIB membalas satu blok kode berisi script
/// lengkap pengganti, tanpa penjelasan. Parsing fail-closed: tanpa blok
/// kode valid → [ScriptRepairException] (loop akan berhenti, bukan menebak).
class LlmScriptRepairAdvisor implements ScriptRepairAdvisor {
  LlmScriptRepairAdvisor(this._llm, {this.maxScriptChars = 20000});

  final LlmProvider _llm;
  final int maxScriptChars;

  static final RegExp _codeFence =
      RegExp(r'```[A-Za-z0-9_+\-]*[ \t]*\r?\n([\s\S]*?)```');

  @override
  Future<String> proposePatch(ScriptRepairInput input) async {
    final request = ChatRequest(
      messages: [
        const ChatMessage(
          role: 'system',
          content: '''
You are a strict script-repair advisor for a sandboxed agent runtime.

Rules:
1. Reply with EXACTLY ONE fenced code block containing the FULL corrected
   script (complete replacement, not a diff, not a fragment).
2. Do not add explanations, comments outside the block, or apologies.
3. Fix the root cause of the reported error. Keep the entry point and
   stdin/stdout contract unchanged.
4. If the error cannot plausibly be fixed (missing external resource,
   fundamentally wrong task), reply with exactly: UNFIXABLE
''',
        ),
        ChatMessage(role: 'user', content: _buildPrompt(input)),
      ],
      stream: false,
      temperature: 0.0,
      maxTokens: 4096,
    );
    final response = await _llm.chat(request).first;
    if (response is! LlmTextDelta) {
      throw ScriptRepairException('advisor LLM tidak menghasilkan teks');
    }
    final text = response.delta.trim();
    if (text.toUpperCase() == 'UNFIXABLE') {
      throw ScriptRepairException('advisor menyatakan UNFIXABLE');
    }
    final patch = _extractLastCodeBlock(text) ?? text;
    if (patch.trim().isEmpty) {
      throw ScriptRepairException('patch kosong');
    }
    if (patch.length > maxScriptChars) {
      throw ScriptRepairException('patch melebihi batas ukuran');
    }
    return patch;
  }

  String _buildPrompt(ScriptRepairInput input) {
    return '''
Entry file: ${input.entryFile}
Command: ${input.command.join(' ')}
Attempt: ${input.attempt}/${input.maxAttempts}
Exit code: ${input.exitCode}

Current script:
```
${input.source}
```

Error output (stderr):
```
${input.stderr}
```

Last stdout (may be empty):
```
${input.stdout}
```

Balas SATU blok kode berisi script lengkap yang sudah diperbaiki.''';
  }

  /// Ambil blok kode fenced TERAKHIR (advisor bisa menyertakan blok lama
  /// saat mengutip; blok terakhir adalah jawabannya).
  String? _extractLastCodeBlock(String text) {
    final matches = _codeFence.allMatches(text).toList();
    if (matches.isEmpty) return null;
    return matches.last.group(1)?.trim();
  }
}
