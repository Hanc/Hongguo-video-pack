import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/playback_gestures.dart';

void main() {
  // 红果式：整屏上下滑切集，没有亮度/音量手势区。
  testWidgets('full screen swipes switch episodes and lock direction', (
    tester,
  ) async {
    final seeks = <Duration>[];
    final episodes = <int>[];
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
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 左侧、右侧、中间都能切集：上滑下一集，下滑上一集。
    await tester.dragFrom(const Offset(100, 220), const Offset(0, -80));
    await tester.dragFrom(const Offset(700, 220), const Offset(0, 80));
    await tester.dragFrom(const Offset(400, 220), const Offset(0, -80));
    await tester.dragFrom(const Offset(400, 180), const Offset(0, 80));
    expect(episodes, [1, -1, 1, -1]);

    // 小于阈值的竖向拖动不算切集。
    await tester.dragFrom(const Offset(400, 220), const Offset(0, -20));
    expect(episodes, [1, -1, 1, -1]);

    // 方向锁定在第一次超过阈值时；之后的大幅横向位移不再改写为横向。
    final diagonal = await tester.startGesture(const Offset(400, 220));
    await diagonal.moveBy(const Offset(0, -30));
    await diagonal.moveBy(const Offset(180, -50));
    await diagonal.up();
    expect(episodes, [1, -1, 1, -1, 1]);
    expect(seeks, isEmpty, reason: 'Vertical direction stays locked');

    // 横向拖动调进度，两端夹紧。
    await tester.dragFrom(const Offset(400, 200), const Offset(300, 0));
    expect(seeks.last, const Duration(seconds: 60));
    await tester.dragFrom(const Offset(400, 200), const Offset(-300, 0));
    expect(seeks.last, Duration.zero);
    final gesture = await tester.startGesture(const Offset(400, 200));
    await gesture.moveBy(const Offset(100, 0));
    await gesture.cancel();
    expect(seeks.length, 2, reason: '取消的拖动不提交进度');
    expect(tester.takeException(), isNull);
  });

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

  // 长按临时加速：按住 400ms 触发，移动则取消，松手结束。
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

    // 按住不动超过阈值：触发加速，且不产生跳转或切集。
    final hold = await tester.startGesture(const Offset(760, 200));
    await tester.pump(const Duration(milliseconds: 500));
    expect(boosts, 1);
    expect(find.text('2.0x 加速中'), findsOneWidget);
    await hold.up();
    await tester.pump();
    expect(ends, 1);
    expect(seeks, isEmpty);

    // 按住后移动：取消加速，走正常的横向拖动。
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

  // 单击浮出控制栏；长按只加速，不能顺带被当成点击。
  testWidgets('a tap toggles the overlay but a long press does not', (
    tester,
  ) async {
    var taps = 0, boosts = 0;
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
                seek: (_) async {},
                changeEpisode: (_) {},
                onTap: () => taps++,
                onBoostStart: () {
                  boosts++;
                  return null;
                },
                child: const ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tapAt(const Offset(400, 200));
    await tester.pump(const Duration(milliseconds: 500));
    expect(taps, 1);

    final hold = await tester.startGesture(const Offset(200, 200));
    await tester.pump(const Duration(milliseconds: 500));
    await hold.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(boosts, 1);
    expect(taps, 1, reason: '长按不应额外触发控制栏');
  });
}
