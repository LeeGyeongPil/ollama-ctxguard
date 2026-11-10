// Ollama 네이티브 응답(JSON 한 개 / NDJSON 줄) → OpenAI `chat.completion` /
// `chat.completion.chunk`. 모양은 Ollama 가 /v1 에서 직접 돌려주는 것과 맞춘다
// (`openai/openai.go` 의 ToChatCompletion · toChunk · FinishChunk · ToUsage).

import 'dart:convert';
import 'dart:math';

final _rand = Random();

String newCompletionId() => 'chatcmpl-${_rand.nextInt(1 << 31)}';
String _newToolCallId() => 'call_${_rand.nextInt(1 << 31).toRadixString(36)}';
int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// 네이티브 tool_calls(arguments 객체) → OpenAI tool_calls(arguments JSON 문자열).
List<Map<String, Object?>> toOpenAiToolCalls(List<Object?> nativeCalls, {int startIndex = 0}) => [
  for (final (i, tc) in nativeCalls.indexed)
    if (tc is Map && tc['function'] is Map)
      {
        'id': tc['id'] is String ? tc['id'] : _newToolCallId(),
        'index': startIndex + i,
        'type': 'function',
        'function': {
          'name': (tc['function'] as Map)['name'],
          'arguments': jsonEncode((tc['function'] as Map)['arguments'] ?? <String, Object?>{}),
        },
      },
];

/// 최종 줄의 지표 → OpenAI usage. 정수가 아니면 0 으로 둔다(판정은 따로 unknown 처리).
Map<String, Object?> toUsage(Map<String, Object?> done) {
  final p = done['prompt_eval_count'] is int ? done['prompt_eval_count'] as int : 0;
  final c = done['eval_count'] is int ? done['eval_count'] as int : 0;
  final cached = done['prompt_eval_cached_count'];
  return {
    'prompt_tokens': p,
    'completion_tokens': c,
    'total_tokens': p + c,
    if (cached is int) 'prompt_tokens_details': {'cached_tokens': cached},
  };
}

/// 비스트리밍 응답 변환. [ctxguard] 는 판정 결과(확장 필드)다.
Map<String, Object?> toChatCompletion(
  Map<String, Object?> native, {
  required String model,
  Map<String, Object?>? ctxguard,
}) {
  final msg = native['message'] is Map ? native['message'] as Map : const <String, Object?>{};
  final toolCalls = msg['tool_calls'] is List
      ? toOpenAiToolCalls(msg['tool_calls'] as List)
      : const <Map<String, Object?>>[];
  final message = <String, Object?>{
    'role': msg['role'] ?? 'assistant',
    'content': msg['content'] ?? '',
    if (msg['thinking'] is String && (msg['thinking'] as String).isNotEmpty) 'reasoning': msg['thinking'],
    if (toolCalls.isNotEmpty) 'tool_calls': toolCalls,
  };
  return {
    'id': newCompletionId(),
    'object': 'chat.completion',
    'created': _nowSeconds(),
    'model': model,
    'system_fingerprint': 'fp_ollama',
    'choices': [
      {'index': 0, 'message': message, 'finish_reason': _finishReason(native['done_reason'], toolCalls.isNotEmpty)},
    ],
    'usage': toUsage(native),
    if (ctxguard != null) 'ctxguard': ctxguard,
  };
}

/// done_reason 이 없으면 stop, 도구 호출을 보냈으면 stop → tool_calls.
String _finishReason(Object? doneReason, bool toolCalls) {
  final reason = doneReason is String && doneReason.isNotEmpty ? doneReason : 'stop';
  if (reason == 'stop' && toolCalls) return 'tool_calls';
  return reason;
}

/// 스트림 한 건의 청크 변환기. 줄마다 [chunksForLine], 마지막에 [finishChunk].
class ChunkTranslator {
  ChunkTranslator({required this.model});

  final String model;
  final String id = newCompletionId();
  final int created = _nowSeconds();
  bool _toolCallSent = false;
  int _toolCallCount = 0;

  Map<String, Object?> _chunk(List<Object?> choices) => {
    'id': id,
    'object': 'chat.completion.chunk',
    'created': created,
    'model': model,
    'system_fingerprint': 'fp_ollama',
    'choices': choices,
  };

  Map<String, Object?> _delta(Map<String, Object?> delta) => _chunk([
    {'index': 0, 'delta': delta, 'finish_reason': null},
  ]);

  /// NDJSON 한 줄 → 0개 이상의 청크. thinking 과 content 가 함께 오면 두 청크로 나눈다.
  List<Map<String, Object?>> chunksForLine(Map<String, Object?> line) {
    final msg = line['message'] is Map ? line['message'] as Map : const <String, Object?>{};
    final out = <Map<String, Object?>>[];
    final thinking = msg['thinking'];
    if (thinking is String && thinking.isNotEmpty) {
      out.add(_delta({'role': 'assistant', 'content': '', 'reasoning': thinking}));
    }
    final content = msg['content'];
    final calls = msg['tool_calls'];
    final hasCalls = calls is List && calls.isNotEmpty;
    if ((content is String && content.isNotEmpty) || hasCalls) {
      final delta = <String, Object?>{'role': 'assistant', 'content': content ?? ''};
      if (hasCalls) {
        delta['tool_calls'] = toOpenAiToolCalls(calls, startIndex: _toolCallCount);
        _toolCallCount += calls.length;
        _toolCallSent = true;
      }
      out.add(_delta(delta));
    }
    return out;
  }

  /// 마지막 청크: 빈 delta + finish_reason (+ 판정 확장 필드).
  Map<String, Object?> finishChunk(Map<String, Object?> doneLine, {Map<String, Object?>? ctxguard}) {
    final c = _chunk([
      {
        'index': 0,
        'delta': <String, Object?>{},
        'finish_reason': _finishReason(doneLine['done_reason'], _toolCallSent),
      },
    ]);
    if (ctxguard != null) c['ctxguard'] = ctxguard;
    return c;
  }

  /// include_usage 일 때만 보내는 usage 청크(choices 는 빈 배열 — OpenAI 규약).
  Map<String, Object?> usageChunk(Map<String, Object?> doneLine) {
    final c = _chunk(const []);
    c['usage'] = toUsage(doneLine);
    return c;
  }

  /// done:true 없이 끝난 스트림: 판정 정보만 담은 청크.
  Map<String, Object?> incompleteChunk(Map<String, Object?> ctxguard) {
    final c = _chunk(const []);
    c['ctxguard'] = ctxguard;
    return c;
  }
}
