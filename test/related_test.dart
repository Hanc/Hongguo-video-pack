import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:hongguo_studio/data/discovery_client.dart';
import 'package:hongguo_studio/domain/discovery.dart';
import 'package:hongguo_studio/related_controller.dart';
import 'discovery_test.dart' show pageResponse;

class RelatedFake extends DiscoveryClient {
  final next = Completer<DiscoveryPage>();
  final queries = <String>[];
  @override
  Future<List<DramaSummary>> recommendations(String id) async => const [
    DramaSummary(id: '2', title: '推荐重复'),
    DramaSummary(id: '3', title: '来源推荐'),
  ];
  @override
  Future<DiscoveryPage> search(
    String keyword, {
    int page = 1,
    String? relatedTo,
    bool expanded = false,
    bool refresh = false,
  }) async {
    queries.add(keyword);
    if (keyword.contains('第二季')) return next.future;
    return DiscoveryPage([
      DramaSummary(id: '4', title: '故事番外：新篇'),
      DramaSummary(id: '5', title: '别的故事第2季'),
    ]);
  }
}

void main() {
  test(
    'manual family search takes precedence over source recommendations',
    () async {
      final source = RelatedFake();
      final c = RelatedController(client: source);
      addTearDown(c.dispose);
      final load = c.load('1', '故事第一季');
      await Future<void>.delayed(Duration.zero);
      expect(c.items.any((row) => row.id == '3'), isTrue);
      source.next.complete(
        const DiscoveryPage([DramaSummary(id: '2', title: '故事第二季')]),
      );
      await load;
      expect(source.queries, ['故事第二季', '故事第2季', '故事番外']);
      expect(c.items.map((row) => row.id), ['2', '4', '3']);
      expect(c.items.firstWhere((row) => row.id == '2').title, '故事第二季');
      expect(c.items.any((row) => row.id == '5'), isFalse);
    },
  );
  test(
    'streamed detail parses related list without importing hot recommendations',
    () async {
      final args = jsonEncode([
        'detail_page',
        [
          {
            'key': 'recommendations',
            'routerDataFnArgs': [
              jsonEncode({
                'recommendationGroups': {
                  'related_list': [
                    {'series_id': '2', 'series_name': '故事第二季'},
                  ],
                  'hot_list': [
                    {'series_id': '3', 'series_name': '不相关热门'},
                  ],
                },
              }),
            ],
          },
        ],
      ]).replaceAll('&', '&amp;').replaceAll('"', '&quot;');
      final base = pageResponse('detail_page', {
        'seriesDetail': {'series_id': '1'},
      }).body;
      final client = DiscoveryClient(
        client: MockClient(
          (_) async => http.Response(
            '$base<script data-fn-args="$args">untrusted()</script>',
            200,
            headers: {'content-type': 'text/html; charset=utf-8'},
          ),
        ),
      );
      addTearDown(client.close);
      final rows = await client.recommendations('1');
      expect(rows.map((row) => row.id), ['2']);
    },
  );
}
