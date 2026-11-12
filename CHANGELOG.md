# Changelog

## 0.2.0

### Added

- Screen language: help, `serve` start/warning/shutdown lines, the `doctor` table and warnings, the `demo` explanation, `mock-upstream` notes and error messages are available in English and Korean.
  - Choose with `--lang en|ko` (before or after the command), then `OLLAMA_CTXGUARD_LANG`, then `LC_ALL` / `LC_MESSAGES` / `LANG`. Anything that is not Korean is English. An invalid `--lang` value exits with 64.
  - `package:args` parse errors (unknown option, missing value, value not allowed) are translated too.
  - A config file that is not valid UTF-8 (or cannot be read) now gives a localized config error with exit code 2 instead of an unhandled exception (exit 255).
  - `ConfigException` gained `code` and `params`; its `message` and `toString()` stay English. `runDoctor` and `runDemo` gained an optional `lang` argument (default English).

- An unknown command (for example `ollama-ctxguard frob`) now prints a localized `error:` line before the usage, like unknown options do. Exit code stays 64.

### Fixed

- README scenario 3: the `strict.yaml` example now puts the model rule under `models:`, so `serve` accepts it. `example/ctxguard.yaml` comments are English with Korean alongside.

### Unchanged on purpose

- Exit codes, `--version`, `doctor --json` (warnings included), the access log, HTTP response bodies and headers, and the demo prompt and raw log lines stay English. Pin the human-readable text with `--lang en` or `OLLAMA_CTXGUARD_LANG=en` if a script compares it.
- Text inside a localized sentence stays as is: OS error originals, YAML parser details, the original text of unrecognized argument errors (after `인자 오류:`), the demo's data labels (`num_ctx=` …) and the model's answer sentence.

## 0.1.0

- `serve`: local proxy in front of Ollama.
  - `/v1/chat/completions` is translated to native `/api/chat` so a per-model `num_ctx` from `ctxguard.yaml` is really applied (streaming SSE, tool calls, images as data URLs, `response_format`, `reasoning_effort`, `stream_options.include_usage`).
  - Native `/api/chat` and `/api/generate` pass through; an empty `options.num_ctx` is filled from the config, an explicit one is kept.
  - Every other path is passed through byte for byte.
  - Each response gets a truncation verdict (`ok`, `near_limit`, `suspect`, `truncated`, `unknown`) in `X-Ctxguard-*` headers, the last SSE chunk (`ctxguard` field) and a JSON Lines access log without request or response bodies.
  - `--strict` turns `truncated` into an error (422, or an `error` chunk when streaming).
  - Listens on `127.0.0.1:11435` by default; a client disconnect cancels the upstream request.
  - Keeps Ollama's browser protection: on a loopback bind, requests whose `Host` is not local get 403 (DNS rebinding, same rule as Ollama), and the client `Origin` is forwarded on every path so `OLLAMA_ORIGINS` still applies.
  - A `num_ctx` above the model's trained maximum is judged with the size Ollama really loads (`num_ctx_source: model_max`).
  - Upstream URLs with a path prefix (Ollama behind a reverse proxy) work for `/api/ps`, `/api/show`, `doctor` and `demo` too.
- `doctor`: compares the configured size, model max, Modelfile value and the currently loaded size.
- `demo` and `mock-upstream`: offline practice mock that reproduces the `/v1` num_ctx problem.

### Known limitations

- A failed `/api/show` lookup is not cached and carries no client `Authorization`, so behind an authenticating reverse proxy the model-max correction is skipped, and a slow upstream adds up to 5 s per request.
- An upstream that violates HTTP framing (unsolicited response on an idle connection) can raise an unhandled exception and stop the proxy. Real Ollama is not expected to do this.
- `--listen localhost:<port>` may bind only `::1` on macOS; use `127.0.0.1`.
- The `mock-upstream` port-in-use message always suggests `--port 11500`.
