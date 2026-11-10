/// ollama-ctxguard: Ollama 앞에 두는 로컬 프록시.
///
/// OpenAI 호환 `/v1/chat/completions` 요청을 네이티브 `/api/chat` 으로 바꿔 모델별
/// num_ctx 를 실제로 적용하고, 응답마다 프롬프트가 잘렸는지 판정한다.
library;

export 'src/access_log.dart' show AccessLog, allowedLogFields;
export 'src/config.dart'
    show ConfigException, CtxguardConfig, LogFormat, globMatch, normalizeModelName, parseListen, parseUpstream;
export 'src/ctx_resolver.dart' show NumCtxSource;
export 'src/demo.dart' show runDemo, secretPrompt, callDirectV1, DirectResult;
export 'src/doctor.dart' show runDoctor, ModelDiagnosis;
export 'src/mock/fake_ollama.dart' show FakeOllama, FakeScenario, PromptEvalMode, ReceivedRequest;
export 'src/native_to_openai.dart' show toChatCompletion, ChunkTranslator;
export 'src/openai_to_native.dart' show openAiToNative, TranslatedChat;
export 'src/errors.dart' show RequestFormatException;
export 'src/host_guard.dart' show isAllowedHost;
export 'src/proxy_server.dart' show ProxyServer;
export 'src/truncation.dart'
    show Reason, TruncationResult, TruncationSettings, Verdict, estimateTokens, judgeTruncation;
