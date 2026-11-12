// 명령줄: serve · doctor · demo · mock-upstream.
// 종료 코드: 0 정상, 2 설정 오류·업스트림 연결 실패, 64 인자 오류.

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import 'access_log.dart';
import 'config.dart';
import 'demo.dart';
import 'doctor.dart';
import 'i18n.dart';
import 'mock/fake_ollama.dart';
import 'proxy_server.dart';

const packageVersion = '0.2.0';

/// 하위 명령 정의. 테스트에서도 같은 파서를 쓴다. 도움말 문구는 [lang] 으로 고른다.
ArgParser buildParser({Lang lang = Lang.en}) {
  String h(String key) => t(lang, 'help.$key');
  // --lang 은 모든 명령 앞뒤에서 받는다. 값 검사와 우선순위는 runCli 가 직접 처리한다.
  void addLang(ArgParser p) => p.addOption('lang', help: h('lang'), valueHelp: 'en|ko');
  final serve = ArgParser()
    ..addOption('config', abbr: 'c', help: h('config'))
    ..addOption('upstream', help: h('upstream'))
    ..addOption('listen', help: h('listen'))
    ..addFlag('strict', negatable: false, help: h('strict'))
    ..addOption('log-format', allowed: ['json', 'text'], help: h('log_format'))
    ..addOption('log-file', help: h('log_file'));
  final doctor = ArgParser()
    ..addOption('config', abbr: 'c', help: h('config'))
    ..addOption('upstream', help: h('upstream'))
    ..addOption('model', abbr: 'm', help: h('model'))
    ..addFlag('json', negatable: false, help: h('json'));
  final mock = ArgParser()
    ..addOption('port', defaultsTo: '11434', help: h('port'))
    ..addOption('default-ctx', defaultsTo: '4096', help: h('default_ctx'))
    ..addOption('model-max', defaultsTo: '40960', help: h('model_max'));
  final demo = ArgParser();
  for (final p in [serve, doctor, mock, demo]) {
    addLang(p);
  }
  final root = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: h('help'))
    ..addFlag('version', negatable: false, help: h('version'));
  addLang(root);
  return root
    ..addCommand('serve', serve)
    ..addCommand('doctor', doctor)
    ..addCommand('demo', demo)
    ..addCommand('mock-upstream', mock);
}

/// 원시 인자에서 `--lang` 값을 찾는다(마지막 것이 이긴다). 파서가 실패해도 오류 문구 언어를 정하려는 용도.
/// 값이 없으면 null, `--` 뒤는 보지 않는다.
String? _scanLangFlag(List<String> args) {
  String? value;
  for (var i = 0; i < args.length; i++) {
    final a = args[i];
    if (a == '--') break;
    if (a == '--lang') {
      if (i + 1 < args.length) value = args[++i];
    } else if (a.startsWith('--lang=')) {
      value = a.substring('--lang='.length);
    }
  }
  return value;
}

/// CLI 진입점. 반환값이 종료 코드. [environment] 는 테스트용(기본은 실제 환경변수).
Future<int> runCli(List<String> args, {StringSink? out, StringSink? err, Map<String, String>? environment}) async {
  out ??= stdout;
  err ??= stderr;
  final env = environment ?? Platform.environment;

  // 화면 언어: --lang > OLLAMA_CTXGUARD_LANG > LC_ALL > LC_MESSAGES > LANG.
  final flag = _scanLangFlag(args);
  final validFlag = flag == 'en' || flag == 'ko' ? flag : null;
  final lang = resolveLang(flag: validFlag, environment: env);
  String usage() => t(lang, 'usage', {'version': packageVersion});
  String errorLine(String text) => '${t(lang, 'prefix.error')} $text';

  if (flag != null && validFlag == null) {
    err.writeln('${errorLine(t(lang, 'lang.invalid', {'value': flag}))}\n\n${usage()}');
    return 64;
  }

  final ArgResults parsed;
  try {
    parsed = buildParser(lang: lang).parse(args);
  } on FormatException catch (e) {
    err.writeln('${errorLine(localizeArgError(lang, e.message))}\n\n${usage()}');
    return 64;
  }
  if (parsed['version'] == true) {
    out.writeln(packageVersion);
    return 0;
  }
  final cmd = parsed.command;
  if (cmd == null && parsed['help'] != true && parsed.rest.isNotEmpty) {
    // 알 수 없는 명령: 오류 줄을 먼저 내고 도움말을 붙인다.
    final msg = localizeArgError(lang, 'Could not find a command named "${parsed.rest.first}".');
    err.writeln('${errorLine(msg)}\n\n${usage()}');
    return 64;
  }
  if (parsed['help'] == true || cmd == null) {
    (cmd == null && parsed['help'] != true ? err : out).write(usage());
    return cmd == null && parsed['help'] != true ? 64 : 0;
  }

  try {
    switch (cmd.name) {
      case 'serve':
        return await _serve(loadServeConfig(cmd), err, lang);
      case 'doctor':
        return await runDoctor(
          config: loadServeConfig(cmd),
          model: cmd['model'] as String?,
          json: cmd['json'] == true,
          out: out,
          lang: lang,
        );
      case 'demo':
        return await runDemo(out: out, lang: lang);
      case 'mock-upstream':
        return await _mockUpstream(cmd, out, err, lang);
    }
  } on ConfigException catch (e) {
    err.writeln(errorLine(e.localized(lang)));
    return 2;
  } on FormatException catch (e) {
    err.writeln(errorLine(localizeArgError(lang, e.message)));
    return 64;
  }
  return 64;
}

