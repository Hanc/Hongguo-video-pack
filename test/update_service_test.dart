import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/services/update_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

const _base = 'https://example.test/updates';

String hexOf(String seed) => List<String>.filled(64, seed).join();

http.Response _json(Map<String, Object?> body) => http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );

Map<String, Object?> _manifest({
  int versionCode = 30,
  String version = '0.12.0',
  String sha256 = '',
  String url = 'https://example.test/updates/android/app-0.12.0.apk',
}) =>
    {
      'platform': 'android',
      'version': version,
      'versionCode': versionCode,
      'url': url,
      'size': 4096,
      'sha256': sha256,
      'kind': 'apk',
      'notes': ['修复若干问题'],
      'publishedAt': '2026-10-29T06:00:00.000Z',
    };

void main() {
  test('a newer manifest reports an available update', () async {
    final service = UpdateService(
      base: _base,
      platform: 'android',
      client: MockClient((request) async {
        expect(request.url.path, '/updates/android/latest.json');
        return _json(_manifest(sha256: hexOf('a')));
      }),
    );
    final result = await service.check(currentVersionCode: 24);
    expect(result.isAvailable, isTrue);
    expect(result.update!.version, '0.12.0');
    expect(result.update!.notes, ['修复若干问题']);
    expect(result.update!.sizeLabel, '4 KB');
  });

  test('the installed build is reported as current', () async {
    final service = UpdateService(
      base: _base,
      platform: 'android',
      client: MockClient(
        (_) async => _json(_manifest(versionCode: 24, sha256: hexOf('b'))),
      ),
    );
    final result = await service.check(currentVersionCode: 24);
    expect(result.isCurrent, isTrue);
    expect(result.update, isNull);
  });

  test('missing, broken and mismatched manifests fail honestly', () async {
    Future<UpdateCheck> run(http.Response response) => UpdateService(
          base: _base,
          platform: 'android',
          client: MockClient((_) async => response),
        ).check(currentVersionCode: 24);

    expect((await run(http.Response('', 404))).error, contains('尚未发布'));
    expect((await run(http.Response('not json', 200))).hasError, isTrue);
    final wrongPlatform = _manifest(sha256: hexOf('c'))..['platform'] = 'windows';
    expect((await run(_json(wrongPlatform))).error, contains('平台不匹配'));
    final insecure = _manifest(sha256: hexOf('d'), url: 'http://example.test/a.apk');
    expect((await run(_json(insecure))).error, contains('https'));
  });

  test('download writes the verified file and rejects a wrong digest', () async {
    final root = await Directory.systemTemp.createTemp('hongguo-update-test');
    addTearDown(() => root.delete(recursive: true));
    final payload = utf8.encode('fake installer bytes');
    final digest = sha256.convert(payload).toString();

    Future<File> fetch(String expected, {String dir = 'downloads'}) async {
      final service = UpdateService(
        base: _base,
        platform: 'android',
        directory: () async => Directory(p.join(root.path, dir)),
        client: MockClient((request) async {
          if (request.url.path.endsWith('latest.json')) {
            return _json(_manifest(sha256: expected));
          }
          return http.Response.bytes(payload, 200, headers: {'content-length': '${payload.length}'});
        }),
      );
      final check = await service.check(currentVersionCode: 24);
      return service.download(check.update!);
    }

    final file = await fetch(digest);
    expect(await file.readAsBytes(), payload);

    await expectLater(fetch(hexOf('e'), dir: 'rejected'), throwsA(isA<StateError>()));
    final leftovers = Directory(p.join(root.path, 'rejected'))
        .listSync()
        .map((entry) => p.basename(entry.path))
        .toList();
    expect(leftovers.where((name) => name.endsWith('.part')), isEmpty);
    expect(leftovers.any((name) => name.endsWith('.apk')), isFalse);
  });
}
