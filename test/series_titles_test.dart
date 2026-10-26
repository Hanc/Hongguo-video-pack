import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/domain/discovery.dart';
import 'package:hongguo_studio/domain/series_titles.dart';

void main() {
  test(
    'Chinese and Arabic season numbers preserve base digits and increment',
    () {
      expect(SeriesTitle('网游2024：第十九季').queries, [
        '网游2024：第二十季',
        '网游2024：第20季',
        '网游2024：番外',
      ]);
      expect(SeriesTitle('网游2024第19季').matches('网游2024：第二十季'), isTrue);
      expect(SeriesTitle('网游2024第一季').matches('网游2025第二季'), isFalse);
      expect(SeriesTitle('故事第一季').matches('故事番外之新篇'), isTrue);
      expect(SeriesTitle('故事第一季').isNextOrExtra('故事第三季'), isFalse);
      expect(SeriesTitle('故事第一季').isNextOrExtra('故事第2季'), isTrue);
      expect(seasonNumber('一百零二'), 102);
      expect(chineseSeason(102), '一百零二');
      expect(SeriesTitle('故事第2部').queries.first, '故事第三部');
    },
  );
  test('manual results win duplicates and current series is excluded', () {
    const a = DramaSummary(id: '2', title: '手工续作');
    final rows = mergeRelated(
      '1',
      [a],
      const [
        DramaSummary(id: '1', title: '当前'),
        DramaSummary(id: '2', title: '推荐重复'),
        DramaSummary(id: '3', title: '来源推荐'),
      ],
    );
    expect(rows.map((row) => row.title), ['手工续作', '来源推荐']);
  });
}
