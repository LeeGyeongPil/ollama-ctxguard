// Screen-language support (English / Korean) for the human-facing CLI output.
//
// All user-visible sentences live in the two message tables below. Machine output
// (doctor --json, access log, HTTP bodies, exit codes) never goes through here.
// Korean sentences avoid fixed particles right after a placeholder ("{x} 가"),
// because the particle would be wrong for half of the possible values.

/// Screen language of the CLI.
enum Lang { en, ko }

/// A message key plus its parameters; can be nested inside another message's parameters.
class Msg {
  const Msg(this.code, [this.params = const {}]);
  final String code;
  final Map<String, Object?> params;

  String text(Lang lang) => t(lang, code, params);
}

/// Picks the language: `--lang` value > OLLAMA_CTXGUARD_LANG > LC_ALL > LC_MESSAGES > LANG.
/// A value starting with "ko" means Korean; anything else (unset, C, POSIX, unknown) is English.
Lang resolveLang({String? flag, Map<String, String> environment = const {}}) {
  if (flag == 'en') return Lang.en;
  if (flag == 'ko') return Lang.ko;
  for (final name in const ['OLLAMA_CTXGUARD_LANG', 'LC_ALL', 'LC_MESSAGES', 'LANG']) {
    final v = environment[name];
    if (v != null && v.trim().isNotEmpty) {
      return v.trim().toLowerCase().startsWith('ko') ? Lang.ko : Lang.en;
    }
  }
  return Lang.en;
}

final _placeholder = RegExp(r'\{(\w+)\}');

/// Looks up [key] in the table of [lang] and fills `{name}` placeholders from [params].
String t(Lang lang, String key, [Map<String, Object?> params = const {}]) {
  final table = lang == Lang.ko ? messagesKo : messagesEn;
  final template = table[key];
  if (template == null) {
    throw ArgumentError.value(key, 'key', 'unknown message key');
  }
  return template.replaceAllMapped(_placeholder, (m) {
    final name = m.group(1)!;
    if (!params.containsKey(name)) return m.group(0)!;
    final v = params[name];
    return v is Msg ? v.text(lang) : '$v';
  });
}

/// Display width in terminal cells (Hangul and other wide characters take two).
int displayWidth(String s) {
  var w = 0;
  for (final r in s.runes) {
    final wide =
        (r >= 0x1100 && r <= 0x115F) ||
        (r >= 0x2E80 && r <= 0xA4CF) ||
        (r >= 0xAC00 && r <= 0xD7A3) ||
        (r >= 0xF900 && r <= 0xFAFF) ||
        (r >= 0xFE30 && r <= 0xFE6F) ||
        (r >= 0xFF00 && r <= 0xFF60);
    w += wide ? 2 : 1;
  }
  return w;
}

/// Translates a package:args parse error into [lang]. English keeps the original text.
String localizeArgError(Lang lang, String message) {
  if (lang == Lang.en) return message;
  final rules = <(RegExp, String, List<String>)>[
    (RegExp(r'^Could not find an option (?:named|or flag) "(.*)"\.$'), 'args.unknown_option', ['name']),
    (RegExp(r'^Could not find an option with short name "(.*)"\.$'), 'args.unknown_option', ['name']),
    (RegExp(r'^Cannot negate option "(.*)"\.$'), 'args.cannot_negate', ['name']),
    (RegExp(r'^Could not find a command named "(.*)"\.$'), 'args.unknown_command', ['name']),
    (RegExp(r'^Missing argument for "(.*)"\.$'), 'args.missing_value', ['name']),
    (RegExp(r'^"(.*)" is not an allowed value for option "(.*)"\.$'), 'args.not_allowed', ['value', 'name']),
    (RegExp(r'^Flag option "(.*)" should not be given a value\.$'), 'args.flag_value', ['name']),
  ];
  for (final (re, key, names) in rules) {
    final m = re.firstMatch(message);
    if (m != null) {
      return t(lang, key, {for (var i = 0; i < names.length; i++) names[i]: m.group(i + 1)});
    }
  }
  return t(lang, 'args.generic', {'message': message});
}

