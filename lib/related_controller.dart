import 'package:flutter/foundation.dart';
import 'data/discovery_client.dart';
import 'domain/discovery.dart';
import 'domain/series_titles.dart';

class RelatedController extends ChangeNotifier {
  RelatedController({required this.client});
  final DiscoveryClient client;
  List<DramaSummary> manual = [], recommended = [];
  String? error;
  bool loading = false;
  bool _disposed = false;
  int _generation = 0;
  String _id = '', _title = '';
  List<DramaSummary> get items => mergeRelated(_id, manual, recommended);

  Future<void> load(String id, String title) async {
    _id = id;
    _title = title;
    final generation = ++_generation;
    manual = [];
    recommended = [];
    error = null;
    loading = true;
    notifyListeners();
    var succeeded = false;
    final family = SeriesTitle(title);
    final queries = family.queries;
    final batches = List<List<DramaSummary>>.generate(
      queries.length,
      (_) => [],
    );
    await Future.wait([
      (() async {
        try {
          final rows = await client.recommendations(id);
          if (_disposed || generation != _generation) return;
          recommended = rows;
          succeeded = true;
          notifyListeners();
        } catch (_) {}
      })(),
      ...queries.asMap().entries.map((entry) async {
        try {
          final result = await client.search(entry.value, refresh: true);
          if (_disposed || generation != _generation) return;
          batches[entry.key] = result.items
              .where((row) => family.isNextOrExtra(row.title))
              .toList();
          manual = mergeRelated(id, batches.expand((rows) => rows), []);
          succeeded = true;
          notifyListeners();
        } catch (_) {}
      }),
    ]);
    if (_disposed || generation != _generation) return;
    loading = false;
    if (!succeeded) error = '相关剧集加载失败，请重试。';
    notifyListeners();
  }

  Future<void> refresh() => load(_id, _title);
  @override
  void dispose() {
    _disposed = true;
    _generation++;
    client.close();
    super.dispose();
  }
}
