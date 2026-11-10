// 명령줄: serve · doctor · demo · mock-upstream.
// 종료 코드: 0 정상, 2 설정 오류·업스트림 연결 실패, 64 인자 오류.

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import 'access_log.dart';
import 'config.dart';
import 'demo.dart';
import 'doctor.dart';
import 'mock/fake_ollama.dart';
import 'proxy_server.dart';

const packageVersion = '0.1.0';

/// 하위 명령 정의. 테스트에서도 같은 파서를 쓴다.
ArgParser buildParser() {
  final serve = ArgParser()
    ..addOption('config', abbr: 'c', help: 'YAML config file (default: ./ctxguard.yaml if present)')
    ..addOption('upstream', help: 'Ollama URL (default http://127.0.0.1:11434)')
    ..addOption('listen', help: 'host:port to listen on (default 127.0.0.1:11435)')
    ..addFlag('strict', negatable: false, help: 'turn "truncated" verdicts into errors (422 / stream error)')
    ..addOption('log-format', allowed: ['json', 'text'], help: 'access log format (default json)')
    ..addOption('log-file', help: 'append the access log to this file instead of stderr');
  final doctor = ArgParser()
    ..addOption('config', abbr: 'c', help: 'YAML config file (default: ./ctxguard.yaml if present)')
    ..addOption('upstream', help: 'Ollama URL (default http://127.0.0.1:11434)')
    ..addOption('model', abbr: 'm', help: 'check one model only')
    ..addFlag('json', negatable: false, help: 'print JSON instead of a table');
  final mock = ArgParser()
    ..addOption('port', defaultsTo: '11434', help: 'port for the practice mock')
    ..addOption('default-ctx', defaultsTo: '4096', help: 'context size /v1 requests get')
    ..addOption('model-max', defaultsTo: '40960', help: 'model max context reported by /api/show');
  return ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('version', negatable: false)
    ..addCommand('serve', serve)
    ..addCommand('doctor', doctor)
    ..addCommand('demo', ArgParser())
    ..addCommand('mock-upstream', mock);
}

const _usage =
    '''
ollama-ctxguard $packageVersion — apply per-model num_ctx to Ollama /v1 requests and flag silent truncation

usage:
  ollama-ctxguard serve   [--config ctxguard.yaml] [--upstream URL] [--listen 127.0.0.1:11435]
                          [--strict] [--log-format json|text] [--log-file PATH]
  ollama-ctxguard doctor  [--config ...] [--upstream URL] [--model NAME] [--json]
  ollama-ctxguard demo                         offline comparison (practice mock)
  ollama-ctxguard mock-upstream [--port 11434] [--default-ctx 4096]   practice mock Ollama
''';

/// CLI 진입점. 반환값이 종료 코드.
Future<int> runCli(List<String> args, {StringSink? out, StringSink? err}) async {
  out ??= stdout;
  err ??= stderr;
  final ArgResults parsed;
  try {
    parsed = buildParser().parse(args);
  } on FormatException catch (e) {
    err.writeln('error: ${e.message}\n\n$_usage');
    return 64;
  }
  if (parsed['version'] == true) {
    out.writeln(packageVersion);
    return 0;
  }
  final cmd = parsed.command;
  if (parsed['help'] == true || cmd == null) {
    (cmd == null && parsed['help'] != true ? err : out).write(_usage);
    return cmd == null && parsed['help'] != true ? 64 : 0;
  }

  try {
    switch (cmd.name) {
      case 'serve':
        return await _serve(loadServeConfig(cmd), err);
      case 'doctor':
        return await runDoctor(
          config: loadServeConfig(cmd),
          model: cmd['model'] as String?,
          json: cmd['json'] == true,
          out: out,
        );
      case 'demo':
        return await runDemo(out: out);
      case 'mock-upstream':
        return await _mockUpstream(cmd, out, err);
    }
  } on ConfigException catch (e) {
    err.writeln('error: $e');
    return 2;
  } on FormatException catch (e) {
    err.writeln('error: ${e.message}');
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

Future<int> _serve(CtxguardConfig config, StringSink err) async {
  final proxy = ProxyServer(config);
  try {
    await proxy.start();
  } on SocketException catch (e) {
    final where = '${config.listenHost}:${config.listenPort}';
    if (isAddressInUse(e)) {
      // 가장 흔한 원인 — 원인과 고치는 방법을 함께 알려 준다.
      err.writeln(
        'error: cannot listen on $where: port already in use (another ctxguard still running?); '
        'pick another with --listen ${config.listenHost}:<port>',
      );
    } else {
      err.writeln('error: cannot listen on $where: ${e.message}${_osDetail(e)}');
    }
    return 2;
  }
  final addr = proxy.address;
  err.writeln(
    'ollama-ctxguard $packageVersion listening on http://${config.listenHost}:${proxy.port} '
    '-> upstream ${config.upstream} (${config.models.length} model rules, strict=${config.strict})',
  );
  if (!addr.isLoopback) {
    // 기본은 loopback. 다른 주소는 사용자가 명시한 경우뿐이므로 한 줄로 분명히 알린다.
    err.writeln(
      'warning: listening on a non-loopback address (${addr.address}); anyone who can reach '
      'this port can use your local models. ctxguard has no authentication.',
    );
  }
  await _waitForSignal();
  err.writeln('shutting down');
  await proxy.close();
  return 0;
}

Future<int> _mockUpstream(ArgResults cmd, StringSink out, StringSink err) async {
  final port = int.tryParse(cmd['port'] as String);
  final ctx = int.tryParse(cmd['default-ctx'] as String);
  final max = int.tryParse(cmd['model-max'] as String);
  if (port == null || ctx == null || max == null) {
    err.writeln('error: --port, --default-ctx and --model-max must be integers');
    return 64;
  }
  final fake = FakeOllama(defaultCtx: ctx, modelMax: max);
  try {
    await fake.start(port: port);
  } on SocketException catch (e) {
    final why = isAddressInUse(e) ? 'port already in use' : '${e.message}${_osDetail(e)}';
    err.writeln('error: cannot listen on 127.0.0.1:$port ($why); is a real Ollama running? try --port 11500');
    return 2;
  }
  out.writeln(
    'practice mock (fake Ollama, no real model) listening on http://127.0.0.1:${fake.port} '
    '— models: ${fake.models.join(', ')}; /v1 ignores num_ctx and uses $ctx. Ctrl-C to stop.',
  );
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
