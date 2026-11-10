// 잘림 판정 규칙 — 순수 함수만 둔다(네트워크·파일 없음).
//
// 근거(Ollama 0.40.15 실측): 프롬프트가 num_ctx 보다 길면 러너가 앞쪽 keep(4)
// 토큰만 남기고 나머지 앞부분을 버린 뒤 "num_ctx - (num_ctx - keep) ~/ 2" 토큰만
// 평가한다(2048 -> 1026, 4096 -> 2050). 그래서 잘린 응답의 prompt_eval_count 는
// num_ctx 근처가 아니라 대략 num_ctx 의 절반에 떨어진다. 이것을 "서명"으로 쓴다.

import 'dart:convert';

/// 판정 5단계. [wireName] 이 헤더·로그·JSON 에 쓰는 이름이다.
enum Verdict {
  ok('ok'),
  nearLimit('near_limit'),
  suspect('suspect'),
  truncated('truncated'),
  unknown('unknown');

  const Verdict(this.wireName);
  final String wireName;

  /// 사용자에게 경고할 만한 판정인지(ok 만 조용하다).
  bool get isWarning => this != Verdict.ok;
}

/// 판정 사유 코드. unknown 의 사유는 "판정 불가"의 이유다.
abstract final class Reason {
  static const noPromptEvalCount = 'no_prompt_eval_count';
  static const invalidPromptEvalCount = 'invalid_prompt_eval_count';
  static const exceedsNumCtx = 'exceeds_num_ctx';
  static const numCtxUnknown = 'num_ctx_unknown';
  static const streamIncomplete = 'stream_incomplete';
  static const contextShiftSignature = 'context_shift_signature';
  static const signatureOnly = 'signature_only';
  static const lowGenerationRoom = 'low_generation_room';
}

/// 판정에 쓰는 조정값(설정 파일 `truncation:` 에서 바꿀 수 있다).
class TruncationSettings {
  const TruncationSettings({this.keepSlack = 8, this.bytesPerToken = 6, this.ratio = 1.2, this.reserve = 512});

  /// 서명 구간의 폭: [num_ctx ~/ 2, num_ctx ~/ 2 + keepSlack].
  final int keepSlack;

  /// 입력 토큰 추정에 쓰는 "UTF-8 바이트 / 토큰" 값(보수적으로 크게 잡는다).
  final double bytesPerToken;

  /// 추정 입력 토큰이 평가 토큰의 몇 배 이상이면 "실제로 넘쳤다"고 볼지.
  final double ratio;

  /// 요청에 max_tokens 가 없을 때 생성용으로 남겨 둘 토큰 수.
  final int reserve;
}

/// 판정 결과. [toJson] 은 스트리밍 마지막 청크의 `ctxguard` 필드로 나간다.
class TruncationResult {
  const TruncationResult({required this.verdict, this.reason, this.numCtx, this.promptTokens, required this.estTokens});

  final Verdict verdict;
  final String? reason;
  final int? numCtx;
  final int? promptTokens;
  final int estTokens;

  Map<String, Object?> toJson() => {
    'verdict': verdict.wireName,
    if (reason != null) 'reason': reason,
    'num_ctx': numCtx,
    'prompt_tokens': promptTokens,
    'est_prompt_tokens': estTokens,
  };
}

/// 텍스트 조각들의 UTF-8 바이트 수로 입력 토큰 수를 추정한다.
///
/// 문자 수가 아니라 바이트 수를 쓰는 이유: 한국어처럼 비ASCII 문자는 한 글자가
/// 토큰 하나 이상이 되기 쉬워, 문자 수로 나누면 크게 과소추정한다.
int estimateTokens(Iterable<String> texts, TruncationSettings settings) {
  var bytes = 0;
  for (final t in texts) {
    bytes += utf8.encode(t).length;
  }
  return (bytes / settings.bytesPerToken).floor();
}

/// 응답 한 건의 잘림 여부를 판정한다.
///
/// [promptEvalCount]·[promptEvalCachedCount] 는 업스트림 JSON 에서 꺼낸 값을
/// 그대로 넘긴다(타입 검사도 여기서 한다). 확신할 수 없으면 언제나 `unknown`.
TruncationResult judgeTruncation({
  required Object? promptEvalCount,
  Object? promptEvalCachedCount,
  required int? numCtx,
  required int estTokens,
  int? maxTokens,
  bool streamComplete = true,
  TruncationSettings settings = const TruncationSettings(),
}) {
  TruncationResult unknown(String reason, {int? p}) =>
      TruncationResult(verdict: Verdict.unknown, reason: reason, numCtx: numCtx, promptTokens: p, estTokens: estTokens);

  // 1) 스트림이 done:true 없이 끝났으면 지표 자체가 없다.
  if (!streamComplete) return unknown(Reason.streamIncomplete);

  // 2) prompt_eval_count 검사: 없음 / 정수 아님·0 이하.
  if (promptEvalCount == null) return unknown(Reason.noPromptEvalCount);
  if (promptEvalCount is! int || promptEvalCount <= 0) {
    return unknown(Reason.invalidPromptEvalCount);
  }

  // 캐시 재사용분을 따로 세는 버전에 대비해 둘 중 큰 값을 쓴다.
  var p = promptEvalCount;
  if (promptEvalCachedCount is int && promptEvalCachedCount > p) {
    p = promptEvalCachedCount;
  }

  // 3) 실효 num_ctx 를 모르면 판정할 수 없다.
  if (numCtx == null || numCtx <= 0) {
    return unknown(Reason.numCtxUnknown, p: p);
  }

  // 4) context shift 가 있으면 p 는 num_ctx 를 넘을 수 없다 → 앞뒤가 안 맞는 값.
  if (p > numCtx) return unknown(Reason.exceedsNumCtx, p: p);

  final half = numCtx ~/ 2;
  final signature = p >= half && p <= half + settings.keepSlack;
  final overflowed = estTokens >= settings.ratio * p;
  final reserve = maxTokens ?? settings.reserve;

  TruncationResult result(Verdict v, String? reason) =>
      TruncationResult(verdict: v, reason: reason, numCtx: numCtx, promptTokens: p, estTokens: estTokens);

  // 5) 서명 + 입력이 평가량보다 확실히 많음 → 잘림.
  if (signature && overflowed) {
    return result(Verdict.truncated, Reason.contextShiftSignature);
  }
  // 6) 서명만 맞음 → 의심(우연히 절반 길이일 수도 있다).
  if (signature) return result(Verdict.suspect, Reason.signatureOnly);
  // 7) 잘리진 않았지만 생성할 자리가 모자람.
  if (p + reserve > numCtx) {
    return result(Verdict.nearLimit, Reason.lowGenerationRoom);
  }
  return result(Verdict.ok, null);
}
