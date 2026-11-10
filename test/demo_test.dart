import 'package:ollama_ctxguard/ollama_ctxguard.dart';
import 'package:test/test.dart';

void main() {
  test('AC-10 demo output: practice mock, direct /v1 forgets, via ctxguard remembers', () async {
    // 컴파일한 실행 파일로 하는 검증은 CI·build-notes 의 명령(AC-10)이 맡고,
    // 여기서는 같은 함수를 직접 불러 출력 내용을 확인한다.
    final out = StringBuffer();
    final code = await runDemo(out: out);
    expect(code, 0);
    final lines = out.toString().split('\n');
    expect(lines.first, contains('practice mock'));

    final direct = lines.firstWhere((l) => l.startsWith('direct /v1'));
    expect(direct, contains('num_ctx=4096'));
    expect(direct, contains('prompt_tokens=2050'));
    expect(direct, contains('verdict=truncated'));
    expect(direct, contains("answer: I don't see a secret code"));

    final via = lines.firstWhere((l) => l.startsWith('via ctxguard'));
    expect(via, contains('num_ctx=16384'));
    expect(via, contains('verdict=ok'));
    expect(via, contains('answer: 7731'));

    // 데모가 보여 주는 로그 줄에도 프롬프트 내용은 없다.
    expect(out.toString().split('proxy log line').last, isNot(contains('SECRET-CODE')));
  });
}
