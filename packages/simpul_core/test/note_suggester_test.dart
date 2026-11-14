import 'package:simpul_core/simpul_core.dart';
import 'package:test/test.dart';

void main() {
  test('SuggestOp.parse accepts Indonesian and English aliases', () {
    expect(SuggestOp.parse('ringkasan'), SuggestOp.ringkasan);
    expect(SuggestOp.parse('Summary'), SuggestOp.ringkasan);
    expect(SuggestOp.parse('tulis-ulang'), SuggestOp.tulisUlang);
    expect(SuggestOp.parse('rewrite'), SuggestOp.tulisUlang);
    expect(SuggestOp.parse('terjemahan'), SuggestOp.terjemahan);
    expect(SuggestOp.parse('translate'), SuggestOp.terjemahan);
    expect(SuggestOp.parse('tugas'), SuggestOp.ekstraksiTugas);
    expect(SuggestOp.parse('tasks'), SuggestOp.ekstraksiTugas);
    expect(
      () => SuggestOp.parse('tidak-ada'),
      throwsArgumentError,
    );
  });

  test('suggest sends the operation instruction and note text', () async {
    final chat = _FakeChat('- poin satu');
    final suggester = NoteSuggester(chat: chat);

    final result = await suggester.suggest(SuggestOp.ringkasan, 'Isi catatan');

    expect(result, '- poin satu');
    expect(chat.lastSystem, contains('SARAN'));
    expect(chat.lastSystem, contains('human-in-the-loop'));
    expect(chat.lastPrompt, contains('Ringkas catatan berikut'));
    expect(chat.lastPrompt, contains('Isi catatan'));
  });

  test('translation prompt carries the target language', () async {
    final chat = _FakeChat('Translated text');
    final suggester = NoteSuggester(chat: chat);

    await suggester.suggest(
      SuggestOp.terjemahan,
      'Isi catatan',
      targetLang: 'Jepang',
    );

    expect(chat.lastPrompt, contains('ke bahasa Jepang'));
  });

  test('task extraction prompt asks for Markdown checkboxes', () async {
    final chat = _FakeChat('- [ ] kirim laporan');
    final suggester = NoteSuggester(chat: chat);

    final result = await suggester.suggest(
      SuggestOp.ekstraksiTugas,
      'kirim laporan besok',
    );

    expect(result, '- [ ] kirim laporan');
    expect(chat.lastPrompt, contains('- [ ] '));
  });
}

class _FakeChat implements OllamaChat {
  _FakeChat(this._reply);

  final String _reply;
  String? lastPrompt;
  String? lastSystem;

  @override
  Future<String> complete(String prompt, {String? system}) async {
    lastPrompt = prompt;
    lastSystem = system;
    return _reply;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
