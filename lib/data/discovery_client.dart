import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../domain/discovery.dart';
import 'hongguo_client.dart' show object, text, integer, Json;
import 'app_search_client.dart';
import 'signed_app_search.dart';

/// Public catalogue pages only. Opening a result still loads the full episode
/// list through HongguoClient, never the preview-only IDs from a catalogue.
class DiscoveryClient {
  DiscoveryClient({http.Client? client, this.appSearch})
    : _http = client ?? http.Client();
  final http.Client _http;
  AppSearchClient? appSearch;

  Future<bool> loadSearchIdentity(File file) async {
    if (!await file.exists()) return false;
    if (await file.length() > 4096) throw const FormatException('本机搜索初始化信息无效');
    final data = object(jsonDecode(await file.readAsString()));
    if (data['version'] != 1) throw const FormatException('本机搜索初始化信息版本不兼容');
    final identity = SearchVisitorIdentity(
      deviceId: text(data['device_id']),
      installId: text(data['iid']),
    );
    final transport = SignedAppSearchTransport(
      identity: identity,
      client: _http,
    );
    appSearch = AppSearchClient(transport.call);
    return true;
  }

  static const boards = {
    'hot-drama': '总热播榜',
    'hot-real-drama': '真人剧榜',
    'hot-comic-drama': '漫剧榜',
    'hot-ai-drama': 'AI 剧榜',
  };
  static const categories = {
    'comic-drama': '漫剧',
    'real-drama': '真人剧',
    'ai-drama': 'AI 剧',
  };

  /// 来源页面在改版后单页可达 339 KB，服务端首字节 1–27 秒不等。
  /// 重复切回同一个榜单/分类时不应再做一次同样的等待。
  static const pageCacheTtl = Duration(minutes: 30);
  static const _pageCacheLimit = 8;

  /// 磁盘页面缓存目录。内存缓存随进程消失，重启后仍要重抓整页，
  /// 所以把榜单/分类页面落盘，让下次启动直接命中。
  Directory? pageCacheDirectory;
  final _pageCache = <String, ({String body, DateTime at})>{};
  final _pageInflight = <String, Future<String>>{};

  static String _cacheKey(String key) =>
      sha1.convert(utf8.encode(key)).toString();

  File? _cacheFile(String key) {
    final directory = pageCacheDirectory;
    if (directory == null) return null;
    return File(p.join(directory.path, '${_cacheKey(key)}.json'));
  }

