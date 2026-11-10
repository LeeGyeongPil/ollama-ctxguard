// 네이티브 /api/chat·/api/generate 통과(+ 빈 num_ctx 채우기)와 그 밖의 경로 바이트 통과.
//
// 네이티브 클라이언트는 이미 num_ctx 를 쓸 수 있으므로 본문은 거의 그대로 둔다.
// options.num_ctx 가 비어 있을 때만 설정값을 채우고, 요청이 직접 값을 주면 존중한다
// (같은 모델에 값이 섞이면 Ollama 가 매번 다시 로드하므로 로그로 알린다).

part of 'proxy_server.dart';

/// 바이트 통과 때 옮기지 않는 헤더(연결 단위 헤더와 길이·호스트).
const _hopByHop = {
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
  'host',
  'content-length',
};

/// num_ctx 가 적용되지 않는 /v1 경로(M1 에서는 변환하지 않고 통과만 한다).
const _numCtxNotApplied = {'/v1/completions', '/v1/embeddings'};

extension on ProxyServer {
  Future<void> _handleNative(HttpRequest req, Map<String, Object?> rec) async {
    final res = req.response;
    final List<int> raw;
    try {
      raw = await _readBody(req);
    } on _BodyTooLarge {
      rec['status'] = 413;
      return ProxyServer._safeRespond(
        res,
        413,
        jsonEncode({'error': 'request body is larger than $maxRequestBytes bytes'}),
      );
    }

    // JSON 이 아니면 손대지 않고 그대로 넘긴다(오류 판단은 Ollama 몫).
    Map<String, Object?>? body;
    try {
      final decoded = jsonDecode(utf8.decode(raw));
      if (decoded is Map<String, Object?>) body = decoded;
    } on FormatException {
      body = null;
    }

    var outBytes = raw;
    String? model;
    int? numCtx;
    var source = NumCtxSource.unknown;
    var est = 0;
    int? maxTokens;
    if (body != null) {
      model = body['model'] is String ? body['model'] as String : null;
      rec['model'] = model;
      rec['stream'] = body['stream'] != false; // 네이티브는 stream 기본값이 true.

      final opts = body['options'] is Map<String, Object?> ? body['options'] as Map<String, Object?> : null;
      final requested = opts?['num_ctx'];
      final configured = model != null ? config.numCtxFor(model) : null;
      if (requested is int && requested > 0) {
        // 요청이 직접 준 값은 그대로 둔다.
        numCtx = requested;
        source = NumCtxSource.request;
        if (configured != null && configured != requested) rec['event'] = 'num_ctx_request_override';
      } else if (configured != null) {
        // 비어 있을 때만 채운다.
        body['options'] = {...?opts, 'num_ctx': configured};
        numCtx = configured;
        source = NumCtxSource.config;
        outBytes = utf8.encode(jsonEncode(body));
      }
      maxTokens = opts?['num_predict'] is int ? opts!['num_predict'] as int : null;
      est = estimateTokens(_nativeTexts(req.uri.path, body), config.truncation);
      rec['est_prompt_tokens'] = est;
    }
    rec['num_ctx_source'] = source;

    final up = await _openUpstream('POST', req.uri.path, req.uri.query, rec, res);
    if (up == null) return;
    try {
      _copyClientHeaders(req, up); // Authorization·Origin
      up.headers.contentType = ContentType.json;
      up.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      up.contentLength = outBytes.length;
      up.add(outBytes);
      final upRes = await _awaitResponse(up, rec, res);
      if (upRes == null) return;

      res.statusCode = upRes.statusCode;
      rec['status'] = upRes.statusCode;
      ProxyServer._noteOriginRejected(req, upRes.statusCode, rec);
      _copyResponseHeaders(upRes, res);

      final relay = await _openRelay(res, up, contentLength: upRes.contentLength);
      Map<String, Object?>? doneLine;
      final judge = upRes.statusCode == 200 && body != null;
      final bool completed;
      try {
        completed = await relay.pump(
          upRes,
          onBytes: relay.addNow, // 줄 내용을 바꾸지 않고 바이트 그대로 중계.
          onLine: judge
              ? (line) async {
                  // 판정에는 마지막(done:true) 줄만 필요하다.
                  if (!line.contains('"done"')) return;
                  try {
                    final j = jsonDecode(line);
                    if (j is Map<String, Object?> && j['done'] == true) doneLine = j;
                  } on FormatException {
                    // 깨진 줄은 무시.
                  }
                }
              : null,
        );
      } finally {
        await _closeRelay(relay);
      }

      if (relay.clientDisconnected) {
        rec['event'] = 'client_disconnected';
        return;
      }
      if (!judge || model == null) return;

      // 요청·설정 값이 모델 최대보다 크면 Ollama 가 줄인 크기로 판정한다.
      final (effective, effSource) = await resolver.effective(model, numCtx, source);
      final done = doneLine;
      final result = judgeTruncation(
        promptEvalCount: done?['prompt_eval_count'],
        promptEvalCachedCount: done?['prompt_eval_cached_count'],
        numCtx: effective,
        estTokens: est,
        maxTokens: maxTokens,
        streamComplete: completed && done != null,
        settings: config.truncation,
      );
      // 네이티브 응답 본문은 바꾸지 않는다 — 판정은 로그로만.
      ProxyServer._recordVerdict(rec, result, effSource);
    } finally {
      _inflight.remove(up);
    }
  }

