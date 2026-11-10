# Changelog

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
