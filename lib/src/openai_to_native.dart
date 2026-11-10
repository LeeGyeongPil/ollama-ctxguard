// OpenAI `/v1/chat/completions` 요청 → Ollama 네이티브 `/api/chat` 본문.
//
// 핵심: Ollama 의 /v1 경로는 num_ctx 를 어디에 넣어도 버리지만, /api/chat 은
// `options.num_ctx` 를 적용한다. 그래서 같은 요청을 네이티브 모양으로 바꿔 보낸다.
// 필드 매핑은 Ollama `openai/openai.go` 의 FromChatRequest 를 따른다.

import 'dart:convert';

import 'errors.dart';
import 'truncation.dart';

/// 변환 결과와, 응답을 다시 OpenAI 모양으로 바꿀 때·판정할 때 필요한 값.
class TranslatedChat {
  TranslatedChat({
    required this.model,
    required this.body,
    required this.stream,
    required this.includeUsage,
    required this.estPromptTokens,
    this.maxTokens,
  });

  final String model;

  /// `/api/chat` 으로 보낼 본문.
  final Map<String, Object?> body;
  final bool stream;

  /// `stream_options.include_usage` — true 일 때만 usage 청크를 보낸다(OpenAI 규약).
  final bool includeUsage;

  /// 메시지 텍스트 + 도구 정의 JSON 의 UTF-8 바이트 기반 추정 입력 토큰.
  final int estPromptTokens;
  final int? maxTokens;
}

/// [req] 를 변환한다. [numCtx] 가 null 이면 num_ctx 를 보내지 않는다(서버 기본값).
TranslatedChat openAiToNative(
  Map<String, Object?> req, {
  int? numCtx,
  TruncationSettings settings = const TruncationSettings(),
}) {
  final model = req['model'];
  if (model is! String || model.isEmpty) {
    throw RequestFormatException('"model" is required');
  }
  final rawMessages = req['messages'];
  if (rawMessages is! List || rawMessages.isEmpty) {
    throw RequestFormatException('"messages" must be a non-empty array');
  }

  final textsForEstimate = <String>[];
  final messages = <Map<String, Object?>>[];
  // tool 메시지의 tool_name 을 찾기 위해 앞선 assistant tool_calls 의 id → 이름을 기억한다.
  final toolNameById = <String, String>{};

  for (final m in rawMessages) {
    if (m is! Map) throw RequestFormatException('each message must be an object');
    final role = m['role'];
    if (role is! String) throw RequestFormatException('message "role" must be a string');

    final out = <String, Object?>{'role': role};
    final (text, images) = _content(m['content']);
    out['content'] = text;
    textsForEstimate.add(text);
    if (images.isNotEmpty) out['images'] = images;

    // OpenAI 확장(reasoning / reasoning_content) → 네이티브 thinking.
    final reasoning = m['reasoning'] ?? m['reasoning_content'];
    if (reasoning is String && reasoning.isNotEmpty) out['thinking'] = reasoning;

    final toolCalls = m['tool_calls'];
    if (toolCalls is List && toolCalls.isNotEmpty) {
      out['tool_calls'] = [for (final (i, tc) in toolCalls.indexed) _toolCallToNative(tc, i, toolNameById)];
      textsForEstimate.add(jsonEncode(toolCalls));
    }

    if (role == 'tool') {
      final id = m['tool_call_id'];
      if (id is String) {
        out['tool_call_id'] = id;
        final name = m['name'] ?? toolNameById[id];
        if (name is String) out['tool_name'] = name;
      } else if (m['name'] is String) {
        out['tool_name'] = m['name'];
      }
    }
    messages.add(out);
  }

  final options = <String, Object?>{};
  if (numCtx != null) options['num_ctx'] = numCtx; // ← 이 한 줄이 프록시의 존재 이유.

  // max_completion_tokens 가 새 이름, max_tokens 가 옛 이름. 둘 다 num_predict 로.
  final maxTokens = _intOrNull(req['max_completion_tokens'] ?? req['max_tokens'], 'max_tokens');
  if (maxTokens != null) options['num_predict'] = maxTokens;

  final stop = req['stop'];
  if (stop is String) {
    options['stop'] = [stop];
  } else if (stop is List) {
    options['stop'] = [
      for (final s in stop)
        if (s is String) s,
    ];
  }
  for (final key in ['temperature', 'top_p', 'frequency_penalty', 'presence_penalty']) {
    final v = req[key];
    if (v == null) continue;
    if (v is! num) throw RequestFormatException('"$key" must be a number');
    options[key] = v;
  }
  final seed = _intOrNull(req['seed'], 'seed');
  if (seed != null) options['seed'] = seed;

  final stream = req['stream'] == true;
  final body = <String, Object?>{
    'model': model,
    'messages': messages,
    'stream': stream,
    if (options.isNotEmpty) 'options': options,
  };

  final tools = req['tools'];
  if (tools is List && tools.isNotEmpty) {
    body['tools'] = tools; // OpenAI 와 네이티브의 도구 정의 모양이 같다.
    textsForEstimate.add(jsonEncode(tools));
  }

  final format = _format(req['response_format']);
  if (format != null) body['format'] = format;

  final think = _think(req);
  if (think != null) body['think'] = think;

  final streamOptions = req['stream_options'];
  final includeUsage = streamOptions is Map && streamOptions['include_usage'] == true;

  return TranslatedChat(
    model: model,
    body: body,
    stream: stream,
    includeUsage: includeUsage,
    estPromptTokens: estimateTokens(textsForEstimate, settings),
    maxTokens: maxTokens,
  );
}

