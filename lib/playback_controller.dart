import 'dart:async';
import 'package:flutter/foundation.dart';
import 'data/hongguo_client.dart';
import 'domain/drama.dart';

abstract class PlaybackEngine {
  Stream<bool> get completed;
  Stream<String> get errors;
  Duration get position;
  Duration get duration;
  Future<void> open(MediaVariant media, {Duration start = Duration.zero});

  /// 播放倍速。
  Future<void> setRate(double rate);
  Future<void> pause();
  Future<void> dispose();
}

class PlaybackController extends ChangeNotifier {
  PlaybackController({
    required this.engine,
    HongguoClient? client,
    double initialRate = 1,
    this.onProgress,
  }) : client = client ?? HongguoClient(),
       rate = nearestSpeed(initialRate) {
    _completed = engine.completed.listen((done) {
      if (done &&
          autoAdvance &&
          !loading &&
          error == null &&
          index + 1 < (drama?.episodes.length ?? 0)) {
        unawaited(play(index + 1));
      }
    });
    _errors = engine.errors.listen((_) {
      if (_disposed || loading) return;
      error = '播放失败，请重试或切换清晰度。';
      notifyListeners();
    });
    _armProgress();
  }
  final PlaybackEngine engine;
  final HongguoClient client;

  /// 定期上报观看位置；由宿主写入本地存储。
  final void Function(int episode, Duration position)? onProgress;
  late final StreamSubscription<bool> _completed;
  late final StreamSubscription<String> _errors;
  Drama? drama;
  List<MediaVariant> variants = [];
  final selected = <int>{};
  int index = 0, quality = 0;
  bool loading = false, autoAdvance = true, _disposed = false;
  double rate;
  String? error;
  int _generation = 0;
  Future<void> _openTail = Future.value();
  Timer? _progressTimer;

  /// 上报间隔：兼顾“关掉不丢位置”和写盘次数。
  static const progressInterval = Duration(seconds: 5);

  /// 已取到的取流结果。签名地址有效期很短，所以只复用很短时间。
  static const prefetchTtl = Duration(minutes: 2);
  final _variants = <int, ({List<MediaVariant> options, DateTime at})>{};
  final _inflight = <int, Future<List<MediaVariant>>>{};

  static const speeds = <double>[.5, .75, 1, 1.25, 1.5, 1.75, 2];
  static double nearestSpeed(double value) =>
      speeds.reduce((a, b) => (a - value).abs() <= (b - value).abs() ? a : b);
  static String speedLabel(double value) =>
      value == value.roundToDouble() ? '${value.toInt()}.0x' : '${value}x';

  Future<List<MediaVariant>> _variantsFor(
    int episodeIndex, {
    bool fresh = false,
  }) async {
    final cached = _variants[episodeIndex];
    if (!fresh &&
        cached != null &&
        DateTime.now().difference(cached.at) < prefetchTtl) {
      return cached.options;
    }
    final pending = _inflight[episodeIndex];
    if (!fresh && pending != null) return pending;
    late final Future<List<MediaVariant>> future;
    future = client
        .fetchVariants(drama!.episodes[episodeIndex], seriesId: drama!.id)
        .then((options) {
          _variants[episodeIndex] = (options: options, at: DateTime.now());
          return options;
        })
        .whenComplete(() {
          if (identical(_inflight[episodeIndex], future)) {
            _inflight.remove(episodeIndex);
          }
        });
    _inflight[episodeIndex] = future;
    return future;
  }

