import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/app_controller.dart';
import 'package:hongguo_studio/domain/drama.dart';
import 'package:hongguo_studio/main.dart';

void main() {
  for (final size in [
    const Size(1320, 900),
    const Size(390, 844),
    const Size(320, 740),
  ]) {
    testWidgets('workspace renders and selects episodes at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = StudioController();
      addTearDown(controller.dispose);
      controller.drama = Drama(
        id: '123',
        title: '持械入宋：第一季',
        intro: '宋末年，烽火连天。一支现代五人小队意外坠入时空隧道，全员携械穿越到大宋。',
        episodes: List.generate(100, (i) => Episode('${i + 1}', i + 1)),
      );
      controller.selected.addAll([1, 2]);
      controller.variants = [
        const MediaVariant(
          url: 'https://fixture.example.test',
          quality: 1080,
          codec: 'hevc',
        ),
      ];
      controller.outputDirectory = 'D:/exports';
      if (Platform.environment['HONGGUO_CAPTURE_UI'] == '1' &&
          Platform.isWindows) {
        await tester.runAsync(() async {
          final loader = FontLoader('Microsoft YaHei');
          final bytes = await File('C:/Windows/Fonts/msyh.ttc').readAsBytes();
          loader.addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load();
          final icons = FontLoader('MaterialIcons');
          final iconBytes = await File(
            'D:/envs/flutter-sdk/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes();
          icons.addFont(Future.value(ByteData.sublistView(iconBytes)));
          await icons.load();
        });
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('capture'),
          child: StudioApp(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('持械入宋：第一季'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (Platform.environment['HONGGUO_CAPTURE_UI'] == '1') {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('capture')),
          );
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('.local/qa').create(recursive: true);
          await File(
            '.local/qa/workspace-${size.width.toInt()}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      final episode = find.text('3');
      await tester.ensureVisible(episode);
      await tester.tap(episode);
      await tester.pump();
      expect(controller.selected, contains(3));
      expect(tester.takeException(), isNull);
    });
  }
}
