import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:ollama_ctxguard/ollama_ctxguard.dart';
import 'package:ollama_ctxguard/src/cli.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  group('AC-6 safe defaults', () {
    test('AC-6 default config binds to loopback 127.0.0.1:11435', () async {
      final config = CtxguardConfig();
      expect(config.listenHost, '127.0.0.1');
      expect(config.listenPort, 11435);

      // 명령줄에서 아무 옵션도 주지 않았을 때도 같은 기본값이어야 한다.
      final parsed = buildParser().parse(['serve']);
      final fromCli = loadServeConfig(parsed.command!, defaultPath: '/nonexistent/ctxguard.yaml');
      expect(fromCli.listenHost, '127.0.0.1');
      expect(fromCli.listenPort, 11435);

      // 실제로 바인딩해 보면 loopback 이다(포트만 임의로).
      final proxy = ProxyServer(fromCli.withOverrides(listenPort: 0), log: AccessLog(sink: (_) {}));
      await proxy.start();
      addTearDown(proxy.close);
      expect(proxy.address.isLoopback, isTrue);
      expect(proxy.address.address, '127.0.0.1');
    });

    test('AC-6 logs never contain request/response bodies or the Authorization header', () async {
      final marker = 'MARKER-${Random.secure().nextInt(1 << 31)}';
      final h = await Harness.start();
      addTearDown(h.close);
      // 가짜 Ollama 가 표식을 그대로 되돌려 주게 한다(응답 본문에도 표식이 있다).
      h.fake.scenario.replyText = 'echo $marker';
      final auth = {'Authorization': 'Bearer $marker'};
      final prompt = 'secret prompt $marker ${words(50)}';

      // 비스트리밍 /v1
      final (r1, b1) = await h.post('/v1/chat/completions', userChat(prompt), headers: auth);
      expect(r1.statusCode, 200);
      expect(b1, contains(marker)); // 응답에는 있다…
      // 스트리밍 /v1
      final (r2, b2) = await h.post('/v1/chat/completions', userChat(prompt, stream: true), headers: auth);
      expect(r2.statusCode, 200);
      expect(b2, contains(marker));
      // 네이티브 /api/chat (스트리밍 NDJSON)
      final (r3, b3) = await h.post('/api/chat', userChat(prompt, stream: true), headers: auth);
      expect(r3.statusCode, 200);
      expect(b3, contains(marker));
      // 네이티브 /api/generate (비스트리밍)
      final (r4, b4) = await h.post('/api/generate', {
        'model': 'qwen3:4b',
        'prompt': prompt,
        'stream': false,
      }, headers: auth);
      expect(r4.statusCode, 200);
      expect(b4, contains(marker));
      // 통과 경로(/v1/embeddings)
      final (r5, _) = await h.post('/v1/embeddings', {'model': 'qwen3:4b', 'input': marker}, headers: auth);
      expect(r5.statusCode, 200);

      await h.waitLogs(5);
      expect(h.logs, hasLength(5));
      // …로그 어디에도 없다.
      for (final line in h.logs) {
        expect(line, isNot(contains(marker)));
        final j = jsonDecode(line) as Map<String, Object?>;
        expect(allowedLogFields, containsAll(j.keys), reason: 'only whitelisted fields: $line');
      }
      // 가짜 Ollama 는 Authorization 을 받았다(그대로 전달은 하지만 기록은 안 한다).
      expect(h.fake.received.where((r) => r.headers['authorization'] == 'Bearer $marker'), isNotEmpty);
    });

    test('AC-6 text log format also keeps only whitelisted fields', () async {
      final marker = 'MARKER-${Random.secure().nextInt(1 << 31)}';
      final h = await Harness.start(logFormat: LogFormat.text);
      addTearDown(h.close);
      await h.post('/v1/chat/completions', userChat('hi $marker'), headers: {'Authorization': marker});
      await h.waitLogs(1);
      expect(h.logs.single, isNot(contains(marker)));
      expect(h.logs.single, contains('verdict=ok'));
    });
  });

  group('AC-6 browser protection: the proxy must not weaken Ollama Host/Origin checks', () {
    // 프록시가 없다면 Ollama 가 막았을 요청은 프록시를 거쳐도 막혀야 하고(음성),
    // 평소의 로컬 클라이언트는 그대로 통과해야 한다(양성).
    late Harness h;
    setUp(() async => h = await Harness.start());
    tearDown(() => h.close());

    final chat = jsonEncode(userChat('hi'));
    final gen = jsonEncode({'model': 'qwen3:4b', 'prompt': 'hi', 'stream': false});
    // (메서드, 경로, 본문) — 변환 경로·네이티브 경로·바이트 통과 경로를 모두 덮는다.
    final routes = <(String, String, String?)>[
      ('POST', '/v1/chat/completions', chat),
      ('POST', '/api/chat', jsonEncode(userChat('hi', stream: false))),
      ('POST', '/api/generate', gen),
      ('GET', '/api/tags', null),
      ('GET', '/v1/models', null),
    ];

    // DNS 리바인딩: 공격 페이지의 이름이 127.0.0.1 로 풀려도 Host 헤더에는 그 이름이 남는다.
    const evilHosts = [
      'evil.example:11435',
      'evil.example',
      'localhost.evil.example:11435',
      '127.0.0.1.nip.io:11435',
      'EVIL.EXAMPLE',
    ];
    for (final host in evilHosts) {
      test('AC-6 Host "$host" is rejected with 403 on every route and never reaches Ollama', () async {
        for (final (method, path, body) in routes) {
          final r = await h.raw(
            method,
            path,
            host: host,
            headers: const {'Content-Type': 'application/json'},
            body: body,
          );
          expect(r.status, 403, reason: '$method $path Host=$host');
          expect(r.body, contains('host_not_allowed'));
        }
        expect(h.fake.received, isEmpty, reason: 'nothing may be forwarded upstream');
        expect(h.fake.loaded, isEmpty, reason: 'no model may be loaded');
        await h.waitLogs(routes.length);
        expect(h.logJson.map((l) => l['event']), everyElement('host_not_allowed'));
        expect(h.logs.join('\n'), isNot(contains('evil')), reason: 'the attacker-chosen host is not logged');
      });
    }

    // 브라우저가 보내는 Origin 은 Ollama 까지 그대로 가서 OLLAMA_ORIGINS 검사를 받아야 한다.
    const evilOrigins = ['http://evil.example', 'https://evil.example:11435', 'null', 'http://localhost.evil.example'];
    for (final origin in evilOrigins) {
      test('AC-6 Origin "$origin" is forwarded and Ollama-style CORS rejects it (403, no generation)', () async {
        for (final (method, path, body) in routes) {
          final r = await h.raw(
            method,
            path,
            headers: {'Origin': origin, 'Content-Type': 'application/json'},
            body: body,
          );
          expect(r.status, 403, reason: '$method $path Origin=$origin');
          final up = h.fake.received.last;
          expect(up.headers['origin'], origin, reason: '$path must forward Origin upstream');
          if (path == '/v1/chat/completions') expect(r.body, contains('OLLAMA_ORIGINS'));
        }
        expect(h.fake.loaded, isEmpty, reason: 'no model may be loaded');
        await h.waitLogs(routes.length);
        expect(h.logJson.map((l) => l['event']), everyElement('origin_rejected'));
        expect(h.logs.join('\n'), isNot(contains('evil')), reason: 'the page-chosen Origin is not logged');
      });
    }

    test('AC-6 cross-site "simple" text/plain POST (no preflight) is rejected too', () async {
      final r = await h.raw(
        'POST',
        '/v1/chat/completions',
        headers: const {'Origin': 'http://evil.example', 'Content-Type': 'text/plain'},
        body: chat,
      );
      expect(r.status, 403);
      expect(h.fake.loaded, isEmpty);
    });

    test('AC-6 preflight OPTIONS from another site gets 403, from localhost gets 204', () async {
      const preflight = {'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'content-type'};
      final bad = await h.raw(
        'OPTIONS',
        '/v1/chat/completions',
        headers: {...preflight, 'Origin': 'http://evil.example'},
      );
      expect(bad.status, 403);
      final good = await h.raw(
        'OPTIONS',
        '/v1/chat/completions',
        headers: {...preflight, 'Origin': 'http://localhost:3000'},
      );
      expect(good.status, 204);
      expect(good.headers['access-control-allow-origin'], 'http://localhost:3000');
    });

    // 양성 표: 평소 쓰는 로컬 클라이언트(curl·SDK·로컬 웹앱·VS Code 확장)는 그대로 된다.
    final localHosts = [
      null, // 127.0.0.1:<port>
      'localhost',
      'LOCALHOST:11435',
      '[::1]:11435',
      'app.localhost:3000',
      'my-mac.local',
      'host.docker.internal:11435',
      '10.0.0.5:11435',
      '192.168.1.20',
      '0.0.0.0:11435',
      Platform.localHostname,
    ];
    for (final host in localHosts) {
      test('AC-6 local Host "${host ?? '127.0.0.1:<port>'}" is served normally', () async {
        for (final (method, path, body) in routes) {
          final r = await h.raw(
            method,
            path,
            host: host,
            headers: const {'Content-Type': 'application/json'},
            body: body,
          );
          expect(r.status, 200, reason: '$method $path Host=$host');
        }
      });
    }

    const localOrigins = [
      'http://localhost:3000',
      'http://127.0.0.1:5173',
      'https://localhost',
      'http://0.0.0.0:8080',
      'vscode-webview://abc123',
      'chrome-extension://abcdefghijklmnop',
      'tauri://localhost',
    ];
    for (final origin in localOrigins) {
      test('AC-6 local Origin "$origin" is allowed and gets CORS headers back', () async {
        for (final (method, path, body) in routes) {
          final r = await h.raw(
            method,
            path,
            headers: {'Origin': origin, 'Content-Type': 'application/json'},
            body: body,
          );
          expect(r.status, 200, reason: '$method $path Origin=$origin');
          expect(r.headers['access-control-allow-origin'], origin, reason: '$method $path');
        }
      });
    }

    test('AC-6 Host check helper follows Ollama rules and is skipped on non-loopback binds', () {
      expect(isAllowedHost('evil.example:80', loopbackBind: true), isFalse);
      expect(isAllowedHost('evil.example:80', loopbackBind: false), isTrue);
      expect(isAllowedHost(null, loopbackBind: true), isTrue); // HTTP/1.0 (Host 없음) — Ollama 와 같음
      expect(isAllowedHost('', loopbackBind: true), isTrue);
      expect(isAllowedHost('[::1]', loopbackBind: true), isTrue);
      expect(isAllowedHost('172.16.0.1:11435', loopbackBind: true), isTrue);
      expect(isAllowedHost('8.8.8.8:11435', loopbackBind: true), isFalse);
      expect(isAllowedHost('8.8.8.8', loopbackBind: true, localAddresses: {'8.8.8.8'}), isTrue);
      expect(isAllowedHost('a.internal.evil', loopbackBind: true), isFalse);
    });
  });

  group('AC-6 text log cannot be forged through user-controlled values', () {
    test('AC-6 a model name with spaces and "=" is quoted in the text log', () {
      final lines = <String>[];
      final log = AccessLog(format: LogFormat.text, sink: lines.add);
      const sneaky = 'x verdict=ok status=200 event="none"';
      log.write({
        'method': 'POST',
        'path': '/v1/chat/completions',
        'model': sneaky,
        'status': 422,
        'verdict': 'truncated',
      });
      final line = lines.single;
      // key=value 를 따옴표를 지켜 나누면 원래 키만 나와야 한다.
      final pairs = RegExp(r'(\w+)=("(?:[^"\\]|\\.)*"|\S+)').allMatches(line).toList();
      expect(pairs.map((m) => m.group(1)), ['method', 'path', 'model', 'status', 'verdict']);
      final model = pairs.firstWhere((m) => m.group(1) == 'model').group(2)!;
      expect(jsonDecode(model), sneaky);
      expect(line, contains('status=422'));
      expect(line, contains('verdict=truncated'));
      expect(line, contains('path=/v1/chat/completions'), reason: 'plain values stay unquoted');
    });
  });

  group('AC-7 disconnects and upstream errors', () {
    test('AC-7 client disconnect mid-stream cancels the upstream request within 2s', () async {
      final h = await Harness.start();
      addTearDown(h.close);
      h.fake.scenario
        ..streamLines = 100
        ..lineDelay = const Duration(milliseconds: 50);

      // 원시 소켓으로 요청하고, 청크 2개를 받은 뒤 연결을 닫는다.
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, h.proxy.port);
      final body = jsonEncode(userChat('hello', stream: true));
      socket.write(
        'POST /v1/chat/completions HTTP/1.1\r\n'
        'Host: 127.0.0.1\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${utf8.encode(body).length}\r\n'
        '\r\n'
        '$body',
      );
      final gotTwo = Completer<void>();
      var received = '';
      final sub = socket.listen((data) {
        received += utf8.decode(data, allowMalformed: true);
        if ('data: '.allMatches(received).length >= 2 && !gotTwo.isCompleted) gotTwo.complete();
      });
      await gotTwo.future.timeout(const Duration(seconds: 5));

      final abortSeen = h.fake.onStreamAbort.first;
      final closedAt = DateTime.now();
      await sub.cancel();
      socket.destroy();

      // 가짜 Ollama 쪽에서 프록시가 연결을 끊었음이 2초 안에 기록돼야 한다.
      final abortedAt = await abortSeen.timeout(const Duration(seconds: 2));
      expect(abortedAt.difference(closedAt).inMilliseconds, lessThan(2000));
      expect(h.fake.streamAborts, hasLength(1));

      await h.waitLogs(1);
      expect(h.logJson.single['event'], 'client_disconnected');

      // 다음 요청은 정상 처리된다.
      h.fake.scenario = FakeScenario();
      final (res, text) = await h.post('/v1/chat/completions', userChat('again'));
      expect(res.statusCode, 200);
      expect((jsonDecode(text) as Map)['object'], 'chat.completion');
    });

    test('AC-7 client disconnect on native NDJSON stream also cancels upstream', () async {
      final h = await Harness.start();
      addTearDown(h.close);
      h.fake.scenario
        ..streamLines = 100
        ..lineDelay = const Duration(milliseconds: 50);
      final req = await h.client.postUrl(h.url('/api/chat'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(userChat('hello', stream: true)));
      final res = await req.close();
      final abortSeen = h.fake.onStreamAbort.first;
      var lines = 0;
      final done = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = res.listen((chunk) {
        lines += '\n'.allMatches(utf8.decode(chunk)).length;
        if (lines >= 2 && !done.isCompleted) {
          done.complete();
          unawaited(sub.cancel()); // 응답 구독 취소 = 소켓을 닫는다.
        }
      });
      await done.future.timeout(const Duration(seconds: 5));
      await abortSeen.timeout(const Duration(seconds: 2));
      await h.waitLogs(1);
      expect(h.logJson.single['event'], 'client_disconnected');
    });

    test('AC-7 upstream down returns 502 in OpenAI error format', () async {
      final port = await deadPort();
      final h = await Harness.start(upstream: Uri.parse('http://127.0.0.1:$port'));
      addTearDown(h.close);
      final (res, text) = await h.post('/v1/chat/completions', userChat('hi'));
      expect(res.statusCode, 502);
      final err = (jsonDecode(text) as Map)['error'] as Map;
      expect(err['type'], 'api_error');
      expect(err['code'], 'upstream_unreachable');
      expect(err['message'], contains('127.0.0.1:$port'));
      // 스트리밍 요청도 헤더를 보내기 전이므로 같은 502.
      final (res2, _) = await h.post('/v1/chat/completions', userChat('hi', stream: true));
      expect(res2.statusCode, 502);
      await h.waitLogs(2);
      expect(h.logJson.map((l) => l['event']), everyElement('upstream_error'));
    });

    test('AC-7 upstream 404 (unknown model) keeps the status with an OpenAI error body', () async {
      final h = await Harness.start();
      addTearDown(h.close);
      for (final stream in [false, true]) {
        final (res, text) = await h.post('/v1/chat/completions', userChat('hi', stream: stream, model: 'nope:1b'));
        expect(res.statusCode, 404);
        final err = (jsonDecode(text) as Map)['error'] as Map;
        expect(err['type'], 'not_found_error');
        expect(err['message'], contains('not found'));
      }
    });

    test('AC-7 upstream 500 mid-request keeps status and uses OpenAI error type api_error', () async {
      final h = await Harness.start();
      addTearDown(h.close);
      h.fake.scenario.errorStatus = 500;
      final (res, text) = await h.post('/v1/chat/completions', userChat('hi'));
      expect(res.statusCode, 500);
      expect(((jsonDecode(text) as Map)['error'] as Map)['message'], 'mock failure');
    });

    test('AC-7 close() releases the port and in-flight upstream requests', () async {
      final h = await Harness.start();
      h.fake.scenario
        ..streamLines = 100
        ..lineDelay = const Duration(milliseconds: 50);
      final req = await h.client.postUrl(h.url('/v1/chat/completions'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(userChat('x', stream: true)));
      final res = await req.close();
      final abortSeen = h.fake.onStreamAbort.first;
      final first = Completer<void>();
      res.listen((_) {
        if (!first.isCompleted) first.complete();
      }, onError: (Object _) {});
      await first.future.timeout(const Duration(seconds: 5));
      final port = h.proxy.port;
      await h.proxy.close(); // 진행 중인 스트림이 있어도 닫힌다.
      await abortSeen.timeout(const Duration(seconds: 2));
      // 같은 포트에 다시 바인딩할 수 있다 = 리스너가 해제됐다.
      final again = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await again.close();
      h.client.close(force: true);
      await h.fake.close();
    });
  });
}
