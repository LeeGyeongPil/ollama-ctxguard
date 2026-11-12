// 화면 언어(en/ko) 테스트: 메시지 표 일치, 언어 결정 순서, 한국어 화면 전환, 불변 출력.

import 'dart:convert';
import 'dart:io';

import 'package:ollama_ctxguard/ollama_ctxguard.dart';
import 'package:ollama_ctxguard/src/cli.dart';
import 'package:ollama_ctxguard/src/i18n.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

/// runCli 를 돌려 (종료 코드, stdout, stderr) 를 돌려 준다. 환경변수는 주입한 값만 쓴다.
Future<(int, String, String)> _run(List<String> args, {Map<String, String> env = const {}}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = await runCli(args, out: out, err: err, environment: env);
  return (code, out.toString(), err.toString());
}

final _hangul = RegExp(r'[가-힣]');

void main() {
  group('message tables', () {
    test('en and ko have exactly the same keys', () {
      expect(messagesKo.keys.toSet(), messagesEn.keys.toSet());
    });

    test('every ko value is non-empty and contains Korean text unless it is a pass-through', () {
      messagesKo.forEach((k, v) {
        expect(v.trim(), isNotEmpty, reason: k);
        if (!const {'config.message', 'doctor.col_modelfile'}.contains(k))
          expect(_hangul.hasMatch(v), isTrue, reason: k);
      });
    });

    test('placeholder names match between en and ko', () {
      final re = RegExp(r'\{(\w+)\}');
      for (final k in messagesEn.keys) {
        Set<String> names(String s) => re.allMatches(s).map((m) => m.group(1)!).toSet();
        expect(names(messagesKo[k]!), names(messagesEn[k]!), reason: k);
      }
    });

    test('ko sentences have no fixed particle right after a placeholder', () {
      // '}' 뒤에 닫는 따옴표·괄호·공백이 와도 조사(이/가/을/를/은/는/의/와/과/로/으로/도/에…)를 잡는다.
      final bad = RegExp(r'\}["\x27”’)\]」』]*\s*(?:으로|에서|에게|부터|까지|이|가|을|를|은|는|의|와|과|로|도|에)(?![가-힣])');
      messagesKo.forEach((k, v) {
        expect(bad.hasMatch(v), isFalse, reason: '$k: $v');
      });
      // 검사 정규식 자체가 잡아야 할 형태를 잡는지 확인한다.
      for (final sample in ['{x} 가', '"{x}" 를', '({x}) 로', '{x}도 ', '{x} 으로', '{x}에서']) {
        expect(bad.hasMatch(sample), isTrue, reason: sample);
      }
      expect(bad.hasMatch('{x} 입니다'), isFalse);
    });

    test('t() fills placeholders, nested messages, and rejects unknown keys', () {
      expect(t(Lang.en, 'serve.shutdown'), 'shutting down');
      expect(t(Lang.ko, 'serve.shutdown'), '종료합니다');
      expect(t(Lang.en, 'warn.v1_modelfile', {'value': 4096}), '4096 (Modelfile)');
      expect(
        t(Lang.ko, 'warn.no_setting', {'v1': const Msg('warn.v1_default'), 'glob': 'a:*', 'suggest': 1}),
        contains('서버 기본값'),
      );
      expect(() => t(Lang.en, 'no.such.key'), throwsArgumentError);
    });

    test('displayWidth counts Hangul as two cells', () {
      expect(displayWidth('abc'), 3);
      expect(displayWidth('모델'), 4);
    });
  });

  group('language resolution', () {
    test('--lang beats every environment variable', () {
      final env = {'OLLAMA_CTXGUARD_LANG': 'ko', 'LC_ALL': 'ko_KR.UTF-8', 'LANG': 'ko_KR.UTF-8'};
      expect(resolveLang(flag: 'en', environment: env), Lang.en);
      expect(resolveLang(flag: 'ko', environment: const {}), Lang.ko);
    });

    test('OLLAMA_CTXGUARD_LANG > LC_ALL > LC_MESSAGES > LANG', () {
      expect(resolveLang(environment: {'OLLAMA_CTXGUARD_LANG': 'en', 'LC_ALL': 'ko_KR.UTF-8'}), Lang.en);
      expect(resolveLang(environment: {'OLLAMA_CTXGUARD_LANG': 'ko', 'LC_ALL': 'en_US.UTF-8'}), Lang.ko);
      expect(resolveLang(environment: {'LC_ALL': 'en_US.UTF-8', 'LC_MESSAGES': 'ko_KR', 'LANG': 'ko_KR'}), Lang.en);
      expect(resolveLang(environment: {'LC_MESSAGES': 'ko_KR.UTF-8', 'LANG': 'en_US.UTF-8'}), Lang.ko);
      expect(resolveLang(environment: {'LANG': 'ko_KR.UTF-8'}), Lang.ko);
    });

    test('empty variables are skipped; C, POSIX, unknown values and nothing at all give English', () {
      expect(resolveLang(environment: {'LC_ALL': '', 'LANG': 'ko_KR.UTF-8'}), Lang.ko);
      expect(resolveLang(environment: {'LANG': 'C'}), Lang.en);
      expect(resolveLang(environment: {'LANG': 'POSIX'}), Lang.en);
      expect(resolveLang(environment: {'OLLAMA_CTXGUARD_LANG': 'fr'}), Lang.en);
      expect(resolveLang(environment: const {}), Lang.en);
    });

    test('the same priority holds through runCli', () async {
      expect((await _run(['--help'], env: {'LANG': 'ko_KR.UTF-8'})).$2, contains('사용법'));
      expect((await _run(['--help'], env: {'LANG': 'C'})).$2, contains('usage:'));
      expect((await _run(['--help'])).$2, contains('usage:'));
      expect((await _run(['--help'], env: {'OLLAMA_CTXGUARD_LANG': 'ko', 'LANG': 'en_US'})).$2, contains('사용법'));
      expect((await _run(['--lang', 'en', '--help'], env: {'OLLAMA_CTXGUARD_LANG': 'ko'})).$2, contains('usage:'));
      expect((await _run(['--lang=ko', '--help'], env: {'OLLAMA_CTXGUARD_LANG': 'en'})).$2, contains('사용법'));
    });

    test('--lang is accepted before and after the command', () async {
      expect((await _run(['doctor', '--lang', 'ko', '--help'])).$2, contains('사용법'));
      final (code, _, err) = await _run(['serve', '--nope', '--lang', 'ko']);
      expect(code, 64);
      expect(err, contains('알 수 없는 옵션입니다: "--nope"'));
    });

    test('an invalid --lang value exits 64 and names the allowed values', () async {
      final (code, _, err) = await _run(['--lang', 'fr', 'demo']);
      expect(code, 64);
      expect(err, contains('allowed: en, ko'));
      final (kcode, _, kerr) = await _run(['--lang', 'fr', 'demo'], env: {'LANG': 'ko_KR.UTF-8'});
      expect(kcode, 64);
      expect(kerr, contains('허용: en, ko'));
    });
  });

  group('Korean screens', () {
    test('help, no-command usage and --version keep their exit codes', () async {
      final en = await _run(['--help']);
      final ko = await _run(['--lang', 'ko', '--help']);
      expect((en.$1, ko.$1), (0, 0));
      expect(ko.$2, contains('ollama-ctxguard $packageVersion'));
      expect(ko.$2, contains('serve'));
      expect(en.$2, contains('--lang en|ko'));
      expect((await _run(['--lang', 'ko'])).$1, 64);
      final v = await _run(['--lang', 'ko', '--version']);
      expect((v.$1, v.$2.trim()), (0, packageVersion));
    });

    test('argument errors are localized, English stays as package:args words it', () async {
      final cases = <List<String>, (String, String)>{
        ['serve', '--nope']: ('Could not find an option named "--nope".', '알 수 없는 옵션입니다: "--nope"'),
        ['serve', '--config']: ('Missing argument for "--config".', '옵션에 값이 없습니다: "--config"'),
        ['serve', '--log-format', 'xml']: (
          '"xml" is not an allowed value for option "--log-format".',
          '허용되지 않는 값입니다: "xml" (옵션: "--log-format")',
        ),
        ['serve', '--no-strict']: ('Cannot negate option "--no-strict".', '이 옵션은 부정형(--no-)으로 쓸 수 없습니다: "--no-strict"'),
        ['serve', '--no-json']: ('Could not find an option named "--no-json".', '알 수 없는 옵션입니다: "--no-json"'),
        ['serve', '-x']: ('Could not find an option or flag "-x".', '알 수 없는 옵션입니다: "-x"'),
        ['serve', '--strict=1']: (
          'Flag option "--strict" should not be given a value.',
          '플래그에는 값을 줄 수 없습니다: "--strict"',
        ),
      };
      for (final entry in cases.entries) {
        final en = await _run(entry.key);
        final ko = await _run(['--lang', 'ko', ...entry.key]);
        expect((en.$1, ko.$1), (64, 64), reason: '${entry.key}');
        expect(en.$3, contains('error: ${entry.value.$1}'));
        expect(ko.$3, contains('오류: ${entry.value.$2}'));
      }
    });

    test('config errors are localized while ConfigException.message stays English', () async {
      final dir = Directory.systemTemp.createTempSync('ctxguard-i18n');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/bad.yaml')..writeAsStringSync('modles: {}\n');
      final en = await _run(['serve', '--config', file.path]);
      final ko = await _run(['serve', '--config', file.path, '--lang', 'ko']);
      expect((en.$1, ko.$1), (2, 2));
      expect(en.$3, contains('error: config error: ${file.path}: unknown key "modles"'));
      expect(ko.$3, contains('오류: 설정 오류: ${file.path}: 알 수 없는 키: "modles"'));

      final missing = await _run(['serve', '--config', '/nonexistent.yaml', '--lang', 'ko']);
      expect(missing.$1, 2);
      expect(missing.$3, contains('파일을 찾을 수 없습니다: /nonexistent.yaml'));

      final listen = await _run(['serve', '--listen', 'nope', '--lang', 'ko']);
      expect(listen.$1, 2);
      expect(listen.$3, contains('listen 형식이 올바르지 않습니다'));

      try {
        CtxguardConfig.fromYamlString('strict: 3\n', source: 'x.yaml');
        fail('should throw');
      } on ConfigException catch (e) {
        expect(e.message, 'x.yaml: "strict" must be true or false');
        expect(e.toString(), 'config error: x.yaml: "strict" must be true or false');
        expect(e.code, 'config.strict_bool');
        expect(e.localized(Lang.ko), contains('true 또는 false'));
      }
    });

    test('every config error key is reachable and localized (no English left in ko)', () {
      final samples = <String, String>{
        'config.top_mapping': '- a\n',
        'config.unknown_key': 'foo: 1\n',
        'config.models_mapping': 'models: 3\n',
        'config.strict_bool': 'strict: 3\n',
        'config.truncation_mapping': 'truncation: 3\n',
        'config.unknown_truncation_key': 'truncation: {nope: 1}\n',
        'config.upstream_form': 'upstream: ftp://x\n',
        'config.listen_form': 'listen: x:y\n',
        'config.log_format': 'log_format: xml\n',
        'config.must_string': 'upstream: 3\n',
        'config.int_range': 'default: 3\n',
        'config.positive': 'truncation: {ratio: -1}\n',
        'config.invalid_yaml': 'a: [\n',
      };
      samples.forEach((code, yaml) {
        try {
          CtxguardConfig.fromYamlString(yaml, source: 's.yaml');
          fail('$code: should throw');
        } on ConfigException catch (e) {
          expect(e.code, code);
          expect(e.localized(Lang.ko), contains('설정 오류:'), reason: code);
          expect(e.localized(Lang.ko), isNot(equals(e.localized(Lang.en))), reason: code);
        }
      });
    });

    test('mock-upstream argument and port errors are localized', () async {
      final bad = await _run(['mock-upstream', '--port', 'abc', '--lang', 'ko']);
      expect(bad.$1, 64);
      expect(bad.$3, contains('정수여야 합니다'));
      final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(busy.close);
      final ko = await _run(['mock-upstream', '--port', '${busy.port}', '--lang', 'ko']);
      expect(ko.$1, 2);
      expect(ko.$3, contains('이미 사용 중'));
      final serve = await _run(['serve', '--listen', '127.0.0.1:${busy.port}', '--lang', 'ko']);
      expect(serve.$1, 2);
      expect(serve.$3, contains('--listen 127.0.0.1:<port>'));
      expect(serve.$3, contains('오류:'));
    });

    test('demo prints Korean explanations but the same data lines and exit code', () async {
      final en = await _run(['demo']);
      final ko = await _run(['demo', '--lang', 'ko']);
      expect((en.$1, ko.$1), (0, 0));
      expect(ko.$2, contains('연습용 목 모드'));
      expect(ko.$2, contains('무슨 일이 있었나'));
      // 데이터(수치·판정)와 원시 로그 줄은 언어와 상관없이 같다.
      for (final needle in ['num_ctx=4096', 'num_ctx=16384', 'verdict=truncated', 'verdict=ok', '"verdict":"ok"']) {
        expect(ko.$2, contains(needle));
      }
      List<String> logLines(String s) => s.split('\n').where((l) => l.startsWith('  {')).toList();
      expect(logLines(ko.$2).length, logLines(en.$2).length);
      expect(ko.$2, contains('SECRET-CODE is 7731'));
    });
  });

  group('doctor in Korean', () {
    late FakeOllama fake;
    late Directory dir;
    late File config;
    setUp(() async {
      fake = FakeOllama(defaultCtx: 4096, modelMax: 40960);
      await fake.start();
      final client = HttpClient();
      final req = await client.postUrl(fake.uri.resolve('/v1/chat/completions'));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(userChat('hi')));
      await (await req.close()).drain<void>();
      client.close();
      dir = Directory.systemTemp.createTempSync('ctxguard-doctor-i18n');
      config = File('${dir.path}/ctxguard.yaml')..writeAsStringSync('models:\n  "qwen3:*": 32768\n');
    });
    tearDown(() async {
      await fake.close();
      dir.deleteSync(recursive: true);
    });

    test('table, warnings and notes are Korean; --json is byte-identical in both languages', () async {
      final args = ['doctor', '--config', config.path, '--upstream', '${fake.uri}'];
      final en = await _run(args);
      final ko = await _run([...args, '--lang', 'ko']);
      expect((en.$1, ko.$1), (0, 0));
      expect(ko.$2, contains('모델'));
      expect(ko.$2, contains('로드 안 됨'));
      expect(ko.$2, contains('서버 기본값'));
      expect(ko.$2, contains('* 현재 로드 크기로 추정한 값입니다'));
      expect(ko.$2, contains('경고: qwen3:4b: 로드된 크기와 설정이 다릅니다'));
      expect(ko.$2, contains('경고: llama3.2:3b: ctxguard 설정이 없습니다'));
      expect(ko.$2, contains('"llama3.2:*": 32768'));
      expect(en.$2, contains('warning: qwen3:4b: loaded at 4096 but config says 32768'));

      // 열이 맞는지: 한글(2칸) 폭을 계산해 모든 행의 두 번째 열이 같은 칸에서 시작한다.
      final rows = ko.$2
          .split('\n')
          .skip(1)
          .where((l) => l.startsWith('모델') || l.startsWith('qwen3') || l.startsWith('llama'));
      final starts = rows.map((l) => displayWidth(RegExp(r'^\S+\s{2,}').firstMatch(l)![0]!)).toSet();
      expect(starts.length, 1);

      final enJson = await _run([...args, '--json']);
      final koJson = await _run([...args, '--json', '--lang', 'ko']);
      expect(koJson.$2, enJson.$2);
      expect(jsonDecode(koJson.$2)['models'][0]['warnings'][0], isA<String>());
      expect(koJson.$2, isNot(matches(_hangul)));
    });

    test('unreachable upstream: localized table message, English JSON, same exit code', () async {
      final port = await deadPort();
      final args = ['doctor', '--upstream', 'http://127.0.0.1:$port'];
      final ko = await _run([...args, '--lang', 'ko']);
      expect(ko.$1, 2);
      expect(ko.$2, contains('Ollama 에 연결할 수 없습니다'));
      final js = await _run([...args, '--json', '--lang', 'ko']);
      expect(js.$1, 2);
      expect(jsonDecode(js.$2)['error'], contains('cannot reach Ollama'));
    });

    test('a config file that is not UTF-8 is a localized config error (exit 2), not a crash', () async {
      final dir = Directory.systemTemp.createTempSync('ctxguard-bad-utf8');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File('${dir.path}/ctxguard.yaml')..writeAsBytesSync([0xff, 0xfe, 0x80, 0x00, 0xc3, 0x28]);
      final en = await _run(['--lang', 'en', 'serve', '--config', f.path]);
      final ko = await _run(['--lang', 'ko', 'serve', '--config', f.path]);
      expect(en.$1, 2);
      expect(ko.$1, 2);
      expect(en.$3, contains('must be a UTF-8 text file'));
      expect(ko.$3, contains('UTF-8 텍스트 파일이어야 함'));
      expect(() => CtxguardConfig.load(f.path), throwsA(isA<ConfigException>()));
    });
  });

  group('unknown command', () {
    test('prints a localized error line before the usage, exit 64', () async {
      final en = await _run(['--lang', 'en', 'frob']);
      expect(en.$1, 64);
      expect(en.$3, startsWith('error: Could not find a command named "frob".\n'));
      expect(en.$3, contains('usage:'));
      final ko = await _run(['--lang', 'ko', 'frob']);
      expect(ko.$1, 64);
      expect(ko.$3, startsWith('오류: 알 수 없는 하위 명령입니다: "frob"\n'));
      expect(ko.$3, contains('사용법:'));
    });

    test('no arguments still prints only the usage, exit 64', () async {
      final r = await _run(['--lang', 'en']);
      expect(r.$1, 64);
      expect(r.$3, isNot(contains('error:')));
    });
  });
}
