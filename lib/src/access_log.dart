// 접근 로그 — 허용 필드 화이트리스트로만 기록한다.
//
// 요청·응답 본문, 헤더(특히 Authorization)는 어떤 경로로도 로그에 들어가지 않는다.
// 호출하는 쪽이 실수로 다른 키를 넘겨도 여기서 버린다.

import 'dart:convert';
import 'dart:io';

import 'config.dart';

/// 로그 한 줄에 허용된 필드(순서도 이대로 쓴다).
const allowedLogFields = [
  'ts',
  'method',
  'path',
  'model',
  'stream',
  'status',
  'num_ctx',
  'num_ctx_source',
  'prompt_tokens',
  'est_prompt_tokens',
  'verdict',
  'reason',
  'ms',
  'event',
];

/// 요청마다 한 줄을 쓰는 로거. [sink] 를 바꾸면 테스트에서 줄을 모을 수 있다.
class AccessLog {
  AccessLog({this.format = LogFormat.json, void Function(String line)? sink})
    : _sink = sink ?? ((line) => stderr.writeln(line));

  /// `--log-file` 용: 파일에 덧붙이고 [maxBytes] 를 넘으면 `<path>.1` 로 한 번 돌린다.
  factory AccessLog.toFile(String path, {LogFormat format = LogFormat.json, int maxBytes = 10 << 20}) {
    final file = File(path);
    return AccessLog(
      format: format,
      sink: (line) {
        if (file.existsSync() && file.lengthSync() > maxBytes) {
          file.renameSync('$path.1'); // 로그 파일이 끝없이 커지지 않게 한 개만 보관.
        }
        file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
      },
    );
  }

  final LogFormat format;
  final void Function(String line) _sink;

  /// [fields] 중 허용 필드만 골라 한 줄로 쓴다. 값이 null 인 필드는 뺀다.
  void write(Map<String, Object?> fields) {
    final clean = <String, Object?>{'ts': DateTime.now().toUtc().toIso8601String()};
    for (final key in allowedLogFields) {
      if (key == 'ts') continue;
      final v = fields[key];
      if (v == null) continue;
      clean[key] = v is String ? _clip(v) : v;
    }
    _sink(format == LogFormat.json ? jsonEncode(clean) : _text(clean));
  }

  String _text(Map<String, Object?> f) {
    final event = f['event'];
    final level = (event == null || event == 'request') ? 'INFO' : 'WARN';
    final parts = <String>[f['ts'].toString(), level];
    f.forEach((k, v) {
      if (k == 'ts') return;
      parts.add('$k=${_textValue(v)}');
    });
    return parts.join(' ');
  }

  /// 텍스트 형식 값: 공백·'='·따옴표·역슬래시가 있는 문자열은 JSON 문자열로 감싼다.
  /// (모델 이름에 "x verdict=ok" 를 넣어 가짜 필드를 만드는 것을 막는다.)
  static String _textValue(Object? v) {
    if (v is! String) return '$v';
    if (v.isEmpty || v.contains(RegExp(r'[\s="\\]'))) return jsonEncode(v);
    return v;
  }

  // 모델 이름·경로처럼 사용자가 정하는 문자열은 길이를 제한하고 줄바꿈을 없앤다.
  static String _clip(String s) {
    final one = s.replaceAll(RegExp(r'[\r\n\t]'), ' ');
    return one.length > 200 ? '${one.substring(0, 200)}...' : one;
  }
}
