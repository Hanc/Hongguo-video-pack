import 'package:http/http.dart' as http;
import 'hongguo_client.dart' show Json, decodeApiResponse;
import 'request_signer.dart';

/// Instance-owned registered visitor identity. No shared built-in identity.
class SearchVisitorIdentity {
  SearchVisitorIdentity({required this.deviceId, required this.installId}) {
    if (!RegExp(r'^[1-9]\d{15,19}$').hasMatch(deviceId) ||
        !RegExp(r'^[1-9]\d{15,19}$').hasMatch(installId)) {
      throw const FormatException('搜索访客身份尚未初始化');
    }
  }
  final String deviceId, installId;
  Map<String, String> get parameters => {
    'device_id': deviceId,
    'iid': installId,
  };
}

class SignedAppSearchTransport {
  SignedAppSearchTransport({
    required this.identity,
    required this.client,
    SearchRequestSigner? signer,
  }) : signer = signer ?? NativeRequestSigner();
  final SearchVisitorIdentity identity;
  final http.Client client;
  final SearchRequestSigner signer;

  Future<Json> call(Map<String, String> query) async {
    final request = await signer.signSearch(query, identity.parameters);
    if (request.url.scheme != 'https' ||
        request.url.host != 'api5-normal-sinfonlinec.fqnovel.com' ||
        request.url.path != '/reading/bookapi/search/tab/v' ||
        request.body.isNotEmpty) {
      throw StateError('搜索签名返回了无效请求');
    }
    final response = await client
        .get(request.url, headers: request.headers)
        .timeout(const Duration(seconds: 25));
    return decodeApiResponse(response);
  }
}
