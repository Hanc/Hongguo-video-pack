import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/app_controller.dart';
import 'package:hongguo_studio/data/hongguo_client.dart';
import 'package:hongguo_studio/domain/drama.dart';
import 'package:hongguo_studio/services/media_engine.dart';
import 'package:path/path.dart' as p;

class TestClient extends HongguoClient {
  int lookups = 0;
  @override
  Future<Drama> fetchDrama(String input) async => const Drama(
    id: '123',
    title: '缓存测试',
    episodes: [Episode('11', 1), Episode('22', 2)],
  );
  @override
  Future<List<MediaVariant>> fetchVariants(
    Episode episode, {
    String? seriesId,
  }) async {
    lookups++;
    return [
      const MediaVariant(
        url: 'https://example.test/media',
        quality: 1080,
        codec: 'hevc',
        duration: 1,
      ),
    ];
  }
}

class TestEngine extends MediaEngine {
  int downloads = 0;
  bool stopNext = false;
  @override
  Future<Map<String, dynamic>> probe(String file) async {
    if (!await File(file).exists()) throw StateError('missing');
    return {
      'streams': [
        {'codec_type': 'video', 'width': 1080, 'height': 1920},
      ],
      'format': {'duration': '1'},
    };
  }

  @override
  Future<void> download(
    MediaVariant media,
    String destination,
    void Function(double) progress,
  ) async {
    checkCancelled();
    if (stopNext) {
      stopNext = false;
      await cancel();
      checkCancelled();
    }
    downloads++;
    await File(destination).writeAsString('clip');
    progress(1);
  }

  @override
  Future<void> merge(
    List<String> inputs,
    String destination,
    void Function(double) progress, {
    bool normalize = false,
    void Function(String)? onStatus,
  }) async {
    checkCancelled();
    await File(destination).writeAsString('merged');
    progress(1);
  }
}

void main() {
  test(
    'completed episodes survive retries; history persists; cache cleanup preserves exports',
    () async {
      final dir = await Directory.systemTemp.createTemp('hongguo-controller-');
      final engine = TestEngine(), client = TestClient();
      final c = StudioController(client: client, engine: engine);
      try {
        final store = File(p.join(dir.path, 'state.json'));
        await c.initialize(store, p.join(dir.path, 'exports'));
        await c.load('123');
        await c.assemble();
        expect(c.error, isNull);
        expect(engine.downloads, 2);
        expect(c.history.length, 1);
        final first = c.output!;
        await c.assemble();
        expect(engine.downloads, 2);
        expect(c.events.any((e) => e.contains('复用第')), isTrue);
        c.selectRange(2, 2);
        c.setQuality(1080);
        await c.flush();
        expect(
          (jsonDecode(await store.readAsString())['history'] as List).length,
          2,
        );
        await c.clearCache();
        expect(await File(first).exists(), isTrue);
        expect(
          await Directory(p.join(c.outputDirectory, '.hongguo-cache')).exists(),
          isFalse,
        );
        final restored = StudioController(
          client: TestClient(),
          engine: TestEngine(),
        );
        await restored.initialize(store, c.outputDirectory);
        expect(restored.history.length, 2);
        await restored.load("123");
        expect(restored.selected, {2});
        expect(restored.quality, 1080);
        restored.dispose();
      } finally {
        c.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'cancelled job can restart and never reports a finished output',
    () async {
      final dir = await Directory.systemTemp.createTemp('hongguo-cancel-');
      final engine = TestEngine()..stopNext = true;
      final c = StudioController(client: TestClient(), engine: engine);
      try {
        c.outputDirectory = dir.path;
        await c.load('123');
        await c.assemble();
        expect(c.output, isNull);
        expect(c.busy, isFalse);
        expect(c.status, contains('已取消'));
        await c.assemble();
        expect(c.output, isNotNull);
        expect(c.history.length, 1);
      } finally {
        c.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
}
