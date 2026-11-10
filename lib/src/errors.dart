// OpenAI 형식 오류 본문: {"error":{"message","type","code"}}.
// OpenAI SDK 는 이 모양을 보고 APIError 계열 예외로 바꿔 준다.

import 'dart:convert';

Map<String, Object?> openAiError(String message, {required String type, String? code}) => {
  'error': {'message': message, 'type': type, 'param': null, 'code': code},
};

String openAiErrorJson(String message, {required String type, String? code}) =>
    jsonEncode(openAiError(message, type: type, code: code));

/// HTTP 상태 코드 → OpenAI 오류 type.
String errorTypeForStatus(int status) => switch (status) {
  400 || 413 || 422 => 'invalid_request_error',
  401 => 'authentication_error',
  403 => 'permission_error',
  404 => 'not_found_error',
  429 => 'rate_limit_error',
  >= 500 => 'api_error',
  _ => 'invalid_request_error',
};

/// 업스트림(Ollama) 오류 본문 `{"error":"..."}` 에서 메시지를 꺼낸다. 본문 전체를
/// 그대로 되돌려 주지 않도록 길이를 제한한다.
String upstreamErrorMessage(String body, int status) {
  var message = 'upstream returned HTTP $status';
  try {
    final j = jsonDecode(body);
    if (j is Map && j['error'] is String) message = j['error'] as String;
    if (j is Map && j['error'] is Map && (j['error'] as Map)['message'] is String) {
      message = (j['error'] as Map)['message'] as String;
    }
  } on FormatException {
    // JSON 이 아니면 기본 메시지를 쓴다.
  }
  return message.length > 500 ? '${message.substring(0, 500)}...' : message;
}

/// 클라이언트 요청 형식 오류(400). 변환기에서 던진다.
class RequestFormatException implements Exception {
  RequestFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}
