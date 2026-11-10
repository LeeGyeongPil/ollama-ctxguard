// 연습용 가짜 Ollama (practice mock).
//
// 실제 모델 없이 "왜 이 프록시가 필요한가"를 그대로 재현한다. 고정된 가짜 답을
// 돌려주는 것이 아니라, 실제 Ollama 0.40.15 에서 측정한 규칙을 흉내 낸다.
//
//  1. /v1/chat/completions 는 요청의 num_ctx(최상위·options 어디든)를 무시하고
//     기본 크기(defaultCtx, 4096)로 모델을 "로드"한다 → /api/ps 가 4096 을 보고.
//  2. /api/chat·/api/generate 는 options.num_ctx 를 적용한다(모델 최대에서 자름).
//  3. 토큰화: 공백으로 나눈 단어 1개 = 토큰 1개, 메시지마다 템플릿 토큰 4개.
//  4. 프롬프트가 num_ctx 보다 길면 context shift: 앞 keep(4) 토큰 + 뒤쪽 토큰만
//     남기고 num_ctx - (num_ctx - keep) ~/ 2 개만 평가한다(실측 2048→1026, 4096→2050).
//  5. 남은 토큰 안에 "SECRET-CODE is <숫자>" 가 있으면 그 숫자로, 없으면
//     "I don't see a secret code" 로 답한다 → 앞부분이 사라진 것이 답에 드러난다.
//
// 테스트용 시나리오 스위치([FakeScenario])로 비정상 지표·도구 호출·오류·느린 스트림
// 같은 상황도 만든다.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../stream_relay.dart';

/// prompt_eval_count 를 어떻게 보고할지(판정 불가 안전장치 시험용).
enum PromptEvalMode { normal, omit, zero, negative, string, exceedsCtx }

/// 가짜 서버의 동작 스위치. 테스트마다 바꿔 쓴다.
class FakeScenario {
  PromptEvalMode promptEval = PromptEvalMode.normal;

  /// 값이 있으면 prompt_eval_cached_count 로 보고한다.
  int? cachedCount;

  /// 값이 있으면 이 이름의 도구 호출로 답한다.
  String? toolCallName;
  Map<String, Object?> toolCallArgs = const {'city': 'Seoul'};

  /// 값이 있으면 message.thinking 으로 함께 보낸다.
  String? thinking;

  /// 값이 있으면 생성 경로가 이 HTTP 상태로 오류를 낸다.
  int? errorStatus;
  String errorMessage = 'mock failure';

  /// 스트림 줄 사이 지연과 내용 줄 수(null 이면 답의 단어 수).
  Duration lineDelay = Duration.zero;
  int? streamLines;

  /// true 면 done:true 줄 없이 스트림을 끝낸다.
  bool incompleteStream = false;

  /// 값이 있으면 규칙 대신 이 답을 돌려준다.
  String? replyText;

  /// true 면 /api/ps 가 500 을 돌려준다.
  bool psFails = false;

  /// 값이 있으면 Modelfile 에 PARAMETER num_ctx 가 있는 것처럼 동작한다.
  int? modelfileNumCtx;

  /// true 면 /api/show 가 500 을 돌려준다.
  bool showFails = false;
}

/// Ollama 기본 허용 Origin(OLLAMA_ORIGINS 를 비워 둔 경우)을 흉내 낸다.
/// 출처: ollama envconfig.AllowedOrigins + server/routes.go 의 CORS 설정
/// (AllowWildcard·AllowBrowserExtensions), 2026-11-11 확인.
bool ollamaDefaultOriginAllowed(String origin) {
  final o = origin.toLowerCase();
  for (final host in const ['localhost', '127.0.0.1', '0.0.0.0']) {
    for (final scheme in const ['http', 'https']) {
      // "http://localhost" 와 "http://localhost:*"
      if (o == '$scheme://$host' || o.startsWith('$scheme://$host:')) return true;
    }
  }
  const schemes = [
    'app://',
    'file://',
    'tauri://',
    'vscode-webview://',
    'vscode-file://',
    // 브라우저 확장(AllowBrowserExtensions)
    'chrome-extension://',
    'safari-extension://',
    'moz-extension://',
    'ms-browser-extension://',
  ];
  return schemes.any(o.startsWith);
}

/// 가짜 서버가 받은 요청 기록(테스트가 "정말 무엇이 전달됐는지" 검사한다).
class ReceivedRequest {
  ReceivedRequest(this.method, this.path, this.body, this.headers);
  final String method;
  final String path;
  final Map<String, Object?>? body;
  final Map<String, String> headers;
}

