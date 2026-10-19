import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/data/hongguo_client.dart';
import 'support/cli_signer.dart';

void main() {
  test('live multi-video protocol returns a usable media variant', () async {
    final client = HongguoClient(signer: CliSigner());
    try {
      final drama = await client.fetchDrama('7671966197985856536');
      final variants = await client.fetchVariants(
        drama.episodes.first,
        seriesId: drama.id,
      );
      expect(drama.episodes.length, 100);
      expect(
        variants.any(
          (v) => v.quality == 1080 && v.downloadable && v.key?.length == 32,
        ),
        isTrue,
      );
      expect(variants.first.duration, greaterThan(100));
    } finally {
      client.close();
    }
  }, skip: Platform.environment['HONGGUO_LIVE_TEST'] != '1');
}
