import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

String historySeriesKey(String title) {
  // Only remove the ordinal itself; subtitles and unrelated title text remain.
  return title
      .replaceAllMapped(
        RegExp(r'第\s*[一二三四五六七八九十百千万零〇两\d]+\s*([季部卷篇剧])'),
        (match) => '第${match[1]}',
      )
      .replaceAll(RegExp(r'\s+'), '')
      .toLowerCase();
}

class WatchPoint {
  WatchPoint({
    required this.title,
    this.dramaId = '',
    this.cover = '',
    this.episodeId = '',
    this.episode = 1,
    this.total = 1,
    this.path = '',
    this.positionMs = 0,
    this.durationMs = 0,
    this.watched = false,
  });
  String title, dramaId, cover, episodeId, path;
  int episode, total, positionMs, durationMs;
  bool watched;
  void updateProgress(
    int position,
    int duration, {
    required bool finalEpisode,
  }) {
    if (duration <= 0 || position < 0) return;
    positionMs = position.clamp(0, duration);
    durationMs = duration;
    watched = watched || (finalEpisode && positionMs / duration > .8);
  }

  bool get local => path.isNotEmpty;
  String get label =>
      '${local ? '合成视频' : '第 $episode 集'} · '
      '${Duration(milliseconds: positionMs).inMinutes}:${(positionMs ~/ 1000 % 60).toString().padLeft(2, '0')}';
  Map<String, dynamic> toJson() => {
    'title': title,
    'dramaId': dramaId,
    'cover': cover,
    'episodeId': episodeId,
    'episode': episode,
    'total': total,
    'path': path,
    'positionMs': positionMs,
    'durationMs': durationMs,
    'watched': watched,
  };
  factory WatchPoint.fromJson(Map<String, dynamic> json) => WatchPoint(
    title: json['title'] as String,
    dramaId: json['dramaId'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    episodeId: json['episodeId'] as String? ?? '',
    episode: json['episode'] as int? ?? 1,
    total: json['total'] as int? ?? 1,
    path: json['path'] as String? ?? '',
    positionMs: (json['positionMs'] as int? ?? 0).clamp(0, 1 << 50),
    durationMs: (json['durationMs'] as int? ?? 0).clamp(0, 1 << 50),
    watched: json['watched'] == true,
  );
  WatchPoint copy() => WatchPoint.fromJson(toJson());
}

class WatchEntry {
  WatchEntry({
    required this.key,
    required this.updated,
    this.online,
    List<WatchPoint>? files,
    this.activePath = '',
  }) : files = files ?? [];
  final String key;
  DateTime updated;
  WatchPoint? online;
  final List<WatchPoint> files;
  String activePath;
  WatchPoint get current =>
      files.where((f) => f.path == activePath).firstOrNull ??
      online ??
      files.first;
  bool get protected => files.isNotEmpty;
  Map<String, dynamic> toJson() => {
    'key': key,
    'updated': updated.toIso8601String(),
    'online': online?.toJson(),
    'files': files.map((f) => f.toJson()).toList(),
    'activePath': activePath,
  };
  factory WatchEntry.fromJson(Map<String, dynamic> json) => WatchEntry(
    key: json['key'] as String,
    updated: DateTime.parse(json['updated'] as String),
    online: json['online'] is Map
        ? WatchPoint.fromJson(Map<String, dynamic>.from(json['online'] as Map))
        : null,
    files: (json['files'] as List? ?? [])
        .map((f) => WatchPoint.fromJson(Map<String, dynamic>.from(f as Map)))
        .toList(),
    activePath: json['activePath'] as String? ?? '',
  );
}

class WatchHistory extends ChangeNotifier {
  WatchHistory({this.limit = 50, DateTime Function()? now})
    : now = now ?? DateTime.now;
  final int limit;
  final DateTime Function() now;
  final _entries = <String, WatchEntry>{};
  final _dismissed = <String>{};
  File? _file;
  Future<void> _tail = Future.value();
  bool _disposed = false;
  bool _notificationQueued = false;
  String? error;
  List<WatchEntry> get entries =>
      _entries.values.toList()..sort((a, b) => b.updated.compareTo(a.updated));
  String keyFor(WatchPoint point) => point.local && point.title == '本地合集'
      ? 'file:${p.normalize(point.path)}'
      : 'series:${historySeriesKey(point.title)}';
  WatchPoint? onlineFor(String id) => _entries.values
      .map((e) => e.online)
      .whereType<WatchPoint>()
      .where((point) => point.dramaId == id)
      .firstOrNull
      ?.copy();
  WatchPoint? fileFor(String path) => _entries.values
      .expand((e) => e.files)
      .where((point) => point.path == path)
      .firstOrNull
      ?.copy();

