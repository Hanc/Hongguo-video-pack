import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/watch_history.dart';
import 'package:hongguo_studio/watch_history_view.dart';

void main() {
  for (final width in [320.0, 390.0, 1320.0]) {
    testWidgets(
      'recent three stay in one row and resume saved points at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var clock = DateTime(2026);
        final history = WatchHistory(
          now: () => clock = clock.add(const Duration(seconds: 1)),
        );
        addTearDown(history.dispose);
        for (var i = 0; i < 5; i++) {
          history.record(
            WatchPoint(
              title: '故事$i',
              dramaId: '$i',
              episode: i + 1,
              positionMs: 12345 + i,
            ),
          );
        }
        WatchPoint? resumed;
        var all = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: RecentHistory(
                  history: history,
                  onResume: (point) => resumed = point,
                  onAll: () => all = true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('故事0'), findsNothing);
        expect(find.text('故事1'), findsNothing);
        final tops = [
          for (final i in [2, 3, 4]) tester.getTopLeft(find.text('故事$i')).dy,
        ];
        expect(tops.toSet().length, 1);
        await tester.tap(find.text('故事4'));
        expect(resumed!.episode, 5);
        expect(resumed!.positionMs, 12349);
        await tester.tap(find.text('全部记录'));
        expect(all, true);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('history deletes an entry after confirmation', (tester) async {
    final history = WatchHistory();
    addTearDown(history.dispose);
    history.record(WatchPoint(title: '故事', dramaId: '1'));
    await tester.pumpWidget(
      MaterialApp(
        home: WatchHistoryScreen(history: history, onResume: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('删除记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除记录'));
    await tester.pumpAndSettle();
    expect(find.text('暂无观看记录'), findsOneWidget);
  });
}
