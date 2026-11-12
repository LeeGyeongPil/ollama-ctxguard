// 설정 읽기·검증과 모델 이름 글롭 매칭.

import 'dart:io';

import 'package:yaml/yaml.dart';

import 'i18n.dart';
import 'truncation.dart';

/// 설정이 잘못됐을 때(종료 코드 2).
class ConfigException implements Exception {
  /// [message] stays English for library users; the CLI shows [code] + [params] in the screen language.
  ConfigException(this.message, {this.code = 'config.message', this.params = const {}});

  /// Builds the English message from the message table, keeping [code] and [params] for the CLI.
  factory ConfigException.coded(String code, [Map<String, Object?> params = const {}]) =>
      ConfigException(t(Lang.en, code, params), code: code, params: params);

  final String message;

  /// Message-table key and its parameters (used to localize at the CLI boundary).
  final String code;
  final Map<String, Object?> params;

  /// Text for the CLI in [lang] (without the "error:" prefix).
  String localized(Lang lang) =>
      '${t(lang, 'prefix.config')} ${code == 'config.message' ? message : t(lang, code, params)}';

  @override
  String toString() => 'config error: $message';
}

/// 로그 형식.
enum LogFormat { json, text }

/// 프록시 전체 설정. 명령줄 옵션은 [withOverrides] 로 덮어쓴다.
class CtxguardConfig {
  CtxguardConfig({
    Uri? upstream,
    this.listenHost = '127.0.0.1',
    this.listenPort = 11435,
    Map<String, int>? models,
    this.defaultNumCtx,
    this.strict = false,
    this.truncation = const TruncationSettings(),
    this.upstreamTimeout = const Duration(seconds: 600),
    this.logFormat = LogFormat.json,
    this.logFile,
  }) : upstream = upstream ?? Uri.parse('http://127.0.0.1:11434'),
       models = Map.unmodifiable(models ?? const <String, int>{});

  /// Ollama 주소(기본 http://127.0.0.1:11434).
  final Uri upstream;

  /// 기본은 loopback. 다른 주소는 사용자가 명시할 때만.
  final String listenHost;
  final int listenPort;

  /// 모델 이름 또는 글롭(`*`, `?`) → num_ctx.
  final Map<String, int> models;

  /// 목록에 없는 모델에 쓸 값. null 이면 손대지 않는다(서버 기본값 그대로).
  final int? defaultNumCtx;

  /// true 면 `truncated` 판정을 오류로 바꾼다.
  final bool strict;
  final TruncationSettings truncation;

  /// 업스트림 응답 헤더를 기다리는 최대 시간(모델 로드가 수십 초 걸릴 수 있어 넉넉히).
  final Duration upstreamTimeout;
  final LogFormat logFormat;
  final String? logFile;

  static const _topKeys = {
    'upstream',
    'listen',
    'models',
    'default',
    'strict',
    'truncation',
    'upstream_timeout_seconds',
    'log_format',
    'log_file',
  };
  static const _truncKeys = {'keep_slack', 'bytes_per_token', 'ratio', 'reserve'};