const messagesEn = <String, String>{
  'prefix.error': 'error:',
  'prefix.warning': 'warning:',
  'prefix.config': 'config error:',
  'config.message': '{message}',
  'usage': '''
ollama-ctxguard {version} — apply per-model num_ctx to Ollama /v1 requests and flag silent truncation

usage:
  ollama-ctxguard serve   [--config ctxguard.yaml] [--upstream URL] [--listen 127.0.0.1:11435]
                          [--strict] [--log-format json|text] [--log-file PATH]
  ollama-ctxguard doctor  [--config ...] [--upstream URL] [--model NAME] [--json]
  ollama-ctxguard demo                         offline comparison (practice mock)
  ollama-ctxguard mock-upstream [--port 11434] [--default-ctx 4096]   practice mock Ollama

global option (before or after the command):
  --lang en|ko    screen language (default: OLLAMA_CTXGUARD_LANG, then LC_ALL / LC_MESSAGES / LANG)
''',
  'help.help': 'print usage',
  'help.version': 'print the version',
  'help.lang': 'screen language: en or ko',
  'help.config': 'YAML config file (default: ./ctxguard.yaml if present)',
  'help.upstream': 'Ollama URL (default http://127.0.0.1:11434)',
  'help.listen': 'host:port to listen on (default 127.0.0.1:11435)',
  'help.strict': 'turn "truncated" verdicts into errors (422 / stream error)',
  'help.log_format': 'access log format (default json)',
  'help.log_file': 'append the access log to this file instead of stderr',
  'help.model': 'check one model only',
  'help.json': 'print JSON instead of a table',
  'help.port': 'port for the practice mock',
  'help.default_ctx': 'context size /v1 requests get',
  'help.model_max': 'model max context reported by /api/show',
  'args.generic': '{message}',
  'args.unknown_option': 'Could not find an option named "{name}".',
  'args.unknown_command': 'Could not find a command named "{name}".',
  'args.cannot_negate': 'Cannot negate option "{name}".',
  'args.missing_value': 'Missing argument for "{name}".',
  'args.not_allowed': '"{value}" is not an allowed value for option "{name}".',
  'args.flag_value': 'Flag option "{name}" should not be given a value.',
  'lang.invalid': '"{value}" is not an allowed value for option "--lang" (allowed: en, ko).',
  'serve.listening':
      'ollama-ctxguard {version} listening on http://{host}:{port} '
      '-> upstream {upstream} ({rules} model rules, strict={strict})',
  'serve.nonloopback':
      'listening on a non-loopback address ({address}); anyone who can reach '
      'this port can use your local models. ctxguard has no authentication.',
  'serve.shutdown': 'shutting down',
  'serve.port_in_use':
      'cannot listen on {where}: port already in use (another ctxguard still running?); '
      'pick another with --listen {host}:<port>',
  'serve.listen_failed': 'cannot listen on {where}: {detail}',
  'mock.not_integer': '--port, --default-ctx and --model-max must be integers',
  'mock.in_use': 'cannot listen on 127.0.0.1:{port} (port already in use); is a real Ollama running? try --port 11500',
  'mock.listen_failed': 'cannot listen on 127.0.0.1:{port} ({detail}); is a real Ollama running? try --port 11500',
  'mock.listening':
      'practice mock (fake Ollama, no real model) listening on http://127.0.0.1:{port} '
      '— models: {models}; /v1 ignores num_ctx and uses {ctx}. Ctrl-C to stop.',
  'doctor.unreachable': 'cannot reach Ollama at {upstream} (is it running? set --upstream)',
  'doctor.header': 'Ollama {version} at {upstream}',
  'doctor.no_models': 'no models installed',
  'doctor.col_model': 'MODEL',
  'doctor.col_config': 'CONFIG',
  'doctor.col_model_max': 'MODEL MAX',
  'doctor.col_modelfile': 'MODELFILE',
  'doctor.col_loaded': 'LOADED',
  'doctor.col_v1': '/v1 DIRECT',
  'doctor.not_loaded': 'not loaded',
  'doctor.server_default': 'server default',
  'doctor.note_guess_1': '* guessed from the current load: a /v1 client gets the server default',
  'doctor.note_guess_2': '  (OLLAMA_CONTEXT_LENGTH or a VRAM-based default) unless the Modelfile sets num_ctx',
  'warn.not_found': 'model not found on this Ollama (ollama pull {model})',
  'warn.exceeds': 'config {config} exceeds model max {max} — Ollama caps it at {max}',
  'warn.v1_modelfile': '{value} (Modelfile)',
  'warn.v1_guess': 'the server default (probably {value}, the current load)',
  'warn.v1_default': 'the server default',
  'warn.no_setting':
      'no ctxguard setting — /v1 clients get {v1}'
      '; add a line under "models:" (for example "{glob}": {suggest})',
  'warn.reload': 'loaded at {loaded} but config says {config} — the next request through ctxguard reloads it',
  'demo.title': 'ollama-ctxguard demo — practice mock: a fake Ollama runs in this process, no real model is used',
  'demo.prompt': 'prompt: {bytes} bytes, "SECRET-CODE is 7731" at the very start; config: "qwen3:*": 16384',
  'demo.direct': 'direct /v1    : num_ctx={numCtx} prompt_tokens={tokens} verdict={verdict}  answer: {answer}',
  'demo.via': 'via ctxguard  : num_ctx={numCtx} prompt_tokens={tokens} verdict={verdict}  answer: {answer}',
  'demo.what_1': 'what happened: /v1 ignored num_ctx, loaded the model at 4096 and silently kept only',
  'demo.what_2': '{tokens} prompt tokens (about half of 4096), so the code at the start was lost.',
  'demo.what_3': 'ctxguard sent the same request to /api/chat with options.num_ctx=16384.',
  'demo.log_title': 'proxy log line (no prompt text is logged):',
  'config.file_not_found': 'file not found: {path}',
  'config.unreadable': 'cannot read {path} (must be a UTF-8 text file): {detail}',
  'config.invalid_yaml': '{source}: invalid YAML: {detail}',
  'config.top_mapping': '{source}: top level must be a mapping',
  'config.unknown_key': '{source}: unknown key "{key}" (allowed: {allowed})',
  'config.models_mapping': '{source}: "models" must be a mapping',
  'config.strict_bool': '{source}: "strict" must be true or false',
  'config.truncation_mapping': '{source}: "truncation" must be a mapping',
  'config.unknown_truncation_key': '{source}: unknown key "truncation.{key}"',
  'config.upstream_form': 'upstream must look like http://127.0.0.1:11434 (got "{raw}")',
  'config.listen_form': 'listen must look like 127.0.0.1:11435 (got "{raw}")',
  'config.log_format': 'log_format must be json or text (got "{raw}")',
  'config.must_string': '{source}: "{key}" must be a string',
  'config.int_range': '{source}: "{what}" must be an integer in [{min}, {max}] (got "{value}")',
  'config.positive': '{source}: "{what}" must be a positive number (got "{value}")',
};

