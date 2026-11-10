import 'dart:io';

import 'package:ollama_ctxguard/src/cli.dart';

Future<void> main(List<String> args) async {
  final code = await runCli(args);
  await stdout.flush();
  exit(code);
}