/// content: 문자열, 또는 `[{type:text}, {type:image_url}]` 배열.
(String, List<String>) _content(Object? content) {
  if (content == null) return ('', const []);
  if (content is String) return (content, const []);
  if (content is! List) throw RequestFormatException('message "content" must be a string or an array');
  final texts = <String>[];
  final images = <String>[];
  for (final part in content) {
    if (part is! Map) continue;
    switch (part['type']) {
      case 'text':
        final t = part['text'];
        if (t is String) texts.add(t);
      case 'image_url':
        final iu = part['image_url'];
        final url = iu is Map ? iu['url'] : iu;
        if (url is! String) throw RequestFormatException('image_url.url must be a string');
        images.add(_dataUrlImage(url));
      default:
        throw RequestFormatException('unsupported content part type "${part['type']}"');
    }
  }
  return (texts.join('\n'), images);
}

/// data URL(`data:image/png;base64,...`)만 받는다. 원격 URL 내려받기는 하지 않는다.
String _dataUrlImage(String url) {
  if (!url.startsWith('data:')) {
    throw RequestFormatException('only data: URLs are supported for images (remote image URLs are not fetched)');
  }
  final comma = url.indexOf(',');
  if (comma < 0 || !url.substring(0, comma).endsWith(';base64')) {
    throw RequestFormatException('image data URL must be base64 encoded');
  }
  return url.substring(comma + 1);
}

/// OpenAI tool_call(arguments = JSON 문자열) → 네이티브(arguments = 객체).
Map<String, Object?> _toolCallToNative(Object? tc, int index, Map<String, String> names) {
  if (tc is! Map || tc['function'] is! Map) {
    throw RequestFormatException('tool_calls[] must have a "function" object');
  }
  final fn = tc['function'] as Map;
  final name = fn['name'];
  if (name is! String) throw RequestFormatException('tool_calls[].function.name must be a string');
  final rawArgs = fn['arguments'];
  Object? args;
  if (rawArgs is String) {
    try {
      args = rawArgs.trim().isEmpty ? <String, Object?>{} : jsonDecode(rawArgs);
    } on FormatException {
      throw RequestFormatException('tool_calls[].function.arguments is not valid JSON');
    }
  } else {
    args = rawArgs ?? <String, Object?>{};
  }
  final id = tc['id'];
  if (id is String) names[id] = name;
  return {
    if (id is String) 'id': id,
    'function': {'index': index, 'name': name, 'arguments': args},
  };
}

/// response_format → format. json_object 는 "json", json_schema 는 스키마 객체.
Object? _format(Object? rf) {
  if (rf is! Map) return null;
  switch (rf['type']) {
    case 'json_object':
      return 'json';
    case 'json_schema':
      final js = rf['json_schema'];
      if (js is Map && js['schema'] != null) return js['schema'];
      throw RequestFormatException('response_format.json_schema.schema is required');
    default:
      return null; // "text" 등은 기본 동작.
  }
}

/// reasoning(객체) 가 reasoning_effort 보다 우선. none → false, 나머지는 단계 문자열.
Object? _think(Map<String, Object?> req) {
  Object? effort;
  final reasoning = req['reasoning'];
  if (reasoning is Map && reasoning['effort'] is String) {
    effort = reasoning['effort'];
  } else if (req['reasoning_effort'] is String) {
    effort = req['reasoning_effort'];
  }
  if (effort == null) return null;
  return switch (effort) {
    'none' => false,
    'low' || 'medium' || 'high' => effort,
    _ => throw RequestFormatException('reasoning_effort must be none, low, medium or high'),
  };
}

int? _intOrNull(Object? v, String name) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double && v == v.roundToDouble()) return v.toInt();
  throw RequestFormatException('"$name" must be an integer');
}
