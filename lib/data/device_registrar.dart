// SPDX-License-Identifier: GPL-3.0-only
// Anonymous device registration adapted from jackotom/hongguo-drama
// (src/native/playback-device.js, GPL-3.0-only), which adapted it from
// tsukiyo-zero/hongguoTV (DeviceRegister.kt, GPL-3.0-only).
// Changes: pure-Dart port, on-disk reuse across launches, best-effort fallback.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';

/// 来源认可的匿名设备身份。没有它时播放接口只会返回空包或 `101000`。
class DeviceIdentity {
  const DeviceIdentity({
    required this.deviceId,
    required this.installId,
    required this.cdid,
  });

  final String deviceId;
  final String installId;
  final String cdid;

  /// 播放接口只认查询参数里的这三个值，不需要额外签名头。
  Map<String, String> get query => {
    'device_id': deviceId,
    'iid': installId,
    'cdid': cdid,
  };

  Map<String, Object?> toJson() => {
    'device_id': deviceId,
    'iid': installId,
    'cdid': cdid,
  };

  static DeviceIdentity? fromJson(Object? value) {
    if (value is! Map) return null;
    final deviceId = '${value['device_id'] ?? ''}';
    final installId = '${value['iid'] ?? ''}';
    final cdid = '${value['cdid'] ?? ''}';
    if (!_isId(deviceId) || !_isId(installId)) return null;
    return DeviceIdentity(deviceId: deviceId, installId: installId, cdid: cdid);
  }

  static bool _isId(String value) =>
      RegExp(r'^\d{1,30}$').hasMatch(value) && value.contains(RegExp('[1-9]'));
}

/// 注册并持久化匿名设备身份；失败时返回 null，由调用方退回随机身份。
class DeviceRegistrar {
  DeviceRegistrar({http.Client? client, Directory? home})
    : _http = client ?? http.Client(),
      _home = home;

  static const registerHost = 'log5-applog-lf.fqnovel.com';
  static const registerPath = '/service/2/device_register/';
  static const registerQuery = {
    'tt_data': 'a',
    'cronet_version': '8d40f833_2026-03-03',
    'ttnet_version': '4.2.243.31-douyin',
    'use_store_region_cookie': '1',
  };
  static const _saltHex =
      '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58';
  static const _userAgent =
      'com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)';
  static const _fileName = 'device-identity.json';

  final http.Client _http;
  final Directory? _home;
  Future<DeviceIdentity?>? _pending;

  /// 进程内只注册一次；磁盘上有记录时直接复用。
  Future<DeviceIdentity?> identity() => _pending ??= _resolve();

