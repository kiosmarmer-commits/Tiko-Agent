import 'dart:async';
import 'dart:convert';

import 'package:agent_core/agent_core.dart';
import 'package:agent_providers/agent_providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('readStreamedErrorBody', () {
    http.StreamedResponse _response(
      Stream<List<int>> body, {
      int statusCode = 500,
    }) =>
        http.StreamedResponse(
          body,
          statusCode,
          contentLength: null,
          request: http.Request('POST', Uri.parse('http://127.0.0.1:9/v1')),
          headers: const {'content-type': 'application/json'},
        );

    test('body kecil → teks penuh', () async {
      final resp = _response(
        Stream.value(utf8.encode('{"error": {"message": "quota exceeded"}}')),
      );
      final text = await readStreamedErrorBody(resp);
      expect(text, contains('quota exceeded'));
    });

    test('body raksasa → terpotong pada maxBytes, never-raises', () async {
      final big = List.filled(200 * 1024, 0x61); // 200 KB 'a'
      final resp = _response(Stream.value(big));
      final text = await readStreamedErrorBody(resp, maxBytes: 64 * 1024);
      expect(text.length, lessThanOrEqualTo(64 * 1024));
      expect(text, isNotEmpty);
    });

    test('body stall → hard deadline mengembalikan byte parsial', () async {
      final ctrl = StreamController<List<int>>();
      final resp = _response(ctrl.stream);
      unawaited(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        ctrl.add(utf8.encode('partial-before-stall'));
        // Tidak pernah close → read tanpa batas akan hang selamanya.
      }());
      final text = await readStreamedErrorBody(
        resp,
        timeout: const Duration(milliseconds: 150),
      );
      expect(text, contains('partial-before-stall'));
      await ctrl.close();
    });

    test('stream error di tengah → parsial dipertahankan, tidak melempar',
        () async {
      final ctrl = StreamController<List<int>>();
      final resp = _response(ctrl.stream);
      unawaited(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        ctrl.add(utf8.encode('awal-diagnostik '));
        ctrl.addError(StateError('socket reset'));
        await ctrl.close();
      }());
      final text = await readStreamedErrorBody(resp);
      expect(text, contains('awal-diagnostik'));
    });
  });

  group('OpenAiCompatProvider bounded error body', () {
    test('stream HTTP 500 → LlmError berisi body terbatas', () async {
      final provider = OpenAiCompatProvider(
        id: 'p-err',
        baseUrl: 'http://127.0.0.1:9/v1',
        model: 'm',
        httpClient: MockClient.streaming(
          (req, _) async => http.StreamedResponse(
            Stream.value(utf8.encode('{"error": "internal server failure"}')),
            500,
          ),
        ),
      );
      final events = await provider
          .chat(ChatRequest(
            messages: const [ChatMessage(role: 'user', content: 'hai')],
            stream: true,
          ))
          .toList();
      final errors = events.whereType<LlmError>().toList();
      expect(errors, hasLength(1));
      expect(errors.first.message, contains('HTTP 500'));
      expect(errors.first.message, contains('internal server failure'));
    });
  });
}
