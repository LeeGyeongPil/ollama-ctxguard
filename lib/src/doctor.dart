// doctor: "이 모델은 지금 실제로 몇 칸짜리 컨텍스트로 돌고 있나"를 한 번에 본다.
//
// 비교하는 값
//   CONFIG     ctxguard.yaml 이 줄 값(프록시를 거치면 이 값이 적용된다)
//   MODEL MAX  모델 학습 최대 길이(/api/show model_info.<arch>.context_length)
//   MODELFILE  Modelfile 의 PARAMETER num_ctx(/api/show parameters)
//   LOADED     지금 메모리에 올라간 크기(/api/ps context_length)
//   /v1 DIRECT 프록시 없이 /v1 로 붙으면 받게 될 크기(Modelfile 값, 없으면 서버 기본값 추정)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';
import 'ctx_resolver.dart';
import 'i18n.dart';

/// 모델 한 개의 진단.
class ModelDiagnosis {
  ModelDiagnosis(this.model);
  final String model;
  int? configNumCtx;
  int? modelMax;
  int? modelfileNumCtx;
  int? loadedNumCtx;
  int? v1DirectNumCtx;

  /// /v1 직접 값의 근거: modelfile(확실) · current_load_guess(지금 로드 크기로 추정) · server_default_unknown.
  String v1DirectBasis = 'server_default_unknown';
  final List<String> warnings = [];

  /// Same warnings as [warnings] but as message keys, so the table can show them in the screen language.
  final List<Msg> warningMsgs = [];

  /// Records a warning: English text for [warnings] (JSON stays English), key for the table.
  void addWarning(Msg msg) {
    warnings.add(msg.text(Lang.en));
    warningMsgs.add(msg);
  }

  Map<String, Object?> toJson() => {
    'model': model,
    'config_num_ctx': configNumCtx,
    'model_max': modelMax,
    'modelfile_num_ctx': modelfileNumCtx,
    'loaded_num_ctx': loadedNumCtx,
    'v1_direct_num_ctx': v1DirectNumCtx,
    'v1_direct_basis': v1DirectBasis,
    'warnings': warnings,
  };
}

/// doctor 실행. 반환값은 종료 코드(0 정상, 2 업스트림 연결 실패·모델 없음).
Future<int> runDoctor({
  required CtxguardConfig config,
  String? model,
  bool json = false,
  required StringSink out,
  Lang lang = Lang.en,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final base = config.upstream;

    // 1) 서버가 살아 있는지 + 버전.
    // upstreamUrl: 역프록시 뒤 Ollama(http://host/ollama)의 경로 접두를 지킨다.
    final version = await _getJson(client, upstreamUrl(base, '/api/version'), timeout);
    if (version == null) {
      final msg = Msg('doctor.unreachable', {'upstream': base});
      if (json) {
        // 기계용 출력은 언제나 영어.
        out.writeln(jsonEncode({'upstream': '$base', 'error': msg.text(Lang.en)}));
      } else {
        out.writeln('${t(lang, 'prefix.error')} ${msg.text(lang)}');
      }
      return 2;
    }

    // 2) 어떤 모델을 볼지: --model 하나, 아니면 설치된 전체.
    final names = <String>[];
    if (model != null) {
      names.add(normalizeModelName(model));
    } else {
      final tags = await _getJson(client, upstreamUrl(base, '/api/tags'), timeout);
      final list = tags?['models'];
      if (list is List) {
        for (final m in list) {
          if (m is Map && m['name'] is String) names.add(normalizeModelName(m['name'] as String));
        }
      }
    }

    // 3) 실제 로드 크기(/api/ps).
    final loaded = await fetchLoaded(client, base, timeout: timeout) ?? const <String, int>{};

    var exit = 0;
    final diags = <ModelDiagnosis>[];
    for (final name in names) {
      final d = ModelDiagnosis(name)
        ..configNumCtx = config.numCtxFor(name)
        ..loadedNumCtx = loaded[name];

      final show = await _postJson(client, upstreamUrl(base, '/api/show'), {'model': name}, timeout);
      if (show == null) {
        d.addWarning(Msg('warn.not_found', {'model': name}));
        exit = 2;
        diags.add(d);
        continue;
      }
      d.modelMax = modelMaxFromShow(show);
      d.modelfileNumCtx = _modelfileNumCtx(show);

      // /v1 직접 = Modelfile 값(확실) > 설정과 다른 크기로 올라가 있으면 그 크기(추정: 프록시 밖의
      // 클라이언트가 서버 기본값으로 올렸을 가능성이 크다) > 모름. 서버 기본값(OLLAMA_CONTEXT_LENGTH·
      // VRAM 기반)을 알려 주는 API 가 없어서, 모델을 새로 올려 보지 않는 한 추정이 최선이다.
      if (d.modelfileNumCtx != null) {
        d.v1DirectNumCtx = d.modelfileNumCtx;
        d.v1DirectBasis = 'modelfile';
      } else if (d.loadedNumCtx != null && d.loadedNumCtx != d.configNumCtx) {
        d.v1DirectNumCtx = d.loadedNumCtx;
        d.v1DirectBasis = 'current_load_guess';
      }
      _warn(d);
      diags.add(d);
    }

    if (json) {
      out.writeln(
        const JsonEncoder.withIndent('  ').convert({
          'upstream': '$base',
          'ollama_version': version['version'],
          'models': [for (final d in diags) d.toJson()],
        }),
      );
    } else {
      _printTable(out, base, version['version'], diags, lang);
    }
    return exit;
  } finally {
    client.close(force: true);
  }
}

