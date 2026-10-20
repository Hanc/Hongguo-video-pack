import 'dart:async';
import 'package:flutter/material.dart';

/// Drag direction is locked after the first 16 logical pixels. Central vertical
/// swipes change episode; the outer thirds adjust brightness and volume.
class PlaybackGestures extends StatefulWidget {
  const PlaybackGestures({
    super.key,
    required this.child,
    required this.position,
    required this.duration,
    required this.seek,
    required this.changeEpisode,
    required this.levels,
    required this.setLevel,
    this.onTogglePlay,
    this.onDispose,
  });
  final Widget child;
  final Duration Function() position, duration;
  final Future<void> Function(Duration) seek;
  final void Function(int) changeEpisode;
  final Future<(double, double)> Function() levels;
  final Future<void> Function(bool brightness, double value) setLevel;
  final VoidCallback? onTogglePlay;
  final VoidCallback? onDispose;
  @override
  State<PlaybackGestures> createState() => _PlaybackGesturesState();
}

class _PlaybackGesturesState extends State<PlaybackGestures> {
  Offset? start;
  Offset delta = Offset.zero;
  int? pointer;
  bool? horizontal;
  double brightness = .5, volume = .5, initial = .5;
  Duration origin = Duration.zero, target = Duration.zero;
  String? hint;
  Timer? timer;
  int generation = 0;
  bool writing = false;
  (bool, double)? pending;
  DateTime? _lastTapAt;
  Offset? _lastTapPoint;

  /// 双击快进/快退的步长。
  static const doubleTapStep = Duration(seconds: 10);

  /// 双击判定窗口；比系统默认略宽，方便手指操作。
  static const doubleTapWindow = Duration(milliseconds: 350);

  /// 在 Listener 里自行判定双击：不额外创建计时器，避免与拖动手势竞争。
  void _registerTap(Offset point) {
    final last = _lastTapAt, lastPoint = _lastTapPoint;
    final now = DateTime.now();
    if (last != null &&
        lastPoint != null &&
        now.difference(last) <= doubleTapWindow &&
        (point - lastPoint).distance <= 48) {
      _lastTapAt = null;
      _lastTapPoint = null;
      _handleDoubleTapAt(point);
      return;
    }
    _lastTapAt = now;
    _lastTapPoint = point;
  }

  /// 双击：左三分之一后退、右三分之一前进、中间播放/暂停。
  void _handleDoubleTapAt(Offset point) {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    if (point.dx < width / 3) {
      unawaited(_jump(-doubleTapStep, '后退 10 秒'));
    } else if (point.dx > width * 2 / 3) {
      unawaited(_jump(doubleTapStep, '前进 10 秒'));
    } else {
      widget.onTogglePlay?.call();
    }
  }

  Future<void> _jump(Duration delta, String label) async {
    final total = widget.duration();
    if (total <= Duration.zero) return;
    final target = widget.position() + delta;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > total ? total : target);
    try {
      await widget.seek(clamped);
      if (!mounted) return;
      _flash(label);
    } catch (_) {
      if (mounted) _flash('跳转失败，请重试');
    }
  }

  void _flash(String label) {
    timer?.cancel();
    setState(() => hint = label);
    timer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => hint = null);
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(_readLevels());
  }

  Future<void> _readLevels() async {
    final token = generation;
    try {
      final values = await widget.levels();
      if (mounted && generation == token) {
        brightness = values.$1;
        volume = values.$2;
      }
    } catch (_) {
      /* Platform unavailable: keep local defaults. */
    }
  }

  Future<void> _write(bool light, double value) async {
    pending = (light, value);
    if (writing) return;
    writing = true;
    try {
      while (pending != null && mounted) {
        final next = pending!;
        pending = null;
        await widget.setLevel(next.$1, next.$2);
      }
    } catch (_) {
      pending = null;
      if (mounted) setState(() => hint = '无法调整，请使用系统控制');
    } finally {
      writing = false;
    }
  }

  String time(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  void finish({bool cancel = false}) {
    if (pointer == null) return;
    if (!cancel && horizontal == true && widget.duration() > Duration.zero) {
      unawaited(
        widget.seek(target).catchError((Object _) {
          if (mounted) setState(() => hint = '跳转失败，请重试');
        }),
      );
    } else if (!cancel && horizontal == false && start != null) {
      final width = context.size!.width;
      if (start!.dx >= width / 3 &&
          start!.dx <= width * 2 / 3 &&
          delta.dy.abs() >= 64) {
        widget.changeEpisode(delta.dy < 0 ? 1 : -1);
      }
    } else if (!cancel &&
        horizontal == null &&
        start != null &&
        delta.distance < 16) {
      // 没有位移，视为点击；连续两次即双击。
      _registerTap(start!);
    }
    pointer = null;
    start = null;
    timer?.cancel();
    if (hint != null) {
      timer = Timer(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => hint = null);
      });
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    pending = null;
    widget.onDispose?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      return Listener(
        onPointerDown: (e) {
          if (pointer != null) {
            finish(cancel: true);
            return;
          }
          // Preserve the top controls and bottom seek bar.
          if (e.localPosition.dy < 64 ||
              e.localPosition.dy > box.maxHeight - 84) {
            return;
          }
          generation++;
          timer?.cancel();
          pointer = e.pointer;
          start = e.localPosition;
          delta = Offset.zero;
          horizontal = null;
          origin = widget.position();
          target = origin;
          initial = start!.dx < box.maxWidth / 3 ? brightness : volume;
        },
        onPointerMove: (e) {
          if (pointer != e.pointer || start == null) return;
          delta = e.localPosition - start!;
          if (horizontal == null && delta.distance < 16) return;
          horizontal ??= delta.dx.abs() > delta.dy.abs();
          if (horizontal!) {
            final duration = widget.duration();
            if (duration <= Duration.zero) return;
            final ms =
                (origin.inMilliseconds + delta.dx / box.maxWidth * 120000)
                    .round()
                    .clamp(0, duration.inMilliseconds);
            target = Duration(milliseconds: ms);
            setState(() => hint = '${time(target)} / ${time(duration)}');
          } else if (start!.dx < box.maxWidth / 3 ||
              start!.dx > box.maxWidth * 2 / 3) {
            final light = start!.dx < box.maxWidth / 3;
            final value = (initial - delta.dy / (box.maxHeight * .65)).clamp(
              light ? .05 : 0.0,
              1.0,
            );
            if (light) {
              brightness = value;
            } else {
              volume = value;
            }
            setState(
              () => hint = '${light ? '亮度' : '音量'} ${(value * 100).round()}%',
            );
            unawaited(_write(light, value));
          } else {
            setState(
              () => hint = delta.dy.abs() < 64
                  ? '继续滑动切集'
                  : delta.dy < 0
                  ? '松开播放下一集'
                  : '松开播放上一集',
            );
          }
        },
        onPointerUp: (e) {
          if (pointer == e.pointer) finish();
        },
        onPointerCancel: (e) {
          if (pointer == e.pointer) finish(cancel: true);
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            if (hint != null)
              IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      hint!,
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );
}
