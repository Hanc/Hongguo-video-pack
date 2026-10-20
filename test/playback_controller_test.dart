import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/data/hongguo_client.dart';
import 'package:hongguo_studio/domain/drama.dart';
import 'package:hongguo_studio/playback_controller.dart';

class FakePlaybackEngine implements PlaybackEngine {
  final end = StreamController<bool>.broadcast();
  final failure = StreamController<String>.broadcast();
  final opened = <MediaVariant>[];
  final starts = <Duration>[];
  bool paused = false, disposed = false;
  double rate = 1;
  Duration currentPosition = Duration.zero;
  @override
  Stream<bool> get completed => end.stream;
  @override
  Stream<String> get errors => failure.stream;
  @override
  Duration get position => currentPosition;
  @override
  Future<void> open(
    MediaVariant media, {
    Duration start = Duration.zero,
  }) async {
    opened.add(media);
    starts.add(start);
  }

  @override
  Future<void> setRate(double value) async {
    rate = value;
  }

  @override
  Future<void> pause() async {
    paused = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await end.close();
    await failure.close();
  }
}

class FakePlaybackClient extends HongguoClient {
  final calls = <String>[];
  final pending = <String, Completer<List<MediaVariant>>>{};
  @override
  Future<Drama> fetchDrama(String input) async => Drama(
    id: input,
    title: '示例剧集',
    episodes: List.generate(100, (i) => Episode('${i + 1}', i + 1)),
  );
  @override
  Future<List<MediaVariant>> fetchVariants(
    Episode episode, {
    String? seriesId,
  }) {
    calls.add(episode.id);
    return pending[episode.id]?.future ??
        Future.value([
          MediaVariant(
            url: 'https://example.com/${episode.id}.mp4',
            quality: 1080,
            codec: 'hevc',
          ),
          MediaVariant(
            url: 'https://example.com/${episode.id}-720.mp4',
            quality: 720,
            codec: 'h264',
          ),
        ]);
  }
}

void main() {
  test(
    'plays full-list episode, retains seek on quality switch, separates stitch selection',
    () async {
      final engine = FakePlaybackEngine(), client = FakePlaybackClient();
      final c = PlaybackController(engine: engine, client: client);
      addTearDown(c.dispose);
      await c.load('123');
      expect(c.drama!.episodes.length, 100);
      expect(engine.opened.single.quality, 1080);
      expect(c.selected, {1});
      c.selectRange(5, 8);
      expect(c.selected, {5, 6, 7, 8});
      await c.play(9);
      expect(c.selected, {5, 6, 7, 8});
      engine.currentPosition = const Duration(seconds: 12);
      await c.setQuality(720);
      expect(engine.opened.last.quality, 720);
      expect(engine.starts.last, const Duration(seconds: 12));
      expect(c.index, 9);
    },
  );
  test('old slow episode resolution cannot replace a newer choice', () async {
    final engine = FakePlaybackEngine(), client = FakePlaybackClient();
    final c = PlaybackController(engine: engine, client: client);
    addTearDown(c.dispose);
    final slow = Completer<List<MediaVariant>>();
    client.pending['2'] = slow;
    await c.load('123');
    final old = c.play(1);
    await c.play(2);
    slow.complete([
      const MediaVariant(
        url: 'https://example.com/stale.mp4',
        quality: 1080,
        codec: 'hevc',
      ),
    ]);
    await old;
    expect(c.index, 2);
    expect(engine.opened.last.url, 'https://example.com/3.mp4');
    expect(engine.opened.any((m) => m.url.contains('stale')), isFalse);
  });
  test(
    'completion advances once, disabling autoplay keeps current episode; errors are sanitized',
    () async {
      final engine = FakePlaybackEngine(), client = FakePlaybackClient();
      final c = PlaybackController(engine: engine, client: client);
      addTearDown(c.dispose);
      await c.load('123');
      engine.end.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(c.index, 1);
      c.setAutoAdvance(false);
      engine.end.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(c.index, 1);
      engine.failure.add('https://private.example/?token=do-not-display');
      await Future<void>.delayed(Duration.zero);
      expect(c.error, isNot(contains('private')));
      expect(c.error, contains('重试'));
    },
  );
  test(
    'prefetches only the next episode stream so switching does not refetch',
    () async {
      final engine = FakePlaybackEngine(), client = FakePlaybackClient();
      final c = PlaybackController(engine: engine, client: client);
      addTearDown(c.dispose);
      await c.load('123');
      await Future<void>.delayed(Duration.zero);
      // 首集播放后只预取第二集取流，不会打开第二条播放通道。
      expect(engine.opened.single.url, 'https://example.com/1.mp4');
      expect(client.calls, ['1', '2']);
      engine.end.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(c.index, 1);
      expect(engine.opened.last.url, 'https://example.com/2.mp4');
      // 切换用的是预取结果，第二集没有被重复请求。
      expect(client.calls.where((id) => id == '2').length, 1);
      await Future<void>.delayed(Duration.zero);
      expect(client.calls, contains('3'));
    },
  );
  test('playback rate is clamped to a supported speed and reaches the engine', () async {
    final engine = FakePlaybackEngine();
    final c = PlaybackController(
      engine: engine,
      client: FakePlaybackClient(),
      initialRate: 1.4,
    );
    addTearDown(c.dispose);
    await c.load('123');
    expect(c.rate, 1.5);
    expect(engine.rate, 1.5);
    await c.setRate(2);
    expect(c.rate, 2);
    expect(engine.rate, 2);
    await c.setRate(1);
    expect(c.rate, 1);
    expect(engine.rate, 1);
    expect(PlaybackController.speedLabel(1), '1.0x');
    expect(PlaybackController.speedLabel(1.25), '1.25x');
  });
}
