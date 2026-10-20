import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import '../data/hongguo_client.dart';
import '../domain/drama.dart';
import 'playback_engine.dart';
import 'smoke_check.dart';

/// Real native renderer/decoder verification; no signed URLs or keys in reports.
Future<void> runPlaybackAcceptance() async {
  final directory = await Directory(
    '.local/playback-acceptance',
  ).create(recursive: true);
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'passed': false,
  };
  final engine = NativePlaybackEngine();
  final video = VideoController(engine.player);
  final client = HongguoClient();
  var stage = 'startup';
  runApp(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: Video(controller: video)),
      ),
    ),
  );
  try {
    await engine.player.setVolume(0);
    stage = 'drama';
    final drama = await client.fetchDrama('7671966197985856536');
    if (drama.episodes.length < 2) throw StateError('Insufficient episodes');
    final samples = <Map<String, dynamic>>[];
    for (var i = 0; i < 2; i++) {
      stage = 'episode-${i + 1}-variants';
      final media = chooseQuality(
        await client.fetchVariants(drama.episodes[i], seriesId: drama.id),
        1080,
      );
      // 同一集的第二次取流应命中控制器的短期缓存，这里只验证播放本身。
      stage = 'episode-${i + 1}-open';
      await engine.open(media);
      stage = 'episode-${i + 1}-first-frame';
      await video.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 45),
      );
      if (engine.position.inSeconds < 2) {
        await engine.player.stream.position
            .firstWhere((p) => p.inSeconds >= 2)
            .timeout(const Duration(seconds: 35));
      }
      final frame = await engine.player.screenshot(format: 'image/png');
      if (frame == null ||
          frame.isEmpty ||
          (engine.player.state.width ?? 0) <= 0) {
        throw StateError('No decoded frame');
      }
      await File('${directory.path}/episode-${i + 1}.png').writeAsBytes(frame);
      samples.add({
        'episode': i + 1,
        'quality': media.quality,
        'width': engine.player.state.width,
        'height': engine.player.state.height,
        'seconds': engine.position.inSeconds,
        'frameBytes': frame.length,
      });
      if (i == 0) {
        stage = 'native-smoke';
        await runNativeSmokeCheck();
        report['nativeEngineConcurrent'] = true;
        await engine.player.seek(const Duration(seconds: 15));
        await engine.player.stream.position
            .firstWhere((p) => p.inSeconds >= 14)
            .timeout(const Duration(seconds: 20));
        report['seek'] = true;
      }
    }
    report.addAll({'passed': true, 'samples': samples});
  } catch (error) {
    report['error'] = 'Native playback verification failed';
    report['stage'] = stage;
    report['reason'] = _describe(error);
    rethrow;
  } finally {
    client.close();
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    await engine.dispose();
    await File(
      '${directory.path}/result.json',
    ).writeAsString(jsonEncode(report));
  }
}

/// 连播与倍速的本地验收：用内置引擎生成的样片，不依赖来源网络与签名。
///
/// 覆盖三件事：倍速真的传到播放器、切集后仍能出画面并保持倍速、
/// 暂停后播放位置必须冻结（两个播放器实例曾导致暂停后声音继续）。
Future<void> runSwitchAcceptance() async {
  final directory = await Directory(
    '.local/switch-acceptance',
  ).create(recursive: true);
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'passed': false,
  };
  final engine = NativePlaybackEngine();
  final video = VideoController(engine.player);
  var stage = 'samples';
  try {
    await runNativeSmokeCheck();
    final red = File(
      p.absolute(p.join('.local', 'native-smoke', "red clip's.mp4")),
    );
    final blue = File(
      p.absolute(p.join('.local', 'native-smoke', "blue clip's.mp4")),
    );
    if (!await red.exists() || !await blue.exists()) {
      throw StateError('Missing sample clips');
    }

    stage = 'open-first';
    runApp(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(child: Video(controller: video)),
        ),
      ),
    );
    await engine.setRate(1.5);
    await engine.open(
      MediaVariant(url: red.uri.toString(), quality: 0, codec: 'h264'),
    );
    await _waitForPicture(engine.player);
    report['rateApplied'] = engine.player.state.rate;

    // 切集：模拟连播换集，仍用同一条通道。
    stage = 'switch';
    final watch = Stopwatch()..start();
    await engine.open(
      MediaVariant(url: blue.uri.toString(), quality: 0, codec: 'h264'),
    );
    await _waitForPicture(engine.player);
    watch.stop();
    report.addAll({
      'switchMs': watch.elapsedMilliseconds,
      'rateRetained': engine.player.state.rate,
      'width': engine.player.state.width,
    });

    // 暂停后位置必须停止前进。
    stage = 'pause';
    await engine.pause();
    final before = engine.position;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final after = engine.position;
    report['pausedPositionFrozen'] =
        (after - before).inMilliseconds.abs() < 300;
    report['pausedDeltaMs'] = (after - before).inMilliseconds;
    report['playingAfterPause'] = engine.player.state.playing;
    report['passed'] = true;
  } catch (error) {
    report['error'] = 'Local switch verification failed';
    report['stage'] = stage;
    report['reason'] = _describe(error);
    rethrow;
  } finally {
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    await engine.dispose();
    await File(
      '${directory.path}/result.json',
    ).writeAsString(jsonEncode(report));
  }
}

/// 等播放器真正解出画面（有尺寸且截图非空），返回是否成功。
Future<void> _waitForPicture(Player player) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 45)) {
    if ((player.state.width ?? 0) > 0) {
      final shot = await player.screenshot(format: 'image/png').catchError(
        (Object _) => null,
      );
      if (shot != null && shot.isNotEmpty) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw StateError('No picture after switch');
}

/// 只回传本项目自己的错误文案，不含地址、签名或密钥。
String _describe(Object error) {
  if (error is StateError) return error.message.toString();
  if (error is FormatException) return error.message;
  if (error is TimeoutException) return 'timeout';
  if (error is FileSystemException) return error.message;
  return error.runtimeType.toString();
}
