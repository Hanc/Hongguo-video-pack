import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/data/hongguo_client.dart';
import 'package:hongguo_studio/data/media_crypto.dart';
import 'package:pointycastle/export.dart';

void main() {
  test(
    'content-key protocol accepts a synthetic valid key and rejects malformed data',
    () {
      const key = '0123456789abcdef0123456789abcdef';
      final plain = ascii.encode('0${key}x');
      final raw = Uint8List(37);
      final previous = [246, 85];
      for (var i = 0; i < plain.length; i++) {
        final b =
            ((plain[i] + 21 + i.toRadixString(2).replaceAll('0', '').length) &
                255) ^
            previous[i % 2];
        raw[i + 1] = b;
        previous[i % 2] = b;
      }
      raw[0] = 50 ^ raw[1] ^ raw[2];
      expect(contentKey(base64.encode(raw)), key);
      expect(() => contentKey('bad'), throwsA(anything));
    },
  );
  test(
    'encrypted address adapter validates header and decrypts a synthetic URL',
    () {
      const constant =
          '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58';
      final salt = [
        for (var i = 0; i < constant.length; i += 2)
          int.parse(constant.substring(i, i + 2), radix: 16),
      ];
      final seed = utf8.encode('synthetic-public-fixture');
      final hash = sha512.convert([
        ...sha512.convert(seed).bytes,
        ...salt,
      ]).bytes;
      const url = 'https://media.example.test/a.mp4';
      final data = utf8.encode(url);
      final padding = 16 - data.length % 16;
      final plain = Uint8List.fromList([
        ...data,
        ...List.filled(padding, padding),
      ]);
      final cipher = CBCBlockCipher(AESEngine())
        ..init(
          true,
          ParametersWithIV(
            KeyParameter(Uint8List.fromList(hash.sublist(0, 16))),
            Uint8List.fromList(hash.sublist(16, 32)),
          ),
        );
      final encrypted = Uint8List(plain.length);
      for (var i = 0; i < plain.length; i += 16) {
        cipher.processBlock(plain, i, encrypted, i);
      }
      final encoded = base64.encode([0xa8, 0, 1, 0, ...encrypted]);
      expect(mediaAddress(encoded, base64.encode(seed)), url);
      expect(
        () => mediaAddress('AA==', base64.encode(seed)),
        throwsFormatException,
      );
    },
  );
  test('codec filtering never presents ByteVC2 as a supported download', () {
    final options = parsePlaybackInfo({
      'video_duration': 10,
      'video_list': {
        'unsupported': {
          'codec_type': 'bytevc2',
          'vwidth': 720,
          'vheight': 1280,
          'main_url': 'ignored',
        },
        'supported': {
          'codec_type': 'bytevc1',
          'vwidth': 1080,
          'vheight': 1920,
          'main_url': 'https://media.example.test/a.mp4',
        },
      },
    });
    expect(options.length, 1);
    expect(options.single.quality, 1080);
    expect(options.single.codec, 'hevc');
  });
}