class FakeOllama {
  FakeOllama({this.defaultCtx = 4096, this.modelMax = 40960, this.keep = 4, this.pathPrefix = '', List<String>? models})
    : models = models ?? const ['qwen3:4b', 'llama3.2:3b'];

  /// 역프록시 뒤 Ollama 흉내: 값이 있으면(예: "/ollama") 이 접두가 붙은 경로만 받는다.
  final String pathPrefix;

  /// 서버 기본 컨텍스트(VRAM 이 작은 PC 의 Ollama 기본값 4096 을 흉내).
  final int defaultCtx;

  /// 모델 학습 최대 길이(/api/show 의 <arch>.context_length).
  final int modelMax;
  final int keep;
  final List<String> models;

  FakeScenario scenario = FakeScenario();

  /// 지금 "로드된" 모델 → context_length (/api/ps 가 보고).
  final Map<String, int> loaded = {};

  /// 최근 받은 요청(최대 50개).
  final List<ReceivedRequest> received = [];

  /// 스트리밍 도중 상대(프록시)가 연결을 끊은 시각.
  final List<DateTime> streamAborts = [];
  final _abortController = StreamController<DateTime>.broadcast();

  /// 스트리밍 응답에서 마지막 줄을 보낸 시각(첫 청크 즉시 중계 시험용).
  DateTime? lastLineSentAt;

  HttpServer? _server;
  final Set<StreamRelay> _activeStreams = {};

  int get port => _server!.port;
  Uri get uri => Uri.parse('http://127.0.0.1:$port');

  /// 스트림 끊김이 기록되면 알린다.
  Stream<DateTime> get onStreamAbort => _abortController.stream;

  Future<void> start({int port = 0}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    _server!.listen((req) => unawaited(_handle(req)));
  }

  Future<void> close() async {
    await _server?.close(force: true);
    for (final s in _activeStreams.toList()) {
      s.destroy();
    }
    _activeStreams.clear();
    await _abortController.close();
  }

  /// 마지막으로 받은 [path] 요청의 본문.
  Map<String, Object?>? lastBody(String path) {
    for (final r in received.reversed) {
      if (r.path == path) return r.body;
    }
    return null;
  }

  // ---------------------------------------------------------------------------

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final text = await utf8.decoder.bind(req).join();
    Map<String, Object?>? body;
    if (text.isNotEmpty) {
      try {
        final j = jsonDecode(text);
        if (j is Map<String, Object?>) body = j;
      } on FormatException {
        body = null;
      }
    }
    final headers = <String, String>{};
    req.headers.forEach((k, v) => headers[k] = v.join(','));
    received.add(ReceivedRequest(req.method, req.uri.path, body, headers));
    if (received.length > 50) received.removeAt(0);

