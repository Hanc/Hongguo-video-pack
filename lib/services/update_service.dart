import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One published build of this app, as described by
/// `updates/<platform>/latest.json` on the update bucket.
class UpdateInfo {
  const UpdateInfo({
    required this.platform,
    required this.version,
    required this.versionCode,
    required this.url,
    required this.size,
    required this.sha256,
    required this.kind,
    this.notes = const <String>[],
    this.publishedAt,
  });

  final String platform;
  final String version;
  final int versionCode;
  final Uri url;
  final int size;
  final String sha256;
  final String kind;
  final List<String> notes;
  final String? publishedAt;

  bool newerThan(int code) => versionCode > code;

  String get sizeLabel {
    final mb = size / (1024 * 1024);
    return mb >= 1 ? '${mb.toStringAsFixed(1)} MB' : '${(size / 1024).toStringAsFixed(0)} KB';
  }

  static UpdateInfo fromJson(Map<String, Object?> json, {String? expectPlatform}) {
    final platform = json['platform'];
    final version = json['version'];
    final versionCode = json['versionCode'];
    final url = json['url'];
    final size = json['size'];
    final sha256 = json['sha256'];
    if (platform is! String || version is! String || versionCode is! int || url is! String || sha256 is! String) {
      throw const FormatException('更新清单字段缺失');
    }
    if (expectPlatform != null && platform != expectPlatform) {
      throw FormatException('更新清单平台不匹配：$platform');
    }
    final parsed = Uri.tryParse(url);
    if (parsed == null || !parsed.isScheme('https')) {
      throw const FormatException('更新地址必须是 https');
    }
    final digest = sha256.toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('更新清单的校验值格式不正确');
    }
    final notes = json['notes'];
    return UpdateInfo(
      platform: platform,
      version: version,
      versionCode: versionCode,
      url: parsed,
      size: size is int ? size : 0,
      sha256: digest,
      kind: json['kind'] is String ? json['kind'] as String : 'apk',
      // 发布脚本写的是单段字符串，早期清单可能给数组，两种都接受。
      notes: switch (notes) {
        final String text => text
            .split('\n')
            .map((line) => line.trim())
            .where((line) => line.isNotEmpty)
            .toList(growable: false),
        final List<dynamic> list => list.whereType<String>().toList(growable: false),
        _ => const <String>[],
      },
      publishedAt: json['publishedAt'] is String ? json['publishedAt'] as String : null,
    );
  }
}

/// Outcome of one manifest check. [update] is null when the installed build is
/// already current; [error] is set only when the check itself could not run.
class UpdateCheck {
  const UpdateCheck.current() : update = null, error = null;
  const UpdateCheck.available(this.update) : error = null;
  const UpdateCheck.failed(this.error) : update = null;

  final UpdateInfo? update;
  final String? error;

  bool get isAvailable => update != null;
  bool get isCurrent => update == null && error == null;
  bool get hasError => error != null;
}

/// Progress of an in-flight installer download.
class DownloadProgress {
  const DownloadProgress(this.received, this.total);

  final int received;
  final int total;

  double? get fraction => total > 0 ? (received / total).clamp(0, 1).toDouble() : null;
}

class UpdateService {
  UpdateService({
    http.Client? client,
    String? base,
    String? platform,
    Future<Directory> Function()? directory,
  })  : _client = client ?? http.Client(),
        _base = base ?? defaultBase,
        _platform = platform ?? defaultPlatform,
        _directory = directory ?? _supportDirectory;

  /// Public read base of the update bucket. Only `latest.json` lives at a fixed
  /// path; installer file names carry a content hash so they cannot be guessed.
  static const defaultBase = 'https://hongputao-1308285894.cos.ap-guangzhou.myqcloud.com/updates';

  static String get defaultPlatform {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    return 'unknown';
  }

  static const _installChannel = MethodChannel('dev.hongguo.studio/platform');

  final http.Client _client;
  final String _base;
  final String _platform;
  final Future<Directory> Function() _directory;

  static Future<Directory> _supportDirectory() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'updates', defaultPlatform));
  }

  Uri get manifestUri => Uri.parse('$_base/$_platform/latest.json');

  /// Reads the manifest and decides whether [currentVersionCode] is behind it.
  ///
  /// A missing manifest (404) or an unreachable bucket is reported as
  /// [UpdateCheck.failed] rather than "already current", so the UI can show an
  /// honest reason instead of pretending there is nothing to install.
  Future<UpdateCheck> check({
    required int currentVersionCode,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    try {
      final response = await _client
          .get(manifestUri, headers: const {'Accept': 'application/json'})
          .timeout(timeout);
      if (response.statusCode == 404) {
        return const UpdateCheck.failed('更新清单不存在（服务端尚未发布）');
      }
      if (response.statusCode != 200) {
        return UpdateCheck.failed('更新检查失败：HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, Object?>) {
        return const UpdateCheck.failed('更新清单格式不正确');
      }
      final info = UpdateInfo.fromJson(decoded, expectPlatform: _platform);
      return info.newerThan(currentVersionCode)
          ? UpdateCheck.available(info)
          : const UpdateCheck.current();
    } on TimeoutException {
      return const UpdateCheck.failed('更新检查超时，请检查网络后重试');
    } on FormatException catch (error) {
      return UpdateCheck.failed('更新清单不可用：${error.message}');
    } catch (error) {
      return UpdateCheck.failed('更新检查失败：$error');
    }
  }

  /// Downloads [info] into the update directory and verifies its digest.
  ///
  /// The returned file is only handed back after the SHA-256 matches, so an
  /// interrupted or tampered download can never reach the installer step.
  Future<File> download(
    UpdateInfo info, {
    void Function(DownloadProgress progress)? onProgress,
    Duration timeout = const Duration(minutes: 15),
  }) async {
    final directory = await _directory();
    await directory.create(recursive: true);
    final name = p.basename(info.url.path);
    final target = File(p.join(directory.path, name));
    final partial = File('${target.path}.part');
    if (await partial.exists()) await partial.delete();

    final digestSink = _DigestSink();
    final input = sha256.startChunkedConversion(digestSink);
    var received = 0;
    final request = http.Request('GET', info.url);
    final response = await _client.send(request).timeout(timeout);
    if (response.statusCode != 200) {
      throw HttpException('下载失败：HTTP ${response.statusCode}', uri: info.url);
    }
    final total = response.contentLength ?? info.size;
    final sink = partial.openWrite();
    try {
      await for (final chunk in response.stream.timeout(timeout)) {
        sink.add(chunk);
        input.add(chunk);
        received += chunk.length;
        onProgress?.call(DownloadProgress(received, total));
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    input.close();
    final actual = digestSink.value.toString();
    if (actual != info.sha256) {
      await partial.delete();
      throw StateError('安装包校验失败，已丢弃本次下载');
    }
    if (await target.exists()) await target.delete();
    return partial.rename(target.path);
  }

  /// Hands [file] to the platform installer.
  Future<void> install(File file) async {
    if (Platform.isAndroid) {
      final result = await _installChannel.invokeMethod<bool>('installApk', {'path': file.path});
      if (result != true) throw StateError('系统未接受安装请求，请允许“安装未知应用”后重试');
      return;
    }
    if (Platform.isWindows) {
      await Process.start(file.path, const [], mode: ProcessStartMode.detached);
      return;
    }
    throw UnsupportedError('当前平台不支持自动安装，请手动打开下载的文件');
  }

  /// Opens the folder that holds a downloaded installer (desktop fallback).
  Future<void> revealDownload(File file) async {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,${file.path}'], mode: ProcessStartMode.detached);
    }
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
