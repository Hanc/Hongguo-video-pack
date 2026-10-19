import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/services/media_engine.dart';
import 'package:path/path.dart' as p;

void main() {
  test('resource budget bounds decoder, encoder and filter threads', () {
    final args = boundedArguments([
      '-i',
      'input.mp4',
      '-c:v',
      'libx264',
      'out.mp4',
    ]);
    expect(args.take(4), [
      '-filter_threads',
      '1',
      '-filter_complex_threads',
      '1',
    ]);
    final input = args.indexOf('-i');
    expect(args[input - 2], '-threads');
    expect(int.parse(args[input - 1]), inInclusiveRange(1, 2));
    expect(args[args.length - 3], '-threads');
  });
  test('dominant size wins even when first clip is the outlier', () {
    Map<String, dynamic> info(int height) => {
      'streams': [
        {
          'codec_type': 'video',
          'codec_name': 'hevc',
          'width': 1080,
          'height': height,
        },
      ],
    };
    expect(
      dominantMediaInfo([
        info(1908),
        info(1920),
        info(1920),
      ])['streams'][0]['height'],
      1920,
    );
  });
  test(
    'HEVC dimension repair keeps majority streams and decodes mixed boundaries',
    () async {
      final dir = await Directory.systemTemp.createTemp('hongguo-repair-');
      final engine = MediaEngine(useExternalProcess:true);
      try {
        final files = <String>[];
        for (final height in [324,320,320]) {
          final file = p.join(dir.path,'${files.length}.mp4');
          await engine.execute(['-y','-f','lavfi','-i','color=c=red:s=180x$height:r=30:d=1',
            '-f','lavfi','-i','sine=frequency=440:duration=1',
            '-c:v','libx265','-x265-params','pools=1:frame-threads=1:log-level=error',
            '-pix_fmt','yuv420p','-c:a','aac','-shortest',file]);
          files.add(file);
        }
        final events = <String>[];
        final output = p.join(dir.path,'repaired.mp4');
        await engine.merge(files,output,(_){},normalize:true,onStatus:events.add);
        expect(events.any((e)=>e.contains('保留 2 集原流')),isTrue);
        expect(events.any((e)=>e.contains('统一为')),isFalse);
        final info = await engine.probe(output);
        final video = (info['streams'] as List).firstWhere((s)=>s['codec_type']=='video');
        expect(video['height'],320);
        expect(video['codec_name'],'hevc');
      } finally { await dir.delete(recursive:true); }
    }, skip:!hasExternalTools(),
  );
  test(
    'FFmpeg merges actual clips with spaces and apostrophes and validates duration',
    () async {
      final dir = await Directory.systemTemp.createTemp("hongguo test '");
      final engine = MediaEngine(useExternalProcess: true);
      try {
        final files = <String>[];
        for (final color in ['red', 'blue']) {
          final file = p.join(dir.path, '$color clip.mp4');
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
            file,
          ]);
          files.add(file);
        }
        final output = p.join(dir.path, 'result.mp4');
        await engine.merge(files, output, (_) {});
        final info = await engine.probe(output);
        expect(
          double.parse(info['format']['duration'] as String),
          closeTo(2, .3),
        );
        expect(
          (info['streams'] as List)
              .where((s) => s['codec_type'] == 'video')
              .single['width'],
          180,
        );
        final other = p.join(dir.path, 'different.mp4');
        await engine.execute([
          '-y',
          '-f',
          'lavfi',
          '-i',
          'color=c=green:s=320x180:r=25:d=1',
          '-c:v',
          'libx264',
          other,
        ]);
        await expectLater(
          engine.merge(
            [files.first, other],
            p.join(dir.path, 'bad.mp4'),
            (_) {},
          ),
          throwsStateError,
        );
        expect(await File(p.join(dir.path, 'bad.mp4')).exists(), isFalse);
        final compatible = p.join(dir.path, 'compatible.mp4');
        await engine.merge(
          [files.first, other],
          compatible,
          (_) {},
          normalize: true,
        );
        final normalized = await engine.probe(compatible);
        final normalizedVideo = (normalized['streams'] as List).firstWhere(
          (s) => s['codec_type'] == 'video',
        );
        final normalizedAudio = (normalized['streams'] as List).firstWhere(
          (s) => s['codec_type'] == 'audio',
        );
        expect(normalizedVideo['width'], 180);
        expect(normalizedVideo['height'], 320);
        expect(normalizedAudio['channels'], 2);
        await engine.cancel();
        await expectLater(
          engine.merge(files, p.join(dir.path, 'cancelled.mp4'), (_) {}),
          throwsA(isA<JobCancelled>()),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
    skip: !hasExternalTools(),
  );
}

bool hasExternalTools() {
  if (!Platform.isWindows && !Platform.isLinux) return false;
  try {
    final ffmpeg = Platform.environment['HONGGUO_FFMPEG'] ?? 'ffmpeg';
    final ffprobe = Platform.environment['HONGGUO_FFPROBE'] ?? 'ffprobe';
    return Process.runSync(ffmpeg, ['-version']).exitCode == 0 &&
        Process.runSync(ffprobe, ['-version']).exitCode == 0;
  } catch (_) {
    return false;
  }
}