  /// 그 밖의 모든 경로: 메서드·헤더·본문을 그대로 넘기고 응답 바이트도 그대로 돌려준다.
  Future<void> _handleRaw(HttpRequest req, Map<String, Object?> rec) async {
    final res = req.response;
    final up = await _openUpstream(req.method, req.uri.path, req.uri.query, rec, res);
    if (up == null) {
      await req.drain<void>().catchError((Object _) {});
      return;
    }
    try {
      // dart:io 가 넣는 기본 헤더 대신 클라이언트가 보낸 헤더를 쓴다.
      up.headers.removeAll(HttpHeaders.acceptEncodingHeader);
      up.headers.removeAll(HttpHeaders.userAgentHeader);
      req.headers.forEach((name, values) {
        if (_hopByHop.contains(name.toLowerCase())) return;
        for (final v in values) {
          up.headers.add(name, v);
        }
      });
      if (req.contentLength >= 0) up.contentLength = req.contentLength;
      try {
        await up.addStream(req);
      } on Object {
        await _upstreamUnavailable(res, rec);
        return;
      }
      final upRes = await _awaitResponse(up, rec, res);
      if (upRes == null) return;

      res.statusCode = upRes.statusCode;
      rec['status'] = upRes.statusCode;
      ProxyServer._noteOriginRejected(req, upRes.statusCode, rec);
      _copyResponseHeaders(upRes, res);

      // 본문이 없는 응답(HEAD·204·304)은 소켓을 넘겨받지 않고 헤더만 돌려준다.
      // (`ollama` CLI 는 HEAD / 로 서버가 살아 있는지 확인한다.)
      final status = upRes.statusCode;
      if (req.method == 'HEAD' || status == 204 || status == 304) {
        if (upRes.contentLength >= 0) res.contentLength = upRes.contentLength;
        await upRes.drain<void>().catchError((Object _) {});
        await ProxyServer._safeClose(res);
        return;
      }

      final relay = await _openRelay(res, up, contentLength: upRes.contentLength);
      try {
        await relay.pump(upRes, onBytes: relay.addNow);
      } finally {
        await _closeRelay(relay);
      }
      if (relay.clientDisconnected) {
        rec['event'] = 'client_disconnected';
        return;
      }
      if (_numCtxNotApplied.contains(req.uri.path)) rec['event'] ??= 'num_ctx_not_applied';
    } finally {
      _inflight.remove(up);
    }
  }

  void _copyResponseHeaders(HttpClientResponse from, HttpResponse to) {
    from.headers.forEach((name, values) {
      if (_hopByHop.contains(name.toLowerCase())) return;
      for (final v in values) {
        to.headers.add(name, v);
      }
    });
  }
}

/// 입력 토큰 추정에 쓸 텍스트: /api/chat 은 메시지·도구, /api/generate 는 system·prompt.
List<String> _nativeTexts(String path, Map<String, Object?> body) {
  final texts = <String>[];
  if (path == '/api/generate') {
    for (final k in ['system', 'prompt', 'suffix']) {
      if (body[k] is String) texts.add(body[k] as String);
    }
    return texts;
  }
  final messages = body['messages'];
  if (messages is List) {
    for (final m in messages) {
      if (m is Map && m['content'] is String) texts.add(m['content'] as String);
    }
  }
  if (body['tools'] is List) texts.add(jsonEncode(body['tools']));
  return texts;
}
