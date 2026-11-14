import 'package:simpul_core/src/ollama_chat.dart';
import 'package:test/test.dart';

void main() {
  test('complete posts chat request and returns message content', () async {
    Uri? capturedUrl;
    Map<String, Object?>? capturedBody;
    final chat = OllamaChat(
      model: 'llama3.2',
      baseUrl: 'http://localhost:11434',
      fetch: (url, body) async {
        capturedUrl = url;
        capturedBody = body;
        return {
          'message': {'content': 'halo dari model'},
        };
      },
    );

    final answer = await chat.complete('pertanyaan uji', system: 'sistem uji');

    expect(answer, 'halo dari model');
    expect(capturedUrl.toString(), 'http://localhost:11434/api/chat');
    expect(capturedBody!['model'], 'llama3.2');
    expect(capturedBody!['stream'], false);
    final messages = capturedBody!['messages'] as List;
    expect((messages.first as Map)['role'], 'system');
    expect((messages.first as Map)['content'], 'sistem uji');
    expect((messages.last as Map)['role'], 'user');
    expect((messages.last as Map)['content'], 'pertanyaan uji');
  });

  test('unexpected response shape fails closed with StateError', () async {
    final chat = OllamaChat(
      fetch: (url, body) async => 'bukan map',
    );

    await expectLater(chat.complete('q'), throwsStateError);
  });

  test('empty content fails closed with StateError', () async {
    final chat = OllamaChat(
      fetch: (url, body) async => {
        'message': {'content': ''},
      },
    );

    await expectLater(chat.complete('q'), throwsStateError);
  });
}
