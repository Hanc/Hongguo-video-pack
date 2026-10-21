import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/watch_history.dart';
import 'package:path/path.dart' as p;

void main() {
  test('completion requires more than 80 percent of final episode', () {
    final point = WatchPoint(title: '故事');
    point.updateProgress(90, 100, finalEpisode: false);
    expect(point.watched, false);
    point.updateProgress(80, 100, finalEpisode: true);
    expect(point.watched, false);
    point.updateProgress(81, 100, finalEpisode: true);
    expect(point.watched, true);
    point.updateProgress(20, 100, finalEpisode: false);
    expect(point.watched, true);
  });
  test(
    'series merges only ordinal differences and retains exact latest episode',
    () async {
      final history = WatchHistory();
      addTearDown(history.dispose);
      history.record(
        WatchPoint(title: '故事第一季', dramaId: '1', positionMs: 1234),
      );
      history.record(
        WatchPoint(
          title: '故事第2季',
          dramaId: '2',
          episode: 18,
          episodeId: '218',
          positionMs: 2345,
        ),
      );
      expect(history.entries.length, 1);
      expect(history.entries.single.current.dramaId, '2');
      expect(history.onlineFor('2')!.episodeId, '218');
      expect(history.onlineFor('2')!.positionMs, 2345);
      expect(historySeriesKey('故事第1季：雪'), isNot(historySeriesKey('故事第2季：雨')));
      expect(historySeriesKey('重生80年代'), isNot(historySeriesKey('重生90年代')));
    },
  );
  test(
    'evict watched first, then oldest; retained files do not consume online allowance',
    () async {
      var time = DateTime(2026);
      final history = WatchHistory(
        limit: 2,
        now: () {
          time = time.add(const Duration(seconds: 1));
          return time;
        },
      );
      addTearDown(history.dispose);
      history.record(WatchPoint(title: 'old', dramaId: '1'));
      history.record(WatchPoint(title: 'watched', dramaId: '2', watched: true));
      history.record(WatchPoint(title: 'new', dramaId: '3'));
      expect(history.entries.map((e) => e.current.title), ['new', 'old']);
      history.record(WatchPoint(title: 'newest', dramaId: '4'));
      expect(history.entries.map((e) => e.current.title), ['newest', 'new']);
      history.record(WatchPoint(title: 'retained', path: 'retained.mp4'));
      expect(history.entries.length, 3);
      expect(history.entries.where((e) => !e.protected).length, 2);
    },
  );
  test(
    'restart, grouped local seek points, missing file cleanup, deletion tombstone and backup',
    () async {
      final base = Directory(
        Platform.isWindows
            ? 'D:/tmp/hongputao-watch-history-tests'
            : p.join(
                Directory.systemTemp.path,
                'hongputao-watch-history-tests',
              ),
      );
      await base.create(recursive: true);
      final dir = await base.createTemp('history-');
      final histories = <WatchHistory>[];
      addTearDown(() async {
        for (final history in histories) {
          history.dispose();
          await history.flush();
        }
        if (!p.isWithin(base.absolute.path, dir.absolute.path)) {
          throw StateError('Unsafe test cleanup');
        }
        await dir.delete(recursive: true);
      });
      final file1 = await File(
        p.join(dir.path, 'one.mp4'),
      ).writeAsString('one');
      final file2 = await File(
        p.join(dir.path, 'two.mp4'),
      ).writeAsString('two');
      final store = File(p.join(dir.path, 'data', 'watch-history.json'));
      final first = WatchHistory();
      histories.add(first);
      await first.initialize(store);
      first.record(
        WatchPoint(
          title: '故事第1季',
          dramaId: '1',
          episode: 12,
          episodeId: '112',
          positionMs: 145000,
        ),
      );
      first.record(
        WatchPoint(title: '故事第2季', path: file1.path, positionMs: 345000),
      );
      first.record(
        WatchPoint(title: '故事第3季', path: file2.path, positionMs: 678000),
      );
      expect(first.entries.length, 1);
      expect(first.entries.single.files.length, 2);
      await first.flush();
      final second = WatchHistory();
      histories.add(second);
      await second.initialize(store);
      expect(second.onlineFor('1')!.positionMs, 145000);
      expect(second.fileFor(file1.path)!.positionMs, 345000);
      expect(second.fileFor(file2.path)!.positionMs, 678000);
      await file2.delete();
      await second.pruneMissing();
      expect(second.fileFor(file2.path), isNull);
      expect(second.entries.single.current.dramaId, '1');
      await second.remove(second.entries.single.key);
      expect(await file1.exists(), true);
      final third = WatchHistory();
      histories.add(third);
      await third.initialize(store);
      third.record(
        WatchPoint(title: '故事第2季', path: file1.path),
        importing: true,
      );
      expect(third.entries, isEmpty);
      third.record(
        WatchPoint(title: '故事第2季', path: file1.path, positionMs: 555),
      );
      await third.flush();
      await store.writeAsString('corrupt');
      final backup = WatchHistory();
      histories.add(backup);
      await backup.initialize(store);
      expect(backup.fileFor(file1.path)!.positionMs, 555);
    },
  );
}