  Future<DeviceIdentity?> _resolve() async {
    final cached = await _load();
    if (cached != null) return cached;
    try {
      final fresh = await _register();
      if (fresh != null) await _save(fresh);
      return fresh;
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> _directory() async {
    if (_home != null) return _home;
    for (final probe in <Future<Directory> Function()>[
      getApplicationSupportDirectory,
      getTemporaryDirectory,
    ]) {
      try {
        final directory = await probe();
        if (!await directory.exists()) await directory.create(recursive: true);
        return directory;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<DeviceIdentity?> _load() async {
    try {
      final directory = await _directory();
      if (directory == null) return null;
      final file = File('${directory.path}${Platform.pathSeparator}$_fileName');
      if (!await file.exists()) return null;
      return DeviceIdentity.fromJson(jsonDecode(await file.readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(DeviceIdentity identity) async {
    try {
      final directory = await _directory();
      if (directory == null) return;
      final file = File('${directory.path}${Platform.pathSeparator}$_fileName');
      await file.writeAsString(jsonEncode(identity.toJson()), flush: true);
    } catch (_) {}
  }

  Future<DeviceIdentity?> _register() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cdid = _uuid();
    final header = <String, Object?>{
      'display_name': '红果免费短剧',
      'update_version_code': 73932,
      'manifest_version_code': 73932,
      'app_version_minor': '7.3.9.32',
      'aid': 8662,
      'channel': 'update_64',
      'package': 'com.phoenix.read',
      'app_version': '7.3.9.32',
      'version_code': 73932,
      'sdk_version': '3.7.0-rc.34-fanqie-xiaoshuo',
      'sdk_target_version': 29,
      'git_hash': '3a88f4e',
      'os': 'Android',
      'os_version': '16',
      'os_api': 36,
      'device_model': '25053RT47C',
      'device_brand': 'Redmi',
      'device_manufacturer': 'Redmi',
      'cpu_abi': 'arm64-v8a',
      'release_build': 'b5e187f',
      'density_dpi': 520,
      'display_density': 'mdpi',
      'resolution': '1280x2772',
      'language': 'zh',
      'timezone': 8,
      'access': 'wifi',
      'not_request_sender': 0,
      'carrier': 'CHINA MOBILE',
      'mcc_mnc': '46000',
      'rom': 'eng.root.20231116.160340',
      'rom_version': 'W528JS release-keys',
      'cdid': cdid,
      'sig_hash': '56a962410c494bbaf0b58dba20cae56f',
      'openudid': _hex(8),
      'clientudid': _uuid(),
      'ipv6_list': <String>[],
      'region': 'CN',
      'tz_name': 'Asia/Shanghai',
      'tz_offset': 28800,
      'sim_region': 'cn',
      'sim_serial_number': <String>[],
      'oaid_may_support': false,
      'req_id': _uuid(),
      'device_platform': 'android',
      'custom': {
        'account_region_src': 'fallback',
        'account_region': 'cn',
        'host_bit': 64,
        'dragon_device_type': 'phone',
      },
      'pre_installed_channel': '',
      'apk_first_install_time': now,
      'is_system_app': 0,
      'sdk_flavor': 'china',
      'guest_mode': 0,
    };
    final payload = utf8.encode(
      jsonEncode({'magic_tag': 'ss_app_log', 'header': header, '_gen_time': now}),
    );
    final compressed = Uint8List.fromList(GZipCodec().encode(payload));
    final random = _randomBytes(32);
    final derived = sha512.convert([
      ...sha512.convert(random).bytes,
      ..._hexToBytes(_saltHex),
    ]).bytes;
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    )..init(
      true,
      PaddedBlockCipherParameters(
        ParametersWithIV(
          KeyParameter(Uint8List.fromList(derived.sublist(0, 16))),
          Uint8List.fromList(derived.sublist(16, 32)),
        ),
        null,
      ),
    );
    final plain = Uint8List.fromList([...sha512.convert(compressed).bytes, ...compressed]);
    final body = Uint8List.fromList([
      0x74, 0x63, 0x05, 0x10, 0x00, 0x00,
      ...random,
      ...cipher.process(plain),
    ]);
    final stub = md5.convert(body).toString().toUpperCase();
    final response = await _http
        .post(
          Uri.https(registerHost, registerPath, registerQuery),
          body: body,
          headers: {
            'User-Agent': _userAgent,
            'Accept': 'application/json',
            'Content-Type': 'application/octet-stream;tt-data=a',
            'log-encode-type': 'gzip',
            'x-ss-dp': '8662',
            'x-ss-req-ticket': '$now',
            'x-vc-bdturing-sdk-version': '4.0.3.cn',
            'lc': '101',
            'sdk-version': '2',
            'passport-sdk-version': '5051452',
            'x-neptune': '-8|50:51:59:30:40:47:49:39',
            'x-ss-stub': stub,
          },
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! Map) return null;
    final code = int.tryParse('${decoded['code'] ?? decoded['Code'] ?? 0}') ?? 0;
    if (code != 0) return null;
    final deviceId = _pick(decoded, 'device_id');
    final installId = _pick(decoded, 'install_id');
    if (deviceId == null || installId == null) return null;
    return DeviceIdentity(deviceId: deviceId, installId: installId, cdid: cdid);
  }

  static String? _pick(Map<dynamic, dynamic> json, String name) {
    for (final candidate in ['${name}_str', name]) {
      final value = json[candidate];
      final text = value is num ? '${value.toInt()}' : '$value'.trim();
      if (DeviceIdentity._isId(text)) return text;
    }
    return null;
  }

  static final _random = Random.secure();

  static Uint8List _randomBytes(int count) => Uint8List.fromList([
    for (var i = 0; i < count; i++) _random.nextInt(256),
  ]);

  static String _hex(int bytes) =>
      _randomBytes(bytes).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _hexToBytes(String hex) => [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];

  static String _uuid() {
    final bytes = _randomBytes(16);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
