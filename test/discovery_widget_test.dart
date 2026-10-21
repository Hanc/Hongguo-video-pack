import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/app_controller.dart';
import 'package:hongguo_studio/discovery_controller.dart';
import 'package:hongguo_studio/domain/discovery.dart';
import 'package:hongguo_studio/main.dart';

void main() {
  for (final width in [1320.0, 390.0, 320.0]) {
    testWidgets('discover, details and navigation at $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = StudioController();
      final d = DiscoveryController();
      addTearDown(c.dispose);
      addTearDown(d.dispose);
      d.items = List.generate(
        8,
        (i) => DramaSummary(
          id: '${i + 1}',
          title: [
            '持械入宋：第一季',
            '满院亲戚全是上古大妖',
            '今天的故事，从这里开始',
            '长标题也需要完整展示的漫剧',
          ][i % 4],
          intro: '一支现代小队，意外穿越到大宋。新的故事正在发生。',
          rank: i + 1,
          episodes: 100,
          heat: '${5362 - i * 100}万热度',
          tags: ['穿越', '漫剧'],
        ),
      );
      d.result = DiscoveryPage(d.items);
      if (Platform.environment['HONGGUO_CAPTURE_UI'] == '1' &&
          Platform.isWindows) {
        await tester.runAsync(() async {
          for (final font in [
            ('Microsoft YaHei', 'C:/Windows/Fonts/msyh.ttc'),
            (
              'MaterialIcons',
              'D:/envs/flutter-sdk/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ),
          ]) {
            final loader = FontLoader(font.$1);
            loader.addFont(
              Future.value(
                ByteData.sublistView(await File(font.$2).readAsBytes()),
              ),
            );
            await loader.load();
          }
        });
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('discovery-capture'),
          child: StudioApp(controller: c, discoveryController: d),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('发现').last);
      await tester.pumpAndSettle();
      expect(find.text('今天，想看什么故事？'), findsOneWidget);
      expect(find.text('HONGGUO  /  STUDIO'), findsNothing);
      expect(find.text('MAKE STORIES FLOW'), findsNothing);
      expect(find.widgetWithText(TextField, '搜索剧名'), findsOneWidget);
      expect(find.text('5362万热度'), findsOneWidget);
      final chips = tester
          .widgetList<ChoiceChip>(find.byType(ChoiceChip))
          .toList();
      expect(chips.length, 4);
      final positions = find
          .byType(ChoiceChip)
          .evaluate()
          .map((element) => tester.getTopLeft(find.byWidget(element.widget)).dy)
          .toSet();
      expect(
        positions.length,
        1,
        reason: 'Ranking filters must stay on one line',
      );
      expect(tester.takeException(), isNull);
      if (Platform.environment['HONGGUO_CAPTURE_UI'] == '1') {
        await tester.runAsync(
          () => precacheImage(
            const AssetImage('assets/branding/logo.png'),
            tester.element(find.byType(StudioApp)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('discovery-capture')),
          );
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('.local/qa').create(recursive: true);
          await File(
            '.local/qa/discovery-${width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final dramaTitle = find.text('持械入宋：第一季').first;
      await tester.ensureVisible(dramaTitle);
      await tester.pumpAndSettle();
      await tester.longPress(dramaTitle);
      await tester.pumpAndSettle();
      expect(find.text('加入工作台'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tapAt(const Offset(8, 100));
      await tester.pumpAndSettle();
      await tester.tap(find.text('任务').last);
      await tester.pumpAndSettle();
      expect(find.text('任务与导出'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
