import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  group('AC-8 native passthrough', () {
    late Harness h;
    setUp(() async => h = await Harness.start(models: {'qwen3:*': 16384}));
    tearDown(() => h.close());

    test('AC-8 /api/chat without options.num_ctx gets the configured value; other options kept', () async {
      final (res, _) = await h.post('/api/chat', {
        ...userChat('hi'),
        'options': {'temperature': 0.1},
      });
      expect(res.statusCode, 200);
      final opts = h.fake.lastBody('/api/chat')!['options'] as Map;
      expect(opts['num_ctx'], 16384);
      expect(opts['temperature'], 0.1);
      expect(h.fake.loaded['qwen3:4b'], 16384);
      await h.waitLogs(1);
      expect(h.logJson.single['num_ctx_source'], 'config');
      expect(h.logJson.single['num_ctx'], 16384);
    });

    test('AC-8 a request that sets num_ctx itself is left alone and logged as source=request', () async {
      final (res, _) = await h.post('/api/chat', {
        ...userChat('hi'),
        'options': {'num_ctx': 2048},
      });
      expect(res.statusCode, 200);
      expect((h.fake.lastBody('/api/chat')!['options'] as Map)['num_ctx'], 2048);
      await h.waitLogs(1);
      final line = h.logJson.single;
      expect(line['num_ctx_source'], 'request');
      expect(line['num_ctx'], 2048);
      // 설정값(16384)과 다르면 재로드 진동 위험을 알린다.
      expect(line['event'], 'num_ctx_request_override');
    });

    test('AC-8 /api/generate is filled too', () async {
      final (res, body) = await h.post('/api/generate', {'model': 'qwen3:4b', 'prompt': 'hello', 'stream': false});
      expect(res.statusCode, 200);
      expect((h.fake.lastBody('/api/generate')!['options'] as Map)['num_ctx'], 16384);
      expect((jsonDecode(body) as Map)['response'], startsWith('Hello from the practice mock'));
    });

    test('AC-8 unconfigured model: request body is forwarded unchanged', () async {
      final original = {
        ...userChat('hi', model: 'llama3.2:3b'),
        'options': {'temperature': 0.3},
      };
      await h.post('/api/chat', original);
      expect(h.fake.lastBody('/api/chat'), original);
    });

    test('AC-8 streamed NDJSON lines are relayed byte for byte', () async {
      // 줄 내용을 그대로 두는지 보려고, 고정 바이트를 보내는 업스트림을 쓴다.
      const lines = [
        '{"model":"qwen3:4b","message":{"role":"assistant","content":"A"},"done":false}\n',
        '{"model":"qwen3:4b","message":{"role":"assistant","content":"B"},  "done":false, "extra":1}\n',
        '{"model":"qwen3:4b","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":9,"eval_count":2}\n',
      ];
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        await req.drain<void>();
        req.response.headers.contentType = ContentType('application', 'x-ndjson');
        for (final l in lines) {
          req.response.write(l);
          await req.response.flush();
        }
        await req.response.close();
      });
      final p = await Harness.start(upstream: Uri.parse('http://127.0.0.1:${upstream.port}'));
      addTearDown(() async {
        await p.close();
        await upstream.close(force: true);
      });
      final (res, body) = await p.post('/api/chat', userChat('x', stream: true));
      expect(res.headers.contentType?.mimeType, 'application/x-ndjson');
      expect(body, lines.join());
      await p.waitLogs(1);
      expect(p.logJson.single['prompt_tokens'], 9);
    });

    test('AC-8 fake Ollama stream through the proxy keeps every line and the final done line', () async {
      final (_, body) = await h.post('/api/chat', userChat('hello', stream: true));
      final parsed = const LineSplitter().convert(body).map((l) => jsonDecode(l) as Map).toList();
      expect(parsed.last['done'], true);
      expect(parsed.last['prompt_eval_count'], 5);
      expect(parsed.last.containsKey('ctxguard'), isFalse, reason: 'native bodies are never modified');
    });

    test('AC-8 native truncation is judged from the done line and logged only', () async {
      final p = await Harness.start(models: {'qwen3:*': 4096});
      addTearDown(p.close);
      final (res, body) = await p.post('/api/chat', userChat(words(6000), stream: false));
      expect(res.statusCode, 200);
      expect((jsonDecode(body) as Map).containsKey('ctxguard'), isFalse);
      await p.waitLogs(1);
      expect(p.logJson.single['verdict'], 'truncated');
      expect(p.logJson.single['event'], 'ctx_warning');
    });

    test('AC-8 /api/tags and /v1/models return the same bytes as the upstream', () async {
      for (final path in ['/api/tags', '/v1/models']) {
        final (direct, directBytes) = await h.getBytes(path, base: h.fake.uri);
        final (proxied, proxiedBytes) = await h.getBytes(path);
        expect(proxied.statusCode, direct.statusCode);
        expect(proxiedBytes, directBytes, reason: path);
        expect(proxied.headers.contentType?.mimeType, 'application/json');
      }
    });

    test('AC-8 other paths pass through: HEAD /, 404s, non-JSON native bodies', () async {
      final head = await (await h.client.openUrl('HEAD', h.url('/'))).close();
      await head.drain<void>();
      expect(head.statusCode, 200);

      final (missing, _) = await h.getBytes('/api/nope');
      expect(missing.statusCode, 404);

      final (bad, _) = await h.post('/api/chat', 'not json');
      expect(bad.statusCode, 400, reason: 'Ollama decides, ctxguard does not rewrite the body');
    });

    test('AC-8 /v1/embeddings passes through and is logged as num_ctx_not_applied', () async {
      final (res, body) = await h.post('/v1/embeddings', {'model': 'qwen3:4b', 'input': 'x'});
      expect(res.statusCode, 200);
      expect((jsonDecode(body) as Map)['object'], 'list');
      await h.waitLogs(1);
      expect(h.logJson.single['event'], 'num_ctx_not_applied');
    });
  });
}
