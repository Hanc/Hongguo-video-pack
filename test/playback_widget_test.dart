import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/app_controller.dart';
import 'package:hongguo_studio/domain/discovery.dart';
import 'package:hongguo_studio/domain/drama.dart';
import 'package:hongguo_studio/playback_controller.dart';
import 'package:hongguo_studio/playback_view.dart';
import 'playback_controller_test.dart'
    show FakePlaybackEngine, FakePlaybackClient;

void main() {
  for (final width in [1320.0, 390.0, 320.0]) {
    testWidgets('playback, stitching and task entry at $width', (tester) async {
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final engine = FakePlaybackEngine();
      final c = PlaybackController(
        engine: engine,
        client: FakePlaybackClient(),
      );
      final tasks = StudioController();
      await c.load('123');
      if (Platform.environment['HONGGUO_CAPTURE_UI'] == '1' &&
          Platform.isWindows) {
        await tester.runAsync(() async {
          final loader = FontLoader('Microsoft YaHei');
          loader.addFont(
            Future.value(
              ByteData.sublistView(
                await File('C:/Windows/Fonts/msyh.ttc').readAsBytes(),
              ),
            ),
          );
          await loader.load();
          final icons = FontLoader('MaterialIcons');
          icons.addFont(
            Future.value(
              ByteData.sublistView(
                await File(
                  'D:/envs/flutter-sdk/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
                ).readAsBytes(),
              ),
            ),
          );
          await icons.load();
        });
      }
      var stitched = <int>{}, taskVisits = 0;
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('player-capture'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: 'Microsoft YaHei',
              platform: width < 600
                  ? TargetPlatform.android
                  : TargetPlatform.windows,
              colorScheme: ColorScheme.fromSeed(
                seedColor: const Color(0xFFC20032),
              ),
            ),
            home: PlaybackScreen(
              summary: const DramaSummary(id: '123', title: '示例剧集'),
              tasks: tasks,
              controller: c,
              videoBuilder: () => const ColoredBox(color: Colors.black),
              onStitch: (_, selection, _) async {
                stitched = selection;
                return true;
              },
              onTasks: () => taskVisits++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (Platform.environment['HONGGUO_CAPTURE_UI'] == '1') {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('player-capture')),
          );
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('.local/qa').create(recursive: true);
          await File(
            '.local/qa/player-${width.toInt()}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(find.text('任务管理'), findsOneWidget);
      await tester.tap(find.text('任务管理'));
      expect(taskVisits, 1);
      await tester.ensureVisible(find.text('拼接所选 1 集'));
      await tester.tap(find.text('拼接所选 1 集'));
      await tester.pumpAndSettle();
      expect(stitched, {1});
      await tester.ensureVisible(find.byKey(const ValueKey('episode-13')));
      await tester.pumpAndSettle();
      final cells = [
        for (var number = 1; number <= 50; number++)
          tester.getRect(find.byKey(ValueKey('episode-$number'))),
      ];
      for (final cell in cells) {
        expect(cell.width, closeTo(cells.first.width, .01));
        expect(cell.height, closeTo(cells.first.height, .01));
      }
      final columns = cells.where((rect) => rect.top == cells.first.top).length;
      for (var i = 0; i < cells.length; i++) {
        expect(
          cells[i].left,
          closeTo(cells[i % columns].left, .01),
          reason: 'Single and double digit episodes share column edges',
        );
      }
      await c.play(12);
      await tester.pumpAndSettle();
      for (var number = 1; number <= 50; number++) {
        expect(
          tester.getRect(find.byKey(ValueKey('episode-$number'))),
          cells[number - 1],
          reason: 'Selection must not move cells',
        );
      }
      if (Platform.environment['HONGGUO_CAPTURE_UI'] == '1') {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('player-capture')),
          );
          final image = await boundary.toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '.local/qa/episodes-${width.toInt()}.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
      tasks.dispose();
    });
  }

  // 倍速入口在播放器控制栏内；控制栏只在真实 Video 就绪时渲染，
  // 因此这里直接验证控制栏按钮组件本身，倍速下发由控制器用例覆盖。
  testWidgets('player speed button offers every supported rate', (
    tester,
  ) async {
    double? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: Center(
            child: PlaybackSpeedButton(
              rate: 1.0,
              onChanged: (value) => picked = value,
            ),
          ),
        ),
      ),
    );
    expect(find.byTooltip('倍速'), findsOneWidget);
    expect(find.text('1.0x'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<double>));
    await tester.pumpAndSettle();
    // 菜单里应包含全部受支持档位。
    for (final value in PlaybackController.speeds) {
      expect(find.text(PlaybackController.speedLabel(value)), findsWidgets);
    }
    await tester.tap(find.text('1.5x').last);
    await tester.pumpAndSettle();
    expect(picked, 1.5);
    expect(tester.takeException(), isNull);
  });

  // 全屏返回按钮必须真的能退出：这里覆盖「拿不到全屏上下文」时的兜底路径，
  // 也就是之前点击无反应的那条。
  testWidgets('fullscreen back button always closes the fullscreen route', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const Scaffold(body: Center(child: FullscreenBackButton())),
                  ),
                ),
                child: const Text('进入全屏'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('进入全屏'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('退出全屏'), findsOneWidget);

    await tester.tap(find.byTooltip('退出全屏'));
    await tester.pumpAndSettle();
    // 回到上一页，说明按钮确实退出了全屏路由。
    expect(find.text('进入全屏'), findsOneWidget);
    expect(find.byTooltip('退出全屏'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // 红果短剧多为竖屏（1080×1920）。对竖屏内容强制横屏只会出现黑边，
  // 所以方向必须按视频自身比例决定，而不是一律横屏。
  test('fullscreen orientation follows the video aspect', () {
    // 竖屏短剧：全屏也保持竖屏，只隐藏系统栏。
    expect(
      orientationsFor(fullscreen: true, landscape: false),
      [DeviceOrientation.portraitUp],
    );
    // 横屏内容：才真的转横屏。
    expect(
      orientationsFor(fullscreen: true, landscape: true),
      [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight],
    );
    // 宽高未知时不强行旋转，避免在竖屏短剧上转出黑边。
    expect(
      orientationsFor(fullscreen: true, landscape: null),
      [DeviceOrientation.portraitUp],
    );
    // 退出全屏一律回竖屏。
    expect(
      orientationsFor(fullscreen: false, landscape: true),
      [DeviceOrientation.portraitUp],
    );
  });

  test('media variant exposes landscape only when both sides are known', () {
    const vertical = MediaVariant(
      url: 'u',
      quality: 1080,
      codec: 'hevc',
      width: 1080,
      height: 1920,
    );
    const horizontal = MediaVariant(
      url: 'u',
      quality: 1080,
      codec: 'hevc',
      width: 1920,
      height: 1080,
    );
    const unknown = MediaVariant(url: 'u', quality: 1080, codec: 'hevc');
    expect(vertical.isLandscape, isFalse);
    expect(horizontal.isLandscape, isTrue);
    expect(unknown.isLandscape, isNull);
  });
}