  Future<String?> _readDisk(String key) async {
    final file = _cacheFile(key);
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      final at = DateTime.tryParse('${raw['at']}');
      final body = raw['body'];
      if (at == null || body is! String || body.isEmpty) return null;
      final age = DateTime.now().difference(at);
      if (age.isNegative || age >= pageCacheTtl) return null;
      return body;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDisk(String key, String body) async {
    final file = _cacheFile(key);
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({'at': DateTime.now().toIso8601String(), 'body': body}),
        flush: true,
      );
      await temp.rename(file.path);
    } catch (_) {
      /* 缓存写失败不影响正常取数据。 */
    }
  }

  Future<String> _get(
    String path, [
    Map<String, String>? query,
    bool useCache = true,
  ]) async {
    final key = Uri(path: path, queryParameters: query).toString();
    if (!useCache) return _fetch(key, path, query, store: false);
    final cached = _pageCache[key];
    if (cached != null &&
        DateTime.now().difference(cached.at) < pageCacheTtl) {
      return cached.body;
    }
    final pending = _pageInflight[key];
    if (pending != null) return pending;
    final future = _loadCached(key, path, query);
    _pageInflight[key] = future;
    try {
      return await future;
    } finally {
      if (identical(_pageInflight[key], future)) _pageInflight.remove(key);
    }
  }

  /// 内存 → 磁盘 → 网络，逐级回退。
  Future<String> _loadCached(
    String key,
    String path,
    Map<String, String>? query,
  ) async {
    final disk = await _readDisk(key);
    if (disk != null) {
      _pageCache[key] = (body: disk, at: DateTime.now());
      return disk;
    }
    return _fetch(key, path, query, store: true);
  }

  Future<String> _fetch(
    String key,
    String path,
    Map<String, String>? query, {
    required bool store,
  }) async {
    final response = await _http
        .get(
          Uri.https('hongguoduanju.com', path, query),
          headers: {'Accept': 'text/html', 'User-Agent': 'Mozilla/5.0'},
        )
        .timeout(const Duration(seconds: 25));
    if (response.statusCode != 200) {
      throw StateError('剧库暂不可用（HTTP ${response.statusCode}），请重试');
    }
    final body = utf8.decode(response.bodyBytes);
    if (!store) return body;
    if (_pageCache.length >= _pageCacheLimit) {
      // 简单的先进先出淘汰，避免长期运行后无限增长。
      _pageCache.remove(_pageCache.keys.first);
    }
    _pageCache[key] = (body: body, at: DateTime.now());
    unawaited(_writeDisk(key, body));
    return body;
  }

  File? indexCache;
  void Function(int)? onIndexProgress;
  Future<List<DramaSummary>>? _index;
  DateTime? _indexTime;
  final _searches = <String, List<DramaSummary>>{};
  final _details = <String, Future<Json?>>{};

  Future<List<DramaSummary>> _catalogue() async {
    if (_indexTime != null &&
        DateTime.now().difference(_indexTime!).inMinutes >= 30) {
      _index = null;
    }
    final pending = _index ??= _loadIndex();
    try {
      return await pending;
    } catch (_) {
      if (identical(_index, pending)) _index = null;
      rethrow;
    }
  }

  Future<List<DramaSummary>> _loadIndex() async {
    final cache = indexCache;
    if (cache != null && await cache.exists()) {
      try {
        final data = object(jsonDecode(await cache.readAsString()));
        final date = DateTime.parse(text(data['time']));
        final age = DateTime.now().difference(date);
        if (data['version'] == 1 && !age.isNegative && age.inMinutes < 30) {
          final rows = parseSummaries(data['items']);
          _indexTime = date;
          onIndexProgress?.call(rows.length);
          return rows;
        }
      } catch (_) {
        /* A broken cache is rebuilt from the source. */
      }
    }
    final rows = <String, DramaSummary>{};
    // Three sequential feeds, bounded to three HTTP requests in flight.
    await Future.wait(
      categories.keys.map((key) async {
        var page = 1;
        var pages = 1;
        final seen = <String>{};
        do {
          final data = await category(key, page: page);
          if (data.pages > 100 || data.pages < page || data.items.isEmpty) {
            throw const FormatException('分类片库不完整，请稍后重试');
          }
          final fresh = data.items.where((d) => seen.add(d.id)).toList();
          if (fresh.isEmpty) throw const FormatException('来源重复返回相同页面，已停止检索');
          for (final row in fresh) {
            rows[row.id] = row;
          }
          onIndexProgress?.call(rows.length);
          pages = data.pages;
          page++;
        } while (page <= pages);
      }),
    );
    _indexTime = DateTime.now();
    final items = rows.values.toList();
    if (cache != null) {
      try {
        final data = {
          'version': 1,
          'time': _indexTime!.toIso8601String(),
          'items': [
            for (final d in items)
              {
                'series_id': d.id,
                'series_title': d.title,
                'series_cover': d.cover,
                'series_intro': d.intro,
                'episode_cnt': d.episodes,
                'tags': d.tags,
              },
          ],
        };
        await cache.parent.create(recursive: true);
        final temporary = File('${cache.path}.tmp');
        await temporary.writeAsString(jsonEncode(data), flush: true);
        await temporary.rename(cache.path);
      } catch (_) {
        /* In-memory search remains available. */
      }
    }
    return items;
  }

  Future<DiscoveryPage> search(
    String keyword, {
    int page = 1,
    String? relatedTo,
    bool expanded = false,
    bool refresh = false,
  }) async {
    keyword = keyword.trim();
    if (keyword.isEmpty ||
        keyword.runes.length > 80 ||
        RegExp(r'[\x00-\x1f]').hasMatch(keyword) ||
        page < 1 ||
        page > 500) {
      throw const FormatException('请输入 1 至 80 个字符的剧名');
    }
    final key = '$keyword|${relatedTo ?? ''}|${expanded ? 'catalogue' : 'web'}';
    if (!expanded) {
      if (appSearch != null && relatedTo == null) {
        return appSearch!.search(keyword, page: page, refresh: refresh);
      }
      // 网站的 /search/<关键词> 页面已改成前端渲染，返回的 HTML 里不再有
      // _ROUTER_DATA，只能拿脚本外壳；数据改由首页脚本同样调用的
      // /api/search/result 提供（query + page，每页 10 条）。
      final data = await _searchApi(keyword, page);
      var rows = parseSummaries(data['searchList']);
      if (relatedTo != null) {
        rows = rows
            .where(
              (d) =>
                  d.id != relatedTo &&
                  _title(seriesKeyword(d.title)) ==
                      _title(seriesKeyword(keyword)),
            )
            .toList();
      }
      // Preserve the source ranking. No catalogue scan or metric requests on
      // this critical path; publish results as soon as this one request returns.
      final totalPages = integer(data['totalPages']).clamp(1, 500);
      // 「相关推荐」是按标题过滤同名前缀，只取首批：给它翻页只会翻到空的，
      // 所以只在真正的关键词搜索里暴露后页。
      final paged = relatedTo == null;
      return DiscoveryPage(
        rows,
        page: page,
        pages: paged ? totalPages : 1,
        total: paged ? integer(data['totalCount']) : rows.length,
        sourceTotal: integer(data['totalCount']),
        canExpand: paged,
        scope: paged ? '红果网页搜索 · 第 $page / $totalPages 页' : '红果网页搜索 · 相关推荐首批',
      );
    }
    var matches = _searches[key] ?? <DramaSummary>[];
    if (page == 1 || !_searches.containsKey(key)) {
      if (page > 1) throw StateError('搜索已过期，请重新搜索');
      final indexed = await _catalogue();
      final needle = _title(keyword);
      matches = indexed.where((d) => _title(d.title).contains(needle)).toList();
      // Supplement the indexed catalogue with the website's first search batch.
      try {
        final data = await _searchApi(keyword, 1);
        final merged = {for (final d in matches) d.id: d};
        for (final d in parseSummaries(data['searchList'])) {
          if (_title(d.title).contains(needle)) merged[d.id] = d;
        }
        matches = merged.values.toList();
      } catch (_) {
        /* Catalogue results remain complete within their stated scope. */
      }
      if (relatedTo != null) {
        matches = matches
            .where(
              (d) =>
                  d.id != relatedTo &&
                  _title(seriesKeyword(d.title)) ==
                      _title(seriesKeyword(keyword)),
            )
            .toList();
      }
      matches.sort((a, b) {
        final scoreA = _title(a.title) == needle
            ? 0
            : _title(a.title).startsWith(needle)
            ? 1
            : 2;
        final scoreB = _title(b.title) == needle
            ? 0
            : _title(b.title).startsWith(needle)
            ? 1
            : 2;
        return scoreA == scoreB
            ? a.title.compareTo(b.title)
            : scoreA.compareTo(scoreB);
      });
      if (_searches.length >= 16) _searches.remove(_searches.keys.first);
      _searches[key] = matches;
    }
    const size = 20;
    final pages = ((matches.length + size - 1) ~/ size).clamp(1, 500);
    if (page > pages) throw StateError('没有更多搜索结果');
    return DiscoveryPage(
      matches.skip((page - 1) * size).take(size).toList(),
      page: page,
      pages: pages,
      total: matches.length,
      scope: '官网分类片库索引＋搜索首批补充 · 非全站完整索引',
    );
  }

  String _title(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[\s：:，,。.!！?？·《》、（）()\-]'), '');

  /// 网站搜索页改成前端渲染后，`/search/<关键词>` 只剩脚本外壳，
  /// 搜索结果由 `/api/search/result?query=…&page=…` 直接给出 JSON
  /// （每页 10 条，返回 totalCount/totalPages/hasMore）。
  Future<Json> _searchApi(String keyword, int page) async {
    final body = await _get('/api/search/result', {
      'query': keyword,
      'page': '$page',
    }, false);
    Json data;
    try {
      data = object(jsonDecode(body));
    } catch (_) {
      throw const FormatException('搜索数据格式已变化，请稍后重试');
    }
    if (data['searchList'] is! List) {
      throw const FormatException('搜索数据格式已变化，请稍后重试');
    }
    final totalPages = integer(data['totalPages']);
    if (totalPages > 0 && page > totalPages) {
      throw StateError('没有更多搜索结果');
    }
    if (page > 1 && integer(data['pageNum']) != page) {
      throw const FormatException('搜索分页不匹配，请重新搜索');
    }
    return data;
  }

  Future<List<DramaSummary>> enrichMetrics(
    List<DramaSummary> rows, {
    void Function(List<DramaSummary>)? onUpdated,
    bool Function()? shouldContinue,
  }) async {
    final results = [...rows];
    var next = 0;
    await Future.wait(
      List.generate(3, (_) async {
        while (next < rows.length) {
          if (shouldContinue?.call() == false) return;
          final i = next++;
          final row = rows[i];
          if (row.metric.isNotEmpty && !needsCoverLookup(row.cover)) continue;
          results[i] = await _readMetrics(row);
          if (shouldContinue?.call() != false) onUpdated?.call([...results]);
        }
      }),
    );
    return results;
  }

  Future<DramaSummary> _readMetrics(DramaSummary row) async {
    if (_details.length >= 500 && !_details.containsKey(row.id)) {
      _details.clear();
    }
    final pending = _details.putIfAbsent(row.id, () => _loadDetails(row.id));
    final page = await pending;
    if (page == null) {
      // A transient failure must be retried on the next user refresh.
      if (identical(_details[row.id], pending)) _details.remove(row.id);
      return row;
    }
    final detail = object(page['seriesDetail']);
    final candidate = text(detail['series_cover']);
    final uri = Uri.tryParse(candidate);
    final useCover =
        needsCoverLookup(row.cover) &&
        candidate.isNotEmpty &&
        !needsCoverLookup(candidate) &&
        uri != null &&
        {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty;
    final social = object(page['seriesSocialInfo']);
    return row.withMetadata(
      cover: useCover ? candidate : null,
      heat: row.heat.isNotEmpty ? row.heat : heatMetric(social),
      plays: row.plays.isNotEmpty
          ? row.plays
          : countMetric(social['series_play_cnt'] ?? social['play_cnt']),
    );
  }

  Future<Json?> _loadDetails(String id) async {
    try {
      final html = await _get('/detail', {'series_id': id}, false);
      final page = routerPage(html, 'detail_page');
      final detail = object(page['seriesDetail']);
      if (text(detail['series_id_str'] ?? detail['series_id']) != id) {
        return null;
      }
      return page;
    } catch (_) {
      return null;
    }
  }

  Future<DiscoveryPage> ranking(String board, {int page = 1}) async {
    if (!boards.containsKey(board) || page < 1 || page > 500) {
      throw const FormatException('榜单参数无效');
    }
    final html = await _get('/rank/$board', {'page': '$page'});
    return parseRanking(html, board, page);
  }

  Future<DiscoveryPage> category(String category, {int page = 1}) async {
    if (!categories.containsKey(category) || page < 1 || page > 500) {
      throw const FormatException('分类参数无效');
    }
    final html = await _get('/category/$category', {'page': '$page'});
    final data = routerPage(html, 'category_\$');
    final pagination = object(data['pagination']);
    if (data['isSuccess'] != true ||
        data['recommendList'] is! List ||
        integer(pagination['pageNum']) != page) {
      throw const FormatException('分类数据格式已变化，请稍后重试');
    }
    return DiscoveryPage(
      parseSummaries(data['recommendList']),
      page: page,
      pages: integer(pagination['totalPages']),
      total: integer(pagination['total']),
    );
  }

  void close() => _http.close();
}

/// App covers can be signed HEIC/HEIF URLs. Changing their suffix invalidates
/// the signature; resolve a compatible cover through this series' detail page.
bool needsCoverLookup(String address) {
  if (address.isEmpty) return true;
  final path = Uri.tryParse(address)?.path.toLowerCase() ?? '';
  return path.endsWith('.heic') || path.endsWith('.heif');
}

Json routerPage(String html, String prefix) {
  final match = RegExp(r'(?:window\.)?_ROUTER_DATA\s*=\s*').firstMatch(html);
  if (match == null) throw const FormatException('剧库页面缺少数据');
  final value = balancedJson(html, html.indexOf('{', match.end));
  final loader = object(object(jsonDecode(value))['loaderData']);
  for (final entry in loader.entries) {
    if (entry.key.startsWith(prefix) && entry.value is Map) {
      return object(entry.value);
    }
  }
  throw const FormatException('剧库页面格式已变化');
}

String balancedJson(String source, int start) {
  if (start < 0) throw const FormatException('页面数据不完整');
  var depth = 0, quoted = false, escaped = false;
  for (var i = start; i < source.length; i++) {
    final c = source[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        quoted = false;
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}' && --depth == 0) {
      return source.substring(start, i + 1);
    }
  }
  throw const FormatException('页面数据不完整');
}