    try {
      // 실제 Ollama 처럼 CORS 검사가 먼저다: 허용되지 않은 Origin 은 처리 전에 403.
      if (!_cors(req, res)) return;

      var path = req.uri.path;
      if (pathPrefix.isNotEmpty) {
        if (!path.startsWith('$pathPrefix/')) return await _plain404(res);
        path = path.substring(pathPrefix.length);
      }
      switch ((req.method, path)) {
        case ('GET', '/') || ('HEAD', '/'):
          res.headers.contentType = ContentType.text;
          res.write('Ollama is running (practice mock)');
          return await res.close();
        case ('GET', '/api/version'):
          return _json(res, {'version': '0.0.0-practice-mock'});
        case ('GET', '/api/tags'):
          return _json(res, {
            'models': [
              for (final m in models)
                {
                  'name': m,
                  'model': m,
                  'size': 2500000000,
                  'details': {'family': m.split(':').first, 'format': 'gguf'},
                },
            ],
          });
        case ('POST', '/api/show'):
          return _show(res, body);
        case ('GET', '/api/ps'):
          if (scenario.psFails) return _json(res, {'error': 'mock /api/ps failure'}, status: 500);
          return _json(res, {
            'models': [
              for (final e in loaded.entries)
                {'name': e.key, 'model': e.key, 'context_length': e.value, 'size_vram': 0},
            ],
          });
        case ('POST', '/api/chat'):
        case ('POST', '/api/generate'):
          return _native(req, res, body);
        case ('POST', '/v1/chat/completions'):
          return _openAiDirect(res, body);
        case ('GET', '/v1/models'):
          return _json(res, {
            'object': 'list',
            'data': [
              for (final m in models) {'id': m, 'object': 'model', 'created': 0, 'owned_by': 'library'},
            ],
          });
        case ('POST', '/v1/embeddings'):
          return _json(res, {
            'object': 'list',
            'data': [
              {
                'object': 'embedding',
                'index': 0,
                'embedding': [0.1, 0.2, 0.3],
              },
            ],
            'model': body?['model'],
          });
        default:
          await _plain404(res);
      }
    } on Object {
      // 상대가 끊어 응답을 못 쓴 경우 등 — 가짜 서버는 조용히 넘어간다.
    }
  }

  Future<void> _plain404(HttpResponse res) async {
    res.statusCode = 404;
    res.headers.contentType = ContentType.text;
    res.write('404 page not found');
    await res.close();
  }

  /// gin-contrib/cors 처럼 동작한다. 응답을 이미 끝냈으면 false.
  ///  - Origin 없음, 또는 Origin 이 자기 자신(http://<Host>) → CORS 요청이 아니다.
  ///  - 허용 목록 밖 → 403(본문 없음). 허용 → Access-Control-Allow-Origin 을 붙인다.
  ///  - 허용된 OPTIONS 프리플라이트 → 204.
  bool _cors(HttpRequest req, HttpResponse res) {
    final origin = req.headers.value('origin');
    if (origin == null) return true;
    final host = req.headers.value(HttpHeaders.hostHeader);
    if (origin == 'http://$host' || origin == 'https://$host') return true;
    if (!ollamaDefaultOriginAllowed(origin)) {
      res.statusCode = HttpStatus.forbidden;
      unawaited(res.close().catchError((Object _) {}));
      return false;
    }
    res.headers
      ..set('Access-Control-Allow-Origin', origin)
      ..add('Vary', 'Origin');
    if (req.method == 'OPTIONS') {
      res.statusCode = HttpStatus.noContent;
      res.headers
        ..set('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,HEAD,OPTIONS')
        ..set('Access-Control-Allow-Headers', 'Authorization,Content-Type,User-Agent,Accept,X-Requested-With')
        ..set('Access-Control-Max-Age', '43200');
      unawaited(res.close().catchError((Object _) {}));
      return false;
    }
    return true;
  }

  Future<void> _json(HttpResponse res, Object body, {int status = 200}) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.json;
    res.write(jsonEncode(body));
    await res.close();
  }

  String? _known(Object? name) {
    if (name is! String) return null;
    final n = name.contains(':') ? name : '$name:latest';
    return models.contains(n) ? n : null;
  }

  Future<void> _notFound(HttpResponse res, Object? name) =>
      _json(res, {'error': 'model "$name" not found, try pulling it first'}, status: 404);

  Future<void> _show(HttpResponse res, Map<String, Object?>? body) async {
    if (scenario.showFails) return _json(res, {'error': 'mock /api/show failure'}, status: 500);
    final name = body?['model'] ?? body?['name'];
    final model = _known(name);
    if (model == null) return _notFound(res, name);
    final params = StringBuffer('temperature 0.6');
    if (scenario.modelfileNumCtx != null) params.write('\nnum_ctx ${scenario.modelfileNumCtx}');
    return _json(res, {
      'parameters': params.toString(),
      'model_info': {'general.architecture': 'qwen3', 'qwen3.context_length': modelMax},
      'details': {'family': 'qwen3', 'format': 'gguf'},
    });
  }

  /// 실효 num_ctx: 요청 값(네이티브만) > Modelfile > 서버 기본값, 모델 최대에서 자름.
  int _effectiveCtx(Object? requested) {
    var ctx = scenario.modelfileNumCtx ?? defaultCtx;
    if (requested is int && requested > 0) ctx = requested;
    return ctx > modelMax ? modelMax : ctx;
  }

  // ---------------------------------------------------------------------------
  // 생성 규칙(이 파일의 핵심)
  // ---------------------------------------------------------------------------

  _Generation _generate(List<(String, String)> messages, int numCtx) {
    // 3) 토큰화: 메시지마다 [<|im_start|>, 역할, 단어들..., <|im_end|>, 줄바꿈].
    final tokens = <String>[];
    for (final (role, content) in messages) {
      tokens
        ..add('<|im_start|>')
        ..add(role)
        ..addAll(content.split(RegExp(r'\s+')).where((w) => w.isNotEmpty))
        ..add('<|im_end|>')
        ..add('\n');
    }
    final n = tokens.length;

    // 4) context shift: 넘치면 앞 keep 개 + 뒤쪽만 남긴다. 오류도 표시도 없다.
    var kept = tokens;
    var evaluated = n;
    if (n > numCtx) {
      evaluated = numCtx - (numCtx - keep) ~/ 2;
      kept = [...tokens.take(keep), ...tokens.skip(n - (evaluated - keep))];
    }

    // 5) 남은 토큰에서 비밀 코드 찾기.
    String reply;
    if (scenario.replyText != null) {
      reply = scenario.replyText!;
    } else if (tokens.contains('SECRET-CODE')) {
      reply = _findSecret(kept) ?? "I don't see a secret code";
    } else {
      reply = 'Hello from the practice mock (fake Ollama). I read $evaluated prompt tokens.';
    }
    return _Generation(promptTokens: n, evaluated: evaluated, reply: reply);
  }

  static String? _findSecret(List<String> kept) {
    for (var i = 0; i + 2 < kept.length; i++) {
      if (kept[i] == 'SECRET-CODE' && kept[i + 1] == 'is') {
        final digits = kept[i + 2].replaceAll(RegExp(r'[^0-9]'), '');
        if (digits.isNotEmpty) return digits;
      }
    }
    return null;
  }

  /// 판정 불가 시험을 위해 지표를 일부러 망가뜨린다.
  Map<String, Object?> _metrics(_Generation g, int numCtx, int evalCount) {
    final m = <String, Object?>{'eval_count': evalCount};
    switch (scenario.promptEval) {
      case PromptEvalMode.normal:
        m['prompt_eval_count'] = g.evaluated;
      case PromptEvalMode.omit:
        break;
      case PromptEvalMode.zero:
        m['prompt_eval_count'] = 0;
      case PromptEvalMode.negative:
        m['prompt_eval_count'] = -5;
      case PromptEvalMode.string:
        m['prompt_eval_count'] = '${g.evaluated}';
      case PromptEvalMode.exceedsCtx:
        m['prompt_eval_count'] = numCtx + 100;
    }
    if (scenario.cachedCount != null) m['prompt_eval_cached_count'] = scenario.cachedCount;
    return m;
  }

  // ---------------------------------------------------------------------------
  // 네이티브 /api/chat · /api/generate
  // ---------------------------------------------------------------------------

  Future<void> _native(HttpRequest req, HttpResponse res, Map<String, Object?>? body) async {
    if (body == null) return _json(res, {'error': 'invalid JSON body'}, status: 400);
    final model = _known(body['model']);
    if (model == null) return _notFound(res, body['model']);
    if (scenario.errorStatus != null) {
      return _json(res, {'error': scenario.errorMessage}, status: scenario.errorStatus!);
    }

    final isChat = req.uri.path == '/api/chat';
    final opts = body['options'] is Map ? body['options'] as Map : const <String, Object?>{};
    final numCtx = _effectiveCtx(opts['num_ctx']); // 2) 네이티브는 num_ctx 를 적용한다.
    loaded[model] = numCtx;

    final messages = isChat ? _messages(body['messages']) : _generateMessages(body);
    final g = _generate(messages, numCtx);
    final stream = body['stream'] != false; // 네이티브 기본은 스트리밍.
    final textKey = isChat ? 'message' : 'response';

    Map<String, Object?> piece({String content = '', String? thinking, List<Object?>? calls}) => isChat
        ? {
            'role': 'assistant',
            'content': content,
            if (thinking != null) 'thinking': thinking,
            if (calls != null) 'tool_calls': calls,
          }
        : {'response': content};

    final calls = scenario.toolCallName == null
        ? null
        : [
            {
              'id': 'call_mock1',
              'function': {'index': 0, 'name': scenario.toolCallName, 'arguments': scenario.toolCallArgs},
            },
          ];
    final words = calls != null ? <String>[] : _streamWords(g.reply);

    Map<String, Object?> line(Map<String, Object?> p, {bool done = false}) => {
      'model': model,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      if (isChat) textKey: p else 'response': p['response'],
      'done': done,
    };

    if (!stream) {
      final p = piece(content: calls != null ? '' : g.reply, thinking: scenario.thinking, calls: calls);
      return _json(res, {
        ...line(p, done: true),
        'done_reason': 'stop',
        ..._metrics(g, numCtx, words.length),
        'total_duration': 1000000,
      });
    }

    res.headers.contentType = ContentType('application', 'x-ndjson');
    final lines = <Map<String, Object?>>[
      if (scenario.thinking != null && isChat) line(piece(thinking: scenario.thinking)),
      if (calls != null) line(piece(calls: calls)),
      for (final w in words) line(piece(content: w)),
      if (!scenario.incompleteStream)
        {...line(piece(), done: true), 'done_reason': 'stop', ..._metrics(g, numCtx, words.length)},
    ];
    await _streamLines(res, [for (final l in lines) '${jsonEncode(l)}\n']);
  }

  List<String> _streamWords(String reply) {
    final count = scenario.streamLines;
    if (count != null) return [for (var i = 0; i < count; i++) 'tok$i '];
    final words = reply.split(' ');
    return [for (var i = 0; i < words.length; i++) i == words.length - 1 ? words[i] : '${words[i]} '];
  }

  /// 줄을 하나씩 보내고 바로 내보낸다. 상대(프록시)가 연결을 끊으면 기록하고 멈춘다.
  /// 끊김을 알아채려고 프록시와 같은 방식(StreamRelay — 소켓 직접 사용)을 쓴다.
  Future<void> _streamLines(HttpResponse res, List<String> lines) async {
    final relay = await StreamRelay.open(res);
    _activeStreams.add(relay);
    unawaited(
      relay.onClientGone.then((_) {
        final now = DateTime.now();
        streamAborts.add(now);
        if (!_abortController.isClosed) _abortController.add(now);
      }),
    );
    try {
      for (final (i, l) in lines.indexed) {
        if (relay.clientDisconnected) break;
        if (i > 0 && scenario.lineDelay > Duration.zero) {
          // 지연 중에 끊겨도 바로 멈춘다.
          await Future.any([Future<void>.delayed(scenario.lineDelay), relay.onClientGone]);
        }
        if (relay.clientDisconnected) break;
        await relay.writeNow(l);
        if (i == lines.length - 1) lastLineSentAt = DateTime.now();
      }
    } finally {
      await relay.finish();
      _activeStreams.remove(relay);
    }
  }

  // ---------------------------------------------------------------------------
  // OpenAI 호환 /v1/chat/completions (직접 붙었을 때의 동작)
  // ---------------------------------------------------------------------------

  Future<void> _openAiDirect(HttpResponse res, Map<String, Object?>? body) async {
    if (body == null) return _json(res, {'error': 'invalid JSON body'}, status: 400);
    final model = _known(body['model']);
    if (model == null) return _notFound(res, body['model']);

    // 1) 핵심 결함 재현: 요청의 num_ctx 는 어디에 있든 읽지 않는다.
    final numCtx = _effectiveCtx(null);
    loaded[model] = numCtx;

    final g = _generate(_messages(body['messages']), numCtx);
    final m = _metrics(g, numCtx, _streamWords(g.reply).length);
    final p = m['prompt_eval_count'] is int ? m['prompt_eval_count'] as int : 0;
    final c = m['eval_count'] as int;
    final usage = {'prompt_tokens': p, 'completion_tokens': c, 'total_tokens': p + c};
    const id = 'chatcmpl-mock';
    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    if (body['stream'] != true) {
      return _json(res, {
        'id': id,
        'object': 'chat.completion',
        'created': created,
        'model': model,
        'system_fingerprint': 'fp_ollama',
        'choices': [
          {
            'index': 0,
            'message': {'role': 'assistant', 'content': g.reply},
            'finish_reason': 'stop',
          },
        ],
        'usage': usage,
      });
    }
    res.headers.contentType = ContentType('text', 'event-stream');
    Map<String, Object?> chunk(Map<String, Object?> delta, String? finish) => {
      'id': id,
      'object': 'chat.completion.chunk',
      'created': created,
      'model': model,
      'system_fingerprint': 'fp_ollama',
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish},
      ],
    };
    await _streamLines(res, [
      for (final w in _streamWords(g.reply))
        'data: ${jsonEncode(chunk({'role': 'assistant', 'content': w}, null))}\n\n',
      'data: ${jsonEncode(chunk({}, 'stop'))}\n\n',
      'data: [DONE]\n\n',
    ]);
  }

  /// OpenAI·네이티브 메시지 목록 → (역할, 텍스트). 텍스트 파트 배열도 이어 붙인다.
  static List<(String, String)> _messages(Object? raw) {
    if (raw is! List) return const [];
    return [
      for (final m in raw)
        if (m is Map) (m['role']?.toString() ?? 'user', _text(m['content'])),
    ];
  }

  static List<(String, String)> _generateMessages(Map<String, Object?> body) => [
    if (body['system'] is String) ('system', body['system'] as String),
    ('user', body['prompt'] is String ? body['prompt'] as String : ''),
  ];

  static String _text(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return [
        for (final p in content)
          if (p is Map && p['text'] is String) p['text'] as String,
      ].join('\n');
    }
    return '';
  }
}

class _Generation {
  _Generation({required this.promptTokens, required this.evaluated, required this.reply});

  /// 잘리기 전 전체 프롬프트 토큰 수.
  final int promptTokens;

  /// 실제로 평가된 토큰 수(= prompt_eval_count).
  final int evaluated;
  final String reply;
}