  Future<void> initialize(File file) async {
    if (_file != null) return;
    _file = file;
    for (final candidate in [file, File('${file.path}.bak')]) {
      if (!await candidate.exists()) continue;
      try {
        final json = jsonDecode(await candidate.readAsString()) as Map;
        final loaded = <String, WatchEntry>{};
        for (final raw in json['entries'] as List? ?? []) {
          try {
            final entry = WatchEntry.fromJson(
              Map<String, dynamic>.from(raw as Map),
            );
            if (entry.online != null || entry.files.isNotEmpty) {
              loaded[entry.key] = entry;
            }
          } catch (_) {
            /* One invalid record must not discard the others. */
          }
        }
        loaded.addAll(_entries);
        _entries.addAll(loaded);
        _dismissed.addAll(
          (json['dismissed'] as List? ?? []).whereType<String>(),
        );
        break;
      } catch (_) {
        error = '观看记录读取失败，正在尝试备份。';
      }
    }
    await pruneMissing();
  }

  void record(WatchPoint point, {bool importing = false, DateTime? date}) {
    if (_disposed || (importing && _dismissed.contains(point.path))) return;
    final value = point.copy();
    final key = keyFor(value);
    final entry = _entries.putIfAbsent(
      key,
      () => WatchEntry(key: key, updated: date ?? now()),
    );
    if (value.local) {
      final old = entry.files.indexWhere((f) => f.path == value.path);
      if (importing && old >= 0) return;
      if (old >= 0) {
        entry.files[old] = value;
      } else {
        entry.files.add(value);
      }
      if (!importing || entry.online == null && entry.files.length == 1) {
        entry.activePath = value.path;
      }
      if (!importing) _dismissed.remove(value.path);
    } else {
      entry.online = value;
      entry.activePath = '';
    }
    if (!importing) entry.updated = now();
    _trim();
    _changed();
  }

  void _trim() {
    while (_entries.values.where((e) => !e.protected).length > limit) {
      final candidates = _entries.values.where((e) => !e.protected).toList()
        ..sort((a, b) {
          final watched = (a.current.watched ? 0 : 1).compareTo(
            b.current.watched ? 0 : 1,
          );
          return watched != 0 ? watched : a.updated.compareTo(b.updated);
        });
      if (candidates.isEmpty) break;
      _entries.remove(candidates.first.key);
    }
  }

  Future<void> pruneMissing() async {
    // Snapshot before awaiting; do not discard a concurrently added file.
    final missing = <String>{};
    for (final path
        in _entries.values.expand((e) => e.files).map((f) => f.path).toSet()) {
      if (!await File(path).exists()) missing.add(path);
    }
    for (final entry in _entries.values.toList()) {
      entry.files.removeWhere((f) => missing.contains(f.path));
      if (missing.contains(entry.activePath)) entry.activePath = '';
      if (entry.online == null && entry.files.isEmpty) {
        _entries.remove(entry.key);
      }
    }
    _trim();
    _changed();
    await flush();
  }

  Future<void> remove(String key) async {
    final entry = _entries.remove(key);
    if (entry != null) _dismissed.addAll(entry.files.map((f) => f.path));
    _changed();
    await flush();
  }

  void _changed() {
    if (_disposed) return;
    if (!_notificationQueued) {
      _notificationQueued = true;
      scheduleMicrotask(() {
        _notificationQueued = false;
        if (!_disposed) notifyListeners();
      });
    }
    unawaited(flush());
  }

  Future<void> flush() {
    final file = _file;
    if (file == null) return _tail;
    final payload = jsonEncode({
      'version': 1,
      'entries': entries.map((e) => e.toJson()).toList(),
      'dismissed': _dismissed.toList(),
    });
    _tail = _tail.then((_) async {
      try {
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(payload, flush: true);
        await temp.rename(file.path);
        await file.copy('${file.path}.bak');
        error = null;
      } catch (_) {
        error = '观看记录保存失败，请检查本地存储空间。';
      }
    });
    return _tail;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
