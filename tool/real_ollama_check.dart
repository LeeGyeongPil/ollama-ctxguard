// 선택적 수동 점검: 실제 Ollama 에서 "직접 /v1" 과 "ctxguard 경유" 를 비교한다.
// CI 에서는 돌리지 않는다(실제 모델·메모리가 필요하고 첫 로드가 수십 초 걸린다).
//
//   dart run tool/real_ollama_check.dart [--upstream http://127.0.0.1:11434] [--model qwen3:4b] [--num-ctx 16384]
//
// 맨 앞에 "SECRET-CODE is 7731" 이 있는 긴 프롬프트를 두 번 보낸다.
//   ① 직접 /v1        — num_ctx 를 넣어도 무시되어 서버 기본값으로 로드, 앞부분이 잘림
//   ② ctxguard 경유    — /api/chat 의 options.num_ctx 로 적용, 비밀 코드를 기억

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:ollama_ctxguard/ollama_ctxguard.dart';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('upstream', defaultsTo: 'http://127.0.0.1:11434')
    ..addOption('model', defaultsTo: 'qwen3:4b')
    ..addOption('num-ctx', defaultsTo: '16384');
  final opts = parser.parse(args);
  final upstream = Uri.parse(opts['upstream'] as String);
  final model = opts['model'] as String;
  final numCtx = int.parse(opts['num-ctx'] as String);

  // 실제 모델은 느릴 수 있다(공유 자원, 첫 로드 수십 초) → 넉넉한 시간 제한.
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final logs = <String>[];
  final proxy = ProxyServer(
    CtxguardConfig(upstream: upstream, listenPort: 0, models: {model: numCtx}),
    log: AccessLog(sink: logs.add),
  );
  await proxy.start();
  try {
    final prompt = secretPrompt();
    stdout.writeln('real Ollama check: $upstream model=$model, prompt ${utf8.encode(prompt).length} bytes');

    final direct = await callDirectV1(
      client,
      upstream,
      model,
      prompt,
      extra: {'max_tokens': 64, 'reasoning_effort': 'none'},
    );
    stdout.writeln(
      'direct /v1    : num_ctx=${direct.numCtx} prompt_tokens=${direct.promptTokens} '
      'verdict=${direct.verdict.verdict.wireName}  answer: ${_oneLine(direct.answer)}',
    );

    final req = await client.postUrl(Uri.parse('http://127.0.0.1:${proxy.port}/v1/chat/completions'));
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode({
        'model': model,
        'max_tokens': 64,
        'reasoning_effort': 'none',
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      }),
    );
    final res = await req.close().timeout(const Duration(minutes: 10));
    final j = jsonDecode(await utf8.decoder.bind(res).join()) as Map<String, Object?>;
    final answer = j['choices'] is List ? (((j['choices'] as List).first as Map)['message'] as Map)['content'] : j;
    stdout.writeln(
      'via ctxguard  : num_ctx=${res.headers.value('x-ctxguard-num-ctx')} '
      'prompt_tokens=${res.headers.value('x-ctxguard-prompt-tokens')} '
      'verdict=${res.headers.value('x-ctxguard-verdict')}  answer: ${_oneLine('$answer')}',
    );
    for (final l in logs) {
      stdout.writeln('log: $l');
    }
  } on SocketException catch (e) {
    stderr.writeln('cannot reach Ollama at $upstream: ${e.message}');
    exitCode = 2;
  } finally {
    client.close(force: true);
    await proxy.close();
  }
}

String _oneLine(String s) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > 120 ? '${t.substring(0, 120)}...' : t;
}