  /// [path] 의 YAML 을 읽는다. 파일이 없으면 [ConfigException].
  static CtxguardConfig load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw ConfigException.coded('config.file_not_found', {'path': path});
    }
    final String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException catch (e) {
      // Non-UTF-8 bytes, a directory, or a permission problem: report as a config error, not a crash.
      throw ConfigException.coded('config.unreadable', {'path': path, 'detail': e.message});
    }
    return fromYamlString(text, source: path);
  }

  /// YAML 문자열을 검증하며 읽는다. 모르는 키는 오타일 가능성이 커서 오류로 본다.
  static CtxguardConfig fromYamlString(String text, {String source = '<string>'}) {
    final Object? doc;
    try {
      doc = loadYaml(text);
    } on YamlException catch (e) {
      throw ConfigException.coded('config.invalid_yaml', {'source': source, 'detail': e.message});
    }
    if (doc == null) return CtxguardConfig();
    if (doc is! YamlMap) throw ConfigException.coded('config.top_mapping', {'source': source});

    for (final k in doc.keys) {
      if (!_topKeys.contains(k)) {
        throw ConfigException.coded('config.unknown_key', {'source': source, 'key': k, 'allowed': _topKeys.join(', ')});
      }
    }

    Uri? upstream;
    if (doc['upstream'] != null) upstream = parseUpstream(_str(doc, 'upstream', source));

    var host = '127.0.0.1';
    var port = 11435;
    if (doc['listen'] != null) {
      (host, port) = parseListen(_str(doc, 'listen', source));
    }

    final models = <String, int>{};
    final rawModels = doc['models'];
    if (rawModels != null) {
      if (rawModels is! YamlMap) throw ConfigException.coded('config.models_mapping', {'source': source});
      rawModels.forEach((k, v) {
        models[k.toString()] = _numCtx(v, 'models["$k"]', source);
      });
    }

    final defaultNumCtx = doc['default'] == null ? null : _numCtx(doc['default'], 'default', source);

    final strict = doc['strict'] ?? false;
    if (strict is! bool) throw ConfigException.coded('config.strict_bool', {'source': source});

    var trunc = const TruncationSettings();
    final rawTrunc = doc['truncation'];
    if (rawTrunc != null) {
      if (rawTrunc is! YamlMap) throw ConfigException.coded('config.truncation_mapping', {'source': source});
      for (final k in rawTrunc.keys) {
        if (!_truncKeys.contains(k)) {
          throw ConfigException.coded('config.unknown_truncation_key', {'source': source, 'key': k});
        }
      }
      trunc = TruncationSettings(
        keepSlack: _int(rawTrunc['keep_slack'] ?? 8, 'truncation.keep_slack', source, min: 0),
        bytesPerToken: _double(rawTrunc['bytes_per_token'] ?? 6, 'truncation.bytes_per_token', source),
        ratio: _double(rawTrunc['ratio'] ?? 1.2, 'truncation.ratio', source),
        reserve: _int(rawTrunc['reserve'] ?? 512, 'truncation.reserve', source, min: 0),
      );
    }

    final timeout = _int(doc['upstream_timeout_seconds'] ?? 600, 'upstream_timeout_seconds', source, min: 1);

    final logFormat = parseLogFormat((doc['log_format'] ?? 'json').toString());
    final logFile = doc['log_file']?.toString();

    return CtxguardConfig(
      upstream: upstream,
      listenHost: host,
      listenPort: port,
      models: models,
      defaultNumCtx: defaultNumCtx,
      strict: strict,
      truncation: trunc,
      upstreamTimeout: Duration(seconds: timeout),
      logFormat: logFormat,
      logFile: logFile,
    );
  }

  /// 명령줄 옵션 덮어쓰기(설정 파일보다 우선). null 인 항목은 그대로 둔다.
  CtxguardConfig withOverrides({
    Uri? upstream,
    String? listenHost,
    int? listenPort,
    bool? strict,
    LogFormat? logFormat,
    String? logFile,
    Map<String, int>? models,
  }) => CtxguardConfig(
    upstream: upstream ?? this.upstream,
    listenHost: listenHost ?? this.listenHost,
    listenPort: listenPort ?? this.listenPort,
    models: models ?? this.models,
    defaultNumCtx: defaultNumCtx,
    strict: strict ?? this.strict,
    truncation: truncation,
    upstreamTimeout: upstreamTimeout,
    logFormat: logFormat ?? this.logFormat,
    logFile: logFile ?? this.logFile,
  );

  /// 이 모델에 줄 num_ctx. 정확 일치 > 가장 구체적인 글롭 > default > null.
  int? numCtxFor(String model) {
    final name = normalizeModelName(model);
    String? bestPattern;
    var bestScore = -1;
    for (final entry in models.entries) {
      final pattern = _normalizePattern(entry.key);
      if (pattern == name) return entry.value; // 정확 일치가 항상 이긴다.
      if (!_hasWildcard(pattern)) continue;
      if (!globMatch(pattern, name)) continue;
      // 글자(와일드카드 제외)가 많을수록 구체적인 패턴으로 본다.
      final score = pattern.replaceAll(RegExp(r'[*?]'), '').length;
      if (score > bestScore) {
        bestScore = score;
        bestPattern = entry.key;
      }
    }
    if (bestPattern != null) return models[bestPattern];
    return defaultNumCtx;
  }
}

