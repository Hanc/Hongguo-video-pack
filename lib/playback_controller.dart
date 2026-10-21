import 'dart:async';
import 'package:flutter/foundation.dart';
import 'data/hongguo_client.dart';
import 'domain/drama.dart';

abstract class PlaybackEngine {
  Stream<bool> get completed;
  Stream<String> get errors;
  Duration get position;
  Future<void> open(MediaVariant media, {Duration start = Duration.zero});
  Future<void> pause();
  Future<void> dispose();
}

class PlaybackController extends ChangeNotifier {
  PlaybackController({required this.engine, HongguoClient? client})
    : client = client ?? HongguoClient() {
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
  }
  final PlaybackEngine engine;
  final HongguoClient client;
  late final StreamSubscription<bool> _completed;
  late final StreamSubscription<String> _errors;
  Drama? drama;
  List<MediaVariant> variants = [];
  final selected = <int>{};
  int index = 0, quality = 0;
  bool loading = false, autoAdvance = true, _disposed = false;
  String? error;
  int _generation = 0;
  Future<void> _openTail = Future.value();
  void Function()? onBeforeChange;

  Future<void> load(
    String id, {
    int episode = 1,
    String episodeId = '',
    Duration start = Duration.zero,
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
      var restored = value.episodes.indexWhere(
        (e) => episodeId.isNotEmpty && e.id == episodeId,
      );
      if (restored < 0) {
        restored = value.episodes.indexWhere((e) => e.number == episode);
      }
      await play(restored < 0 ? 0 : restored, start: start);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      error = '读取分集失败，请重试。';
      loading = false;
      notifyListeners();
    }
  }

  Future<void> play(int episodeIndex, {Duration start = Duration.zero}) async {
    final value = drama;
    if (_disposed ||
        value == null ||
        episodeIndex < 0 ||
        episodeIndex >= value.episodes.length) {
      return;
    }
    onBeforeChange?.call();
    final generation = ++_generation;
    index = episodeIndex;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final options = await client.fetchVariants(
        value.episodes[episodeIndex],
        seriesId: value.id,
      );
      if (_disposed || generation != _generation) return;
      final media = chooseQuality(options, quality);
      variants = options;
      final next = _openTail.then((_) async {
        if (_disposed || generation != _generation) return;
        await engine.open(media, start: start);
      });
      _openTail = next.catchError((_) {});
      await next;
      if (_disposed || generation != _generation) return;
      loading = false;
      notifyListeners();
    } catch (_) {
      if (_disposed || generation != _generation) return;
      error = '播放准备失败，请重试或切换清晰度。';
      loading = false;
      notifyListeners();
    }
  }

  Future<void> setQuality(int value) {
    final position = engine.position;
    quality = value;
    return play(index, start: position);
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
    unawaited(_completed.cancel());
    unawaited(_errors.cancel());
    unawaited(_openTail.then((_) => engine.dispose()));
    client.close();
    super.dispose();
  }
}
