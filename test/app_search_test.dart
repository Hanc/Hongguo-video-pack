import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:hongguo_studio/data/app_search_client.dart';
import 'package:hongguo_studio/data/discovery_client.dart';
import 'package:hongguo_studio/data/hongguo_client.dart' show Json;

// Observed shape only: fabricated IDs/session, no captured credentials or URLs.
Json response(
  List<String> ids, {
  int next = 6,
  String session = 'test-session',
  bool more = true,
}) => {
  'code': 0,
  'search_tabs': [
    {
      'tab_type': 11,
      'query': '重生',
      'has_more': more,
      'next_offset': next,
      'passback': 'test-passback',
      'search_id': session,
      'data': [
        {
          'show_type': 532,
          'video_data': [
            {
              'vid': 'preview',
              'album_info': {'album_id': '999'},
            },
          ],
        },
        {'show_type': 611, 'lynx_data': '{}'},
        for (final id in ids)
          {
            'show_type': 369,
            'video_data': [
              {
                'vid': 'not-the-series-id',
                'series_id': id,
                'title': '预览标题',
                'show_rec_text': true,
                'rec_text': '123万热度',
                'show_play_cnt': true,
                'play_cnt': 12345,
                'video_detail': {
                  'series_id_str': id,
                  'series_title': '剧集$id',
                  'episode_cnt': 80,
                },
              },
            ],
          },
      ],
    },
  ],
};

void main() {
  test('mixed cards yield unique series, never album or preview IDs', () {
    final batch = parseAppSearch(
      response(['101', '101', '102']),
      keyword: '重生',
    );
    expect(batch.items.map((d) => d.id), ['101', '102']);
    expect(batch.items.first.title, '剧集101');
    expect(batch.items.first.episodes, 80);
    expect(batch.items.first.heat, '123万热度');
    expect(batch.items.first.plays, '12345');
    expect(batch.next!.offset, 6);
  });
  test(
    'cursor follows source offsets, deduplicates overlap and caches back page',
    () async {
      final calls = <Map<String, String>>[];
      final client = AppSearchClient((q) async {
        calls.add(q);
        return q['offset'] == '0'
            ? response(['101', '102'])
            : response(['102', '103'], next: 16, more: false);
      });
      final discovery = DiscoveryClient(appSearch: client);
      addTearDown(discovery.close);
      final first = await discovery.search('重生');
      final second = await discovery.search('重生', page: 2);
      expect(first.hasMore, isTrue);
      expect(second.items.single.id, '103');
      expect(second.hasMore, isFalse);
      expect(calls.last['offset'], '6');
      expect(calls.last['passback'], 'test-passback');
      expect(calls.last['search_id'], 'test-session');
      expect(identical(await client.search('重生', page: 2), second), isTrue);
      expect(calls.length, 2);
      expect(identical(await client.search('重生'), first), isTrue);
      await expectLater(client.search('重生', page: 3), throwsStateError);
    },
  );
  test(
    'failed request does not consume cursor; duplicate page rejected',
    () async {
      var calls = 0;
      final client = AppSearchClient((q) async {
        calls++;
        if (calls == 2) throw StateError('offline');
        return response(['101'], next: calls == 1 ? 6 : 16);
      });
      await client.search('重生');
      await expectLater(client.search('重生', page: 2), throwsStateError);
      await expectLater(client.search('重生', page: 2), throwsStateError);
      expect(calls, 3);
    },
  );
  test(
    'wrong keyword, invalid cursor, expired session and API error fail closed',
    () {
      final wrong = response(['101']);
      expect(
        () => parseAppSearch(wrong, keyword: '另一个'),
        throwsFormatException,
      );
      expect(
        () => parseAppSearch(response(['101'], next: 0), keyword: '重生'),
        throwsFormatException,
      );
      expect(
        () => parseAppSearch(response(['101']), keyword: '重生', searchId: 'old'),
        throwsStateError,
      );
      expect(
        () => parseAppSearch({'code': 1}, keyword: '重生'),
        throwsStateError,
      );
    },
  );
  test('an older response cannot overwrite a restarted search', () async {
    final old = Completer<Json>();
    var calls = 0;
    final client = AppSearchClient(
      (_) => ++calls == 1 ? old.future : Future.value(response(['102'])),
    );
    final pending = client.search('重生');
    final expectation = expectLater(pending, throwsStateError);
    expect((await client.search('重生', refresh: true)).items.single.id, '102');
    old.complete(response(['101']));
    await expectation;
  });
}
