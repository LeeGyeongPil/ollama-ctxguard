// Host 헤더 검사 — DNS 리바인딩 방어.
//
// 왜 필요한가: 프록시는 업스트림으로 보낼 때 Host 를 Ollama 주소(127.0.0.1:11434)로
// 바꾼다. 그러면 Ollama 자체의 Host 검사(allowedHostsMiddleware)는 언제나 통과하므로,
// 공격 페이지(evil.example → 127.0.0.1 로 다시 풀리게 만든 이름)가 ctxguard 포트로
// 보낸 요청도 그대로 모델을 부른다. 그래서 같은 규칙을 프록시 입구에서 검사한다.
//
// 규칙(ollama server/routes.go allowedHost·allowedHostsMiddleware, 2026-11-11 확인)
//   - 프록시가 loopback 이 아닌 주소에 바인딩됐으면 검사하지 않는다(Ollama 와 같음).
//   - Host 가 IP 면: loopback·사설망·0.0.0.0·이 PC 의 인터페이스 주소만 허용.
//   - 이름이면: 비었거나 localhost, 이 PC 의 호스트 이름, *.localhost·*.local·*.internal 만 허용.

import 'dart:io';

/// [hostHeader] 는 요청의 Host 헤더 원문(`name:port`, `[::1]:port`, 포트 없음 모두 가능).
bool isAllowedHost(
  String? hostHeader, {
  required bool loopbackBind,
  Set<String> localAddresses = const {},
  String? machineName,
}) {
  if (!loopbackBind) return true;
  final host = hostOnly(hostHeader ?? '').toLowerCase();
  if (host.isEmpty || host == 'localhost') return true;

  final ip = InternetAddress.tryParse(host);
  if (ip != null) {
    return ip.isLoopback || _isPrivate(ip) || _isUnspecified(ip) || localAddresses.contains(ip.address);
  }

  final name = (machineName ?? _localHostname()).toLowerCase();
  if (name.isNotEmpty && host == name) return true;
  for (final tld in const ['localhost', 'local', 'internal']) {
    if (host.endsWith('.$tld')) return true;
  }
  return false;
}

/// Host 헤더에서 포트를 뗀다. `[::1]:11435` → `::1`, `localhost:11435` → `localhost`.
String hostOnly(String raw) {
  final s = raw.trim();
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    return end < 0 ? s : s.substring(1, end);
  }
  // 콜론이 두 개 이상이면 대괄호 없는 IPv6 — 포트가 없다고 본다.
  final first = s.indexOf(':');
  if (first < 0 || first != s.lastIndexOf(':')) return s;
  return s.substring(0, first);
}

bool _isUnspecified(InternetAddress ip) => ip.rawAddress.every((b) => b == 0);

/// Go netip.Addr.IsPrivate 와 같은 범위: 10/8, 172.16/12, 192.168/16, fc00::/7.
bool _isPrivate(InternetAddress ip) {
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 10 || (b[0] == 172 && (b[1] & 0xf0) == 16) || (b[0] == 192 && b[1] == 168);
  }
  return (b[0] & 0xfe) == 0xfc;
}

String _localHostname() {
  try {
    return Platform.localHostname;
  } on Object {
    return '';
  }
}

/// 이 PC 의 네트워크 인터페이스 주소(Ollama isLocalIP 와 같은 목적). 못 읽으면 빈 집합.
Future<Set<String>> localInterfaceAddresses() async {
  try {
    final list = await NetworkInterface.list(includeLoopback: true, includeLinkLocal: true);
    return {
      for (final i in list)
        for (final a in i.addresses) a.address,
    };
  } on Object {
    return const {};
  }
}
