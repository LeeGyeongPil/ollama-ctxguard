# 보안 정책 / Security policy

보안 취약점을 발견하셨다면 **공개 이슈 대신** 이 레포의 **Security → Report a vulnerability**(비공개 취약점 신고)로 알려 주세요. 확인 후 답변드리고, 고친 버전을 릴리스하면서 함께 안내합니다.

If you find a security issue, please **do not open a public issue**. Use **Security → Report a vulnerability** in this repository to report it privately. We will reply after checking and announce the fix with a release.

`ollama-ctxguard` 는 로컬 Ollama 앞에 두는 상주형 프록시입니다. 인증과 TLS 가 없고, 기본 설정은 내 컴퓨터(127.0.0.1)에서만 접속되도록 되어 있습니다. `0.0.0.0` 처럼 loopback 이 아닌 주소로 열면 같은 네트워크의 누구나 로컬 모델을 쓸 수 있으니 시작 경고를 확인하세요. loopback 일 때는 Host 검사(DNS 리바인딩 방어)로 localhost·이 PC·사설 주소가 아닌 Host 를 403 으로 거절하고, 브라우저 `Origin` 은 Ollama 로 그대로 전달해 `OLLAMA_ORIGINS` 가 적용되게 합니다.

`ollama-ctxguard` is a long-running proxy for a local Ollama. It has no authentication or TLS and listens on 127.0.0.1 by default; binding a non-loopback address exposes your local models to the network. On loopback it rejects requests whose Host is not localhost, this machine or a private address (DNS rebinding protection) and forwards the browser Origin to Ollama so `OLLAMA_ORIGINS` still applies.