  /// [resumeEpisode] 从 1 开始计数；越界时回到第一集。
  Future<void> load(
    String id, {
    int? resumeEpisode,
    Duration resumePosition = Duration.zero,
  }) async {
    final generation = ++_generation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final value = await client.fetchDrama(id);
      if (_disposed || generation != _generation) return;
      if (value.episodes.isEmpty) throw StateError('来源未返回分集');
      drama = value;
      selected.clear();
      selected.add(value.episodes.first.number);
      _inflight.clear();
      _variants.clear();
      if (rate != 1) await engine.setRate(rate);
      final target = (resumeEpisode ?? 1).clamp(1, value.episodes.length) - 1;
      final start = target == 0 && resumeEpisode == null
          ? Duration.zero
          : resumePosition;
      await play(target, start: start);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      error = '读取分集失败，请重试。';
      loading = false;
      notifyListeners();
    }
  }

  /// 切集或离开页面前，把当前位置记下来。
  void _flushProgress() {
    final report = onProgress;
    if (report == null || _disposed || loading || drama == null) return;
    final position = engine.position;
    if (position <= Duration.zero) return;
    final total = engine.duration;
    // 已经播到结尾的集不必恢复，否则下次会从片尾开始。
    if (total > Duration.zero &&
        position >= total - const Duration(seconds: 3)) {
      return;
    }
    report(index, position);
  }

  void _armProgress() {
    _progressTimer?.cancel();
    if (onProgress == null) return;
    _progressTimer = Timer.periodic(progressInterval, (_) => _flushProgress());
  }

  Future<void> play(int episodeIndex, {Duration start = Duration.zero}) async {
    final value = drama;
    if (_disposed ||
        value == null ||
        episodeIndex < 0 ||
        episodeIndex >= value.episodes.length) {
      return;
    }
    _flushProgress();
    final generation = ++_generation;
    index = episodeIndex;
    loading = true;
    error = null;
    notifyListeners();
    try {
      var options = await _variantsFor(episodeIndex);
      if (_disposed || generation != _generation) return;
      try {
        await _open(options, start, generation);
      } catch (_) {
        // 预取到的签名地址可能已过期，重新取流后重试一次。
        if (_disposed || generation != _generation) return;
        options = await _variantsFor(episodeIndex, fresh: true);
        if (_disposed || generation != _generation) return;
        await _open(options, start, generation);
      }
      if (_disposed || generation != _generation) return;
      loading = false;
      notifyListeners();
      _prefetchNext(generation);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      error = '播放准备失败，请重试或切换清晰度。';
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _open(
    List<MediaVariant> options,
    Duration start,
    int generation,
  ) async {
    final media = chooseQuality(options, quality);
    variants = options;
    final next = _openTail.then((_) async {
      if (_disposed || generation != _generation) return;
      await engine.open(media, start: start);
    });
    _openTail = next.catchError((_) {});
    await next;
  }

  /// 只预取下一集的取流结果（签名 + 地址），不碰播放器。
  void _prefetchNext(int generation) {
    final value = drama;
    if (_disposed || !autoAdvance || value == null) return;
    final next = index + 1;
    if (next >= value.episodes.length) return;
    unawaited(_warm(next, generation));
  }

  Future<void> _warm(int next, int generation) async {
    try {
      await _variantsFor(next);
    } catch (_) {
      /* 预取失败只影响过渡速度，切过去时按需重取。 */
    }
  }

  Future<void> setQuality(int value) async {
    final position = engine.position;
    quality = value;
    await play(index, start: position);
  }

  Future<void> setRate(double value) async {
    final target = nearestSpeed(value);
    if (target == rate) return;
    rate = target;
    await engine.setRate(target);
    notifyListeners();
  }

  void toggleSelection(int number) {
    selected.contains(number) ? selected.remove(number) : selected.add(number);
    notifyListeners();
  }

  void selectAll(bool all) {
    selected.clear();
    if (all) selected.addAll(drama?.episodes.map((e) => e.number) ?? <int>[]);
    notifyListeners();
  }

  void selectRange(int first, int last) {
    if (drama == null ||
        first < 1 ||
        last < first ||
        last > drama!.episodes.last.number) {
      return;
    }
    selected.clear();
    selected.addAll(
      drama!.episodes
          .where((e) => e.number >= first && e.number <= last)
          .map((e) => e.number),
    );
    notifyListeners();
  }

  void setAutoAdvance(bool value) {
    autoAdvance = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _progressTimer?.cancel();
    unawaited(_completed.cancel());
    unawaited(_errors.cancel());
    unawaited(_openTail.then((_) => engine.dispose()));
    client.close();
    super.dispose();
  }
}
