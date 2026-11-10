// 실효 num_ctx 결정과 출처.
//
// 우선순위: 요청이 직접 준 값(네이티브만) > 설정 파일 > (둘 다 없으면) 응답 뒤
// Ollama /api/ps 가 보고하는 실제 로드 크기 > 모름(unknown).
//
// 단, 요청·설정 값이 모델 학습 최대 길이보다 크면 Ollama 가 최대로 줄여서 로드한다
// (ollama llm/server.go "requested context size too large for model", 2026-11-11 확인).
// 그래서 판정에는 min(값, 모델 최대) 를 쓴다 — 큰 설정값으로 판정하면 작은 창의
// 잘림 서명을 놓친다. 모델 최대는 /api/show 로 읽는다(모델 파일 정보라 바뀌지 않음).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'config.dart';

/// num_ctx 출처 이름(헤더·로그·ctxguard 필드에 그대로 쓴다).
abstract final class NumCtxSource {
  static const request = 'request';
  static const config = 'config';
  static const ollamaPs = 'ollama_ps';

  /// 설정·요청 값이 모델 최대를 넘어 Ollama 가 최대로 줄인 경우(판정도 최대로 한다).
  static const modelMax = 'model_max';
  static const unknown = 'unknown';
}

/// `/api/ps` 의 context_length 를 모델별로 잠깐(기본 30초), `/api/show` 의 모델 최대 길이를
/// 조금 길게(기본 10분) 기억한다.
class CtxResolver {
  CtxResolver({
    required this.upstream,
    required HttpClient client,
    this.ttl = const Duration(seconds: 30),
    this.maxTtl = const Duration(minutes: 10),
    this.maxEntries = 256,
    this.timeout = const Duration(seconds: 5),
  }) : _client = client;

  final Uri upstream;
  final HttpClient _client;
  final Duration ttl;

  /// 모델 최대 길이 캐시 유지 시간(모델을 다시 pull 하면 바뀔 수 있어 영구 보관은 하지 않는다).
  final Duration maxTtl;

  /// 캐시 상한 — 넘으면 비운다(모델 이름이 끝없이 쌓이지 않게).
  final int maxEntries;
  final Duration timeout;
  final _cache = <String, (int, DateTime)>{};
  final _maxCache = <String, (int, DateTime)>{};

  /// 모델이 지금 실제로 몇으로 올라가 있는지. 모르면 null.
  Future<int?> loadedContext(String model) async {
    final key = normalizeModelName(model);
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$2) < ttl) return hit.$1;

    final loaded = await fetchLoaded(_client, upstream, timeout: timeout);
    if (loaded == null) return null;
    if (_cache.length >= maxEntries) _cache.clear();
    final now = DateTime.now();
    loaded.forEach((name, ctx) => _cache[name] = (ctx, now));
    return loaded[key];
  }

  /// 모델 학습 최대 길이(/api/show). 모르면 null — 실패는 캐시하지 않는다.
  Future<int?> modelMax(String model) async {
    final key = normalizeModelName(model);
    final hit = _maxCache[key];
    if (hit != null && DateTime.now().difference(hit.$2) < maxTtl) return hit.$1;

    final max = await fetchModelMax(_client, upstream, key, timeout: timeout);
    if (max == null) return null;
    if (_maxCache.length >= maxEntries) _maxCache.clear();
    _maxCache[key] = (max, DateTime.now());
    return max;
  }

  /// 판정에 쓸 num_ctx 와 출처.
  ///  - [known](요청·설정 값)이 있으면 모델 최대와 비교해 작은 쪽. 줄었으면 출처는 model_max.
  ///  - 없으면 /api/ps 의 실제 로드 크기, 그것도 없으면 unknown.
  Future<(int?, String)> effective(String model, int? known, String knownSource) async {
    if (known != null) {
      final max = await modelMax(model);
      if (max != null && known > max) return (max, NumCtxSource.modelMax);
      return (known, knownSource);
    }
    final loaded = await loadedContext(model);
    return loaded != null ? (loaded, NumCtxSource.ollamaPs) : (null, NumCtxSource.unknown);
  }
}

/// GET /api/ps → {정규화한 모델 이름: context_length}. 실패하면 null.
Future<Map<String, int>?> fetchLoaded(
  HttpClient client,
  Uri upstream, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    final req = await client.getUrl(upstreamUrl(upstream, '/api/ps')).timeout(timeout);
    final res = await req.close().timeout(timeout);
    final text = await utf8.decoder.bind(res).join().timeout(timeout);
    if (res.statusCode != 200) return null;
    final j = jsonDecode(text);
    if (j is! Map || j['models'] is! List) return null;
    final out = <String, int>{};
    for (final m in j['models'] as List) {
      if (m is! Map) continue;
      final ctx = m['context_length'];
      if (ctx is! int || ctx <= 0) continue;
      for (final field in ['name', 'model']) {
        if (m[field] is String) out[normalizeModelName(m[field] as String)] = ctx;
      }
    }
    return out;
  } on Object {
    return null; // 연결 실패·시간 초과·JSON 오류 모두 "모름".
  }
}

/// POST /api/show {"model"} → 모델 학습 최대 길이. 실패하면 null.
Future<int?> fetchModelMax(
  HttpClient client,
  Uri upstream,
  String model, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    final req = await client.postUrl(upstreamUrl(upstream, '/api/show')).timeout(timeout);
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'model': model}));
    final res = await req.close().timeout(timeout);
    final text = await utf8.decoder.bind(res).join().timeout(timeout);
    if (res.statusCode != 200) return null;
    final j = jsonDecode(text);
    return j is Map<String, Object?> ? modelMaxFromShow(j) : null;
  } on Object {
    return null;
  }
}

/// /api/show 응답의 `model_info.<arch>.context_length`.
int? modelMaxFromShow(Map<String, Object?> show) {
  final info = show['model_info'];
  if (info is! Map) return null;
  final arch = info['general.architecture'];
  final v = arch is String ? info['$arch.context_length'] : null;
  return v is int && v > 0 ? v : null;
}
