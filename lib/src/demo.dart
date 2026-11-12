// demo: 실제 Ollama 없이 1분 안에 "왜 필요한가"를 보여 주는 오프라인 비교.
//
// 연습용 가짜 Ollama 와 프록시를 이 프로세스 안에서 임의 포트로 띄우고, 맨 앞에
// "SECRET-CODE is 7731" 을 넣은 긴 프롬프트를 두 번 보낸다.
//   ① 직접 /v1   — num_ctx=16384 를 요청에 넣어도 무시되어 4096 으로 로드, 앞부분이 잘림
//   ② 프록시 경유 — /api/chat 으로 바꿔 보내 16384 가 적용, 비밀 코드를 기억함

import 'dart:convert';
import 'dart:io';

import 'access_log.dart';
import 'config.dart';
import 'i18n.dart';
import 'ctx_resolver.dart';
import 'mock/fake_ollama.dart';
import 'proxy_server.dart';
import 'truncation.dart';

/// 데모 프롬프트: 비밀 코드 한 줄 + 채움 문장 [fillerSentences] 개 + 질문.
String secretPrompt({int fillerSentences = 500}) {
  final b = StringBuffer('SECRET-CODE is 7731. Remember this code.\n');
  for (var i = 0; i < fillerSentences; i++) {
    b.write('Filler sentence $i keeps the context window busy with ordinary words. ');
  }
  b.write('\nQuestion: what is the SECRET-CODE? Answer with the number only.');
  return b.toString();
}

/// 직접 /v1 호출 한 번의 결과(데모·테스트 공용).
class DirectResult {
  DirectResult(this.numCtx, this.promptTokens, this.answer, this.verdict);
  final int? numCtx;
  final int? promptTokens;
  final String answer;
  final TruncationResult verdict;
}

/// 프록시 없이 가짜 Ollama 의 /v1 에 직접 보낸다(요청에 num_ctx 를 넣어도 무시된다).
/// [extra] 는 실제 모델 점검용(max_tokens 등)으로 본문에 더할 필드.
Future<DirectResult> callDirectV1(
  HttpClient client,
  Uri upstream,
  String model,
  String prompt, {
  Map<String, Object?> extra = const {},
}) async {
  final body = {
    'model': model,
    'messages': [
      {'role': 'user', 'content': prompt},
    ],
    'num_ctx': 16384, // 최상위에도
    'options': {'num_ctx': 16384}, // options 에도 넣어 보지만 /v1 은 읽지 않는다.
    ...extra,
  };
  final j = await _postJson(client, upstreamUrl(upstream, '/v1/chat/completions'), body);
  final usage = j['usage'] as Map;
  final answer = ((j['choices'] as List).first as Map)['message']['content'] as String;
  // 프록시가 없으니 판정은 우리가 직접: /api/ps 로 실제 로드 크기를 확인한다.
  final loaded = await fetchLoaded(client, upstream);
  final numCtx = loaded?[normalizeModelName(model)];
  final verdict = judgeTruncation(
    promptEvalCount: usage['prompt_tokens'],
    numCtx: numCtx,
    estTokens: estimateTokens([prompt], const TruncationSettings()),
  );
  return DirectResult(numCtx, usage['prompt_tokens'] as int?, answer, verdict);
}

/// 데모 실행. 반환값은 종료 코드.
Future<int> runDemo({required StringSink out, Lang lang = Lang.en}) async {
  out.writeln(t(lang, 'demo.title'));
  final fake = FakeOllama(defaultCtx: 4096, modelMax: 40960);
  await fake.start();
  final logLines = <String>[];
  final proxy = ProxyServer(
    CtxguardConfig(
      upstream: fake.uri,
      listenPort: 0, // 임의 포트
      models: {'qwen3:*': 16384},
    ),
    log: AccessLog(sink: logLines.add),
  );
  await proxy.start();
  final client = HttpClient();
  try {
    const model = 'qwen3:4b';
    final prompt = secretPrompt();
    out.writeln(t(lang, 'demo.prompt', {'bytes': utf8.encode(prompt).length}));
    out.writeln('');

    // ① 직접 /v1
    final d = await callDirectV1(client, fake.uri, model, prompt);
    out.writeln(
      t(lang, 'demo.direct', {
        'numCtx': d.numCtx,
        'tokens': d.promptTokens,
        'verdict': d.verdict.verdict.wireName,
        'answer': d.answer,
      }),
    );

    // ② 프록시 경유 — 클라이언트는 base_url 만 바꿨다.
    final viaUri = Uri.parse('http://127.0.0.1:${proxy.port}/v1/chat/completions');
    final req = await client.postUrl(viaUri);
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode({
        'model': model,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      }),
    );
    final res = await req.close();
    final j = jsonDecode(await utf8.decoder.bind(res).join()) as Map<String, Object?>;
    final answer = ((j['choices'] as List).first as Map)['message']['content'];
    out.writeln(
      t(lang, 'demo.via', {
        'numCtx': res.headers.value('x-ctxguard-num-ctx'),
        'tokens': res.headers.value('x-ctxguard-prompt-tokens'),
        'verdict': res.headers.value('x-ctxguard-verdict'),
        'answer': answer,
      }),
    );
    out.writeln('');
    out.writeln(t(lang, 'demo.what_1'));
    out.writeln(t(lang, 'demo.what_2', {'tokens': d.promptTokens}));
    out.writeln(t(lang, 'demo.what_3'));
    out.writeln('');
    out.writeln(t(lang, 'demo.log_title'));
    for (final l in logLines) {
      out.writeln('  $l');
    }
    return 0;
  } finally {
    client.close(force: true);
    await proxy.close();
    await fake.close();
  }
}

Future<Map<String, Object?>> _postJson(HttpClient client, Uri uri, Object body) async {
  final req = await client.postUrl(uri);
  req.headers.contentType = ContentType.json;
  req.write(jsonEncode(body));
  final res = await req.close();
  return jsonDecode(await utf8.decoder.bind(res).join()) as Map<String, Object?>;
}
