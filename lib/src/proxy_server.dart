// 프록시 서버: 경로 라우팅, 업스트림 HttpClient 수명, /v1/chat/completions 변환.
//
// 요청 한 건의 흐름(/v1/chat/completions)
//   Host 검사(DNS 리바인딩 방어) → 본문 읽기 → 모델별 num_ctx 찾기
//   → /api/chat 본문으로 변환 → Ollama 로 전송(Authorization·Origin 은 그대로 전달)
//   → (비스트리밍) JSON 변환 + X-Ctxguard-* 헤더
//   → (스트리밍) NDJSON 줄마다 SSE 청크, 마지막 청크에 판정(ctxguard 필드)
//   → 접근 로그 한 줄(본문 없음)

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'access_log.dart';
import 'config.dart';
import 'ctx_resolver.dart';
import 'errors.dart';
import 'host_guard.dart';
import 'native_to_openai.dart';
import 'openai_to_native.dart';
import 'stream_relay.dart';
import 'truncation.dart';

part 'passthrough.dart';

/// 요청 본문 상한(이미지 data URL 을 감안해 넉넉히). 넘으면 413.
const maxRequestBytes = 64 << 20;

class ProxyServer {
  ProxyServer(this.config, {AccessLog? log})
    : log =
          log ??
          (config.logFile != null
              ? AccessLog.toFile(config.logFile!, format: config.logFormat)
              : AccessLog(format: config.logFormat)) {
    _client = HttpClient()
      // 통과 경로에서 바이트를 그대로 넘기기 위해 자동 압축 해제를 끈다.
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 15);
    resolver = CtxResolver(upstream: config.upstream, client: _client);
  }

  final CtxguardConfig config;
  final AccessLog log;
  late final HttpClient _client;
  late final CtxResolver resolver;
  HttpServer? _server;

  /// 진행 중인 업스트림 요청 — 서버를 닫을 때 모두 끊는다.
  final Set<HttpClientRequest> _inflight = {};

  /// 소켓을 넘겨받은 스트리밍 응답 — HttpServer.close 가 닫아 주지 않으므로 직접 닫는다.
  final Set<StreamRelay> _relays = {};

  /// loopback 에 바인딩했을 때만 Host 검사를 한다(Ollama 와 같은 규칙, host_guard.dart).
  bool _loopbackBind = true;

  /// 이 PC 의 인터페이스 주소 — Host 가 그 IP 면 허용(Ollama isLocalIP).
  Set<String> _localAddresses = const {};

  int get port => _server!.port;
  InternetAddress get address => _server!.address;

  /// 설정한 주소에 바인딩한다(기본 127.0.0.1:11435, 포트 0 이면 임의 포트).
  Future<void> start() async {
    final server = await HttpServer.bind(config.listenHost, config.listenPort);
    _loopbackBind = server.address.isLoopback;
    if (_loopbackBind) _localAddresses = await localInterfaceAddresses();
    // 업스트림 응답 헤더만 내보내도록 dart:io 기본 헤더(X-Frame-Options 등)를 뺀다.
    server.defaultResponseHeaders.clear();
    server.listen((req) => unawaited(_handle(req)));
    _server = server;
  }

  /// 듣기를 멈추고, 진행 중인 업스트림 요청과 연결 풀을 정리한다.
  Future<void> close() async {
    await _server?.close(force: true);
    for (final r in _inflight.toList()) {
      r.abort(const SocketException('ctxguard shutting down'));
    }
    _inflight.clear();
    for (final r in _relays.toList()) {
      r.destroy();
    }
    _relays.clear();
    _client.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    final sw = Stopwatch()..start();
    final rec = <String, Object?>{'method': req.method, 'path': req.uri.path};
    try {
      // 1) DNS 리바인딩 방어: 프록시가 Host 를 업스트림 주소로 바꾸므로 Ollama 의 Host 검사가
      //    더는 동작하지 않는다 → 같은 검사를 여기서 먼저 한다. (값은 공격자가 정하므로 로그에 남기지 않는다.)
      final hostHeader = req.headers.value(HttpHeaders.hostHeader);
      if (!isAllowedHost(hostHeader, loopbackBind: _loopbackBind, localAddresses: _localAddresses)) {
        rec['event'] = 'host_not_allowed';
        await req.drain<void>().catchError((Object _) {});
        return await _clientError(
          req.response,
          rec,
          403,
          'host not allowed: ctxguard only answers requests addressed to localhost or this machine '
          '(DNS rebinding protection, same rule as Ollama)',
          code: 'host_not_allowed',
        );
      }

      // 2) Origin(브라우저 출처)은 모든 경로에서 Ollama 에 그대로 전달해 OLLAMA_ORIGINS 검사를 받게 한다.
      final path = req.uri.path;
      if (req.method == 'POST' && path == '/v1/chat/completions') {
        await _handleChat(req, rec);
      } else if (req.method == 'POST' && (path == '/api/chat' || path == '/api/generate')) {
        await _handleNative(req, rec);
      } else {
        await _handleRaw(req, rec);
      }
    } on Object catch (e) {
      // 마지막 방어선: 예상 못 한 오류도 프로세스를 죽이지 않고 500 으로 답한다.
      rec['status'] = 500;
      rec['event'] = 'internal_error';
      await _safeRespond(
        req.response,
        500,
        openAiErrorJson('internal proxy error: ${e.runtimeType}', type: 'api_error'),
      );
    } finally {
      rec['ms'] = sw.elapsedMilliseconds;
      log.write(rec);
    }
  }

  // ---------------------------------------------------------------------------
  // /v1/chat/completions
  // ---------------------------------------------------------------------------

  Future<void> _handleChat(HttpRequest req, Map<String, Object?> rec) async {
    final res = req.response;
    final Map<String, Object?> openAiReq;
    try {
      final decoded = jsonDecode(utf8.decode(await _readBody(req)));
      if (decoded is! Map<String, Object?>) throw const FormatException('not an object');
      openAiReq = decoded;
    } on _BodyTooLarge {
      return _clientError(res, rec, 413, 'request body is larger than $maxRequestBytes bytes');
    } on FormatException {
      return _clientError(res, rec, 400, 'request body must be a JSON object');
    }

    final model = openAiReq['model'];
    if (model is String) rec['model'] = model;

    // 설정에서 모델별 num_ctx 를 찾는다. 없으면 보내지 않는다(서버 기본값 그대로).
    final configured = model is String ? config.numCtxFor(model) : null;
    final TranslatedChat chat;
    try {
      chat = openAiToNative(openAiReq, numCtx: configured, settings: config.truncation);
    } on RequestFormatException catch (e) {
      return _clientError(res, rec, 400, e.message);
    }
    rec['stream'] = chat.stream;
    rec['est_prompt_tokens'] = chat.estPromptTokens;

    final upstream = await _openUpstream('POST', '/api/chat', '', rec, res);
    if (upstream == null) return;
    try {
      _copyClientHeaders(req, upstream);
      final upRes = await _sendJson(upstream, chat.body, rec, res);
      if (upRes == null) return;
      // Ollama 가 허용한 Origin 이면 CORS 응답 헤더도 돌려줘야 로컬 웹앱이 응답을 읽을 수 있다.
      _copyCorsHeaders(upRes, res);

      if (upRes.statusCode != 200) {
        // 모델 없음(404) 등: 상태 코드는 유지하고 본문만 OpenAI 형식으로 바꾼다.
        final text = await _readCapped(upRes, 1 << 20);
        rec['status'] = upRes.statusCode;
        if (upRes.statusCode >= 500) rec['event'] = 'upstream_error';
        var message = upstreamErrorMessage(text, upRes.statusCode);
        if (_noteOriginRejected(req, upRes.statusCode, rec)) {
          message +=
              ' — Ollama rejected the browser Origin of this request; allow it with OLLAMA_ORIGINS on the Ollama server';
        }
        await _safeRespond(res, upRes.statusCode, openAiErrorJson(message, type: errorTypeForStatus(upRes.statusCode)));
        return;
      }

      if (chat.stream) {
        await _relayChatStream(req, upstream, upRes, chat, configured, rec);
      } else {
        await _respondChatJson(res, upRes, chat, configured, rec);
      }
    } finally {
      _inflight.remove(upstream);
    }
  }

  Future<void> _respondChatJson(
    HttpResponse res,
    HttpClientResponse upRes,
    TranslatedChat chat,
    int? configured,
    Map<String, Object?> rec,
  ) async {
    final Map<String, Object?> native;
    try {
      final decoded = jsonDecode(await _readCapped(upRes, maxRequestBytes));
      if (decoded is! Map<String, Object?>) throw const FormatException('not an object');
      native = decoded;
    } on FormatException {
      rec['status'] = 502;
      rec['event'] = 'upstream_error';
      return _safeRespond(
        res,
        502,
        openAiErrorJson('upstream returned a non-JSON response', type: 'api_error', code: 'upstream_bad_response'),
      );
    }

    final (numCtx, source) = await resolver.effective(chat.model, configured, NumCtxSource.config);
    final result = judgeTruncation(
      promptEvalCount: native['prompt_eval_count'],
      promptEvalCachedCount: native['prompt_eval_cached_count'],
      numCtx: numCtx,
      estTokens: chat.estPromptTokens,
      maxTokens: chat.maxTokens,
      settings: config.truncation,
    );
    _recordVerdict(rec, result, source);
    _setVerdictHeaders(res.headers, result, source);

    // --strict: 잘림이 확실할 때(truncated)만 422 로 막는다. unknown 등은 통과.
    if (config.strict && result.verdict == Verdict.truncated) {
      rec['status'] = 422;
      return _safeRespond(res, 422, jsonEncode(_truncatedError(result)));
    }

    final body = toChatCompletion(native, model: chat.model, ctxguard: _ctxguardField(result, source));
    rec['status'] = 200;
    await _safeRespond(res, 200, jsonEncode(body));
  }

  Future<void> _relayChatStream(
    HttpRequest req,
    HttpClientRequest upstream,
    HttpClientResponse upRes,
    TranslatedChat chat,
    int? configured,
    Map<String, Object?> rec,
  ) async {
    final res = req.response;
    // 헤더는 첫 바이트 전에 나간다 → 판정은 헤더가 아니라 마지막 청크로 알린다.
    res.statusCode = 200;
    res.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
    res.headers.set('Cache-Control', 'no-cache');
    if (configured != null) {
      // 설정값이 모델 최대보다 크면 Ollama 가 줄인 크기(model_max)를 알린다.
      final (numCtx, source) = await resolver.effective(chat.model, configured, NumCtxSource.config);
      res.headers.set('X-Ctxguard-Num-Ctx', '$numCtx', preserveHeaderCase: true);
      res.headers.set('X-Ctxguard-Num-Ctx-Source', source, preserveHeaderCase: true);
    }
    rec['status'] = 200;

    final relay = await _openRelay(res, upstream);
    try {
      final chunks = ChunkTranslator(model: chat.model);
      Map<String, Object?>? doneLine;
      String? upstreamError;

      // NDJSON 한 줄 = SSE 청크 0~2개. 받는 즉시 내보낸다.
      final completed = await relay.pump(
        upRes,
        onLine: (line) async {
          final Object? j;
          try {
            j = jsonDecode(line);
          } on FormatException {
            return; // 깨진 줄은 건너뛴다(판정은 done 줄로만 한다).
          }
          if (j is! Map<String, Object?>) return;
          if (j['error'] != null) {
            upstreamError = j['error'].toString();
            return;
          }
          for (final c in chunks.chunksForLine(j)) {
            await relay.writeSse(c);
          }
          if (j['done'] == true) doneLine = j;
        },
      );

      if (relay.clientDisconnected) {
        // 클라이언트가 떠났다: 업스트림은 relay 가 이미 끊었다. 기록만 남긴다.
        rec['event'] = 'client_disconnected';
        return;
      }

      if (upstreamError != null) {
        rec['event'] = 'upstream_error';
        await relay.writeSse(
          openAiError(
            upstreamErrorMessage(jsonEncode({'error': upstreamError}), 500),
            type: 'api_error',
            code: 'upstream_error',
          ),
        );
        await relay.writeNow('data: [DONE]\n\n');
        return;
      }

      // 마지막 줄(done:true)의 prompt_eval_count 로 판정한다.
      final done = doneLine;
      final streamComplete = completed && done != null;
      final (numCtx, source) = await resolver.effective(chat.model, configured, NumCtxSource.config);
      final result = judgeTruncation(
        promptEvalCount: done?['prompt_eval_count'],
        promptEvalCachedCount: done?['prompt_eval_cached_count'],
        numCtx: numCtx,
        estTokens: chat.estPromptTokens,
        maxTokens: chat.maxTokens,
        streamComplete: streamComplete,
        settings: config.truncation,
      );
      _recordVerdict(rec, result, source);
      final field = _ctxguardField(result, source);

      if (done != null && streamComplete) {
        await relay.writeSse(chunks.finishChunk(done, ctxguard: field));
        if (chat.includeUsage) await relay.writeSse(chunks.usageChunk(done));
      } else {
        await relay.writeSse(chunks.incompleteChunk(field));
      }
      // --strict 스트리밍: 이미 200 을 보냈으므로 error 청크로 알린다.
      // (OpenAI Python SDK 는 스트림 안의 "error" 키를 APIError 로 올린다.)
      if (config.strict && result.verdict == Verdict.truncated) {
        await relay.writeSse(_truncatedError(result));
      }
      await relay.writeNow('data: [DONE]\n\n');
    } finally {
      await _closeRelay(relay);
    }
  }

  /// 응답 헤더를 보내고 소켓을 넘겨받는다(끊김 감지용). 서버 종료 때 정리하도록 등록.
  Future<StreamRelay> _openRelay(HttpResponse res, HttpClientRequest upstream, {int contentLength = -1}) async {
    final relay = await StreamRelay.open(res, upstreamRequest: upstream, contentLength: contentLength);
    _relays.add(relay);
    return relay;
  }

  Future<void> _closeRelay(StreamRelay relay) async {
    await relay.finish();
    _relays.remove(relay);
  }

  // ---------------------------------------------------------------------------
  // 공용 도우미
  // ---------------------------------------------------------------------------

  /// 업스트림 요청을 연다. 연결 실패면 502 를 답하고 null.
  Future<HttpClientRequest?> _openUpstream(
    String method,
    String path,
    String query,
    Map<String, Object?> rec,
    HttpResponse res,
  ) async {
    try {
      final r = await _client.openUrl(method, upstreamUrl(config.upstream, path, query: query));
      _inflight.add(r);
      return r;
    } on Object {
      await _upstreamUnavailable(res, rec);
      return null;
    }
  }

  /// JSON 본문을 보내고 응답 헤더를 기다린다. 실패하면 502/504 를 답하고 null.
  Future<HttpClientResponse?> _sendJson(
    HttpClientRequest up,
    Map<String, Object?> body,
    Map<String, Object?> rec,
    HttpResponse res,
  ) async {
    final bytes = utf8.encode(jsonEncode(body));
    up.headers.contentType = ContentType.json;
    // 변환·검사를 위해 압축되지 않은 응답을 받는다.
    up.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    up.contentLength = bytes.length;
    up.add(bytes);
    return _awaitResponse(up, rec, res);
  }

  Future<HttpClientResponse?> _awaitResponse(HttpClientRequest up, Map<String, Object?> rec, HttpResponse res) async {
    try {
      // 모델 첫 로드는 수십 초 걸릴 수 있다 → 기본 600초로 넉넉히 기다린다.
      return await up.close().timeout(config.upstreamTimeout);
    } on TimeoutException {
      up.abort();
      rec['status'] = 504;
      rec['event'] = 'upstream_timeout';
      await _safeRespond(
        res,
        504,
        openAiErrorJson(
          'upstream Ollama did not answer within ${config.upstreamTimeout.inSeconds}s',
          type: 'api_error',
          code: 'upstream_timeout',
        ),
      );
      return null;
    } on Object {
      await _upstreamUnavailable(res, rec);
      return null;
    }
  }

  Future<void> _upstreamUnavailable(HttpResponse res, Map<String, Object?> rec) async {
    rec['status'] = 502;
    rec['event'] = 'upstream_error';
    await _safeRespond(
      res,
      502,
      openAiErrorJson(
        'cannot reach upstream Ollama at ${config.upstream} — is it running?',
        type: 'api_error',
        code: 'upstream_unreachable',
      ),
    );
  }

  /// 변환·네이티브 경로에서 클라이언트 헤더 중 업스트림에 꼭 가야 하는 것만 옮긴다.
  ///  - Authorization: 인증 프록시 뒤의 Ollama 를 위해 그대로 전달(로그에는 절대 남기지 않음).
  ///  - Origin: Ollama 의 CORS 검사(OLLAMA_ORIGINS)가 프록시 뒤에서도 그대로 적용되게 한다.
  ///    빠뜨리면 다른 사이트의 페이지가 ctxguard 를 거쳐 로컬 모델을 부를 수 있다.
  /// (바이트 통과 경로 _handleRaw 는 모든 종단 간 헤더를 옮기므로 Origin 도 이미 간다.)
  void _copyClientHeaders(HttpRequest req, HttpClientRequest up) {
    for (final name in const [HttpHeaders.authorizationHeader, 'origin']) {
      final value = req.headers.value(name);
      if (value != null) up.headers.set(name, value);
    }
  }

  /// Origin 이 있는 요청에 업스트림이 403 이면 CORS 거부로 보고 로그 event 로 남긴다.
  /// (Origin 값은 페이지가 정하므로 로그에 쓰지 않는다.)
  static bool _noteOriginRejected(HttpRequest req, int status, Map<String, Object?> rec) {
    if (status != HttpStatus.forbidden || req.headers.value('origin') == null) return false;
    rec['event'] = 'origin_rejected';
    return true;
  }

  /// 업스트림 CORS 응답 헤더(Access-Control-*·Vary)를 변환 응답에도 붙인다.
  static void _copyCorsHeaders(HttpClientResponse from, HttpResponse to) {
    from.headers.forEach((name, values) {
      final n = name.toLowerCase();
      if (!n.startsWith('access-control-') && n != 'vary') return;
      for (final v in values) {
        to.headers.add(name, v);
      }
    });
  }

  Future<void> _clientError(HttpResponse res, Map<String, Object?> rec, int status, String message, {String? code}) {
    rec['status'] = status;
    return _safeRespond(res, status, openAiErrorJson(message, type: errorTypeForStatus(status), code: code));
  }

  Future<List<int>> _readBody(HttpRequest req) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in req) {
      builder.add(chunk);
      if (builder.length > maxRequestBytes) throw _BodyTooLarge();
    }
    return builder.takeBytes();
  }

  Future<String> _readCapped(Stream<List<int>> body, int maxBytes) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in body) {
      builder.add(chunk);
      if (builder.length > maxBytes) throw const FormatException('response too large');
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  static void _recordVerdict(Map<String, Object?> rec, TruncationResult r, String source) {
    rec['num_ctx'] = r.numCtx;
    rec['num_ctx_source'] = source;
    rec['prompt_tokens'] = r.promptTokens;
    rec['est_prompt_tokens'] = r.estTokens;
    rec['verdict'] = r.verdict.wireName;
    rec['reason'] = r.reason;
    // 판정이 ok 가 아니면 경고 줄로 표시한다(요청당 한 줄).
    if (r.verdict.isWarning) rec['event'] ??= 'ctx_warning';
  }

  static void _setVerdictHeaders(HttpHeaders h, TruncationResult r, String source) {
    void set(String name, String value) => h.set(name, value, preserveHeaderCase: true);
    set('X-Ctxguard-Verdict', r.verdict.wireName);
    if (r.reason != null) set('X-Ctxguard-Reason', r.reason!);
    set('X-Ctxguard-Num-Ctx', r.numCtx?.toString() ?? 'unknown');
    set('X-Ctxguard-Num-Ctx-Source', source);
    set('X-Ctxguard-Prompt-Tokens', r.promptTokens?.toString() ?? 'unknown');
    set('X-Ctxguard-Est-Prompt-Tokens', '${r.estTokens}');
  }

  static Map<String, Object?> _ctxguardField(TruncationResult r, String source) => {
    ...r.toJson(),
    'num_ctx_source': source,
  };

  static Map<String, Object?> _truncatedError(TruncationResult r) => openAiError(
    'prompt appears truncated by the Ollama context window '
    '(num_ctx=${r.numCtx}, prompt_tokens=${r.promptTokens}, est_prompt_tokens=${r.estTokens}). '
    'Raise num_ctx for this model in ctxguard.yaml.',
    type: 'context_truncated',
    code: 'ctxguard_truncated',
  );

  /// 응답을 한 번에 쓰고 닫는다. 클라이언트가 이미 떠났으면 조용히 넘어간다.
  /// (끊긴 연결에서는 close() 가 끝나지 않을 수 있어 시간 제한을 둔다.)
  static Future<void> _safeRespond(HttpResponse res, int status, String jsonBody) async {
    try {
      final bytes = utf8.encode(jsonBody);
      res.statusCode = status;
      // dart:io 는 422 의 사유 문구를 모른다("Status 422") → 표준 문구를 넣는다.
      if (status == 422) res.reasonPhrase = 'Unprocessable Entity';
      res.headers.contentType = ContentType.json;
      res.contentLength = bytes.length;
      res.add(bytes);
    } on Object {
      // 헤더를 이미 보낸 경우 — 닫기만 한다.
    }
    await _safeClose(res);
  }

  static Future<void> _safeClose(HttpResponse res) async {
    try {
      await res.close().timeout(const Duration(seconds: 30));
    } on Object {
      // 연결이 이미 끊겼다.
    }
  }
}

class _BodyTooLarge implements Exception {}
