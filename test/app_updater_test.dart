import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:hongguo_studio/services/app_updater.dart';

Map<String, dynamic> release(
  String tag, {
  bool prerelease = false,
  bool draft = false,
  String platform = 'windows',
  List<int> bytes = const [1, 2, 3],
  bool digest = true,
}) {
  final version = tag.startsWith('v') ? tag.substring(1) : tag;
  final name = platform == 'windows'
      ? 'Hongputao-Windows-$version-Setup.exe'
      : 'Hongputao-Android-arm64-$version.apk';
  return {
    'tag_name': tag,
    'prerelease': prerelease,
    'draft': draft,
    'body': 'Update notes',
    'assets': [
      for (final asset in [name, 'SHA256SUMS.txt'])
        {
          'name': asset,
          'state': 'uploaded',
          'size': asset == name ? bytes.length : 100,
          'browser_download_url':
              'https://github.com/adoin/Hongguo-video-pack/releases/download/$tag/$asset',
          if (digest) 'digest': 'sha256:${sha256.convert(bytes)}',
        },
    ],
  };
}

void main() {
  test(
    'broken mirror download retries GitHub with checksum verification',
    () async {
      final root = Directory(
        Platform.isWindows
            ? 'D:/tmp/hongputao-updater-tests'
            : p.join(Directory.systemTemp.path, 'hongputao-updater-tests'),
      );
      await root.create(recursive: true);
      final dir = await root.createTemp('fallback-');
      final bytes = utf8.encode('same package');
      final row = release('v2.0.0', bytes: bytes);
      final mirror = jsonDecode(jsonEncode(row)) as Map;
      for (final asset in mirror['assets'] as List) {
        asset['browser_download_url'] =
            (asset['browser_download_url'] as String).replaceFirst(
              'github.com',
              'gitee.com',
            );
      }
      final updater = AppUpdater(
        versionReader: () async => '1.0.0',
        platform: 'windows',
        directory: () async => dir,
        client: MockClient((request) async {
          if (request.url.path.endsWith('SHA256SUMS.txt')) {
            return http.Response(
              '${sha256.convert(bytes)}  Hongputao-Windows-2.0.0-Setup.exe',
              200,
            );
          }
          return http.Response(
            jsonEncode([request.url.host == 'gitee.com' ? mirror : row]),
            200,
          );
        }),
        downloadClient: () => MockClient(
          (request) async => request.url.host == 'gitee.com'
              ? http.Response('', 500)
              : http.Response.bytes(bytes, 200),
        ),
      );
      addTearDown(() async {
        updater.dispose();
        if (!p.isWithin(root.absolute.path, dir.absolute.path)) {
          throw StateError('unsafe cleanup');
        }
        await dir.delete(recursive: true);
      });
      await updater.check();
      expect(updater.release!.source, 'Gitee');
      await updater.download();
      expect(updater.release!.source, 'GitHub');
      expect(await (await updater.verifyForInstall()).readAsBytes(), bytes);
    },
  );
  test('cancel removes partial package and does not run fallback', () async {
    final root = Directory(
      Platform.isWindows
          ? 'D:/tmp/hongputao-updater-tests'
          : p.join(Directory.systemTemp.path, 'hongputao-updater-tests'),
    );
    await root.create(recursive: true);
    final dir = await root.createTemp('cancel-');
    final started = Completer<void>();
    final data = StreamController<List<int>>();
    final updater = AppUpdater(
      versionReader: () async => '1.0.0',
      platform: 'windows',
      giteeRepository: '',
      directory: () async => dir,
      client: MockClient(
        (_) async => http.Response(jsonEncode([release('v2.0.0')]), 200),
      ),
      downloadClient: () => MockClient.streaming((_, _) async {
        started.complete();
        return http.StreamedResponse(data.stream, 200, contentLength: 3);
      }),
    );
    addTearDown(() async {
      updater.dispose();
      if (!p.isWithin(root.absolute.path, dir.absolute.path)) {
        throw StateError('unsafe cleanup');
      }
      await dir.delete(recursive: true);
    });
    await updater.check();
    final operation = updater.download();
    await started.future;
    updater.cancel();
    data.add([1, 2, 3]);
    await data.close();
    await operation;
    expect(updater.readyFile, isNull);
    expect(updater.status, '已取消下载');
    expect(await dir.list().isEmpty, true);
  });
  test('ready domestic release wins without a GitHub request', () async {
    var githubCalls = 0;
    final row = release('v2.0.0');
    for (final asset in row['assets'] as List) {
      asset['browser_download_url'] = (asset['browser_download_url'] as String)
          .replaceFirst('github.com', 'gitee.com');
      asset.remove('size');
      asset.remove('state');
      asset.remove('digest');
    }
    final updater = AppUpdater(
      versionReader: () async => '1.0.0',
      platform: 'windows',
      client: MockClient((request) async {
        if (request.url.host == 'api.github.com') githubCalls++;
        return http.Response(jsonEncode([row]), 200);
      }),
    );
    addTearDown(updater.dispose);
    await updater.check();
    expect(updater.release!.source, 'Gitee');
    expect(githubCalls, 0);
  });
  test('incomplete or unavailable mirror falls back to GitHub', () async {
    final updater = AppUpdater(
      versionReader: () async => '1.0.0',
      platform: 'windows',
      client: MockClient(
        (request) async => request.url.host == 'gitee.com'
            ? http.Response('[]', 200)
            : http.Response(jsonEncode([release('v2.0.0')]), 200),
      ),
    );
    addTearDown(updater.dispose);
    await updater.check();
    expect(updater.release!.source, 'GitHub');
  });
  test('only plain release triplets compare numerically', () {
    for (final value in [
      '1.2.3-beta',
      'v2.0.0-alpha.1',
      '3.0.0-rc1',
      'v1.2.3+4',
      '1.2',
      '01.2.3',
    ]) {
      expect(StableVersion.parse(value), isNull);
    }
    expect(
      StableVersion.parse('v1.10.0')!.compareTo(StableVersion.parse('1.9.99')!),
      greaterThan(0),
    );
  });
  test(
    'ignore draft, flagged prerelease and suffixed tags; never downgrade',
    () async {
      final updater = AppUpdater(
        versionReader: () async => '1.9.0',
        platform: 'windows',
        client: MockClient(
          (_) async => http.Response(
            jsonEncode([
              release('v9.0.0', prerelease: true),
              release('v8.0.0', draft: true),
              release('v7.0.0-rc1'),
              release('v1.9.1'),
              release('v1.10.0'),
            ]),
            200,
          ),
        ),
      );
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.hasUpdate, true);
      expect(updater.release!.tag, 'v1.10.0');
      expect(
        updater.release!.installer!.name,
        'Hongputao-Windows-1.10.0-Setup.exe',
      );
      final newer = AppUpdater(
        versionReader: () async => '2.0.0',
        client: MockClient(
          (_) async => http.Response(jsonEncode([release('v1.0.0')]), 200),
        ),
      );
      addTearDown(newer.dispose);
      await newer.check();
      expect(newer.hasUpdate, false);
    },
  );
  test('paginated releases and Android exact asset selection', () async {
    final updater = AppUpdater(
      versionReader: () async => '1.0.0',
      platform: 'android',
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(
            request.url.queryParameters['page'] == '1'
                ? List.generate(
                    100,
                    (_) => release('v99.0.0', prerelease: true),
                  )
                : [release('v2.0.0', platform: 'android')],
          ),
          200,
        ),
      ),
    );
    addTearDown(updater.dispose);
    await updater.check();
    expect(
      updater.release!.installer!.name,
      'Hongputao-Android-arm64-2.0.0.apk',
    );
  });
  test(
    'network failure and unexpected asset host fail without offering execution',
    () async {
      final bad = release('v2.0.0');
      (bad['assets'] as List).first['browser_download_url'] =
          'https://evil.example/package.exe';
      final updater = AppUpdater(
        versionReader: () async => '1.0.0',
        platform: 'windows',
        client: MockClient((_) async => http.Response(jsonEncode([bad]), 200)),
      );
      addTearDown(updater.dispose);
      await updater.check();
      expect(updater.release!.installer, isNull);
      await updater.download();
      expect(updater.readyFile, isNull);
      final limited = AppUpdater(
        versionReader: () async => '1.0.0',
        client: MockClient((_) async => http.Response('', 403)),
      );
      addTearDown(limited.dispose);
      await limited.check();
      expect(limited.error, isNotEmpty);
    },
  );
  for (final valid in [true, false]) {
    test(
      'download validates checksum and rejects later tampering: $valid',
      () async {
        final root = Directory(
          Platform.isWindows
              ? 'D:/tmp/hongputao-updater-tests'
              : p.join(Directory.systemTemp.path, 'hongputao-updater-tests'),
        );
        await root.create(recursive: true);
        final dir = await root.createTemp('download-');
        final bytes = utf8.encode('test installer');
        final updater = AppUpdater(
          versionReader: () async => '1.0.0',
          platform: 'windows',
          directory: () async => dir,
          client: MockClient(
            (_) async => http.Response(
              jsonEncode([release('v2.0.0', bytes: bytes)]),
              200,
            ),
          ),
          downloadClient: () => MockClient(
            (_) async => http.Response.bytes(
              valid ? bytes : List.filled(bytes.length, 0),
              200,
            ),
          ),
        );
        addTearDown(() async {
          updater.dispose();
          if (!p.isWithin(root.absolute.path, dir.absolute.path)) {
            throw StateError('unsafe cleanup');
          }
          await dir.delete(recursive: true);
        });
        await updater.check();
        await updater.download();
        expect(
          await dir.list().where((file) => file.path.endsWith('.part')).isEmpty,
          true,
        );
        if (valid) {
          expect(await (await updater.verifyForInstall()).readAsBytes(), bytes);
          await updater.readyFile!.writeAsString('tampered');
          await expectLater(updater.verifyForInstall(), throwsFormatException);
        } else {
          expect(updater.readyFile, isNull);
          expect(updater.error, isNotEmpty);
        }
      },
    );
  }
  test('SHA256SUMS fallback is accepted and parses BOM', () async {
    final root = Directory(
      Platform.isWindows
          ? 'D:/tmp/hongputao-updater-tests'
          : p.join(Directory.systemTemp.path, 'hongputao-updater-tests'),
    );
    await root.create(recursive: true);
    final dir = await root.createTemp('checksum-');
    final bytes = utf8.encode('test installer');
    final updater = AppUpdater(
      versionReader: () async => '1.0.0',
      platform: 'windows',
      directory: () async => dir,
      client: MockClient(
        (request) async => http.Response(
          request.url.host == 'api.github.com'
              ? jsonEncode([release('v2.0.0', bytes: bytes, digest: false)])
              : '\uFEFF${sha256.convert(bytes)}  Hongputao-Windows-2.0.0-Setup.exe\n',
          200,
          headers: {'content-type': 'text/plain; charset=utf-8'},
        ),
      ),
      downloadClient: () =>
          MockClient((_) async => http.Response.bytes(bytes, 200)),
    );
    addTearDown(() async {
      updater.dispose();
      if (!p.isWithin(root.absolute.path, dir.absolute.path)) {
        throw StateError('unsafe cleanup');
      }
      await dir.delete(recursive: true);
    });
    await updater.check();
    await updater.download();
    expect(updater.readyFile, isNotNull);
  });
}
