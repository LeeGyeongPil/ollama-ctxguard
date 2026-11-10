import 'dart:convert';
import 'dart:io';

import 'package:ollama_ctxguard/ollama_ctxguard.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// 표의 한 행을 2칸 이상 공백으로 나눈다.
List<String> _row(String table, String model) =>
    table.split('\n').firstWhere((l) => l.startsWith('$model ')).split(RegExp(r'\s{2,}'));

void main() {
  group('AC-9 doctor', () {
    late FakeOllama fake;
    setUp(() async {
      fake = FakeOllama(defaultCtx: 4096, modelMax: 40960);
      await fake.start();
      // 누군가 프록시 없이 /v1 로 붙어 기본값 4096 으로 올라가 있는 상태를 만든다.
      final client = HttpClient();
      final req = await client.postUrl(fake.uri.resolve('/v1/chat/completions'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(userChat('hi')));
      await (await req.close()).drain<void>();
      client.close();
    });
    tearDown(() => fake.close());

    test('AC-9 table shows config, model max, loaded size and the /v1 direct size', () async {
      final out = StringBuffer();
      final code = await runDoctor(
        config: CtxguardConfig(upstream: fake.uri, models: {'qwen3:*': 32768}),
        out: out,
      );
      expect(code, 0);
      final table = out.toString();
      expect(table, contains('0.0.0-practice-mock'));
      final header = _row(table, 'MODEL');
      expect(header, ['MODEL', 'CONFIG', 'MODEL MAX', 'MODELFILE', 'LOADED', '/v1 DIRECT']);
      final row = _row(table, 'qwen3:4b');
      // /v1 DIRECT 4096* — 지금 로드 크기로 추정한 값이라 * 표시와 각주가 붙는다.
      expect(row, ['qwen3:4b', '32768', '40960', '-', '4096', '4096*']);
      expect(table, contains('* guessed from the current load'));
      // 설정과 다른 크기로 올라가 있다는 안내.
      expect(table, contains('warning: qwen3:4b: loaded at 4096 but config says 32768'));
      // 설정이 없는 모델에는 권장 줄을 보여 준다.
      final other = _row(table, 'llama3.2:3b');
      expect(other[1], '-');
      expect(other[4], 'not loaded');
      expect(table, contains('"llama3.2:*": 32768'));
    });

    test('AC-9 warns when the config exceeds the model max', () async {
      final out = StringBuffer();
      await runDoctor(
        config: CtxguardConfig(upstream: fake.uri, models: {'qwen3:*': 65536}),
        model: 'qwen3:4b',
        out: out,
      );
      expect(out.toString(), contains('config 65536 exceeds model max 40960'));
    });

    test('AC-9 --json has the same content', () async {
      final out = StringBuffer();
      final code = await runDoctor(
        config: CtxguardConfig(upstream: fake.uri, models: {'qwen3:*': 32768}),
        model: 'qwen3:4b',
        json: true,
        out: out,
      );
      expect(code, 0);
      final j = jsonDecode(out.toString()) as Map;
      expect(j['ollama_version'], '0.0.0-practice-mock');
      final m = (j['models'] as List).single as Map;
      expect(m['model'], 'qwen3:4b');
      expect(m['config_num_ctx'], 32768);
      expect(m['model_max'], 40960);
      expect(m['loaded_num_ctx'], 4096);
      expect(m['v1_direct_num_ctx'], 4096);
      expect(m['v1_direct_basis'], 'current_load_guess');
      expect(m['warnings'], isNotEmpty);
    });

    test('AC-9 a Modelfile num_ctx is what /v1 clients get', () async {
      fake.scenario.modelfileNumCtx = 8192;
      final out = StringBuffer();
      await runDoctor(
        config: CtxguardConfig(upstream: fake.uri),
        model: 'qwen3:4b',
        json: true,
        out: out,
      );
      final m = ((jsonDecode(out.toString()) as Map)['models'] as List).single as Map;
      expect(m['modelfile_num_ctx'], 8192);
      expect(m['v1_direct_num_ctx'], 8192);
      expect(m['v1_direct_basis'], 'modelfile');
    });

    test('AC-9 unknown model exits 2', () async {
      final out = StringBuffer();
      final code = await runDoctor(
        config: CtxguardConfig(upstream: fake.uri),
        model: 'nope:1b',
        out: out,
      );
      expect(code, 2);
      expect(out.toString(), contains('model not found'));
    });
  });

  test('AC-9 upstream URL with a path prefix keeps the prefix for every lookup', () async {
    final fake = FakeOllama(pathPrefix: '/ollama');
    await fake.start();
    addTearDown(fake.close);
    final out = StringBuffer();
    final code = await runDoctor(
      config: CtxguardConfig(
        upstream: fake.uri.replace(path: '/ollama'),
        models: {'qwen3:*': 32768},
      ),
      model: 'qwen3:4b',
      out: out,
    );
    expect(code, 0, reason: '$out');
    expect(_row(out.toString(), 'qwen3:4b'), ['qwen3:4b', '32768', '40960', '-', 'not loaded', 'server default']);
    expect(fake.received.map((r) => r.path), everyElement(startsWith('/ollama/api/')));
  });

  test('AC-9 upstream unreachable exits 2 (table and --json)', () async {
    final port = await deadPort();
    final config = CtxguardConfig(upstream: Uri.parse('http://127.0.0.1:$port'));
    final out = StringBuffer();
    expect(await runDoctor(config: config, out: out), 2);
    expect(out.toString(), contains('cannot reach Ollama'));
    final js = StringBuffer();
    expect(await runDoctor(config: config, json: true, out: js), 2);
    expect((jsonDecode(js.toString()) as Map)['error'], contains('cannot reach Ollama'));
  });
}
