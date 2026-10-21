import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../app_controller.dart';
import '../domain/discovery.dart';
import '../playback_view.dart';
import '../watch_history.dart';
import 'media_engine.dart';
import 'playback_engine.dart';

/// Offline end-to-end check against the real renderer, route disposal and store.
/// The caller must choose an isolated diagnostic directory, never user data.
Future<void> runHistoryAcceptance() async {
  final path = Platform.environment['HONGPUTAO_ACCEPTANCE_DIR'];
  if (path == null || !p.isAbsolute(path)) {
    throw StateError(
      'Set HONGPUTAO_ACCEPTANCE_DIR to an absolute test directory',
    );
  }
  final directory = await Directory(path).create(recursive: true);
  final source = p.join(path, 'source.mp4');
  final merged = p.join(path, 'merged.mp4');
  final store = File(p.join(path, 'workspace.json'));
  final report = <String, dynamic>{
    'passed': false,
    'platform': Platform.operatingSystem,
  };
  final media = MediaEngine();
  final navigator = GlobalKey<NavigatorState>();
  final controllers = <StudioController>[];
  try {
    await media.execute([
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=size=160x90:rate=10',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=44100',
      '-t',
      '12',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      source,
    ]);
    await media.merge([source, source], merged, (_) {});
    final tasks = StudioController();
    controllers.add(tasks);
    await tasks.initialize(store, directory.path);
    tasks.watchHistory.record(
      WatchPoint(title: '续播验证第一季', path: merged, positionMs: 8000),
    );
    await tasks.watchHistory.flush();
    runApp(
      MaterialApp(
        navigatorKey: navigator,
        home: const Scaffold(body: Text('本地续播验证')),
      ),
    );
    await WidgetsBinding.instance.endOfFrame;
    Future<void> open(
      StudioController tasks,
      NativePlaybackEngine engine,
      WatchPoint point,
    ) async {
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => PlaybackScreen(
            summary: DramaSummary(id: '', title: point.title),
            tasks: tasks,
            resume: point,
            nativeEngine: engine,
            onStitch: (_, _, _) async => false,
            onTasks: () {},
          ),
        ),
      );
      await engine.player.stream.position
          .firstWhere(
            (value) => value.inMilliseconds >= point.positionMs + 1500,
          )
          .timeout(const Duration(seconds: 35));
      if ((engine.player.state.width ?? 0) <= 0) {
        throw StateError('No decoded local video');
      }
      await engine.pause();
      navigator.currentState!.pop();
      await WidgetsBinding.instance.endOfFrame;
      await tasks.watchHistory.flush();
    }

    final first = NativePlaybackEngine();
    await first.player.setVolume(0);
    await open(tasks, first, tasks.watchHistory.fileFor(merged)!);
    final saved = tasks.watchHistory.fileFor(merged)!;
    if (saved.positionMs < 9500) throw StateError('Checkpoint not persisted');
    final restored = StudioController();
    controllers.add(restored);
    await restored.initialize(store, directory.path);
    final point = restored.watchHistory.fileFor(merged)!;
    if (point.positionMs != saved.positionMs) {
      throw StateError('Restart changed checkpoint');
    }
    final second = NativePlaybackEngine();
    await second.player.setVolume(0);
    await open(restored, second, point);
    report.addAll({
      'passed': true,
      'savedMs': saved.positionMs,
      'resumedMs': restored.watchHistory.fileFor(merged)!.positionMs,
      'localMergedVideo': true,
      'restartRestored': true,
    });
  } finally {
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    for (final controller in controllers) {
      await controller.flush();
      controller.dispose();
    }
    await File(p.join(path, 'result.json')).writeAsString(jsonEncode(report));
  }
}
