import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hongguo_studio/services/app_updater.dart';
import 'package:hongguo_studio/update_view.dart';
import 'app_updater_test.dart' show release;

void main() {
  for (final width in [320.0, 1320.0]) {
    testWidgets(
      'update page shows stable version and blocks task interruption at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final updater = AppUpdater(
          versionReader: () async => '1.0.0',
          giteeRepository: '',
          client: MockClient(
            (_) async => http.Response(jsonEncode([release('v2.0.0')]), 200),
          ),
        );
        addTearDown(updater.dispose);
        await updater.check();
        // No executable is created or run by this UI test.
        updater.readyFile = File('never-run.exe');
        var installs = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: UpdateScreen(
              updater: updater,
              busy: () => true,
              install: () async {
                installs++;
                return true;
              },
              openRelease: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('当前版本：1.0.0'), findsOneWidget);
        await tester.tap(find.text('安装更新'));
        await tester.pumpAndSettle();
        expect(installs, 0);
        expect(find.text('请先完成或取消当前拼接任务，再安装更新。'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