String decodeAttribute(String value) => value
    .replaceAll('&quot;', '"')
    .replaceAll('&#34;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&#x27;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');

DiscoveryPage parseRanking(String html, String board, int page) {
  final route = 'rank_$board/page';
  final loader = routerPage(html, route);
  if (integer(loader['pageNum']) != page) {
    throw const FormatException('榜单分页不匹配');
  }
  var content = object(loader['content']);
  if (content.isEmpty) {
    for (final tag in RegExp(
      r'<script\b[^>]*>',
      caseSensitive: false,
    ).allMatches(html)) {
      final attrs = <String, String>{};
      for (final m in RegExp(
        r'''([\w-]+)=["'](.*?)["'](?=\s|>)''',
        dotAll: true,
      ).allMatches(tag[0]!)) {
        attrs[m[1]!] = decodeAttribute(m[2]!);
      }
      final raw = attrs['data-fn-args'];
      if (raw == null) continue;
      final name = attrs['data-fn-name'];
      if (name != 'mergeLoaderData' && name != 'r') continue;
      final args = jsonDecode(raw) as List;
      if (args.isEmpty || args.first != route) continue;
      if (name == 'r' && args.length == 3 && args[1] == 'content') {
        content = object(args[2]);
      } else if (name == 'mergeLoaderData' &&
          args.length == 2 &&
          args[1] is List) {
        for (final field in args[1]) {
          final f = object(field);
          if (f['key'] == 'content' && f['routerDataFnName'] == 'p') {
            final values = f['routerDataFnArgs'] as List? ?? [];
            if (values.length == 1 && values.first is String) {
              content = object(jsonDecode(values.first as String));
            }
          }
        }
      }
      if (content.isNotEmpty) break;
    }
  }
  final pagination = object(content['pagination']);
  if (content['isSuccess'] != true ||
      content['rankList'] is! List ||
      integer(pagination['pageNum']) != page ||
      integer(pagination['totalPages']) < page) {
    throw const FormatException('榜单数据格式已变化，请稍后重试');
  }
  return DiscoveryPage(
    parseSummaries(content['rankList']),
    page: page,
    pages: integer(pagination['totalPages']),
    updated: text(loader['updatedText']),
  );
}

