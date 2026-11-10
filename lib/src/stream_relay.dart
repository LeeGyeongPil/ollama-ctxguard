// 스트리밍 중계: 업스트림 본문을 받는 대로 클라이언트에 흘려보낸다.
//
// 지켜야 할 두 가지
// 1. 버퍼링 금지 — 줄(또는 바이트 조각)이 도착하면 바로 쓰고 내보낸다(flush).
//    그래야 첫 토큰이 생성 끝을 기다리지 않고 화면에 나온다.
// 2. 클라이언트가 끊으면 업스트림도 끊는다 — 안 그러면 아무도 읽지 않는 답을
//    Ollama 가 끝까지 생성하며 GPU 를 잡고 있는다.
//
// 왜 소켓을 직접 다루나(detachSocket)
//   dart:io 의 HttpResponse 는 응답 도중 상대가 연결을 닫아도 알려 주지 않는다
//   (flush() 가 끝나지 않고 done 도 오류로 끝나지 않는다 — 직접 실험으로 확인).
//   그래서 응답 헤더를 보낸 뒤 소켓을 넘겨받아, 소켓의 읽기 쪽이 닫히는 순간
//   (onDone)을 끊김 신호로 쓴다. 본문은 HTTP/1.1 chunked 형식으로 직접 감싸고,
//   응답이 끝나면 연결을 닫는다(Connection: close).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

final _crlf = ascii.encode('\r\n');
final _lastChunk = ascii.encode('0\r\n\r\n');

/// 응답 소켓 한 개와(있으면) 업스트림 요청 한 개를 묶어 끊김을 전파한다.
class StreamRelay {
  StreamRelay._(this._socket, this._upstreamRequest, this._chunked) {
    _socket.listen(
      (_) {}, // 요청 뒤에 클라이언트가 더 보내는 바이트는 쓰지 않는다.
      onDone: _markClientGone,
      onError: (Object _) => _markClientGone(),
      cancelOnError: true,
    );
  }

  /// 응답 헤더를 보내고 소켓을 넘겨받는다. [res] 의 상태 코드·헤더는 미리 정해 둔다.
  /// [contentLength] 를 알면 그 길이대로, 모르면 chunked 로 보낸다.
  static Future<StreamRelay> open(
    HttpResponse res, {
    HttpClientRequest? upstreamRequest,
    int contentLength = -1,
  }) async {
    res.persistentConnection = false; // 끝나면 연결을 닫는다.
    final chunked = contentLength < 0;
    if (chunked) {
      res.headers.chunkedTransferEncoding = true;
    } else {
      res.contentLength = contentLength;
    }
    final socket = await res.detachSocket(writeHeaders: true);
    return StreamRelay._(socket, upstreamRequest, chunked);
  }

  final Socket _socket;
  final HttpClientRequest? _upstreamRequest;
  final bool _chunked;
  bool _finished = false;
  bool _clientGone = false;
  final _gone = Completer<void>();

  bool get clientDisconnected => _clientGone;

  /// 클라이언트가 떠나면 완료된다.
  Future<void> get onClientGone => _gone.future;

  void _markClientGone() {
    if (_finished || _clientGone) return; // 우리가 정상 종료하며 닫은 경우는 끊김이 아니다.
    _clientGone = true;
    // 업스트림 소켓을 닫는다 → Ollama 가 요청 취소를 알아채고 생성을 멈춘다.
    _upstreamRequest?.abort(const SocketException('client disconnected'));
    _gone.complete();
  }

  /// 바이트를 쓰고 바로 내보낸다. 끊긴 뒤에는 아무것도 하지 않는다.
  Future<void> addNow(List<int> bytes) async {
    if (_clientGone || _finished || bytes.isEmpty) return;
    try {
      if (_chunked) _socket.add(ascii.encode('${bytes.length.toRadixString(16)}\r\n'));
      _socket.add(bytes);
      if (_chunked) _socket.add(_crlf);
      // flush 와 끊김 중 먼저 오는 것을 기다린다(끊긴 소켓의 flush 는 안 끝날 수 있다).
      await Future.any([_socket.flush(), _gone.future]);
    } on Object {
      _markClientGone();
    }
  }

  Future<void> writeNow(String text) => addNow(utf8.encode(text));

  /// SSE 이벤트 한 개: `data: <json>\n\n`.
  Future<void> writeSse(Object data) => writeNow('data: ${data is String ? data : jsonEncode(data)}\n\n');

  /// 본문을 마무리하고 연결을 닫는다. 여러 번 불러도 된다.
  Future<void> finish() async {
    if (_finished) return;
    if (!_clientGone) {
      try {
        if (_chunked) _socket.add(_lastChunk);
        await Future.any([_socket.flush(), _gone.future]);
      } on Object {
        // 이미 끊겼다.
      }
    }
    _finished = true;
    try {
      await _socket.close().timeout(const Duration(seconds: 5));
    } on Object {
      // 상대가 응답하지 않아도 아래에서 소켓을 정리한다.
    }
    _socket.destroy();
  }

  /// 서버 종료 때: 기다리지 않고 바로 닫는다.
  void destroy() {
    _finished = true;
    _socket.destroy();
  }

  /// 업스트림 [body] 를 끝까지(또는 끊길 때까지) 읽는다.
  ///
  /// [onBytes] 가 있으면 받은 바이트 조각을 먼저 넘기고(바이트 그대로 통과),
  /// [onLine] 이 있으면 이어서 완성된 줄마다 부른다. 업스트림이 중간에 오류로
  /// 끊기면 예외를 삼키고 `false` 를 돌려준다(호출한 쪽이 "미완료 스트림"으로 판정).
  Future<bool> pump(
    Stream<List<int>> body, {
    Future<void> Function(List<int> bytes)? onBytes,
    Future<void> Function(String line)? onLine,
  }) async {
    final lines = <String>[];
    final lineSink = const LineSplitter().startChunkedConversion(_ListSink(lines));
    final decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(lineSink);

    Future<void> drainLines() async {
      for (final line in List.of(lines)) {
        if (_clientGone) break;
        if (line.trim().isNotEmpty) await onLine!(line);
      }
      lines.clear();
    }

    final it = StreamIterator(body);
    var completed = true;
    try {
      while (true) {
        // 업스트림 다음 조각 또는 클라이언트 끊김 중 먼저 오는 것.
        final hasNext = await Future.any([it.moveNext(), _gone.future.then((_) => false)]);
        if (!hasNext || _clientGone) break;
        final chunk = it.current;
        if (onBytes != null) await onBytes(chunk);
        if (onLine != null) {
          decoder.add(chunk);
          await drainLines();
        }
        if (_clientGone) break;
      }
      if (!_clientGone && onLine != null) {
        decoder.close(); // 마지막 줄바꿈이 없는 줄도 꺼낸다.
        await drainLines();
      }
    } on Object {
      completed = false; // 업스트림 연결 오류(중간 끊김).
    } finally {
      await it.cancel().catchError((Object _) => null);
    }
    return completed && !_clientGone;
  }
}

class _ListSink implements Sink<String> {
  _ListSink(this.out);
  final List<String> out;
  @override
  void add(String data) => out.add(data);
  @override
  void close() {}
}
