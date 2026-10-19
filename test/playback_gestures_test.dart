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
}
