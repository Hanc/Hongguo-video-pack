import '../domain/discovery.dart';
import 'hongguo_client.dart' show Json, object, text, integer;

/// A search request must be signed afresh by the transport. Captured account,
/// device, cookie and signature values never belong in this adapter.
typedef AppSearchTransport = Future<Json> Function(Map<String, String> query);

class AppSearchCursor {
  const AppSearchCursor({
    required this.offset,
    required this.searchId,
    required this.passback,
  });
  final int offset;
  final String searchId, passback;
  Map<String, String> get parameters => {
    'offset': '$offset',
    'search_id': searchId,
    'passback': passback,
  };
}

class AppSearchBatch {
  const AppSearchBatch(this.items, {this.next});
  final List<DramaSummary> items;
  final AppSearchCursor? next;
}

/// Parses the observed mixed search cards. UGC albums, ranking containers and
/// preview video IDs are deliberately not treated as playable series IDs.
AppSearchBatch parseAppSearch(
  Json response, {
  required String keyword,
  int tabType = 11,
  int offset = 0,
  String? searchId,
}) {
  if (text(response['code']) != '0') {
    throw StateError('来源搜索暂不可用，请重试');
  }
  final tabs = response['search_tabs'];
  if (tabs is! List) throw const FormatException('搜索标签结构已变化');
  final matches = tabs
      .map(object)
      .where((t) => integer(t['tab_type']) == tabType);
  if (matches.length != 1) throw const FormatException('来源未返回所选搜索标签');
  final tab = matches.single;
  if (text(tab['query']) != keyword || tab['data'] is! List) {
    throw const FormatException('来源返回了不匹配的搜索结果');
  }
  final session = text(tab['search_id']);
  if (searchId != null && session != searchId) {
    throw StateError('搜索会话已失效，请重新搜索');
  }
  final rows = <DramaSummary>[];
  final seen = <String>{};
  for (final raw in tab['data'] as List) {
    final videos = object(raw)['video_data'];
    if (videos is! List) continue;
    for (final value in videos) {
      final video = object(value),
          detail = object(object(value)['video_detail']);
      final id = text(detail['series_id_str']).isNotEmpty
          ? text(detail['series_id_str'])
          : text(video['series_id'] ?? detail['series_id']);
      final title = text(
        detail['series_title'] ?? video['raw_book_name'] ?? video['title'],
      );
      if (!RegExp(r'^\d+$').hasMatch(id) ||
          title.trim().isEmpty ||
          !seen.add(id)) {
        continue;
      }
      final rec = video['show_rec_text'] == true ? text(video['rec_text']) : '';
      rows.add(
        DramaSummary(
          id: id,
          title: title,
          cover: text(detail['series_cover'] ?? video['cover']),
          intro: text(detail['series_intro']),
          episodes: integer(detail['episode_cnt'] ?? video['episode_cnt']),
          heat: rec.contains('热度') ? rec : '',
          plays: video['show_play_cnt'] == true ? text(video['play_cnt']) : '',
        ),
      );
    }
  }
  AppSearchCursor? next;
  if (tab['has_more'] == true) {
    final nextOffset = int.tryParse(text(tab['next_offset']));
    final passback = text(tab['passback']);
    if (nextOffset == null ||
        nextOffset <= offset ||
        session.isEmpty ||
        passback.isEmpty) {
      throw const FormatException('来源未返回有效的后页游标');
    }
    next = AppSearchCursor(
      offset: nextOffset,
      searchId: session,
      passback: passback,
    );
  }
  return AppSearchBatch(List.unmodifiable(rows), next: next);
}

/// Sequential source pagination with retry-safe commits and cached back pages.
/// Not enabled by default until an independent signed transport is verified.
class AppSearchClient {
  AppSearchClient(this.transport);
  final AppSearchTransport transport;
  final _sessions = <String, _SearchSession>{};

  Future<DiscoveryPage> search(
    String keyword, {
    int page = 1,
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
    if (page == 1 && (refresh || !_sessions.containsKey(keyword))) {
      if (_sessions.length >= 16) _sessions.remove(_sessions.keys.first);
      _sessions[keyword] = _SearchSession();
    }
    final session = _sessions[keyword];
    if (session == null || page > session.pages.length + 1) {
      throw StateError('请先读取前一页或重新搜索');
    }
    if (DateTime.now().difference(session.created).inMinutes >= 5) {
      throw StateError('搜索已过期，请重新搜索');
    }
    if (page <= session.pages.length) return session.pages[page - 1];
    if (session.busy) throw StateError('搜索正在加载，请稍候');
    final cursor = session.cursor;
    if (page > 1 && cursor == null) throw StateError('没有更多搜索结果');
    session.busy = true;
    try {
      final response = await transport({
        'query': keyword,
        'tab_type': '11',
        'count': '0',
        'bookshelf_search_plan': '4',
        'user_is_login': '0',
        if (cursor == null) 'offset': '0' else ...cursor.parameters,
      });
      final batch = parseAppSearch(
        response,
        keyword: keyword,
        offset: cursor?.offset ?? 0,
        searchId: cursor?.searchId,
      );
      if (!identical(_sessions[keyword], session)) {
        throw StateError('搜索已被新请求替代');
      }
      final fresh = batch.items
          .where((d) => !session.ids.contains(d.id))
          .toList();
      if (batch.items.isNotEmpty && fresh.isEmpty) {
        throw StateError('来源重复返回相同结果，已停止翻页');
      }
      final result = DiscoveryPage(
        List.unmodifiable(fresh),
        page: page,
        pages: batch.next == null ? page : page + 1,
        total: session.ids.length + fresh.length,
        totalPagesKnown: false,
        scope: '红果 App 搜索 · 已读取结果数量；来源未提供总页数',
      );
      session.ids.addAll(fresh.map((d) => d.id));
      session.cursor = batch.next;
      session.pages.add(result);
      return result;
    } finally {
      session.busy = false;
    }
  }
}

class _SearchSession {
  final created = DateTime.now();
  final pages = <DiscoveryPage>[];
  final ids = <String>{};
  AppSearchCursor? cursor;
  bool busy = false;
}
