// SPDX-License-Identifier: GPL-3.0-only
// Protocol adaptation; see THIRD_PARTY_NOTICES.md for upstream attribution.
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

String contentKey(String value) {
  final raw = base64.decode(base64.normalize(value));
  if (raw.length < 3 || raw.length > 1024) {
    throw const FormatException('媒体授权数据无效');
  }
  final length = (raw.length - (raw[0] ^ raw[1] ^ raw[2]) + 47).clamp(
    0,
    raw.length - 1,
  );
  if (length < 33) throw const FormatException('媒体授权数据不完整');
  final work = raw.sublist(1, 1 + length);
  var a = 85, b = 246;
  for (var i = 0; i < work.length; i++) {
    final old = work[i];
    final previous = i.isOdd ? a : b;
    if (i.isOdd) {
      a = old;
    } else {
      b = old;
    }
    work[i] =
        (-21 -
            i.toRadixString(2).replaceAll('0', '').length +
            (previous ^ old)) &
        255;
  }
  final key = ascii.decode(work.sublist(1, 33));
  if (!RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(key)) {
    throw const FormatException('媒体授权协议暂不支持');
  }
  return key;
}

String mediaAddress(String value, String seed) {
  if (seed.isEmpty) {
    if (value.startsWith('http')) return value;
    return utf8.decode(base64.decode(base64.normalize(value)));
  }
  final raw = base64.decode(base64.normalize(value));
  if (raw.length < 20 || raw[0] != 0xa8 || raw[2] != 1 || raw[3] != 0) {
    throw const FormatException('媒体地址格式异常');
  }
  const constant =
      '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58';
  final salt = [
    for (var i = 0; i < constant.length; i += 2)
      int.parse(constant.substring(i, i + 2), radix: 16),
  ];
  final hash = sha512.convert([
    ...sha512.convert(base64.decode(base64.normalize(seed))).bytes,
    ...salt,
  ]).bytes;
  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      false,
      ParametersWithIV(
        KeyParameter(Uint8List.fromList(hash.sublist(0, 16))),
        Uint8List.fromList(hash.sublist(16, 32)),
      ),
    );
  final length = (raw.length - 4) ~/ 16 * 16;
  final plain = Uint8List(length);
  for (var i = 0; i < length; i += 16) {
    cipher.processBlock(raw, i + 4, plain, i);
  }
  var end = plain.length;
  final pad = plain.last;
  if (pad >= 1 && pad <= 16 && pad <= end) end -= pad;
  while (end > 0 && plain[end - 1] == 0) {
    end--;
  }
  final url = utf8.decode(plain.sublist(0, end));
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    throw const FormatException('媒体地址无效');
  }
  return url;
}
