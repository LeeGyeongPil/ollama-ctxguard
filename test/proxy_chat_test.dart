import 'dart:convert';

import 'package:ollama_ctxguard/ollama_ctxguard.dart';
import 'package:test/test.dart';

import 'support/harness.dart';

Map<String, Object?> _json(String body) => jsonDecode(body) as Map<String, Object?>;
Map<String, Object?> _choice(Map<String, Object?> j) => (j['choices'] as List).first as Map<String, Object?>;

void main() {
  group('AC-1 non-streaming /v1/chat/completions -> /api/chat with num_ctx', () {
    late Harness h;
    setUp(() async => h = await Harness.start(models: {'qwen3:*': 16384}));
    tearDown(() => h.close());

    test('AC-1 configured model: num_ctx reaches Ollama and is really loaded', () async {
      final (res, body) = await h.post('/v1/chat/completions', {
        'model': 'qwen3:4b',
        'messages': [
          {'role': 'system', 'content': 'be brief'},
          {'role': 'user', 'content': 'hello there'},
        ],
        'max_tokens': 64,
        'stop': ['\n\n', 'END'],
        'temperature': 0.2,
        'top_p': 0.9,
        'seed': 7,
        'response_format': {'type': 'json_object'},
      });
      expect(res.statusCode, 200);

      // 가짜 Ollama 가 실제로 받은 /api/chat 본문을 검사한다(요청에 넣었는지만 보면 함정).
      final sent = h.fake.lastBody('/api/chat')!;
      final options = sent['options'] as Map;
      expect(options['num_ctx'], 16384);
      expect(options['num_predict'], 64);
      expect(options['stop'], ['\n\n', 'END']);
      expect(options['temperature'], 0.2);
      expect(options['top_p'], 0.9);
      expect(options['seed'], 7);
      expect(sent['format'], 'json');
      expect(sent['stream'], false);
      expect(h.fake.lastBody('/v1/chat/completions'), isNull, reason: 'the /v1 path is never used');

      // 가짜 /api/ps 도 16384 로 로드됐다고 보고한다.
      final (_, ps) = await h.getBytes('/api/ps', base: h.fake.uri);
      final loaded = ((_json(utf8.decode(ps))['models'] as List).single as Map)['context_length'];
      expect(loaded, 16384);

      final j = _json(body);
      expect(j['object'], 'chat.completion');
      expect(_choice(j)['finish_reason'], 'stop');
      expect((_choice(j)['message'] as Map)['role'], 'assistant');
      final usage = j['usage'] as Map;
      // 가짜 토크나이저: 단어 + 메시지당 4 → (2+4) + (2+4) = 12
      expect(usage['prompt_tokens'], 12);
      expect(usage['total_tokens'], (usage['prompt_tokens'] as int) + (usage['completion_tokens'] as int));

      expect(res.headers.value('X-Ctxguard-Verdict'), 'ok');
      expect(res.headers.value('X-Ctxguard-Num-Ctx'), '16384');
      expect(res.headers.value('X-Ctxguard-Num-Ctx-Source'), 'config');
      expect(res.headers.value('X-Ctxguard-Prompt-Tokens'), '12');
      expect((j['ctxguard'] as Map)['verdict'], 'ok');
    });

    test('AC-1 unconfigured model: no num_ctx is sent; size comes from /api/ps', () async {
      final (res, _) = await h.post('/v1/chat/completions', userChat('hi', model: 'llama3.2:3b'));
      expect(res.statusCode, 200);
      final sent = h.fake.lastBody('/api/chat')!;
      expect((sent['options'] as Map?)?.containsKey('num_ctx') ?? false, isFalse);
      expect(res.headers.value('X-Ctxguard-Num-Ctx'), '4096');
      expect(res.headers.value('X-Ctxguard-Num-Ctx-Source'), 'ollama_ps');
    });

    test('AC-1 json_schema, max_completion_tokens, reasoning_effort, penalties, single stop', () async {
      final schema = {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
        },
      };
      await h.post('/v1/chat/completions', {
        ...userChat('x'),
        'max_completion_tokens': 10,
        'stop': 'END',
        'frequency_penalty': 0.5,
        'presence_penalty': 0.25,
        'reasoning_effort': 'none',
        'response_format': {
          'type': 'json_schema',
          'json_schema': {'name': 's', 'schema': schema},
        },
      });
      final sent = h.fake.lastBody('/api/chat')!;
      expect(sent['format'], schema);
      expect(sent['think'], false);
      final options = sent['options'] as Map;
      expect(options['num_predict'], 10);
      expect(options['stop'], ['END']);
      expect(options['frequency_penalty'], 0.5);
      expect(options['presence_penalty'], 0.25);
    });

    test('AC-1 tools, assistant tool_calls, tool results and data-URL images are mapped', () async {
      final tools = [
        {
          'type': 'function',
          'function': {
            'name': 'get_weather',
            'parameters': {'type': 'object'},
          },
        },
      ];
      await h.post('/v1/chat/completions', {
        'model': 'qwen3:4b',
        'tools': tools,
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'what is this'},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/png;base64,AAAA'},
              },
            ],
          },
          {
            'role': 'assistant',
            'content': null,
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'get_weather', 'arguments': '{"city":"Seoul"}'},
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'sunny'},
        ],
      });
      final sent = h.fake.lastBody('/api/chat')!;
      expect(sent['tools'], tools);
      final msgs = sent['messages'] as List;
      expect((msgs[0] as Map)['content'], 'what is this');
      expect((msgs[0] as Map)['images'], ['AAAA']);
      final call = ((msgs[1] as Map)['tool_calls'] as List).single as Map;
      expect((call['function'] as Map)['arguments'], {'city': 'Seoul'}, reason: 'JSON string -> object');
      expect((msgs[2] as Map)['tool_name'], 'get_weather');
      expect((msgs[2] as Map)['tool_call_id'], 'call_1');
    });

    test('AC-1 tool call and thinking responses come back in OpenAI shape', () async {
      h.fake.scenario
        ..toolCallName = 'get_weather'
        ..thinking = 'let me think';
      final (_, body) = await h.post('/v1/chat/completions', userChat('weather?'));
      final c = _choice(_json(body));
      expect(c['finish_reason'], 'tool_calls');
      final msg = c['message'] as Map;
      expect(msg['reasoning'], 'let me think');
      final call = (msg['tool_calls'] as List).single as Map;
      expect(call['type'], 'function');
      expect(call['id'], 'call_mock1');
      expect((call['function'] as Map)['name'], 'get_weather');
      expect((call['function'] as Map)['arguments'], '{"city":"Seoul"}');
    });

    test('AC-1 malformed requests get 400 in OpenAI error format', () async {
      for (final bad in <Object>[
        'not json',
        {'messages': <Object?>[]},
        {'model': 'qwen3:4b'},
        {
          'model': 'qwen3:4b',
          'messages': [
            {
              'role': 'user',
              'content': [
                {
                  'type': 'image_url',
                  'image_url': {'url': 'https://example.com/a.png'},
                },
              ],
            },
          ],
        },
      ]) {
        final (res, body) = await h.post('/v1/chat/completions', bad);
        expect(res.statusCode, 400, reason: '$bad');
        expect((_json(body)['error'] as Map)['type'], 'invalid_request_error');
      }
    });
  });

  group('AC-4 unknown verdicts through the proxy', () {
    Future<void> expectUnknown(Harness h, String reason, {String model = 'qwen3:4b'}) async {
      final (res, _) = await h.post('/v1/chat/completions', userChat(words(6000), model: model));
      // strict 모드여도 막지 않는다.
      expect(res.statusCode, 200);
      expect(res.headers.value('X-Ctxguard-Verdict'), 'unknown');
      expect(res.headers.value('X-Ctxguard-Reason'), reason);
      await h.waitLogs(1);
      // 경고 로그 정확히 1줄.
      final warn = h.logJson.where((l) => l['event'] == 'ctx_warning').toList();
      expect(warn, hasLength(1));
      expect(warn.single['verdict'], 'unknown');
      expect(warn.single['reason'], reason);
    }

    for (final (mode, reason) in [
      (PromptEvalMode.omit, Reason.noPromptEvalCount),
      (PromptEvalMode.zero, Reason.invalidPromptEvalCount),
      (PromptEvalMode.negative, Reason.invalidPromptEvalCount),
      (PromptEvalMode.string, Reason.invalidPromptEvalCount),
      (PromptEvalMode.exceedsCtx, Reason.exceedsNumCtx),
    ]) {
      test('AC-4 prompt_eval_count ${mode.name} -> unknown/$reason, not blocked in strict', () async {
        final h = await Harness.start(models: {'qwen3:*': 4096}, strict: true);
        addTearDown(h.close);
        h.fake.scenario.promptEval = mode;
        await expectUnknown(h, reason);
      });
    }

    test('AC-4 no config and /api/ps fails -> unknown/num_ctx_unknown', () async {
      final h = await Harness.start(models: {}, strict: true);
      addTearDown(h.close);
      h.fake.scenario.psFails = true;
      await expectUnknown(h, Reason.numCtxUnknown);
      expect(h.logJson.single['num_ctx_source'], 'unknown');
    });

    test('AC-4 stream without done:true -> final chunk unknown/stream_incomplete, not blocked', () async {
      final h = await Harness.start(models: {'qwen3:*': 4096}, strict: true);
      addTearDown(h.close);
      h.fake.scenario.incompleteStream = true;
      final (res, body) = await h.post('/v1/chat/completions', userChat(words(6000), stream: true));
      expect(res.statusCode, 200);
      final chunks = sseChunks(body);
      final last = chunks.last;
      expect((last['ctxguard'] as Map)['verdict'], 'unknown');
      expect((last['ctxguard'] as Map)['reason'], Reason.streamIncomplete);
      expect(chunks.where((c) => c.containsKey('error')), isEmpty);
      expect(sseData(body).last, '[DONE]');
      await h.waitLogs(1);
      expect(h.logJson.single['event'], 'ctx_warning');
      expect(h.logJson.single['reason'], Reason.streamIncomplete);
    });
  });

  group('AC-3 a num_ctx above the model max is judged with the size Ollama really uses', () {
    // Ollama 는 모델 학습 길이보다 큰 num_ctx 를 학습 길이로 줄인다(llm/server.go).
    // 설정값 65536 으로 판정하면 8192 창의 잘림 서명(p=4098)을 놓친다.
    Future<Harness> clamped({bool strict = false}) async {
      final h = await Harness.start(models: {'qwen3:*': 65536}, fake: FakeOllama(modelMax: 8192), strict: strict);
      addTearDown(h.close);
      return h;
    }

    test('AC-3 /v1 non-stream: config 65536 > model max 8192 -> truncated at 8192', () async {
      final h = await clamped();
      final (res, body) = await h.post('/v1/chat/completions', userChat(words(9000)));
      expect(res.statusCode, 200);
      // 설정값은 그대로 보내고(Ollama 가 줄인다), 판정만 실제 크기로 한다.
      expect((h.fake.lastBody('/api/chat')!['options'] as Map)['num_ctx'], 65536);
      expect(h.fake.loaded['qwen3:4b'], 8192);
      expect(res.headers.value('X-Ctxguard-Verdict'), 'truncated');
      expect(res.headers.value('X-Ctxguard-Num-Ctx'), '8192');
      expect(res.headers.value('X-Ctxguard-Num-Ctx-Source'), NumCtxSource.modelMax);
      expect(res.headers.value('X-Ctxguard-Prompt-Tokens'), '4098');
      final field = _json(body)['ctxguard'] as Map;
      expect(field['num_ctx'], 8192);
      expect(field['num_ctx_source'], 'model_max');
      await h.waitLogs(1);
      expect(h.logJson.single['num_ctx'], 8192);
      expect(h.logJson.single['num_ctx_source'], 'model_max');
      expect(h.logJson.single['event'], 'ctx_warning');
    });

    test('AC-3 /v1 stream: header and final chunk use the capped size', () async {
      final h = await clamped();
      final (res, body) = await h.post('/v1/chat/completions', userChat(words(9000), stream: true));
      expect(res.statusCode, 200);
      expect(res.headers.value('X-Ctxguard-Num-Ctx'), '8192');
      expect(res.headers.value('X-Ctxguard-Num-Ctx-Source'), 'model_max');
      final field = sseChunks(body).last['ctxguard'] as Map;
      expect(field['verdict'], 'truncated');
      expect(field['num_ctx'], 8192);
    });

    test('AC-3 --strict blocks the capped truncation with 422', () async {
      final h = await clamped(strict: true);
      final (res, body) = await h.post('/v1/chat/completions', userChat(words(9000)));
      expect(res.statusCode, 422);
      expect((_json(body)['error'] as Map)['message'], contains('num_ctx=8192'));
    });

    test('AC-3 native /api/chat asking for num_ctx 65536 is judged at 8192 too', () async {
      final h = await clamped();
      final (res, _) = await h.post('/api/chat', {
        ...userChat(words(9000)),
        'options': {'num_ctx': 65536},
      });
      expect(res.statusCode, 200);
      await h.waitLogs(1);
      final line = h.logJson.single;
      expect(line['num_ctx'], 8192);
      expect(line['num_ctx_source'], 'model_max');
      expect(line['verdict'], 'truncated');
    });

    test('AC-3 a short prompt under the capped size stays ok', () async {
      final h = await clamped();
      final (res, _) = await h.post('/v1/chat/completions', userChat('hello there'));
      expect(res.headers.value('X-Ctxguard-Verdict'), 'ok');
      expect(res.headers.value('X-Ctxguard-Num-Ctx'), '8192');
    });

    test('AC-3 config below the model max keeps source=config (no change for the normal case)', () async {
      final h = await Harness.start(models: {'qwen3:*': 4096}, fake: FakeOllama(modelMax: 8192));
      addTearDown(h.close);
      final (res, _) = await h.post('/v1/chat/completions', userChat(words(6000)));
      expect(res.headers.value('X-Ctxguard-Verdict'), 'truncated');
      expect(res.headers.value('X-Ctxguard-Num-Ctx'), '4096');
      expect(res.headers.value('X-Ctxguard-Num-Ctx-Source'), 'config');
    });

    test('AC-3 if /api/show cannot be read the configured value is used as before', () async {
      final h = await clamped();
      h.fake.scenario.showFails = true;
      final (res, _) = await h.post('/v1/chat/completions', userChat('hello there'));
      expect(res.statusCode, 200);
      expect(res.headers.value('X-Ctxguard-Num-Ctx'), '65536');
      expect(res.headers.value('X-Ctxguard-Num-Ctx-Source'), 'config');
    });
  });

  group('AC-1 upstream URL with a path prefix (Ollama behind a reverse proxy)', () {
    test('AC-1 /api/ps lookup keeps the prefix, so an unconfigured model still gets its size', () async {
      final fake = FakeOllama(pathPrefix: '/ollama');
      final h = await Harness.start(models: {}, fake: fake, upstreamPath: '/ollama');
      addTearDown(h.close);
      final (res, _) = await h.post('/v1/chat/completions', userChat('hi', model: 'llama3.2:3b'));
      expect(res.statusCode, 200);
      expect(res.headers.value('X-Ctxguard-Num-Ctx'), '4096');
      expect(res.headers.value('X-Ctxguard-Num-Ctx-Source'), 'ollama_ps');
      expect(fake.received.map((r) => r.path), everyElement(startsWith('/ollama/')));
    });
  });

  group('AC-5 --strict non-streaming', () {
    test('AC-5 truncated -> 422 context_truncated / ctxguard_truncated', () async {
      final h = await Harness.start(models: {'qwen3:*': 4096}, strict: true);
      addTearDown(h.close);
      final (res, body) = await h.post('/v1/chat/completions', userChat(words(6000)));
      expect(res.statusCode, 422);
      final err = _json(body)['error'] as Map;
      expect(err['type'], 'context_truncated');
      expect(err['code'], 'ctxguard_truncated');
      expect(err['message'], contains('num_ctx=4096'));
      expect(res.headers.value('X-Ctxguard-Verdict'), 'truncated');
      await h.waitLogs(1);
      expect(h.logJson.single['status'], 422);
      expect(h.logJson.single['verdict'], 'truncated');
    });

    test('AC-5 without --strict the same request is 200 with verdict truncated', () async {
      final h = await Harness.start(models: {'qwen3:*': 4096});
      addTearDown(h.close);
      final (res, _) = await h.post('/v1/chat/completions', userChat(words(6000)));
      expect(res.statusCode, 200);
      expect(res.headers.value('X-Ctxguard-Verdict'), 'truncated');
      expect(res.headers.value('X-Ctxguard-Prompt-Tokens'), '2050');
    });

    test('AC-5 suspect and near_limit are not blocked', () async {
      final h = await Harness.start(models: {'qwen3:*': 4096}, strict: true);
      addTearDown(h.close);
      // 짧은 입력인데 cached 값이 서명 구간 → suspect
      h.fake.scenario.cachedCount = 2050;
      final (r1, _) = await h.post('/v1/chat/completions', userChat('short'));
      expect(r1.statusCode, 200);
      expect(r1.headers.value('X-Ctxguard-Verdict'), 'suspect');
      // 잘리지는 않았지만 생성 자리가 모자람 → near_limit
      h.fake.scenario = FakeScenario();
      final (r2, _) = await h.post('/v1/chat/completions', userChat(words(3700)));
      expect(r2.statusCode, 200);
      expect(r2.headers.value('X-Ctxguard-Verdict'), 'near_limit');
    });
  });
}
