// 테스트 공용: 가짜 Ollama + 프록시를 임의 포트로 띄우고, 요청·로그를 다루는 도우미.
// 실제 Ollama·네트워크 없이 127.0.0.1 안에서만 돈다.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ollama_ctxguard/ollama_ctxguard.dart';

class Harness {
  Harness._(this.fake, this.proxy, this.logs);

  final FakeOllama fake;
  final ProxyServer proxy;

  /// 프록시가 쓴 접근 로그 줄(원문 그대로).
  final List<String> logs;
  final HttpClient client = HttpClient();

  static Future<Harness> start({
    Map<String, int> models = const {'qwen3:*': 16384},
    bool strict = false,
    FakeOllama? fake,
    Uri? upstream,
    LogFormat logFormat = LogFormat.json,
    String upstreamPath = '',
  }) async {
    final f = fake ?? FakeOllama();
    await f.start();
    final logs = <String>[];
    // upstreamPath: 역프록시 뒤 Ollama 처럼 업스트림 주소에 경로 접두를 붙인다.
    final up = upstream ?? (upstreamPath.isEmpty ? f.uri : f.uri.replace(path: upstreamPath));
    final proxy = ProxyServer(
      CtxguardConfig(upstream: up, listenPort: 0, models: models, strict: strict, logFormat: logFormat),
      log: AccessLog(format: logFormat, sink: logs.add),
    );
    await proxy.start();
    return Harness._(f, proxy, logs);
  }

  Uri url(String path) => Uri.parse('http://127.0.0.1:${proxy.port}$path');

  List<Map<String, Object?>> get logJson => [for (final l in logs) jsonDecode(l) as Map<String, Object?>];

  /// 비동기로 쓰이는 로그 줄을 [count] 개가 될 때까지 기다린다.
  Future<void> waitLogs(int count, {Duration timeout = const Duration(seconds: 3)}) async {
    final end = DateTime.now().add(timeout);
    while (logs.length < count && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<(HttpClientResponse, String)> post(
    String path,
    Object body, {
    Map<String, String> headers = const {},
    HttpClient? using,
  }) async {
    final req = await (using ?? client).postUrl(url(path));
    req.headers.contentType = ContentType.json;
    headers.forEach(req.headers.set);
    req.write(body is String ? body : jsonEncode(body));
    final res = await req.close();
    return (res, await utf8.decoder.bind(res).join());
  }

  Future<(HttpClientResponse, List<int>)> getBytes(String path, {Uri? base}) async {
    final req = await client.getUrl(base == null ? url(path) : base.resolve(path));
    final res = await req.close();
    final bytes = <int>[];
    await for (final c in res) {
      bytes.addAll(c);
    }
    return (res, bytes);
  }

  /// 원시 소켓으로 요청을 보낸다 — `Host`·`Origin` 같은 헤더를 브라우저처럼 마음대로 정할 수 있다.
  /// [host] 가 null 이면 `127.0.0.1:<프록시 포트>`.
  Future<RawResponse> raw(
    String method,
    String path, {
    String? host,
    Map<String, String> headers = const {},
    String? body,
  }) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, proxy.port);
    final bytes = body == null ? const <int>[] : utf8.encode(body);
    final head = StringBuffer()
      ..write('$method $path HTTP/1.1\r\n')
      ..write('Host: ${host ?? '127.0.0.1:${proxy.port}'}\r\n')
      ..write('Connection: close\r\n');
    headers.forEach((k, v) => head.write('$k: $v\r\n'));
    if (body != null) head.write('Content-Length: ${bytes.length}\r\n');
    head.write('\r\n');
    socket.add(utf8.encode(head.toString()));
    socket.add(bytes);
    await socket.flush();
    final received = <int>[];
    await socket.listen(received.addAll).asFuture<void>().timeout(const Duration(seconds: 10));
    socket.destroy();
    return RawResponse.parse(utf8.decode(received, allowMalformed: true));
  }

  Future<void> close() async {
    client.close(force: true);
    await proxy.close();
    await fake.close();
  }
}

/// 원시 HTTP 응답(상태 코드·소문자 헤더·본문 문자열).
class RawResponse {
  RawResponse(this.status, this.headers, this.body);

  factory RawResponse.parse(String text) {
    final split = text.indexOf('\r\n\r\n');
    final head = split < 0 ? text : text.substring(0, split);
    final lines = head.split('\r\n');
    final status = int.parse(lines.first.split(' ')[1]);
    final headers = <String, String>{};
    for (final l in lines.skip(1)) {
      final i = l.indexOf(':');
      if (i > 0) headers[l.substring(0, i).trim().toLowerCase()] = l.substring(i + 1).trim();
    }
    return RawResponse(status, headers, split < 0 ? '' : text.substring(split + 4));
  }

  final int status;
  final Map<String, String> headers;
  final String body;
}

/// SSE 본문 → `data:` 값 목록(`[DONE]` 포함).
List<String> sseData(String body) => [
  for (final block in body.split('\n\n'))
    if (block.startsWith('data: ')) block.substring(6),
];

/// SSE 본문 → JSON 청크들(`[DONE]` 제외).
List<Map<String, Object?>> sseChunks(String body) => [
  for (final d in sseData(body))
    if (d != '[DONE]') jsonDecode(d) as Map<String, Object?>,
];

Map<String, Object?> userChat(String content, {bool stream = false, String model = 'qwen3:4b'}) => {
  'model': model,
  'stream': stream,
  'messages': [
    {'role': 'user', 'content': content},
  ],
};

/// 단어 [n] 개짜리 긴 텍스트(가짜 토크나이저 기준 대략 n 토큰).
String words(int n) => List.filled(n, 'lorem').join(' ');

/// 아무도 듣지 않는 로컬 포트(업스트림 꺼짐 시험용).
Future<int> deadPort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final p = s.port;
  await s.close();
  return p;
}
