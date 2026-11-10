import 'dart:io';

import 'package:ollama_ctxguard/ollama_ctxguard.dart';
import 'package:test/test.dart';

/// 바이트 수 → 추정 토큰(기본 6 바이트/토큰).
int est(int bytes) => estimateTokens(['x' * bytes], const TruncationSettings());

void main() {
  group('AC-3 verdict rules reproduce the measured Ollama 0.40.15 cases', () {
    test('AC-3 (2048, p=1026, long input) -> truncated', () {
      // 실측: num_ctx 2048 에 약 7048 토큰 프롬프트 → 1026 만 평가, 비밀 코드 소실.
      final r = judgeTruncation(promptEvalCount: 1026, numCtx: 2048, estTokens: est(7048 * 4));
      expect(r.verdict, Verdict.truncated);
      expect(r.reason, Reason.contextShiftSignature);
    });

    test('AC-3 (4096, p=2050, long input) -> truncated', () {
      // 실측: /v1 기본 4096 → usage.prompt_tokens 2050.
      final r = judgeTruncation(promptEvalCount: 2050, numCtx: 4096, estTokens: est(7048 * 4));
      expect(r.verdict, Verdict.truncated);
    });

    test('AC-3 (2048, p=1465, 7840 bytes) -> ok (not truncated though above num_ctx/2)', () {
      final r = judgeTruncation(promptEvalCount: 1465, numCtx: 2048, estTokens: est(7840), maxTokens: 16);
      expect(r.verdict, Verdict.ok);
      expect(r.reason, isNull);
    });

    test('AC-3 (8192, p=13) -> ok', () {
      final r = judgeTruncation(promptEvalCount: 13, numCtx: 8192, estTokens: est(60));
      expect(r.verdict, Verdict.ok);
    });

    test('AC-3 signature only (short input) -> suspect', () {
      final r = judgeTruncation(promptEvalCount: 2050, numCtx: 4096, estTokens: est(2050 * 6));
      expect(r.verdict, Verdict.suspect);
      expect(r.reason, Reason.signatureOnly);
    });

    test('AC-3 p + reserve > num_ctx -> near_limit', () {
      final r = judgeTruncation(promptEvalCount: 3800, numCtx: 4096, estTokens: est(3800 * 6));
      expect(r.verdict, Verdict.nearLimit);
      expect(r.reason, Reason.lowGenerationRoom);
      // max_tokens 를 주면 reserve 대신 그 값을 쓴다.
      final r2 = judgeTruncation(promptEvalCount: 3800, numCtx: 4096, estTokens: est(3800 * 6), maxTokens: 100);
      expect(r2.verdict, Verdict.ok);
    });

    test('AC-3 larger prompt_eval_cached_count wins', () {
      // count 가 캐시분을 빼고 보고하는 버전이라도 cached 쪽으로 서명을 잡는다.
      final r = judgeTruncation(
        promptEvalCount: 1,
        promptEvalCachedCount: 1025,
        numCtx: 2048,
        estTokens: est(7048 * 4),
      );
      expect(r.promptTokens, 1025);
      expect(r.verdict, Verdict.truncated);
    });

    test('AC-3 signature window is [num_ctx~/2, num_ctx~/2 + keep_slack]', () {
      int long() => est(100000);
      expect(judgeTruncation(promptEvalCount: 2048, numCtx: 4096, estTokens: long()).verdict, Verdict.truncated);
      expect(judgeTruncation(promptEvalCount: 2056, numCtx: 4096, estTokens: long()).verdict, Verdict.truncated);
      expect(judgeTruncation(promptEvalCount: 2057, numCtx: 4096, estTokens: long()).verdict, isNot(Verdict.truncated));
      expect(judgeTruncation(promptEvalCount: 2047, numCtx: 4096, estTokens: long()).verdict, isNot(Verdict.truncated));
      const wide = TruncationSettings(keepSlack: 20);
      expect(
        judgeTruncation(promptEvalCount: 2060, numCtx: 4096, estTokens: long(), settings: wide).verdict,
        Verdict.truncated,
      );
    });

    test('AC-3 estimate uses UTF-8 bytes, so Korean text is not under-counted', () {
      const s = TruncationSettings();
      expect(estimateTokens(['abcdef'], s), 1);
      // 한글 2글자 = 6바이트 → 1토큰(문자 수/6 이면 0).
      expect(estimateTokens(['한글'], s), 1);
    });

    test('AC-3 direct /v1 on the fake server ignores num_ctx: loads 4096, p=2050', () async {
      // demo 와 같은 경로(callDirectV1): 프록시 없이 /v1 에 num_ctx=16384 를 넣어 보낸다.
      final fake = FakeOllama();
      await fake.start();
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await fake.close();
      });
      final r = await callDirectV1(client, fake.uri, 'qwen3:4b', secretPrompt());
      expect(fake.loaded['qwen3:4b'], 4096, reason: '/api/ps reports the default, not 16384');
      expect(r.numCtx, 4096);
      expect(r.promptTokens, 2050);
      expect(r.verdict.verdict, Verdict.truncated);
      expect(r.answer, "I don't see a secret code");
      // 요청 본문에는 num_ctx 가 분명히 들어 있었다(그런데도 무시됨).
      final sent = fake.lastBody('/v1/chat/completions')!;
      expect(sent['num_ctx'], 16384);
      expect((sent['options'] as Map)['num_ctx'], 16384);
    });
  });

  group('AC-4 cannot-judge safeguards return unknown, never truncated', () {
    final long = est(100000);

    test('AC-4 missing prompt_eval_count -> unknown/no_prompt_eval_count', () {
      final r = judgeTruncation(promptEvalCount: null, numCtx: 4096, estTokens: long);
      expect(r.verdict, Verdict.unknown);
      expect(r.reason, Reason.noPromptEvalCount);
    });

    test('AC-4 zero, negative or string prompt_eval_count -> unknown/invalid_prompt_eval_count', () {
      for (final bad in <Object>[0, -5, '2050', 2050.5]) {
        final r = judgeTruncation(promptEvalCount: bad, numCtx: 4096, estTokens: long);
        expect(r.verdict, Verdict.unknown, reason: '$bad');
        expect(r.reason, Reason.invalidPromptEvalCount);
      }
    });

    test('AC-4 p > num_ctx -> unknown/exceeds_num_ctx', () {
      final r = judgeTruncation(promptEvalCount: 5000, numCtx: 4096, estTokens: long);
      expect(r.verdict, Verdict.unknown);
      expect(r.reason, Reason.exceedsNumCtx);
    });

    test('AC-4 unknown num_ctx -> unknown/num_ctx_unknown', () {
      final r = judgeTruncation(promptEvalCount: 2050, numCtx: null, estTokens: long);
      expect(r.verdict, Verdict.unknown);
      expect(r.reason, Reason.numCtxUnknown);
    });

    test('AC-4 stream without done:true -> unknown/stream_incomplete', () {
      final r = judgeTruncation(promptEvalCount: 2050, numCtx: 4096, estTokens: long, streamComplete: false);
      expect(r.verdict, Verdict.unknown);
      expect(r.reason, Reason.streamIncomplete);
    });
  });
}
