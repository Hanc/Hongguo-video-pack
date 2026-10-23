import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hongguo_studio/data/discovery_client.dart';
import 'package:hongguo_studio/discovery_controller.dart';
import 'package:hongguo_studio/domain/discovery.dart';

http.Response detail(
  String id, {
  String cover = 'https://example.com/cover.jpeg',
}) => http.Response(
  '<script>window._ROUTER_DATA=${jsonEncode({
    'loaderData': {
      'detail_page': {
        'seriesDetail': {'series_id': id, 'series_cover': cover},
        'seriesSocialInfo': {
          'hot_score_data': {'text': '1万热度'},
        },
      },
    },
  })}</script>',
  200,
  headers: {'content-type': 'text/html; charset=utf-8'},
);

void main() {
  test(
    'HEIC cover resolves by matching series ID without delaying search or replacing heat',
    () async {
      final pending = Completer<http.Response>();
      var detailCalls = 0;
      final client = DiscoveryClient(
        client: MockClient((request) async {
          if (request.url.path == '/detail') {
            expect(request.url.queryParameters['series_id'], '101');
            detailCalls++;
            return pending.future;
          }
          expect(request.url.path, '/api/search/result');
          return http.Response(
            jsonEncode({
              'searchList': [
                {
                  'video_data': {
                    'series_id': '101',
                    'series_title': '重生',
                    'series_cover': 'https://example.com/cover.heic?signature=unchanged',
                    'hot_score_data': {'text': '4702万热度'},
                  },
                },
              ],
              'totalCount': '1',
              'pageNum': 1,
              'totalPages': 1,
              'hasMore': false,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final controller = DiscoveryController(client: client);
      addTearDown(controller.dispose);
      await controller.show(DiscoveryMode.search, keyword: '重生');
      expect(controller.loading, isFalse);
      expect(controller.items.single.heat, '4702万热度');
      expect(controller.items.single.cover, contains('.heic?'));
      expect(pending.isCompleted, isFalse);
      pending.complete(detail('101'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.items.single.cover, 'https://example.com/cover.jpeg');
      expect(controller.items.single.heat, '4702万热度');
      expect(detailCalls, 1);
    },
  );

  test(
    'shared detail cache preserves each caller metadata instead of returning stale rows',
    () async {
      var calls = 0;
      final client = DiscoveryClient(
        client: MockClient((_) async {
          calls++;
          return detail('101');
        }),
      );
      addTearDown(client.close);
      const first = DramaSummary(
        id: '101',
        title: 'first',
        cover: 'https://example.com/a.heic',
        heat: '2万热度',
      );
      const newer = DramaSummary(
        id: '101',
        title: 'newer',
        cover: 'https://example.com/a.heic',
        heat: '3万热度',
      );
      final a = await client.enrichMetrics([first]);
      final b = await client.enrichMetrics([newer]);
      expect(a.single.cover, endsWith('.jpeg'));
      expect(b.single.title, 'newer');
      expect(b.single.heat, '3万热度');
      expect(calls, 1);
    },
  );

  test(
    'failed or mismatched detail is retriable and cannot replace a cover',
    () async {
      var calls = 0;
      final client = DiscoveryClient(
        client: MockClient((_) async {
          calls++;
          return calls == 1
              ? http.Response('', 503)
              : detail(calls == 2 ? '999' : '101');
        }),
      );
      addTearDown(client.close);
      const row = DramaSummary(
        id: '101',
        title: 'kept',
        cover: 'https://example.com/a.HEIC?x=1',
        heat: '2万热度',
      );
      expect(
        identical((await client.enrichMetrics([row])).single, row),
        isTrue,
      );
      expect(
        identical((await client.enrichMetrics([row])).single, row),
        isTrue,
      );
      expect(
        (await client.enrichMetrics([row])).single.cover,
        endsWith('.jpeg'),
      );
      expect(calls, 3);
    },
  );

  test(
    'cover updates publish progressively, bound concurrency and stop stale queued work',
    () async {
      final pending = <Completer<http.Response>>[];
      final client = DiscoveryClient(
        client: MockClient((_) {
          final response = Completer<http.Response>();
          pending.add(response);
          return response.future;
        }),
      );
      addTearDown(client.close);
      var current = true;
      final updates = <List<DramaSummary>>[];
      final future = client.enrichMetrics(
        [
          for (var i = 0; i < 5; i++)
            DramaSummary(
              id: '${101 + i}',
              title: 'row',
              cover: 'https://example.com/$i.heic',
              heat: '2万热度',
            ),
        ],
        onUpdated: updates.add,
        shouldContinue: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      expect(pending.length, 3);
      pending[0].complete(detail('101'));
      await Future<void>.delayed(Duration.zero);
      expect(updates, hasLength(1));
      expect(updates.single.first.cover, endsWith('.jpeg'));
      expect(pending.length, 4);
      current = false;
      pending[1].complete(detail('102'));
      pending[2].complete(detail('103'));
      pending[3].complete(detail('104'));
      await future;
      expect(updates, hasLength(1));
      expect(pending.length, 4);
    },
  );
}
