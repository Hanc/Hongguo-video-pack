import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SignedRequest {
  const SignedRequest(this.url, this.headers, this.body);
  final Uri url;
  final Map<String, String> headers;
  final String body;
  factory SignedRequest.fromJson(Map<String, dynamic> data) => SignedRequest(
    Uri.parse(data['url'] as String),
    Map<String, String>.from(data['headers'] as Map),
    data['body'] as String,
  );
}

abstract class RequestSigner {
  Future<SignedRequest> sign(String body, Map<String, String> device);
}

abstract class SearchRequestSigner {
  Future<SignedRequest> signSearch(
    Map<String, String> query,
    Map<String, String> identity,
  );
}

class NativeRequestSigner implements RequestSigner, SearchRequestSigner {
  static const channel = MethodChannel('dev.hongguo.studio/platform');
  Future<String>? _worker;
  Future<String> _prepare() async {
    // The worker must be written somewhere the current user can actually write.
    // Application support is preferred; a locked-down or read-only profile must
    // not turn into "playback cannot start", so fall back to temp dirs.
    final candidates = <Directory>[];
    try {
      candidates.add(await getApplicationSupportDirectory());
    } catch (_) {
      /* Platform without app-support directory. */
    }
    try {
      candidates.add(await getTemporaryDirectory());
    } catch (_) {
      /* Platform without temp directory. */
    }
    candidates.add(Directory.systemTemp);
    Object? failure;
    final seen = <String>{};
    for (final base in candidates) {
      if (!seen.add(p.normalize(base.path))) continue;
      try {
        final dir = await Directory(
          p.join(base.path, 'protocol-v1'),
        ).create(recursive: true);
        for (final name in ['worker.cjs', 'signer.cjs']) {
          final data = await rootBundle.loadString('assets/protocol/$name');
          await File(p.join(dir.path, name)).writeAsString(data, flush: true);
        }
        return p.join(dir.path, 'worker.cjs');
      } catch (error) {
        failure = error;
      }
    }
    throw StateError('签名服务无法写入磁盘，请检查目录权限：$failure');
  }

  @override
  Future<SignedRequest> sign(String body, Map<String, String> device) async {
    return _run({'body': body, 'device': device}, 'sign');
  }

  @override
  Future<SignedRequest> signSearch(
    Map<String, String> query,
    Map<String, String> identity,
  ) {
    return _run({
      'operation': 'search',
      'query': query,
      'device': identity,
    }, 'signSearch');
  }

  Future<SignedRequest> _run(Map<String, dynamic> input, String method) async {
    if (Platform.isAndroid) {
      final result = await channel.invokeMapMethod<String, dynamic>(
        method,
        input,
      );
      if (result == null) throw StateError('签名服务无响应');
      return SignedRequest.fromJson(result);
    }
    final worker = await (_worker ??= _prepare());
    final bundled = p.join(
      p.dirname(Platform.resolvedExecutable),
      'runtime',
      Platform.isWindows ? 'node.exe' : 'node',
    );
    final node = await File(bundled).exists() ? bundled : 'node';
    final process = await Process.start(node, [worker]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    process.stdin.writeln(jsonEncode(input));
    await process.stdin.close();
    final exit = await process.exitCode.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    final value = await output;
    await errors;
    if (exit != 0) throw StateError('签名服务启动失败，请确认安装包完整');
    return SignedRequest.fromJson(
      Map<String, dynamic>.from(jsonDecode(value) as Map),
    );
  }
}
