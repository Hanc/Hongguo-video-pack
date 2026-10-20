import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hongguo_studio/data/discovery_client.dart';
import 'package:hongguo_studio/discovery_controller.dart';

http.Response pageResponse(String route, Map<String, dynamic> page) =>
    http.Response(
      '<script>window._ROUTER_DATA=${jsonEncode({
        'loaderData': {route: page},
      })}</script>',
      200,
      headers: {'content-type': 'text/html; charset=utf-8'},
    );

void main() {
  test(
    'default search makes one web request and never scans the catalogue',
    () async {
      final paths = <String>[];
      final client = DiscoveryClient(
        client: MockClient((req) async {
          paths.add(Uri.decodeComponent(req.url.path));
          expect(Uri.decodeComponent(req.url.path), '/search/持械入宋');
          return pageResponse('search_(keyword)/page', {
            'isSuccess': true,
            'query': '持械入宋',
            'totalCount': 195,
            'searchList': [
              {
                'video_data': {
                  'series_id': '123',
                  'series_title': '持械入宋：第一季',
                  'hot_score_data': {'text': '5362万热度'},
                },
              },
            ],
          });
        }),
      );
      addTearDown(client.close);
      final page = await client.search('持械入宋');
      expect(paths, ['/search/持械入宋']);
      expect(page.items.single.metric, '5362万热度');
      expect(page.sourceTotal, 195);
      expect(page.canExpand, isTrue);
      expect(page.hasMore, isFalse);
      await expectLater(client.search('持械入宋', page: 2), throwsStateError);
    },
  );

  test('search publishes results without waiting for missing heat', () async {
    final details = Completer<http.Response>();
    final client = DiscoveryClient(
      client: MockClient((req) async {
        if (req.url.path == '/detail') return details.future;
        expect(Uri.decodeComponent(req.url.path), '/search/测试');
        return pageResponse('search_(keyword)/page', {
          'isSuccess': true,
          'query': '测试',
          'totalCount': 1,
          'searchList': [
            {'series_id': '123', 'series_name': '测试'},
          ],
        });
      }),
    );
    final c = DiscoveryController(client: client);
    addTearDown(c.dispose);
    await c.show(DiscoveryMode.search, keyword: '测试');
    expect(c.loading, isFalse);
    expect(c.items.single.title, '测试');
    expect(details.isCompleted, isFalse);
    details.complete(
      pageResponse('detail_page', {
        'seriesDetail': {'series_id': '123'},
        'seriesSocialInfo': {
          'hot_score_data': {'text': '123万热度'},
        },
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(c.items.single.metric, '123万热度');
  });

  test('reads streamed ranking JSON without evaluating page scripts', () async {
    final html = await File('test/fixtures/ranking.html').readAsString();
    final page = parseRanking(html, 'hot-drama', 1);
    expect(page.items.length, 2);
    expect(page.items.first.rank, 1);
    expect(page.items.first.cover, startsWith('https://'));
    expect(page.hasMore, isTrue);
    expect(() => parseRanking(html, 'hot-drama', 2), throwsFormatException);
  });

  test(
    'search page 2 has different real matches; page 1 is stable on return',
    () async {
      var categoryCalls = 0;
      final client = DiscoveryClient(
        client: MockClient((req) async {
          if (!req.url.path.startsWith('/category/')) {
            return http.Response('', 503);
          }
          categoryCalls++;
          final page = int.parse(req.url.queryParameters['page']!);
          final type = DiscoveryClient.categories.keys.toList().indexOf(
            req.url.pathSegments.last,
          );
          return pageResponse('category_\$', {
            'isSuccess': true,
            'pagination': {'pageNum': page, 'totalPages': 2, 'total': 28},
            'recommendList': List.generate(
              page == 1 ? 24 : 4,
              (i) => {
                'series_id': '${100000 + type * 1000 + (page - 1) * 24 + i}',
                'series_name': '持械入宋：第${type * 100 + (page - 1) * 24 + i + 1}季',
                'episode_cnt': 100,
              },
            ),
          });
        }),
      );
      addTearDown(client.close);
      final first = await client.search('持械入宋', expanded: true);
      final second = await client.search('持械入宋', page: 2, expanded: true);
      final back = await client.search('持械入宋', page: 1, expanded: true);
      expect(first.total, 84);
      expect(first.pages, 5);
      expect(second.items.length, 20);
      expect(
        first.items
            .map((d) => d.id)
            .toSet()
            .intersection(second.items.map((d) => d.id).toSet()),
        isEmpty,
      );
      expect(back.items.map((d) => d.id), first.items.map((d) => d.id));
      expect(categoryCalls, 6);
      final related = await client.search(
        '持械入宋',
        relatedTo: first.items.first.id,
        expanded: true,
      );
      expect(related.total, 83);
      expect(related.items.any((d) => d.id == first.items.first.id), isFalse);
    },
  );

  test(
    'repeating upstream pages fail visibly instead of pretending pagination',
    () async {
      final client = DiscoveryClient(
        client: MockClient(
          (req) async => pageResponse('category_\$', {
            'isSuccess': true,
            'pagination': {
              'pageNum': int.parse(req.url.queryParameters['page']!),
              'totalPages': 2,
            },
            'recommendList': [
              {'series_id': '123', 'series_name': '同一页'},
            ],
          }),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.search('同一页', expanded: true),
        throwsFormatException,
      );
    },
  );

  test('metrics preserve heat vs plays and ignore ratings as traffic', () {
    final rows = parseSummaries([
      {
        'series_id': '1',
        'series_name': '热度',
        'hot_score_data': {'score': 53622944, 'text': '5362万热度'},
        'score': '9.1',
      },
      {'series_id': '2', 'series_name': '播放量', 'series_play_cnt': '25000'},
      {'series_id': '3', 'series_name': '只有评分', 'score': '9.8'},
      {
        'series_id': '4',
        'series_name': '零热度',
        'hot_score_data': {'score': 0},
      },
    ]);
    expect(rows[0].metric, '5362万热度');
    expect(rows[1].metric, '2.5万 次播放');
    expect(rows[2].metric, isEmpty);
    expect(rows[3].metric, '0 热度');
  });

  test('an old slow response cannot replace a newly selected mode', () async {
    final delayed = Completer<http.Response>();
    final client = DiscoveryClient(
      client: MockClient((req) async {
        if (req.url.path.startsWith('/rank/')) return delayed.future;
        return pageResponse('category_\$', {
          'isSuccess': true,
          'pagination': {'pageNum': 1, 'totalPages': 1},
          'recommendList': [
            {'series_id': '456', 'series_name': '新的漫剧'},
          ],
        });
      }),
    );
    final c = DiscoveryController(client: client);
    addTearDown(c.dispose);
    final old = c.refresh();
    await c.show(DiscoveryMode.comic);
    delayed.complete(http.Response('', 503));
    await old;
    expect(c.items.single.id, '456');
    expect(c.error, isNull);
    expect(c.loading, isFalse);
  });

  test(
    'live ranking, category pagination and search pagination',
    () async {
      final client = DiscoveryClient();
      addTearDown(client.close);
      client.indexCache = File('.local/live-catalogue-v1.json');
      final rank = await client.ranking('hot-drama');
      final nextRank = await client.ranking('hot-drama', page: 2);
      expect(rank.items.first.rank, 1);
      expect(nextRank.items.first.rank, greaterThan(rank.items.last.rank));
      final comics = await client.category('comic-drama');
      final nextComics = await client.category('comic-drama', page: 2);
      expect(
        comics.items
            .map((d) => d.id)
            .toSet()
            .intersection(nextComics.items.map((d) => d.id).toSet()),
        isEmpty,
      );
      final stopwatch = Stopwatch()..start();
      final direct = await client.search('我');
      stopwatch.stop();
      expect(direct.items, isNotEmpty);
      expect(direct.canExpand, isTrue);
      expect(direct.hasMore, isFalse);
      final search = await client.search('我', expanded: true);
      expect(search.hasMore, isTrue);
      final nextSearch = await client.search('我', page: 2, expanded: true);
      expect(nextSearch.items, isNotEmpty);
      expect(
        (await client.enrichMetrics(
          search.items,
        )).where((d) => d.metric.isNotEmpty),
        isNotEmpty,
      );
      final withMetrics = await client.enrichMetrics(nextSearch.items);
      expect(withMetrics.where((d) => d.metric.isNotEmpty), isNotEmpty);
      expect(
        search.items
            .map((d) => d.id)
            .toSet()
            .intersection(nextSearch.items.map((d) => d.id).toSet()),
        isEmpty,
      );
      final related = await client.search(
        '持械入宋',
        relatedTo: '7671966197985856536',
      );
      expect(related.items, isNotEmpty);
      await File('.local/discovery-proof.json').writeAsString(
        jsonEncode({
          'time': DateTime.now().toIso8601String(),
          'rank1': rank.items.first.id,
          'rank2': nextRank.items.first.id,
          'directSearchMs': stopwatch.elapsedMilliseconds,
          'directItems': direct.items.length,
          'searchTotal': search.total,
          'search1': search.items.map((d) => d.id).toList(),
          'search2': nextSearch.items.map((d) => d.id).toList(),
          'metrics': withMetrics
              .map((d) => {'id': d.id, 'metric': d.metric})
              .toList(),
          'related': related.items
              .map((d) => {'id': d.id, 'title': d.title})
              .toList(),
        }),
      );
    },
    skip: Platform.environment['HONGGUO_DISCOVERY_LIVE'] != '1',
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('repeated page loads hit the cache; a different board still fetches', () async {
    var calls = 0;
    final client = DiscoveryClient(
      client: MockClient((req) async {
        calls++;
        return pageResponse('rank_hot-drama/page', {
          'pageNum': 1,
          'content': <String, dynamic>{},
        });
      }),
    );
    addTearDown(client.close);
    for (var i = 0; i < 2; i++) {
      try {
        await client.ranking('hot-drama');
      } catch (_) {
        // 页面结构不完整时解析会抛错，但这次请求本身仍应计入并可被缓存。
      }
    }
    expect(calls, 1, reason: '同一榜单的第二次进入不应再次请求来源页面');
    try {
      await client.ranking('hot-real-drama');
    } catch (_) {}
    expect(calls, 2, reason: '换榜单属于新页面，必须重新请求');
  });

  test('page cache survives a process restart through the disk cache', () async {
    final dir = await Directory.systemTemp.createTemp('hongguo-pagecache-');
    var first = 0, second = 0;
    final client = DiscoveryClient(
      client: MockClient((req) async {
        first++;
        return pageResponse('rank_hot-drama/page', {
          'pageNum': 1,
          'content': <String, dynamic>{},
        });
      }),
    );
    client.pageCacheDirectory = dir;
    DiscoveryClient? restarted;
    try {
      try {
        await client.ranking('hot-drama');
      } catch (_) {}
      expect(first, 1);
      // 等待异步写盘完成。
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // 新实例代表重启后的进程：内存缓存为空，但磁盘缓存还在。
      restarted = DiscoveryClient(
        client: MockClient((req) async {
          second++;
          return pageResponse('rank_hot-drama/page', {
            'pageNum': 1,
            'content': <String, dynamic>{},
          });
        }),
      );
      restarted.pageCacheDirectory = dir;
      try {
        await restarted.ranking('hot-drama');
      } catch (_) {}
      expect(second, 0, reason: '重启后应直接命中磁盘缓存，不再请求来源');
    } finally {
      restarted?.close();
      client.close();
      await dir.delete(recursive: true);
    }
  });
}
