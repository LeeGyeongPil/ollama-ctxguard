import 'dart:io';

import 'package:ollama_ctxguard/ollama_ctxguard.dart';
import 'package:ollama_ctxguard/src/cli.dart';
import 'package:test/test.dart';

void main() {
  group('model matching', () {
    final config = CtxguardConfig(
      models: {
        'qwen3:*': 32768,
        'qwen3:4b': 16384,
        'qwen3:4b-*': 24576,
        'llama3.2': 8192, // 태그 없음 → llama3.2:latest
        'hf.co/*': 4096,
      },
    );

    test('exact match beats any glob', () {
      expect(config.numCtxFor('qwen3:4b'), 16384);
    });

    test('most specific glob wins', () {
      expect(config.numCtxFor('qwen3:4b-instruct-q4_K_M'), 24576);
      expect(config.numCtxFor('qwen3:8b'), 32768);
    });

    test('names without a tag are treated as :latest', () {
      expect(config.numCtxFor('llama3.2'), 8192);
      expect(config.numCtxFor('llama3.2:latest'), 8192);
      expect(config.numCtxFor('llama3.2:1b'), isNull);
      expect(normalizeModelName('hf.co/org/model'), 'hf.co/org/model:latest');
      expect(normalizeModelName('qwen3:4b'), 'qwen3:4b');
    });

    test('unlisted models get null unless default is set', () {
      expect(config.numCtxFor('mistral:7b'), isNull);
      final withDefault = CtxguardConfig.fromYamlString('default: 8192\n');
      expect(withDefault.numCtxFor('mistral:7b'), 8192);
    });

    test('glob ? matches exactly one character', () {
      expect(globMatch('qwen?:4b', 'qwen3:4b'), isTrue);
      expect(globMatch('qwen?:4b', 'qwen:4b'), isFalse);
      expect(globMatch('a.b*', 'aXb'), isFalse, reason: 'dot is literal');
    });
  });

  group('YAML loading', () {
    test('full example file parses', () {
      final c = CtxguardConfig.load('example/ctxguard.yaml');
      expect(c.upstream.toString(), 'http://127.0.0.1:11434');
      expect(c.listenHost, '127.0.0.1');
      expect(c.listenPort, 11435);
      expect(c.numCtxFor('qwen3:4b'), 32768);
      expect(c.strict, isFalse);
      expect(c.truncation.bytesPerToken, 6);
    });

    test('all keys', () {
      final c = CtxguardConfig.fromYamlString('''
upstream: http://192.168.0.10:11434
listen: "[::1]:9000"
strict: true
default: 4096
models:
  "qwen3:*": 16384
truncation:
  keep_slack: 16
  bytes_per_token: 3.5
  ratio: 1.5
  reserve: 256
upstream_timeout_seconds: 30
log_format: text
log_file: /tmp/ctxguard.log
''');
      expect(c.upstream.host, '192.168.0.10');
      expect(c.listenHost, '::1');
      expect(c.listenPort, 9000);
      expect(c.strict, isTrue);
      expect(c.defaultNumCtx, 4096);
      expect(c.truncation.keepSlack, 16);
      expect(c.truncation.bytesPerToken, 3.5);
      expect(c.truncation.ratio, 1.5);
      expect(c.truncation.reserve, 256);
      expect(c.upstreamTimeout, const Duration(seconds: 30));
      expect(c.logFormat, LogFormat.text);
      expect(c.logFile, '/tmp/ctxguard.log');
    });

    test('empty file means defaults', () {
      final c = CtxguardConfig.fromYamlString('');
      expect(c.models, isEmpty);
      expect(c.listenHost, '127.0.0.1');
    });

    test('typos and bad values are reported, not ignored', () {
      expect(() => CtxguardConfig.fromYamlString('modles: {}'), throwsA(isA<ConfigException>()));
      expect(() => CtxguardConfig.fromYamlString('models: {"a": "big"}'), throwsA(isA<ConfigException>()));
      expect(() => CtxguardConfig.fromYamlString('models: {"a": 10}'), throwsA(isA<ConfigException>()));
      expect(() => CtxguardConfig.fromYamlString('upstream: ftp://x'), throwsA(isA<ConfigException>()));
      expect(() => CtxguardConfig.fromYamlString('listen: "nohost:"'), throwsA(isA<ConfigException>()));
      expect(() => CtxguardConfig.fromYamlString('truncation: {ratio: 0}'), throwsA(isA<ConfigException>()));
      expect(() => CtxguardConfig.fromYamlString('truncation: {foo: 1}'), throwsA(isA<ConfigException>()));
      expect(() => CtxguardConfig.fromYamlString('strict: "yes"'), throwsA(isA<ConfigException>()));
      expect(() => CtxguardConfig.fromYamlString('log_format: xml'), throwsA(isA<ConfigException>()));
      expect(() => CtxguardConfig.fromYamlString('[1, 2'), throwsA(isA<ConfigException>()));
      expect(() => CtxguardConfig.load('/nonexistent/ctxguard.yaml'), throwsA(isA<ConfigException>()));
    });
  });

  group('command line', () {
    test('options override the config file', () {
      final dir = Directory.systemTemp.createTempSync('ctxguard_cfg');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/c.yaml')..writeAsStringSync('listen: 127.0.0.1:12000\nstrict: false\n');
      final parsed = buildParser().parse([
        'serve',
        '--config',
        file.path,
        '--listen',
        '127.0.0.1:12001',
        '--strict',
        '--upstream',
        'http://127.0.0.1:12002',
      ]);
      final c = loadServeConfig(parsed.command!);
      expect(c.listenPort, 12001);
      expect(c.strict, isTrue);
      expect(c.upstream.port, 12002);
    });

    test('bad arguments exit 64, bad config exits 2', () async {
      final err = StringBuffer();
      expect(await runCli(['serve', '--nope'], out: StringBuffer(), err: err), 64);
      expect(await runCli([], out: StringBuffer(), err: err), 64);
      expect(await runCli(['serve', '--config', '/nonexistent.yaml'], out: StringBuffer(), err: err), 2);
      final out = StringBuffer();
      expect(await runCli(['--version'], out: out, err: err), 0);
      expect(out.toString().trim(), packageVersion);
    });

    test('a port that is already in use exits 2 with a hint to pick another', () async {
      final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(busy.close);
      final err = StringBuffer();
      final code = await runCli(
        ['serve', '--listen', '127.0.0.1:${busy.port}'],
        out: StringBuffer(),
        err: err,
      ).timeout(const Duration(seconds: 5));
      expect(code, 2);
      expect(err.toString(), contains('already in use'));
      expect(err.toString(), contains('--listen 127.0.0.1:'));
    });

    test('EADDRINUSE from another process is recognised on macOS, Linux and Windows', () {
      for (final code in [48, 98, 10048]) {
        expect(isAddressInUse(SocketException('bind', osError: OSError('Address already in use', code))), isTrue);
      }
      expect(isAddressInUse(SocketException('bind', osError: const OSError('Permission denied', 13))), isFalse);
    });
  });
}