/// 태그 없는 이름은 Ollama 처럼 `:latest` 를 붙여 같은 모델로 본다.
String normalizeModelName(String name) {
  final n = name.trim();
  final lastSlash = n.lastIndexOf('/');
  final tail = lastSlash < 0 ? n : n.substring(lastSlash + 1);
  if (tail.isEmpty || tail.contains(':')) return n;
  return '$n:latest';
}

String _normalizePattern(String p) => _hasWildcard(p) ? p.trim() : normalizeModelName(p);

bool _hasWildcard(String p) => p.contains('*') || p.contains('?');

/// `*`(0자 이상)·`?`(1자) 글롭. 나머지 글자는 그대로 비교한다.
bool globMatch(String pattern, String text) {
  final buf = StringBuffer('^');
  for (final rune in pattern.runes) {
    final ch = String.fromCharCode(rune);
    if (ch == '*') {
      buf.write('.*');
    } else if (ch == '?') {
      buf.write('.');
    } else {
      buf.write(RegExp.escape(ch));
    }
  }
  buf.write(r'$');
  return RegExp(buf.toString()).hasMatch(text);
}

/// `http://host:port` 형식만 받는다.
Uri parseUpstream(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
    throw ConfigException.coded('config.upstream_form', {'raw': raw});
  }
  return uri;
}

/// 업스트림 기준 주소에 API 경로를 붙인다. 업스트림 주소의 경로 접두는 유지한다
/// (`http://host/ollama` + `/api/ps` → `http://host/ollama/api/ps`). `Uri.resolve('/api/ps')`
/// 는 접두를 버리므로 업스트림으로 가는 모든 요청(프록시·/api/ps·doctor·demo)이 이 함수를 쓴다.
Uri upstreamUrl(Uri base, String path, {String query = ''}) {
  final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
  return base.replace(path: '$prefix$path', query: query.isEmpty ? null : query);
}

/// `host:port`, `[::1]:port`, 또는 포트만.
(String, int) parseListen(String raw) {
  final s = raw.trim();
  String host;
  String portText;
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    if (end < 0 || end + 1 >= s.length || s[end + 1] != ':') {
      throw ConfigException.coded('config.listen_form', {'raw': raw});
    }
    host = s.substring(1, end);
    portText = s.substring(end + 2);
  } else if (!s.contains(':')) {
    host = '127.0.0.1';
    portText = s;
  } else {
    final i = s.lastIndexOf(':');
    host = s.substring(0, i);
    portText = s.substring(i + 1);
  }
  final port = int.tryParse(portText);
  if (host.isEmpty || port == null || port < 0 || port > 65535) {
    throw ConfigException.coded('config.listen_form', {'raw': raw});
  }
  return (host, port);
}

LogFormat parseLogFormat(String raw) => switch (raw) {
  'json' => LogFormat.json,
  'text' => LogFormat.text,
  _ => throw ConfigException.coded('config.log_format', {'raw': raw}),
};

String _str(YamlMap m, String key, String source) {
  final v = m[key];
  if (v is! String) throw ConfigException.coded('config.must_string', {'source': source, 'key': key});
  return v;
}

int _numCtx(Object? v, String what, String source) => _int(v, what, source, min: 256, max: 4194304);

int _int(Object? v, String what, String source, {int min = 0, int max = 1 << 31}) {
  if (v is! int || v < min || v > max) {
    throw ConfigException.coded('config.int_range', {
      'source': source,
      'what': what,
      'min': min,
      'max': max,
      'value': v,
    });
  }
  return v;
}

double _double(Object? v, String what, String source) {
  if (v is! num || v <= 0) {
    throw ConfigException.coded('config.positive', {'source': source, 'what': what, 'value': v});
  }
  return v.toDouble();
}
