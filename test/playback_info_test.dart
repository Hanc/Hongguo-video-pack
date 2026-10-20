import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/app_controller.dart';
import 'package:hongguo_studio/playback_info.dart';

void main() {
  test('progress label formats episode and position', () {
    expect(
      const PlayProgress(3, Duration(minutes: 2, seconds: 5), '').label,
      '第 3 集 · 2:05',
    );
    expect(
      const PlayProgress(12, Duration(seconds: 7), '').label,
      '第 12 集 · 0:07',
    );
  });

  testWidgets('info panel renders the provided rows and can be closed', (
    tester,
  ) async {
    var closed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: PlaybackInfoPanel(
            info: const PlaybackInfo([
              ('解码分辨率', '1080 × 1920'),
              ('解码方式', '硬解 · yuv420p'),
              ('已缓冲', '0:12'),
            ]),
            onClose: () => closed++,
          ),
        ),
      ),
    );
    expect(find.text('播放信息'), findsOneWidget);
    expect(find.text('1080 × 1920'), findsOneWidget);
    expect(find.text('硬解 · yuv420p'), findsOneWidget);
    expect(find.text('0:12'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();
    expect(closed, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('info panel shows a placeholder when nothing is known yet', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackInfoPanel(info: const PlaybackInfo([]), onClose: () {}),
        ),
      ),
    );
    expect(find.text('正在读取媒体信息…'), findsOneWidget);
  });
}
