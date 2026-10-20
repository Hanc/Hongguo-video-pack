import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../data/discovery_client.dart';
import '../data/hongguo_client.dart';
import '../domain/drama.dart';

/// 单项探测结果。只保留可安全外传的信息：不含地址、签名与解密材料。
class HealthStep {
  const HealthStep({
    required this.name,
    required this.ok,
    required this.ms,
    this.detail = '',
  });

  final String name;
  final bool ok;
  final int ms;
  final String detail;
}

/// 来源自检报告。可以直接复制给开发者，不包含任何敏感数据。
class SourceHealthReport {
  const SourceHealthReport({
    required this.platform,
    required this.version,
    required this.startedAt,
    required this.steps,
  });

  final String platform;
  final String version;
  final DateTime startedAt;
  final List<HealthStep> steps;

  bool get ok => steps.isNotEmpty && steps.every((step) => step.ok);
  int get passed => steps.where((step) => step.ok).length;

  /// 诊断文本。刻意不输出 URL、签名、设备标识与解密密钥。
  String toText() {
    final stamp = startedAt
        .toIso8601String()
        .replaceFirst('T', ' ')
        .substring(0, 19);
    final buffer = StringBuffer()
      ..writeln('红葡萄 来源自检 · $version')
      ..writeln('时间: $stamp  平台: $platform')
      ..writeln('整体: ${ok ? '全部通过' : '有未通过项'} ($passed/${steps.length})')
      ..writeln();
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i];
      final mark = step.ok ? '通过' : '未通过';
      buffer.writeln(
        '[${i + 1}] ${step.name}  $mark  ${step.ms} ms'
        '${step.detail.isEmpty ? '' : '  ${step.detail}'}',
      );
    }
    buffer
      ..writeln()
      ..writeln('本报告不含地址、签名与解密材料，可直接发送给开发者。');
    return buffer.toString();
  }
}

/// 逐项探测来源是否可用，用于把「不能用」定位到具体环节。
class SourceHealthChecker {
  SourceHealthChecker({
    HongguoClient? client,
    DiscoveryClient? discovery,
    this.version = '',
  }) : client = client ?? HongguoClient(),
       discovery = discovery ?? DiscoveryClient();

  final HongguoClient client;
  final DiscoveryClient discovery;
  final String version;

  /// 自检用的固定剧目，避免把用户输入带进报告。
  static const probeDramaId = '7671966197985856536';

  Future<SourceHealthReport> run({
    void Function(int done, int total, String current)? onProgress,
  }) async {
    final startedAt = DateTime.now();
    final steps = <HealthStep>[];
    final labels = ['详情与分集', '签名取流与解密', '媒体 CDN', '榜单页面', '搜索'];
    void tick(int done) => onProgress?.call(done, 5, labels[done]);

    String? mediaUrl;
    Episode? probeEpisode;
    String? probeSeries;
    tick(0);

    // 1. 详情：同时验证签名链路是否还能通过。
    steps.add(
      await _step('详情与分集', () async {
        final drama = await client.fetchDrama(probeDramaId);
        if (drama.episodes.isEmpty) throw StateError('来源未返回分集');
        probeEpisode = drama.episodes.first;
        probeSeries = drama.id;
        return '${drama.episodes.length} 集';
      }),
    );
    tick(1);

    // 2. 取流与解密：签名 + 媒体地址解密 + CENC 密钥。
    steps.add(
      await _step('签名取流与解密', () async {
        final episode = probeEpisode;
        if (episode == null) throw StateError('缺少分集，跳过');
        final options = await client.fetchVariants(
          episode,
          seriesId: probeSeries,
        );
        if (options.isEmpty) throw StateError('来源无可用清晰度');
        final best = chooseQuality(options, 0);
        mediaUrl = best.url;
        final qualities = options.map((e) => e.quality).where((q) => q > 0);
        final top = qualities.isEmpty
            ? '未知'
            : '${qualities.reduce((a, b) => a > b ? a : b)}P';
        final keyed = best.key == null ? '无密钥' : '含解密密钥';
        return '$top · ${options.length} 档 · $keyed';
      }),
    );
    tick(2);

    // 3. 媒体 CDN：真正发一次 Range 请求，确认能取到字节。
    steps.add(
      await _step('媒体 CDN', () async {
        final url = mediaUrl;
        if (url == null) throw StateError('缺少媒体地址，跳过');
        final response = await http
            .get(
              Uri.parse(url),
              headers: const {
                'Range': 'bytes=0-2047',
                'Referer': 'https://novel.snssdk.com/',
              },
            )
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200 && response.statusCode != 206) {
          throw StateError('媒体返回 HTTP ${response.statusCode}');
        }
        return 'HTTP ${response.statusCode} · ${response.bodyBytes.length} 字节';
      }),
    );
    tick(3);

    // 4. 榜单页面：这是当前最慢的一环，单独计时便于对照。
    steps.add(
      await _step('榜单页面', () async {
        final watch = Stopwatch()..start();
        await discovery.ranking('hot-drama');
        watch.stop();
        final ms = watch.elapsedMilliseconds;
        return ms > 3000 ? '耗时偏高（服务端渲染慢）' : '';
      }),
    );
    tick(4);

    // 5. 搜索：走网页首批，确认搜索入口仍然可用。
    steps.add(
      await _step('搜索', () async {
        final page = await discovery.search('剧');
        return '${page.items.length} 条结果';
      }),
    );
    tick(5);

    return SourceHealthReport(
      platform: Platform.operatingSystem,
      version: version,
      startedAt: startedAt,
      steps: steps,
    );
  }

  Future<HealthStep> _step(    String name,
    Future<String> Function() action,
  ) async {
    final watch = Stopwatch()..start();
    try {
      final detail = await action();
      return HealthStep(
        name: name,
        ok: true,
        ms: watch.elapsedMilliseconds,
        detail: detail,
      );
    } catch (error) {
      return HealthStep(
        name: name,
        ok: false,
        ms: watch.elapsedMilliseconds,
        detail: _describe(error),
      );
    }
  }

  /// 只回传本项目自己的错误文案或错误类型，避免把地址带进报告。
  String _describe(Object error) {
    if (error is StateError) return error.message.toString();
    if (error is FormatException) return error.message;
    if (error is TimeoutException) return '超时';
    if (error is SocketException) return '网络不可达';
    if (error is FileSystemException) return error.message;
    return error.runtimeType.toString();
  }

  void close() {
    client.close();
    discovery.close();
  }
}
