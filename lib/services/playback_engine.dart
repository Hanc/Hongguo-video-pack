import 'package:media_kit/media_kit.dart';
import '../domain/drama.dart';
import '../playback_controller.dart';

/// 内置 libmpv 播放通道。
///
/// 只用一个 [Player]：这是 media_kit 的标准用法，全屏、音轨、字幕等行为与
/// 官方控件一致。连播的加速由控制器提前取好下一集地址完成，不在播放器层
/// 预开第二条通道——两个实例会带来全屏暂停、暂停后仍有声音等问题。
class NativePlaybackEngine implements PlaybackEngine {
  NativePlaybackEngine()
    : player = Player(
        configuration: const PlayerConfiguration(
          title: '红葡萄',
          bufferSize: 32 * 1024 * 1024,
        ),
      );

  final Player player;
  bool _configured = false;
  double _rate = 1;

  @override
  Stream<bool> get completed => player.stream.completed;
  @override
  Stream<String> get errors => player.stream.error;
  @override
  Duration get position => player.state.position;
  @override
  Duration get duration => player.state.duration;

  @override
  Future<void> open(
    MediaVariant media, {
    Duration start = Duration.zero,
  }) async {
    final native = player.platform;
    if (native is! NativePlayer) throw StateError('当前平台不支持内置播放');
    if (!_configured) {
      await native.setProperty('vd-lavc-threads', '2');
      await native.setProperty('cache-on-disk', 'no');
      await native.setProperty('demuxer-max-bytes', '${32 * 1024 * 1024}');
      // 切集时不要在缓冲上再等一轮：签名的取流已经拿到了地址，
      // 首帧越早出越好，不足的数据让播放器边播边补。
      await native.setProperty('cache-secs', '5');
      await native.setProperty('cache-pause-wait', '1');
      await native.setProperty('demuxer-readahead-secs', '1');
      _configured = true;
    }
    if (media.key != null &&
        !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(media.key!)) {
      throw StateError('媒体授权数据无效');
    }
    // 每集的 CENC 密钥不同，必须在 loadfile 之前改好。
    // 不再单独 stop：open 本身会替换当前文件，少一次往返也少一次缓存清空。
    await native.setProperty(
      'demuxer-lavf-o',
      media.key == null ? '' : 'decryption_key=${media.key}',
    );
    await player.open(
      Media(
        media.url,
        httpHeaders: const {'Referer': 'https://novel.snssdk.com/'},
        start: start,
      ),
    );
    if (_rate != 1) await player.setRate(_rate);
  }

  @override
  Future<void> setRate(double rate) async {
    _rate = rate;
    await player.setRate(rate);
  }

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> dispose() => player.dispose();
}
