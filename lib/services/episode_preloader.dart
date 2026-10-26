import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../domain/drama.dart';

class PreloadedEpisode {
  PreloadedEpisode(this.media, this.directory);
  final MediaVariant media;
  final Directory directory;
  Future<void> dispose() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
        return;
      } catch (_) {
        if (attempt < 2) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  }
}

/// Owns only application-created temporary episode directories, never exports.
class EpisodePreloader {
  EpisodePreloader({required this.directory, http.Client Function()? client})
    : _clientFactory = client ?? (() => http.Client());
  final Future<Directory> Function() directory;
  final http.Client Function() _clientFactory;
  http.Client? _active;
  int _generation = 0;
  static const maxBytes = 64 * 1024 * 1024;
  void cancel() {
    _generation++;
    _active?.close();
    _active = null;
  }

  Future<PreloadedEpisode?> load(MediaVariant media) async {
    cancel();
    final generation = _generation;
    final uri = Uri.tryParse(media.url);
    if (uri == null || !{'http', 'https'}.contains(uri.scheme)) return null;
    Directory? temporary;
    IOSink? sink;
    Timer? deadline;
    final client = _clientFactory();
    _active = client;
    try {
      final root = await directory();
      await root.create(recursive: true);
      // Recover only our abandoned temporary folders after a prior crash.
      await for (final entity in root.list(followLinks: false)) {
        if (entity is Directory &&
            p.basename(entity.path).startsWith('next-')) {
          try {
            if (DateTime.now()
                    .difference(await entity.stat().then((s) => s.modified))
                    .inHours >=
                24) {
              await entity.delete(recursive: true);
            }
          } catch (_) {}
        }
      }
      if (generation != _generation) return null;
      temporary = await root.createTemp('next-');
      final file = File(p.join(temporary.path, 'episode.mp4'));
      deadline = Timer(const Duration(seconds: 60), client.close);
      final response = await client
          .send(
            http.Request('GET', uri)
              ..headers['Referer'] = 'https://novel.snssdk.com/',
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > maxBytes) {
        return null;
      }
      sink = file.openWrite();
      var bytes = 0;
      final watch = Stopwatch()..start();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        if (generation != _generation ||
            watch.elapsed > const Duration(seconds: 60)) {
          return null;
        }
        bytes += chunk.length;
        if (bytes > maxBytes) return null;
        sink.add(chunk);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (generation != _generation ||
          bytes == 0 ||
          (response.contentLength != null && bytes != response.contentLength)) {
        return null;
      }
      final result = PreloadedEpisode(
        MediaVariant(
          url: file.uri.toString(),
          quality: media.quality,
          codec: media.codec,
          key: media.key,
          duration: media.duration,
          source: media.source,
        ),
        temporary,
      );
      temporary =
          null; // Ownership transfers to playback until the demuxer stops.
      return result;
    } catch (_) {
      return null;
    } finally {
      deadline?.cancel();
      try {
        await sink?.close();
      } catch (_) {}
      client.close();
      if (identical(_active, client)) _active = null;
      if (temporary != null) {
        try {
          await temporary.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}
