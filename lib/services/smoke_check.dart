import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'media_engine.dart';
import '../app_controller.dart';
import '../data/discovery_client.dart';
import 'app_storage.dart';

Future<void> runSearchAcceptance() async {
  final directory = await Directory(
    '.local/search-acceptance',
  ).create(recursive: true);
  final report = <String, dynamic>{'platform': Platform.operatingSystem};
  final client = DiscoveryClient();
  try {
    final support = await appSupportDirectory();
    if (!await client.loadSearchIdentity(
      File(p.join(support.path, 'search-visitor.json')),
    )) {
      throw StateError('本机搜索尚未初始化');
    }
    final first = await client.search('重生');
    final second = await client.search('重生', page: 2);
    final back = await client.search('重生');
    final covered = await client.enrichMetrics([
      ...first.items,
      ...second.items,
    ]);
    var decodedCovers = 0;
    final images = http.Client();
    try {
      for (final row in covered) {
        final response = await images
            .get(Uri.parse(row.cover))
            .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) throw StateError('封面读取失败');
        final codec = await ui.instantiateImageCodec(
          response.bodyBytes,
          targetWidth: 32,
        );
        try {
          final frame = await codec.getNextFrame();
          frame.image.dispose();
          decodedCovers++;
        } finally {
          codec.dispose();
        }
      }
    } finally {
      images.close();
    }
    final overlap = first.items
        .map((d) => d.id)
        .toSet()
        .intersection(second.items.map((d) => d.id).toSet());
    if (first.items.isEmpty ||
        second.items.isEmpty ||
        overlap.isNotEmpty ||
        !identical(back, first)) {
      throw StateError('搜索分页验证未通过');
    }
    report.addAll({
      'passed': true,
      'first': first.items.length,
      'second': second.items.length,
      'overlap': overlap.length,
      'backCached': true,
      'more': second.hasMore,
      'heat': second.items.where((d) => d.heat.isNotEmpty).length,
      'coversDecoded': decodedCovers,
    });
  } catch (_) {
    report['passed'] = false;
    rethrow;
  } finally {
    client.close();
    await File(
      p.join(directory.path, 'result.json'),
    ).writeAsString(jsonEncode(report));
  }
}

Future<void> runRemoteAcceptance() async {
  final directory = await Directory(
    '.local/acceptance',
  ).create(recursive: true);
  final controller = StudioController();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'started': DateTime.now().toIso8601String(),
  };
  try {
    await controller.initialize(
      File(p.join(directory.path, 'workspace.json')),
      p.absolute(directory.path),
    );
    await controller.load(
      'https://hongguoduanju.com/player/7671966197985856536',
    );
    if (controller.error != null) throw StateError(controller.error!);
    report['episodes'] = controller.drama!.episodes.length;
    report['qualities'] = controller.variants.map((v) => v.quality).toList();
    await controller.assemble();
    if (controller.output == null) {
      throw StateError(controller.error ?? controller.status);
    }
    final info = await controller.engine.probe(controller.output!);
    await controller.engine.execute([
      '-xerror',
      '-i',
      controller.output!,
      '-map',
      '0:v:0',
      '-map',
      '0:a:0?',
      '-f',
      'null',
      '-',
    ]);
    report.addAll({
      'passed': true,
      'output': controller.output,
      'duration': info['format']['duration'],
      'streams': [
        for (final s in info['streams'])
          {
            'type': s['codec_type'],
            'codec': s['codec_name'],
            'width': s['width'],
            'height': s['height'],
          },
      ],
      'events': controller.events,
      'selected': controller.selected.toList(),
    });
  } catch (e) {
    report.addAll({
      'passed': false,
      'error': friendlyError(e),
      'events': controller.events,
    });
    rethrow;
  } finally {
    report['finished'] = DateTime.now().toIso8601String();
    await File(
      p.join(directory.path, 'result.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    controller.dispose();
  }
}

/// Run in the real Flutter host to exercise the bundled native plugin.
Future<void> runNativeSmokeCheck() async {
  final dir = await Directory('.local/native-smoke').create(recursive: true);
  final engine = MediaEngine();
  final files = <String>[];
  final result = <String, dynamic>{'platform': Platform.operatingSystem};
  try {
    for (final color in ['red', 'blue']) {
      final path = p.absolute(p.join(dir.path, "$color clip's.mp4"));
      await engine.execute([
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=c=$color:s=180x320:r=25:d=1',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=1',
        '-c:v',
        'libx264',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        '-shortest',
        path,
      ]);
      files.add(path);
    }
    final output = p.absolute(
      p.join(dir.path, 'merged-${DateTime.now().millisecondsSinceEpoch}.mp4'),
    );
    await engine.merge(files, output, (_) {});
    final info = await engine.probe(output);
    final duration = double.parse(info['format']['duration'] as String);
    if ((duration - 2).abs() > .3) {
      throw StateError('Unexpected duration $duration');
    }
    result.addAll({'passed': true, 'duration': duration, 'output': output});
    final mixed = <String>[];
    for (final height in [324, 320, 320]) {
      final path = p.absolute(p.join(dir.path, 'hevc-${mixed.length}.mp4'));
      await engine.execute([
        '-y',
        '-f',
        'lavfi',
        '-i',
        'color=c=blue:s=180x$height:r=30:d=1',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=1',
        '-c:v',
        'libx265',
        '-x265-params',
        'pools=1:frame-threads=1:log-level=error',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        '-shortest',
        path,
      ]);
      mixed.add(path);
    }
    final events = <String>[];
    final repaired = p.absolute(
      p.join(
        dir.path,
        'hevc-repaired-${DateTime.now().millisecondsSinceEpoch}.mp4',
      ),
    );
    await engine.merge(
      mixed,
      repaired,
      (_) {},
      normalize: true,
      onStatus: events.add,
    );
    final repairedInfo = await engine.probe(repaired);
    final repairedVideo = (repairedInfo['streams'] as List).firstWhere(
      (s) => s['codec_type'] == 'video',
    );
    if (repairedVideo['height'] != 320 ||
        repairedVideo['codec_name'] != 'hevc' ||
        !events.any((e) => e.contains('保留 2 集原流')) ||
        events.any((e) => e.contains('统一为'))) {
      throw StateError('Native HEVC selective repair did not pass');
    }
    result.addAll({'hevcSelectiveRepair': true, 'repairEvents': events});
  } catch (e) {
    result.addAll({'passed': false, 'error': '$e'});
    rethrow;
  } finally {
    await File(
      p.join(dir.path, 'result.json'),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
  }
}