List<DramaSummary> parseSummaries(dynamic value) {
  if (value is! List) throw const FormatException('剧集列表格式异常');
  final seen = <String>{};
  final result = <DramaSummary>[];
  for (final row in value) {
    final outer = object(row);
    final item = outer['video_data'] is Map
        ? object(outer['video_data'])
        : outer;
    final id = text(
      item['series_id_str'] ??
          item['series_id'] ??
          item['seriesId'] ??
          item['id'],
    );
    final title = text(
      item['series_title'] ?? item['series_name'] ?? item['title'],
    );
    if (!RegExp(r'^\d{1,32}$').hasMatch(id) ||
        title.trim().isEmpty ||
        !seen.add(id)) {
      continue;
    }
    final tags = <String>[
      for (final t in item['tags'] as List? ?? [])
        if (t is String) t,
      for (final t in item['category_list'] as List? ?? [])
        text(object(t)['name']),
    ].where((s) => s.isNotEmpty).toSet().toList();
    final cover = text(
      item['series_cover'] ?? item['cover'],
    ).replaceAll(r'\u002F', '/');
    final uri = Uri.tryParse(cover);
    result.add(
      DramaSummary(
        id: id,
        title: title,
        cover: uri?.scheme == 'https' ? cover : '',
        intro: text(item['series_intro'] ?? item['description']),
        episodes: integer(
          item['episode_cnt'] ?? (item['episodeVids'] as List?)?.length,
        ),
        tags: tags,
        rank: integer(item['rank']),
        heat: heatMetric(item),
        plays: countMetric(item['series_play_cnt'] ?? item['play_cnt']),
      ),
    );
  }
  if (value.isNotEmpty && result.isEmpty) {
    throw const FormatException('列表未返回可识别的剧集');
  }
  return result;
}

String countMetric(dynamic value) {
  final raw = text(value);
  final number = num.tryParse(raw);
  if (number == null || !number.isFinite || number < 0) return '';
  if (number >= 100000000) return '${(number / 100000000).toStringAsFixed(1)}亿';
  if (number >= 10000) return '${(number / 10000).toStringAsFixed(1)}万';
  return number.toInt().toString();
}

String heatMetric(Json item) {
  final hot = object(item['hot_score_data']);
  final label = text(item['heatText'] ?? hot['text']);
  if (label.isNotEmpty && label != '未知') return label;
  return countMetric(hot['score']);
}