const messagesKo = <String, String>{
  'prefix.error': '오류:',
  'prefix.warning': '경고:',
  'prefix.config': '설정 오류:',
  'config.message': '{message}',
  'usage': '''
ollama-ctxguard {version} — Ollama /v1 요청에 모델별 num_ctx 를 적용하고, 조용히 잘리는 프롬프트를 알려 줍니다

사용법:
  ollama-ctxguard serve   [--config ctxguard.yaml] [--upstream URL] [--listen 127.0.0.1:11435]
                          [--strict] [--log-format json|text] [--log-file PATH]
  ollama-ctxguard doctor  [--config ...] [--upstream URL] [--model NAME] [--json]
  ollama-ctxguard demo                         오프라인 비교 (연습용 목 모드)
  ollama-ctxguard mock-upstream [--port 11434] [--default-ctx 4096]   연습용 가짜 Ollama

공통 옵션 (명령 앞뒤 어디든 가능):
  --lang en|ko    화면 언어 (기본: OLLAMA_CTXGUARD_LANG, 그다음 LC_ALL / LC_MESSAGES / LANG)
''',
  'help.help': '사용법 출력',
  'help.version': '버전 출력',
  'help.lang': '화면 언어: en 또는 ko',
  'help.config': 'YAML 설정 파일 (기본: 있으면 ./ctxguard.yaml)',
  'help.upstream': 'Ollama 주소 (기본 http://127.0.0.1:11434)',
  'help.listen': '대기할 host:port (기본 127.0.0.1:11435)',
  'help.strict': '"truncated" 판정을 오류로 바꿈 (422 / 스트림 오류)',
  'help.log_format': '접근 로그 형식 (기본 json)',
  'help.log_file': '접근 로그를 stderr 대신 이 파일에 이어 씀',
  'help.model': '모델 하나만 점검',
  'help.json': '표 대신 JSON 출력',
  'help.port': '연습용 목 서버 포트',
  'help.default_ctx': '/v1 요청이 받는 컨텍스트 크기',
  'help.model_max': '/api/show 가 알려 주는 모델 최대 컨텍스트',
  'args.generic': '인자 오류: {message}',
  'args.unknown_option': '알 수 없는 옵션입니다: "{name}"',
  'args.unknown_command': '알 수 없는 하위 명령입니다: "{name}"',
  'args.cannot_negate': '이 옵션은 부정형(--no-)으로 쓸 수 없습니다: "{name}"',
  'args.missing_value': '옵션에 값이 없습니다: "{name}"',
  'args.not_allowed': '허용되지 않는 값입니다: "{value}" (옵션: "{name}")',
  'args.flag_value': '플래그에는 값을 줄 수 없습니다: "{name}"',
  'lang.invalid': '허용되지 않는 값입니다: "{value}" (옵션: "--lang", 허용: en, ko)',
  'serve.listening':
      'ollama-ctxguard {version} 시작 — 주소: http://{host}:{port}, '
      '업스트림: {upstream} (모델 규칙 {rules}개, strict={strict})',
  'serve.nonloopback':
      '루프백이 아닌 주소에서 대기 중입니다 (주소: {address}). 이 포트에 접근할 수 있는 사람은 '
      '누구나 로컬 모델을 쓸 수 있으며 ctxguard 에는 인증이 없습니다.',
  'serve.shutdown': '종료합니다',
  'serve.port_in_use':
      '대기할 수 없습니다 (주소: {where}): 포트가 이미 사용 중입니다 (다른 ctxguard 가 아직 실행 중인가요?). '
      '--listen {host}:<port> 로 다른 포트를 고르세요',
  'serve.listen_failed': '대기할 수 없습니다 (주소: {where}): {detail}',
  'mock.not_integer': '--port, --default-ctx, --model-max 는 정수여야 합니다',
  'mock.in_use':
      '대기할 수 없습니다 (주소: 127.0.0.1:{port}): 포트가 이미 사용 중입니다. '
      '진짜 Ollama 가 실행 중인가요? --port 11500 을 써 보세요',
  'mock.listen_failed':
      '대기할 수 없습니다 (주소: 127.0.0.1:{port}): {detail}. '
      '진짜 Ollama 가 실행 중인가요? --port 11500 을 써 보세요',
  'mock.listening':
      '연습용 목 서버 (가짜 Ollama, 실제 모델 없음) 대기 주소: http://127.0.0.1:{port} '
      '— 모델: {models}; /v1 은 num_ctx 를 무시하고 고정값을 씁니다 (고정값: {ctx}). 중지하려면 Ctrl-C 를 누르세요.',
  'doctor.unreachable': 'Ollama 에 연결할 수 없습니다 (주소: {upstream}). 실행 중인지 확인하고 --upstream 을 지정하세요',
  'doctor.header': 'Ollama {version} 접속 주소: {upstream}',
  'doctor.no_models': '설치된 모델이 없습니다',
  'doctor.col_model': '모델',
  'doctor.col_config': '설정',
  'doctor.col_model_max': '모델 최대',
  'doctor.col_modelfile': 'MODELFILE',
  'doctor.col_loaded': '로드됨',
  'doctor.col_v1': '/v1 직접',
  'doctor.not_loaded': '로드 안 됨',
  'doctor.server_default': '서버 기본값',
  'doctor.note_guess_1': '* 현재 로드 크기로 추정한 값입니다: /v1 클라이언트는 서버 기본값을 받습니다',
  'doctor.note_guess_2': '  (OLLAMA_CONTEXT_LENGTH 또는 VRAM 기반 기본값). 단 Modelfile 에 num_ctx 가 있으면 그 값입니다',
  'warn.not_found': '이 Ollama 에 모델이 없습니다 (ollama pull {model})',
  'warn.exceeds': '설정값이 모델 최대치를 넘어 Ollama 가 최대치로 제한합니다 (설정: {config}, 모델 최대: {max})',
  'warn.v1_modelfile': '{value} (Modelfile 값)',
  'warn.v1_guess': '서버 기본값 (현재 로드 크기 기준 추정: {value})',
  'warn.v1_default': '서버 기본값',
  'warn.no_setting':
      'ctxguard 설정이 없습니다 — /v1 클라이언트가 받는 값: {v1}'
      '. "models:" 아래에 줄을 추가하세요 (예: "{glob}": {suggest})',
  'warn.reload':
      '로드된 크기와 설정이 다릅니다 (로드: {loaded}, 설정: {config}). '
      'ctxguard 를 거치는 다음 요청에서 다시 로드됩니다',
  'demo.title': 'ollama-ctxguard 데모 — 연습용 목 모드: 가짜 Ollama 가 이 프로세스 안에서 돌며 실제 모델은 쓰지 않습니다',
  'demo.prompt': '프롬프트: {bytes} 바이트, 맨 앞에 "SECRET-CODE is 7731"; 설정: "qwen3:*": 16384',
  'demo.direct': '직접 /v1      : num_ctx={numCtx} prompt_tokens={tokens} verdict={verdict}  답변: {answer}',
  'demo.via': 'ctxguard 경유  : num_ctx={numCtx} prompt_tokens={tokens} verdict={verdict}  답변: {answer}',
  'demo.what_1': '무슨 일이 있었나: /v1 은 num_ctx 를 무시하고 모델을 4096 으로 로드했으며, 조용히',
  'demo.what_2': '프롬프트 토큰 {tokens} 개만 남겼습니다 (4096 의 절반 정도). 그래서 맨 앞의 코드가 사라졌습니다.',
  'demo.what_3': 'ctxguard 는 같은 요청을 options.num_ctx=16384 로 /api/chat 에 보냈습니다.',
  'demo.log_title': '프록시 로그 한 줄 (프롬프트 본문은 기록하지 않습니다):',
  'config.file_not_found': '파일을 찾을 수 없습니다: {path}',
  'config.unreadable': '파일을 읽을 수 없습니다 (UTF-8 텍스트 파일이어야 함): {path} / {detail}',
  'config.invalid_yaml': '{source}: YAML 형식이 올바르지 않습니다: {detail}',
  'config.top_mapping': '{source}: 최상위는 매핑이어야 합니다',
  'config.unknown_key': '{source}: 알 수 없는 키: "{key}" (허용: {allowed})',
  'config.models_mapping': '{source}: "models" 항목은 매핑이어야 합니다',
  'config.strict_bool': '{source}: "strict" 항목은 true 또는 false 여야 합니다',
  'config.truncation_mapping': '{source}: "truncation" 항목은 매핑이어야 합니다',
  'config.unknown_truncation_key': '{source}: 알 수 없는 키: "truncation.{key}"',
  'config.upstream_form': 'upstream 형식이 올바르지 않습니다. 예: http://127.0.0.1:11434 (입력: "{raw}")',
  'config.listen_form': 'listen 형식이 올바르지 않습니다. 예: 127.0.0.1:11435 (입력: "{raw}")',
  'config.log_format': 'log_format 은 json 또는 text 여야 합니다 (입력: "{raw}")',
  'config.must_string': '{source}: 문자열이어야 하는 항목: "{key}"',
  'config.int_range': '{source}: 정수여야 하며 범위는 [{min}, {max}] 입니다 (항목: "{what}", 입력: "{value}")',
  'config.positive': '{source}: 0보다 큰 숫자여야 합니다 (항목: "{what}", 입력: "{value}")',
};
