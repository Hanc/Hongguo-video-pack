import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/services/source_health.dart';

void main() {
  test('report lists every step and never leaks addresses', () {
    final report = SourceHealthReport(
      platform: 'windows',
      version: '0.6.1',
      startedAt: DateTime(2026, 10, 20, 18, 30, 5),
      steps: const [
        HealthStep(name: '详情与分集', ok: true, ms: 312, detail: '100 集'),
        HealthStep(
          name: '签名取流与解密',
          ok: true,
          ms: 1204,
          detail: '1080P · 3 档 · 含解密密钥',
        ),
        HealthStep(name: '媒体 CDN', ok: false, ms: 20003, detail: '超时'),
      ],
    );
    final text = report.toText();

    expect(text, contains('红葡萄 来源自检 · 0.6.1'));
    expect(text, contains('2026-10-20 18:30:05'));
    expect(text, contains('windows'));
    expect(text, contains('[1] 详情与分集  通过  312 ms'));
    expect(text, contains('[3] 媒体 CDN  未通过  20003 ms'));
    expect(text, contains('2/3'));
    expect(text, contains('不含地址、签名与解密材料'));

    // 报告是要发给别人看的，不能夹带地址或密钥。
    expect(text, isNot(contains('http')));
    expect(text, isNot(contains('decryption')));
    expect(text, isNot(contains('undefined')));
  });

  test('overall state is only ok when every step passes', () {
    const ok = HealthStep(name: 'a', ok: true, ms: 1);
    const bad = HealthStep(name: 'b', ok: false, ms: 2, detail: '超时');
    final healthy = SourceHealthReport(
      platform: 'android',
      version: '2',
      startedAt: DateTime(2026),
      steps: const [ok, ok],
    );
    final degraded = SourceHealthReport(
      platform: 'android',
      version: '2',
      startedAt: DateTime(2026),
      steps: const [ok, bad],
    );
    expect(healthy.ok, isTrue);
    expect(healthy.passed, 2);
    expect(degraded.ok, isFalse);
    expect(degraded.passed, 1);
    // 空报告不能被当成健康。
    expect(
      SourceHealthReport(
        platform: 'android',
        version: '2',
        startedAt: DateTime(2026),
        steps: const [],
      ).ok,
      isFalse,
    );
  });
}
