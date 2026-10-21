import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/playback_gestures.dart';

void main() {
  testWidgets(
    'fullscreen regions, direction lock, seek clamp and cancellation',
    (tester) async {
      final levels = <(bool, double)>[];
      final seeks = <Duration>[];
      final episodes = <int>[];
      var resets = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 800,
                height: 400,
                child: PlaybackGestures(
                  position: () => const Duration(seconds: 30),
                  duration: () => const Duration(seconds: 60),
                  seek: (value) async {
                    seeks.add(value);
                  },
                  changeEpisode: episodes.add,
                  levels: () async => (.5, .5),
                  setLevel: (light, value) async {
                    levels.add((light, value));
                  },
                  onDispose: () => resets++,
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.dragFrom(const Offset(100, 220), const Offset(0, -80));
      await tester.pump();
      expect(levels.last.$1, isTrue);
      expect(levels.last.$2, greaterThan(.5));
      await tester.dragFrom(const Offset(700, 220), const Offset(0, 80));
      await tester.pump();
      expect(levels.last.$1, isFalse);
      expect(levels.last.$2, lessThan(.5));
      expect(episodes, isEmpty);
      await tester.dragFrom(const Offset(400, 220), const Offset(0, -80));
      await tester.dragFrom(const Offset(400, 180), const Offset(0, 80));
      expect(episodes, [1, -1]);
      final diagonal = await tester.startGesture(const Offset(400, 220));
      await diagonal.moveBy(const Offset(0, -30));
      await diagonal.moveBy(const Offset(180, -50));
      await diagonal.up();
      expect(episodes, [1, -1, 1]);
      expect(seeks, isEmpty, reason: 'Vertical direction stays locked');
      await tester.dragFrom(const Offset(400, 200), const Offset(300, 0));
      expect(seeks.last, const Duration(seconds: 60));
      await tester.dragFrom(const Offset(400, 200), const Offset(-300, 0));
      expect(seeks.last, Duration.zero);
      final gesture = await tester.startGesture(const Offset(400, 200));
      await gesture.moveBy(const Offset(100, 0));
      await gesture.cancel();
      expect(seeks.length, 2);
      final count = levels.length;
      await tester.dragFrom(const Offset(100, 30), const Offset(0, 80));
      expect(levels.length, count);
      await tester.pumpWidget(const SizedBox());
      expect(resets, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('double tap seeks 10s and toggles playback in the middle', (
    tester,
  ) async {
    final seeks = <Duration>[];
    var toggles = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 800,
              height: 400,
              child: PlaybackGestures(
                position: () => const Duration(seconds: 30),
                duration: () => const Duration(seconds: 60),
                seek: (value) async => seeks.add(value),
                changeEpisode: (_) {},
                levels: () async => (.5, .5),
                setLevel: (_, _) async {},
                onTogglePlay: () => toggles++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    Future<void> doubleTapAt(Offset point) async {
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 30));
      await tester.tapAt(point);
      await tester.pump();
    }

    // 右侧三分之一：前进 10 秒（30 → 40）。
    await doubleTapAt(const Offset(760, 200));
    expect(seeks.last, const Duration(seconds: 40));
    // 左侧三分之一：后退 10 秒（30 → 20）。
    await doubleTapAt(const Offset(40, 200));
    expect(seeks.last, const Duration(seconds: 20));
    // 中间：切换播放/暂停，不跳转。
    final before = seeks.length;
    await doubleTapAt(const Offset(400, 200));
    expect(toggles, 1);
    expect(seeks.length, before);

    // 收尾：让提示浮层的计时器结束，避免留下未完成的 Timer。
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  // 长按左右两侧临时加速：按住 400ms 触发，移动则取消，松手结束。
  testWidgets('long press boosts until release and movement cancels it', (
    tester,
  ) async {
    var boosts = 0, ends = 0;
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 800,
              height: 400,
              child: PlaybackGestures(
                position: () => const Duration(seconds: 30),
                duration: () => const Duration(seconds: 60),
                seek: (value) async => seeks.add(value),
                changeEpisode: (_) {},
                levels: () async => (.5, .5),
                setLevel: (_, _) async {},
                onBoostStart: () {
                  boosts++;
                  return '2.0x 加速中';
                },
                onBoostEnd: () => ends++,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 按住不动超过阈值：触发加速。
    final hold = await tester.startGesture(const Offset(760, 200));
    await tester.pump(const Duration(milliseconds: 500));
    expect(boosts, 1);
    expect(find.text('2.0x 加速中'), findsOneWidget);
    await hold.up();
    await tester.pump();
    expect(ends, 1);
    // 长按不应同时被当成点击或拖动。
    expect(seeks, isEmpty);

    // 按住后移动：取消加速，走正常的拖动手势。
    final drag = await tester.startGesture(const Offset(400, 200));
    await drag.moveBy(const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 500));
    expect(boosts, 1, reason: '移动后不应触发加速');
    await drag.up();
    await tester.pump();

    // 清理提示计时器。
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
