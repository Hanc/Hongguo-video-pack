import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new/log_redirection_strategy.dart';
import 'package:path/path.dart' as p;
import '../domain/drama.dart';

class JobCancelled implements Exception {}

class MediaEngine {
  MediaEngine({this.useExternalProcess = false}) {
    // Keep probe output available to validation without printing signed URLs/keys on errors.
    FFmpegKitConfig.setLogRedirectionStrategy(
      LogRedirectionStrategy.neverPrintLogs,
    );
  }
  final bool useExternalProcess;
  Process? _process;
  int? _session;
  bool _cancelled = false;
  void reset() => _cancelled = false;
  void checkCancelled() {
    if (_cancelled) throw JobCancelled();
  }

  Future<void> cancel() async {
    _cancelled = true;
    _process?.kill();
    if (_session != null) await FFmpegKit.cancel(_session);
  }

  Future<void> execute(
    List<String> arguments, {
    void Function(double)? onSeconds,
  }) async {
    checkCancelled();
    arguments = boundedArguments(arguments);
    if (useExternalProcess && (Platform.isWindows || Platform.isLinux)) {
      final executable = Platform.environment['HONGGUO_FFMPEG'] ?? 'ffmpeg';
      final process = await Process.start(executable, [
        '-hide_banner',
        '-loglevel',
        'error',
        '-nostdin',
        '-progress',
        'pipe:1',
        ...arguments,
      ]);
      _process = process;
      final output = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line.startsWith('out_time_us=')) {
              onSeconds?.call(
                (double.tryParse(line.split('=').last) ?? 0) / 1000000,
              );
            }
          });
      // Drain without persisting signed addresses or media authorization data.
      final errors = process.stderr.drain<void>();
      final code = await process.exitCode;
      await output.cancel();
      await errors;
      _process = null;
      checkCancelled();
      if (code != 0) throw StateError('FFmpeg 处理失败（$code）。请检查素材、源站授权或编码兼容性');
    } else {
      final done = Completer<void>();
      final session = await FFmpegKit.executeWithArgumentsAsync(
        ['-hide_banner', '-loglevel', 'error', ...arguments],
        (session) async {
          final code = await session.getReturnCode();
          if (ReturnCode.isSuccess(code)) {
            done.complete();
          } else {
            done.completeError(StateError('视频处理失败（${code?.getValue()}）'));
          }
        },
        null,
        (stats) => onSeconds?.call(stats.getTime() / 1000),
      );
      _session = session.getSessionId();
      if (_cancelled) await FFmpegKit.cancel(_session);
      try {
        await done.future;
      } finally {
        _session = null;
      }
      checkCancelled();
    }
  }

  Future<Map<String, dynamic>> probe(String file) async {
    checkCancelled();
    final args = [
      '-v',
      'error',
      '-show_streams',
      '-show_format',
      '-of',
      'json',
      file,
    ];
    if (useExternalProcess && (Platform.isWindows || Platform.isLinux)) {
      final ffmpeg = Platform.environment['HONGGUO_FFMPEG'];
      final executable =
          Platform.environment['HONGGUO_FFPROBE'] ??
          (ffmpeg == null
              ? 'ffprobe'
              : p.join(
                  p.dirname(ffmpeg),
                  Platform.isWindows ? 'ffprobe.exe' : 'ffprobe',
                ));
      final result = await Process.run(
        executable,
        args,
      ).timeout(const Duration(seconds: 30));
      if (result.exitCode != 0) throw StateError('无法读取视频信息');
      return Map<String, dynamic>.from(
        jsonDecode(result.stdout as String) as Map,
      );
    }
    final result = await FFprobeKit.executeWithArguments(args);
    if (!ReturnCode.isSuccess(await result.getReturnCode())) {
      throw StateError('无法读取视频信息');
    }
    return Map<String, dynamic>.from(
      jsonDecode((await result.getOutput())!) as Map,
    );
  }

  Future<void> download(
    MediaVariant media,
    String destination,
    void Function(double) progress,
  ) async {
    if (!media.downloadable) throw StateError('当前来源仅支持原站播放，下载适配尚未完成');
    final partial = '$destination.part.mp4';
    final file = File(partial);
    try {
      await execute(
        [
          '-y',
          '-rw_timeout',
          '20000000',
          '-headers',
          'Referer: https://novel.snssdk.com/\r\n',
          if (media.key != null) ...['-decryption_key', media.key!],
          '-i',
          media.url,
          '-map',
          '0:v:0',
          '-map',
          '0:a:0?',
          '-c',
          'copy',
          '-movflags',
          '+faststart',
          partial,
        ],
        onSeconds: (seconds) => progress(
          media.duration > 0 ? (seconds / media.duration).clamp(0, 0.99) : 0,
        ),
      );
      final info = await probe(partial);
      if ((info['streams'] as List? ?? []).every(
        (s) => s['codec_type'] != 'video',
      )) {
        throw StateError('下载结果缺少视频轨道');
      }
      final duration =
          double.tryParse('${(info['format'] as Map?)?['duration']}') ?? 0;
      if (media.duration > 0 && (duration - media.duration).abs() > 2) {
        throw StateError('下载时长校验失败，请重试');
      }
      await execute([
        '-xerror',
        '-i',
        partial,
        '-t',
        '1',
        '-map',
        '0:v:0',
        '-map',
        '0:a:0?',
        '-f',
        'null',
        '-',
      ]);
      await file.rename(destination);
      progress(1);
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> merge(
    List<String> inputs,
    String destination,
    void Function(double) progress, {
    bool normalize = false,
    void Function(String)? onStatus,
  }) async {
    if (inputs.isEmpty) throw StateError('请先选择素材');
    final infos = <Map<String, dynamic>>[];
    for (final input in inputs) {
      infos.add(await probe(input));
    }
    final signatures = infos.map(streamSignature).toSet();
    if (signatures.length != 1) {
      if (normalize) {
        if (await _repairDimensions(
          inputs,
          infos,
          destination,
          progress,
          onStatus,
        )) {
          return;
        }
        await _normalizeAndMerge(
          inputs,
          infos,
          destination,
          progress,
          onStatus,
        );
        return;
      }
      throw StateError('素材的编码、尺寸或音轨参数不一致；当前最小版本仅支持同规格无损拼接，请选择相同清晰度');
    }
    final duration = infos.fold<double>(
      0,
      (sum, info) =>
          sum +
          (double.tryParse('${(info['format'] as Map?)?['duration']}') ?? 0),
    );
    final manifest = File(
      p.join(
        p.dirname(destination),
        '.concat-${DateTime.now().microsecondsSinceEpoch}.txt',
      ),
    );
    final partial = File('$destination.part.mp4');
    try {
      await manifest.writeAsString(
        inputs.map((f) => "file '${concatEscape(p.absolute(f))}'").join('\n'),
      );
      await execute(
        [
          '-y',
          '-f',
          'concat',
          '-safe',
          '0',
          '-i',
          manifest.path,
          '-map',
          '0:v:0',
          '-map',
          '0:a:0?',
          '-c',
          'copy',
          '-movflags',
          '+faststart',
          partial.path,
        ],
        onSeconds: (seconds) =>
            progress(duration > 0 ? (seconds / duration).clamp(0, 0.99) : 0),
      );
      final output = await probe(partial.path);
      final actual =
          double.tryParse('${(output['format'] as Map?)?['duration']}') ?? 0;
      if (duration > 0 && (actual - duration).abs() > 2) {
        throw StateError('导出时长校验失败');
      }
      checkCancelled();
      await partial.rename(destination);
      progress(1);
    } finally {
      if (await manifest.exists()) await manifest.delete();
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _normalizeAndMerge(
    List<String> inputs,
    List<Map<String, dynamic>> infos,
    String destination,
    void Function(double) progress,
    void Function(String)? onStatus,
  ) async {
    final target = dominantMediaInfo(infos);
    final firstVideo = (target['streams'] as List).firstWhere(
      (s) => s['codec_type'] == 'video',
    );
    final width = (firstVideo['width'] as int) ~/ 2 * 2;
    final height = (firstVideo['height'] as int) ~/ 2 * 2;
    final scratch = await Directory(
      p.dirname(destination),
    ).createTemp('.normalize-');
    final normalized = <String>[];
    try {
      for (var i = 0; i < inputs.length; i++) {
        checkCancelled();
        onStatus?.call('统一为 $width×$height · 限制线程转码 ${i + 1}/${inputs.length}');
        final path = p.join(scratch.path, '$i.mp4');
        final audio = (infos[i]['streams'] as List).any(
          (s) => s['codec_type'] == 'audio',
        );
        final duration =
            double.tryParse('${(infos[i]['format'] as Map?)?['duration']}') ??
            0;
        await execute(
          [
            '-y',
            '-i',
            inputs[i],
            if (!audio) ...['-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo'],
            '-map',
            '0:v:0',
            '-map',
            audio ? '0:a:0' : '1:a:0',
            '-vf',
            'scale=$width:$height:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=$width:$height:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30,format=yuv420p',
            '-c:v',
            'libx264',
            '-preset',
            'fast',
            '-crf',
            '20',
            '-c:a',
            'aac',
            '-ar',
            '48000',
            '-ac',
            '2',
            '-b:a',
            '160k',
            '-shortest',
            path,
          ],
          onSeconds: (s) => progress(
            (i + (duration > 0 ? (s / duration).clamp(0, 1) : 0)) /
                inputs.length *
                .9,
          ),
        );
        normalized.add(path);
      }
      onStatus?.call('兼容处理完成，正在拼接…');
      await merge(normalized, destination, (v) => progress(.9 + .1 * v));
    } finally {
      await scratch.delete(recursive: true);
    }
  }

  Future<bool> _repairDimensions(
    List<String> inputs,
    List<Map<String, dynamic>> infos,
    String destination,
    void Function(double) progress,
    void Function(String)? onStatus,
  ) async {
    final target = dominantMediaInfo(infos);
    final video = (target['streams'] as List).firstWhere(
      (s) => s['codec_type'] == 'video',
    );
    final codec = video['codec_name'];
    // Reuse originals only for dimension-only differences in supported codecs.
    if (!{'hevc', 'h264'}.contains(codec) ||
        video['pix_fmt'] != 'yuv420p' ||
        infos.any(
          (info) =>
              streamSignature(info, ignoreDimensions: true) !=
              streamSignature(target, ignoreDimensions: true),
        )) {
      return false;
    }
    final width = video['width'] as int, height = video['height'] as int;
    if (width.isOdd || height.isOdd) return false;
    final timebase = '${video['time_base']}'.split('/');
    if (timebase.length != 2 ||
        timebase.first != '1' ||
        int.tryParse(timebase.last) == null) {
      return false;
    }
    final changed = <int>[
      for (var i = 0; i < infos.length; i++)
        if (streamSignature(infos[i]) != streamSignature(target)) i,
    ];
    final scratch = await Directory(
      p.dirname(destination),
    ).createTemp('.repair-');
    try {
      final repaired = [...inputs];
      for (var n = 0; n < changed.length; n++) {
        checkCancelled();
        final i = changed[n];
        onStatus?.call(
          '保留 ${inputs.length - changed.length} 集原流 · 调整 ${n + 1}/${changed.length} 集至 $width×$height',
        );
        final path = p.join(scratch.path, '$i.mp4');
        final duration =
            double.tryParse('${(infos[i]['format'] as Map?)?['duration']}') ??
            0;
        await execute(
          [
            '-y',
            '-i',
            inputs[i],
            '-map',
            '0:v:0',
            '-map',
            '0:a:0?',
            '-vf',
            'scale=$width:$height:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=$width:$height:(ow-iw)/2:(oh-ih)/2,setsar=1',
            '-c:v',
            codec == 'hevc' ? 'libx265' : 'libx264',
            '-preset',
            'fast',
            '-crf',
            '20',
            if (codec == 'hevc') ...[
              '-x265-params',
              'pools=1:frame-threads=1:repeat-headers=1:log-level=error',
            ],
            '-pix_fmt',
            'yuv420p',
            '-r',
            '${video['r_frame_rate']}',
            '-video_track_timescale',
            timebase.last,
            '-c:a',
            'copy',
            path,
          ],
          onSeconds: (s) => progress(
            (n + (duration > 0 ? (s / duration).clamp(0, 1) : 0)) /
                changed.length *
                .75,
          ),
        );
        final info = await probe(path);
        if (streamSignature(info) != streamSignature(target)) return false;
        repaired[i] = path;
      }
      onStatus?.call('差异集数处理完成，正在拼接并校验完整视频…');
      final joined = p.join(scratch.path, 'joined.mp4');
      await merge(repaired, joined, (v) => progress(.75 + .1 * v));
      final duration = infos.fold<double>(
        0,
        (sum, info) =>
            sum +
            (double.tryParse('${(info['format'] as Map?)?['duration']}') ?? 0),
      );
      // Validate every boundary before delivering mixed encoder configurations.
      await execute(
        [
          '-xerror',
          '-i',
          joined,
          '-map',
          '0:v:0',
          '-map',
          '0:a:0?',
          '-f',
          'null',
          '-',
        ],
        onSeconds: (s) => progress(
          .85 + .14 * (duration > 0 ? (s / duration).clamp(0, 1) : 0),
        ),
      );
      checkCancelled();
      await File(joined).rename(destination);
      progress(1);
      return true;
    } on JobCancelled {
      rethrow;
    } catch (_) {
      return false;
    } finally {
      await scratch.delete(recursive: true);
    }
  }
}

Map<String, dynamic> dominantMediaInfo(List<Map<String, dynamic>> infos) {
  final counts = <String, int>{};
  for (final info in infos) {
    final key = streamSignature(info);
    counts[key] = (counts[key] ?? 0) + 1;
  }
  final dominant = counts.entries
      .reduce((a, b) => a.value >= b.value ? a : b)
      .key;
  return infos.firstWhere((info) => streamSignature(info) == dominant);
}

String concatEscape(String path) {
  if (path.contains('\n') || path.contains('\r')) {
    throw const FormatException('文件名不能包含换行符');
  }
  return path.replaceAll('\\', '/').replaceAll("'", "'\\''");
}

/// Bound decoder, encoder and filter pools independently. This is a thread
/// budget, not a promise of a strict OS-wide CPU percentage.
List<String> boundedArguments(List<String> args) {
  final threads = (Platform.numberOfProcessors ~/ 4).clamp(1, 2).toString();
  return [
    '-filter_threads',
    '1',
    '-filter_complex_threads',
    '1',
    for (var i = 0; i < args.length; i++) ...[
      if (args[i] == '-i' || i == args.length - 1) ...['-threads', threads],
      args[i],
    ],
  ];
}

String streamSignature(
  Map<String, dynamic> info, {
  bool ignoreDimensions = false,
}) => jsonEncode([
  for (final s in info['streams'] as List? ?? [])
    if (s['codec_type'] == 'video' || s['codec_type'] == 'audio')
      [
        s['codec_type'],
        s['codec_name'],
        s['profile'],
        if (!ignoreDimensions) s['width'],
        if (!ignoreDimensions) s['height'],
        s['pix_fmt'],
        s['r_frame_rate'],
        s['time_base'],
        s['sample_rate'],
        s['channels'],
        s['channel_layout'],
      ],
]);