void _warn(ModelDiagnosis d) {
  final cfg = d.configNumCtx;
  if (cfg != null && d.modelMax != null && cfg > d.modelMax!) {
    d.addWarning(Msg('warn.exceeds', {'config': cfg, 'max': d.modelMax}));
  }
  if (cfg == null) {
    final v1 = switch (d.v1DirectBasis) {
      'modelfile' => Msg('warn.v1_modelfile', {'value': d.v1DirectNumCtx}),
      'current_load_guess' => Msg('warn.v1_guess', {'value': d.v1DirectNumCtx}),
      _ => const Msg('warn.v1_default'),
    };
    d.addWarning(Msg('warn.no_setting', {'v1': v1, 'glob': _globFor(d.model), 'suggest': _suggest(d)}));
  } else if (d.loadedNumCtx != null && d.loadedNumCtx != cfg) {
    d.addWarning(Msg('warn.reload', {'loaded': d.loadedNumCtx, 'config': cfg}));
  }
}

String _globFor(String model) {
  final i = model.indexOf(':');
  return i < 0 ? model : '${model.substring(0, i)}:*';
}

int _suggest(ModelDiagnosis d) {
  const want = 32768;
  final max = d.modelMax;
  return max != null && max < want ? max : want;
}

int? _modelfileNumCtx(Map<String, Object?> show) {
  final params = show['parameters'];
  if (params is! String) return null;
  for (final line in const LineSplitter().convert(params)) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length == 2 && parts[0] == 'num_ctx') return int.tryParse(parts[1]);
  }
  return null;
}

void _printTable(StringSink out, Uri base, Object? version, List<ModelDiagnosis> diags, Lang lang) {
  out.writeln(t(lang, 'doctor.header', {'version': version, 'upstream': base}));
  if (diags.isEmpty) {
    out.writeln(t(lang, 'doctor.no_models'));
    return;
  }
  String cell(int? v) => v?.toString() ?? '-';
  final rows = <List<String>>[
    [
      for (final k in const ['model', 'config', 'model_max', 'modelfile', 'loaded', 'v1']) t(lang, 'doctor.col_$k'),
    ],
    for (final d in diags)
      [
        d.model,
        cell(d.configNumCtx),
        cell(d.modelMax),
        cell(d.modelfileNumCtx),
        d.loadedNumCtx?.toString() ?? t(lang, 'doctor.not_loaded'),
        switch (d.v1DirectBasis) {
          'modelfile' => '${d.v1DirectNumCtx}',
          'current_load_guess' => '${d.v1DirectNumCtx}*',
          _ => t(lang, 'doctor.server_default'),
        },
      ],
  ];
  final widths = [
    for (var c = 0; c < rows.first.length; c++) rows.map((r) => displayWidth(r[c])).reduce((a, b) => a > b ? a : b),
  ];
  for (final r in rows) {
    out.writeln(
      [for (var c = 0; c < r.length; c++) r[c] + ' ' * (widths[c] - displayWidth(r[c]))].join('  ').trimRight(),
    );
  }
  if (diags.any((d) => d.v1DirectBasis == 'current_load_guess')) {
    out.writeln(t(lang, 'doctor.note_guess_1'));
    out.writeln(t(lang, 'doctor.note_guess_2'));
  }
  for (final d in diags) {
    for (final w in d.warningMsgs) {
      out.writeln('${t(lang, 'prefix.warning')} ${d.model}: ${w.text(lang)}');
    }
  }
}

Future<Map<String, Object?>?> _getJson(HttpClient client, Uri uri, Duration timeout) async {
  try {
    final req = await client.getUrl(uri).timeout(timeout);
    return await _readJson(await req.close().timeout(timeout), timeout);
  } on Object {
    return null;
  }
}

Future<Map<String, Object?>?> _postJson(HttpClient client, Uri uri, Map<String, Object?> body, Duration timeout) async {
  try {
    final req = await client.postUrl(uri).timeout(timeout);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode(body));
    return await _readJson(await req.close().timeout(timeout), timeout);
  } on Object {
    return null;
  }
}

Future<Map<String, Object?>?> _readJson(HttpClientResponse res, Duration timeout) async {
  final text = await utf8.decoder.bind(res).join().timeout(timeout);
  if (res.statusCode != 200) return null;
  final j = jsonDecode(text);
  return j is Map<String, Object?> ? j : null;
}