/// 설정 파일(있으면) + 명령줄 덮어쓰기. 아무것도 없으면 127.0.0.1:11435 기본값.
CtxguardConfig loadServeConfig(ArgResults cmd, {String defaultPath = 'ctxguard.yaml'}) {
  final path = cmd['config'] as String?;
  CtxguardConfig config;
  if (path != null) {
    config = CtxguardConfig.load(path);
  } else if (File(defaultPath).existsSync()) {
    config = CtxguardConfig.load(defaultPath);
  } else {
    config = CtxguardConfig();
  }
  String? opt(String name) => cmd.options.contains(name) ? cmd[name] as String? : null;
  final listen = opt('listen');
  final (host, port) = listen != null ? parseListen(listen) : (null, null);
  final upstream = opt('upstream');
  final logFormat = opt('log-format');
  return config.withOverrides(
    upstream: upstream != null ? parseUpstream(upstream) : null,
    listenHost: host,
    listenPort: port,
    strict: cmd.options.contains('strict') && cmd['strict'] == true ? true : null,
    logFormat: logFormat != null ? parseLogFormat(logFormat) : null,
    logFile: opt('log-file'),
  );
}

Future<int> _serve(CtxguardConfig config, StringSink err, Lang lang) async {
  final proxy = ProxyServer(config);
  final errorPrefix = t(lang, 'prefix.error');
  try {
    await proxy.start();
  } on SocketException catch (e) {
    final where = '${config.listenHost}:${config.listenPort}';
    if (isAddressInUse(e)) {
      // 가장 흔한 원인 — 원인과 고치는 방법을 함께 알려 준다.
      err.writeln('$errorPrefix ${t(lang, 'serve.port_in_use', {'where': where, 'host': config.listenHost})}');
    } else {
      err.writeln(
        '$errorPrefix ${t(lang, 'serve.listen_failed', {'where': where, 'detail': '${e.message}${_osDetail(e)}'})}',
      );
    }
    return 2;
  }
  final addr = proxy.address;
  err.writeln(
    t(lang, 'serve.listening', {
      'version': packageVersion,
      'host': config.listenHost,
      'port': proxy.port,
      'upstream': config.upstream,
      'rules': config.models.length,
      'strict': config.strict,
    }),
  );
  if (!addr.isLoopback) {
    // 기본은 loopback. 다른 주소는 사용자가 명시한 경우뿐이므로 한 줄로 분명히 알린다.
    err.writeln('${t(lang, 'prefix.warning')} ${t(lang, 'serve.nonloopback', {'address': addr.address})}');
  }
  await _waitForSignal();
  err.writeln(t(lang, 'serve.shutdown'));
  await proxy.close();
  return 0;
}

Future<int> _mockUpstream(ArgResults cmd, StringSink out, StringSink err, Lang lang) async {
  final errorPrefix = t(lang, 'prefix.error');
  final port = int.tryParse(cmd['port'] as String);
  final ctx = int.tryParse(cmd['default-ctx'] as String);
  final max = int.tryParse(cmd['model-max'] as String);
  if (port == null || ctx == null || max == null) {
    err.writeln('$errorPrefix ${t(lang, 'mock.not_integer')}');
    return 64;
  }
  final fake = FakeOllama(defaultCtx: ctx, modelMax: max);
  try {
    await fake.start(port: port);
  } on SocketException catch (e) {
    final msg = isAddressInUse(e)
        ? t(lang, 'mock.in_use', {'port': port})
        : t(lang, 'mock.listen_failed', {'port': port, 'detail': '${e.message}${_osDetail(e)}'});
    err.writeln('$errorPrefix $msg');
    return 2;
  }
  out.writeln(t(lang, 'mock.listening', {'port': fake.port, 'models': fake.models.join(', '), 'ctx': ctx}));
  await _waitForSignal();
  await fake.close();
  return 0;
}

/// 포트가 이미 쓰이는 중인가: 다른 프로세스면 OS 오류 EADDRINUSE(macOS 48, Linux 98, Windows 10048),
/// 같은 프로세스 안에서 두 번 바인딩하면 dart:io 가 OS 오류 없이 "binding multiple times" 로 알린다.
bool isAddressInUse(SocketException e) =>
    const {48, 98, 10048}.contains(e.osError?.errorCode) || e.toString().contains('binding multiple times');

String _osDetail(SocketException e) => e.osError == null ? '' : ' (${e.osError!.message})';

/// Ctrl-C(SIGINT) 또는 SIGTERM 을 기다린다.
Future<void> _waitForSignal() async {
  final stop = Completer<void>();
  final subs = <StreamSubscription<ProcessSignal>>[];
  void done(ProcessSignal _) {
    if (!stop.isCompleted) stop.complete();
  }

  subs.add(ProcessSignal.sigint.watch().listen(done));
  if (!Platform.isWindows) subs.add(ProcessSignal.sigterm.watch().listen(done));
  await stop.future;
  for (final s in subs) {
    await s.cancel();
  }
}

/// 테스트·임베드용: 로그를 모으는 서버 만들기.
ProxyServer proxyWithLog(CtxguardConfig config, void Function(String line) sink) => ProxyServer(
  config,
  log: AccessLog(format: config.logFormat, sink: sink),
);
