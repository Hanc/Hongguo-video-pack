import 'package:media_kit/media_kit.dart';
import '../domain/drama.dart';
import '../playback_controller.dart';

class NativePlaybackEngine implements PlaybackEngine {
  NativePlaybackEngine()
    : player = Player(
        configuration: const PlayerConfiguration(
          title: '红葡萄',
          bufferSize: 32 * 1024 * 1024,
        ),
      );
  final Player player;
  static NativePlaybackEngine? _active;
  bool _configured = false;
  @override
  Stream<bool> get completed => player.stream.completed;
  @override
  Stream<String> get errors => player.stream.error;
  @override
  Duration get position => player.state.position;
  @override
  Future<void> open(
    MediaVariant media, {
    Duration start = Duration.zero,
  }) async {
    final previous = _active;
    if (previous != null && previous != this) await previous.pause();
    _active = this;
    final native = player.platform;
    if (native is! NativePlayer) throw StateError('当前平台不支持内置播放');
    if (!_configured) {
      await native.setProperty('vd-lavc-threads', '2');
      await native.setProperty('cache-on-disk', 'no');
      await native.setProperty('demuxer-max-bytes', '${32 * 1024 * 1024}');
      _configured = true;
    }
    if (media.key != null &&
        !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(media.key!)) {
      throw StateError('媒体授权数据无效');
    }
    // Stop the previous demuxer before changing a per-episode CENC key.
    await player.stop();
    await native.setProperty(
      'demuxer-lavf-o',
      media.key == null ? '' : 'decryption_key=${media.key}',
    );
    await player.open(
      Media(
        media.url,
        httpHeaders: Uri.parse(media.url).scheme == 'file'
            ? const {}
            : const {'Referer': 'https://novel.snssdk.com/'},
        start: start,
      ),
    );
  }

  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> dispose() {
    if (_active == this) _active = null;
    return player.dispose();
  }
}
