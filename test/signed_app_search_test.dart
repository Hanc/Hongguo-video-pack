import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hongguo_studio/data/request_signer.dart';
import 'package:hongguo_studio/data/signed_app_search.dart';

class FakeSearchSigner implements SearchRequestSigner {
  FakeSearchSigner(this.host);
  final String host;
  @override
  Future<SignedRequest> signSearch(
    Map<String, String> query,
    Map<String, String> identity,
  ) async => SignedRequest(
    Uri.https(host, '/reading/bookapi/search/tab/v', {...query, ...identity}),
    {'x-test-signature': 'fresh'},
    '',
  );
}

void main() {
  final identity = SearchVisitorIdentity(
    deviceId: '1000000000000001',
    installId: '1000000000000002',
  );
  test(
    'signed search GET carries instance identity and surfaces empty response',
    () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.url.queryParameters['query'], '重生');
        expect(request.url.queryParameters['device_id'], identity.deviceId);
        expect(request.headers.containsKey('cookie'), isFalse);
        expect(request.headers['x-test-signature'], 'fresh');
        return http.Response('', 200);
      });
      addTearDown(client.close);
      final transport = SignedAppSearchTransport(
        identity: identity,
        client: client,
        signer: FakeSearchSigner('api5-normal-sinfonlinec.fqnovel.com'),
      );
      await expectLater(transport.call({'query': '重生'}), throwsStateError);
    },
  );
  test('signed search cannot redirect identity to another host', () async {
    final client = MockClient((_) async => throw StateError('must not send'));
    addTearDown(client.close);
    final transport = SignedAppSearchTransport(
      identity: identity,
      client: client,
      signer: FakeSearchSigner('example.com'),
    );
    await expectLater(transport.call({'query': '重生'}), throwsStateError);
  });
}
