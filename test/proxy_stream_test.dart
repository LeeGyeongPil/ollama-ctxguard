import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

Map<String, Object?> _choice(Map<String, Object?> chunk) => (chunk['choices'] as List).first as Map<String, Object?>;
Map<String, Object?> _delta(Map<String, Object?> chunk) => _choice(chunk)['delta'] as Map<String, Object?>;

void main() {
  group('AC-2 streaming NDJSON -> SSE', () {
    late Harness h;
    setUp(() async => h = await Harness.start(models: {'qwen3:*': 16384}));
    tearDown(() => h.close());

    test('AC-2 first chunk reaches the client before the upstream sends its last line', () async {
      h.fake.scenario
        ..streamLines = 6
        ..lineDelay = const Duration(milliseconds: 100);
      final req = await h.client.postUrl(h.url('/v1/chat/completions'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(userChat('hi', stream: true)));
      final res = await req.close();
      expect(res.headers.contentType?.mimeType, 'text/event-stream');

      DateTime? firstChunkAt;
      final text = StringBuffer();
      await for (final part in res.transform(utf8.decoder)) {
        if (firstChunkAt == null && part.contains('data: ')) firstChunkAt = DateTime.now();
        text.write(part);
      }
      final lastLine = h.fake.lastLineSentAt!;
      // 줄 사이 100ms × 6 → 버퍼링했다면 첫 청크가 마지막 줄 뒤에 도착한다.
      expect(firstChunkAt!.isBefore(lastLine), isTrue, reason: 'first=$firstChunkAt last=$lastLine');
      expect(lastLine.difference(firstChunkAt).inMilliseconds, greaterThan(300));
      expect(sseData(text.toString()).last, '[DONE]');
    });

    test('AC-2 content deltas, final chunk with finish_reason + ctxguard, then [DONE]', () async {
      final (res, body) = await h.post('/v1/chat/completions', userChat('hello world', stream: true));
      expect(res.statusCode, 200);
      // 스트리밍은 헤더가 먼저 나가므로 미리 아는 값(설정)만 헤더에 있다.
      expect(res.headers.value('X-Ctxguard-Num-Ctx'), '16384');
      expect(res.headers.value('X-Ctxguard-Verdict'), isNull);

      final data = sseData(body);
      expect(data.last, '[DONE]');
      final chunks = sseChunks(body);
      for (final c in chunks) {
        expect(c['object'], 'chat.completion.chunk');
        expect(c['model'], 'qwen3:4b');
      }
      // 모든 청크가 같은 id.
      expect(chunks.map((c) => c['id']).toSet(), hasLength(1));

      final content = chunks
          .where((c) => (c['choices'] as List).isNotEmpty && _delta(c)['content'] != null)
          .map((c) => _delta(c)['content'])
          .join();
      expect(content, startsWith('Hello from the practice mock'));

      final last = chunks.last;
      expect(_choice(last)['finish_reason'], 'stop');
      final guard = last['ctxguard'] as Map;
      expect(guard['verdict'], 'ok');
      expect(guard['num_ctx'], 16384);
      expect(guard['num_ctx_source'], 'config');
      expect(guard['prompt_tokens'], 6);
      // include_usage 가 없으면 usage 청크도 없다.
      expect(chunks.where((c) => c.containsKey('usage')), isEmpty);
      // finish_reason 은 마지막 청크에만.
      expect(
        chunks.where((c) => (c['choices'] as List).isNotEmpty && _choice(c)['finish_reason'] != null),
        hasLength(1),
      );
    });

    test('AC-2 stream_options.include_usage adds one usage chunk with empty choices', () async {
      final (_, body) = await h.post('/v1/chat/completions', {
        ...userChat('hello world', stream: true),
        'stream_options': {'include_usage': true},
      });
      final chunks = sseChunks(body);
      final usage = chunks.where((c) => c.containsKey('usage')).toList();
      expect(usage, hasLength(1));
      expect(usage.single['choices'], isEmpty);
      expect((usage.single['usage'] as Map)['prompt_tokens'], 6);
      expect(sseData(body).last, '[DONE]');
    });

    test('AC-2 tool calls stream as delta.tool_calls with JSON-string arguments', () async {
      h.fake.scenario.toolCallName = 'get_weather';
      final (_, body) = await h.post('/v1/chat/completions', userChat('weather?', stream: true));
      final chunks = sseChunks(body);
      final withCalls = chunks.where((c) => (c['choices'] as List).isNotEmpty && _delta(c)['tool_calls'] != null);
      final call = ((_delta(withCalls.single)['tool_calls'] as List).single) as Map;
      expect(call['index'], 0);
      expect(call['id'], 'call_mock1');
      expect(call['type'], 'function');
      expect((call['function'] as Map)['name'], 'get_weather');
      expect((call['function'] as Map)['arguments'], '{"city":"Seoul"}');
      expect(_choice(chunks.last)['finish_reason'], 'tool_calls');
    });

    test('AC-2 thinking streams as delta.reasoning', () async {
      h.fake.scenario.thinking = 'hmm';
      final (_, body) = await h.post('/v1/chat/completions', userChat('x', stream: true));
      final chunks = sseChunks(body);
      expect(_delta(chunks.first)['reasoning'], 'hmm');
    });

    test('AC-2 the client sees each line as it is produced (no buffering at the end)', () async {
      h.fake.scenario
        ..streamLines = 3
        ..lineDelay = const Duration(milliseconds: 150);
      final req = await h.client.postUrl(h.url('/v1/chat/completions'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(userChat('hi', stream: true)));
      final res = await req.close();
      final arrivals = <DateTime>[];
      await for (final part in res.transform(utf8.decoder)) {
        for (var i = 0; i < 'data: '.allMatches(part).length; i++) {
          arrivals.add(DateTime.now());
        }
      }
      // 3줄 + 마지막 청크 + [DONE]; 첫 청크와 마지막 청크 사이에 지연이 보여야 한다.
      expect(arrivals.length, greaterThanOrEqualTo(5));
      expect(arrivals.last.difference(arrivals.first).inMilliseconds, greaterThan(250));
    });
  });

  group('AC-5 --strict streaming', () {
    test('AC-5 truncated stream ends with an error chunk then [DONE]', () async {
      final h = await Harness.start(models: {'qwen3:*': 4096}, strict: true);
      addTearDown(h.close);
      final (res, body) = await h.post('/v1/chat/completions', userChat(words(6000), stream: true));
      expect(res.statusCode, 200, reason: 'headers were already sent');
      final data = sseData(body);
      expect(data.last, '[DONE]');
      final errorChunk = jsonDecode(data[data.length - 2]) as Map;
      final err = errorChunk['error'] as Map;
      expect(err['type'], 'context_truncated');
      expect(err['code'], 'ctxguard_truncated');
      // 판정 정보는 그 앞 마지막 청크에 있다.
      final finish = jsonDecode(data[data.length - 3]) as Map<String, Object?>;
      expect((finish['ctxguard'] as Map)['verdict'], 'truncated');
    });

    test('AC-5 without --strict there is no error chunk', () async {
      final h = await Harness.start(models: {'qwen3:*': 4096});
      addTearDown(h.close);
      final (_, body) = await h.post('/v1/chat/completions', userChat(words(6000), stream: true));
      final chunks = sseChunks(body);
      expect(chunks.where((c) => c.containsKey('error')), isEmpty);
      expect((chunks.last['ctxguard'] as Map)['verdict'], 'truncated');
    });

    test('AC-5 suspect stream is not blocked in strict mode', () async {
      final h = await Harness.start(models: {'qwen3:*': 4096}, strict: true);
      addTearDown(h.close);
      h.fake.scenario.cachedCount = 2050;
      final (_, body) = await h.post('/v1/chat/completions', userChat('short', stream: true));
      final chunks = sseChunks(body);
      expect(chunks.where((c) => c.containsKey('error')), isEmpty);
      expect((chunks.last['ctxguard'] as Map)['verdict'], 'suspect');
    });
  });

  test('AC-2 a streamed upstream error line becomes an OpenAI error chunk', () async {
    // 업스트림이 스트림 도중 {"error": ...} 줄을 보내는 경우(모델 크래시 등).
    final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      await req.drain<void>();
      req.response.headers.contentType = ContentType('application', 'x-ndjson');
      req.response.write(
        '${jsonEncode({
          'model': 'qwen3:4b',
          'message': {'role': 'assistant', 'content': 'Hi'},
          'done': false,
        })}\n',
      );
      req.response.write('${jsonEncode({'error': 'model runner crashed'})}\n');
      await req.response.close();
    });
    final h = await Harness.start(upstream: Uri.parse('http://127.0.0.1:${upstream.port}'));
    addTearDown(() async {
      await h.close();
      await upstream.close(force: true);
    });
    final (_, body) = await h.post('/v1/chat/completions', userChat('x', stream: true));
    final chunks = sseChunks(body);
    expect(((chunks.last['error'] as Map)['message']), 'model runner crashed');
    expect(sseData(body).last, '[DONE]');
  });
}
