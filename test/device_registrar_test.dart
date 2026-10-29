import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/data/device_registrar.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('identity parses, validates and exposes the query fields', () {
    const identity = DeviceIdentity(
      deviceId: '3770698542658059',
      installId: '3770698542924299',
      cdid: 'cd9f9d92-6a4f-4a7f-9f61-1f2f9b1a2c3d',
    );
    expect(identity.query, {
      'device_id': '3770698542658059',
      'iid': '3770698542924299',
      'cdid': 'cd9f9d92-6a4f-4a7f-9f61-1f2f9b1a2c3d',
    });
    expect(DeviceIdentity.fromJson(identity.toJson())?.deviceId, identity.deviceId);
    expect(DeviceIdentity.fromJson({'device_id': 'abc', 'iid': '1'}), isNull);
    expect(DeviceIdentity.fromJson({'device_id': '0', 'iid': '123'}), isNull);
    expect(DeviceIdentity.fromJson('nope'), isNull);
  });

  test('registration reuses the identity written to disk', () async {
    final home = await Directory.systemTemp.createTemp('device-identity-test');
    addTearDown(() => home.delete(recursive: true));
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      expect(request.url.host, DeviceRegistrar.registerHost);
      expect(request.headers['x-ss-stub'], isNotEmpty);
      return http.Response(
        jsonEncode({
          'code': 0,
          'device_id': 3770698542658059,
          'install_id': 3770698542924299,
          'device_id_str': '3770698542658059',
          'install_id_str': '3770698542924299',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final first = await DeviceRegistrar(client: client, home: home).identity();
    expect(first?.deviceId, '3770698542658059');
    expect(first?.installId, '3770698542924299');
    expect(calls, 1);

    final offline = MockClient((_) async => http.Response('', 503));
    final second = await DeviceRegistrar(client: offline, home: home).identity();
    expect(second?.deviceId, first?.deviceId);
    expect(second?.installId, first?.installId);
    expect(second?.cdid, first?.cdid);
  });

  test('a rejected registration yields no identity instead of throwing', () async {
    final home = await Directory.systemTemp.createTemp('device-identity-fail');
    addTearDown(() => home.delete(recursive: true));
    final client = MockClient((_) async => http.Response('{"code":100}', 200));
    expect(await DeviceRegistrar(client: client, home: home).identity(), isNull);
  });
}
