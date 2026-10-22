import 'dart:async';
import 'package:flutter/material.dart';

/// 红果短剧式的画面操作逻辑：抬手单击切换控制栏，双击左/右三分之一快退或
/// 快进 10 秒、中间切换播放与暂停，长按临时顶到最高倍速，横向拖动调进度，
/// 整屏上下滑播放上一集/下一集。
///
/// 亮度与音量**不占用**画面手势：红果用上下滑切集，两者冲突，因此这里不再
/// 提供左右两侧的亮度/音量拖动，音量交给系统或控制栏。
///
/// 手势全部走 [Listener] 原始指针事件，避免和下层纹理、控制栏的手势竞技场
/// 互相抢占；拖动方向在位移超过 [directionSlop] 后锁定，中途不再改判。
class PlaybackGestures extends StatefulWidget {
  const PlaybackGestures({
    super.key,
    required this.child,
    required this.position,
    required this.duration,
    required this.seek,
    required this.changeEpisode,
    this.onTap,
    this.onTogglePlay,
    this.onBoostStart,
    this.onBoostEnd,
  });

  final Widget child;
  final Duration Function() position, duration;
  final Future<void> Function(Duration) seek;

  /// `1` 播放下一集，`-1` 播放上一集。
  final void Function(int) changeEpisode;

  /// 没有位移的单击。
  final VoidCallback? onTap;
  final VoidCallback? onTogglePlay;

  /// 长按开始：返回要展示的提示文案，null 表示不提示。
  final String? Function()? onBoostStart;

  /// 长按结束（松手或取消）。
  final VoidCallback? onBoostEnd;

  @override
  State<PlaybackGestures> createState() => _PlaybackGesturesState();
}

class _PlaybackGesturesState extends State<PlaybackGestures> {
  Offset? start;
  Offset delta = Offset.zero;
  int? pointer;
  bool? horizontal;
  Duration origin = Duration.zero, target = Duration.zero;
  String? hint;
  Timer? timer;
  DateTime? _lastTapAt;
  Offset? _lastTapPoint;
  Timer? _holdTimer;
  bool _boosted = false;

  /// 长按触发加速的等待时长。
  static const holdDelay = Duration(milliseconds: 400);

  /// 超过这个位移就不再算点击或长按，交给拖动逻辑。
  static const directionSlop = 16.0;

  /// 上下滑动切集需要的最小位移。
  static const episodeThreshold = 48.0;

  /// 双击快进/快退的步长。
  static const doubleTapStep = Duration(seconds: 10);

  /// 双击判定窗口；比系统默认略宽，方便手指操作。
  static const doubleTapWindow = Duration(milliseconds: 350);

  /// 横向拖动扫过的最大跨度：整宽对应两分钟。
  static const seekSpan = Duration(minutes: 2);

  /// 在 Listener 里自行判定双击，不额外创建计时器去和拖动手势竞争。
  /// 返回 true 表示这一下是双击的第二击。
  bool _registerTap(Offset point) {
    final last = _lastTapAt, lastPoint = _lastTapPoint;
    final now = DateTime.now();
    if (last != null &&
        lastPoint != null &&
        now.difference(last) <= doubleTapWindow &&
        (point - lastPoint).distance <= 48) {
      _lastTapAt = null;
      _lastTapPoint = null;
      _handleDoubleTapAt(point);
      return true;
    }
    _lastTapAt = now;
    _lastTapPoint = point;
    return false;
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

  String time(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  void finish({bool cancel = false}) {
    if (pointer == null) return;
    _holdTimer?.cancel();
    _holdTimer = null;
    final wasBoosted = _boosted;
    _boosted = false;
    if (wasBoosted) {
      // 长按已经加速，松手只负责结束加速，不再当成点击或拖动。
      widget.onBoostEnd?.call();
    } else if (!cancel &&
        horizontal == true &&
        widget.duration() > Duration.zero) {
      unawaited(
        widget.seek(target).catchError((Object _) {
          if (mounted) setState(() => hint = '跳转失败，请重试');
        }),
      );
    } else if (!cancel &&
        horizontal == false &&
        start != null &&
        delta.dy.abs() >= episodeThreshold) {
      // 上滑下一集、下滑上一集；整屏都可以滑。
      widget.changeEpisode(delta.dy < 0 ? 1 : -1);
    } else if (!cancel &&
        horizontal == null &&
        start != null &&
        delta.distance < directionSlop) {
      // 没有位移，视为点击；连续两次即双击。
      if (!_registerTap(start!)) widget.onTap?.call();
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
    _holdTimer?.cancel();
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      return Listener(
        // 手势层必须自己吃掉点击：child 往往是空的 SizedBox，
        // deferToChild 会让事件穿透到下面的纹理，什么都收不到。
        behavior: HitTestBehavior.opaque,
        onPointerDown: (e) {
          if (pointer != null) {
            finish(cancel: true);
            return;
          }
          timer?.cancel();
          pointer = e.pointer;
          start = e.localPosition;
          delta = Offset.zero;
          horizontal = null;
          origin = widget.position();
          target = origin;
          // 按住不动超过 holdDelay 就临时加速；一旦移动就取消。
          _holdTimer?.cancel();
          _holdTimer = Timer(holdDelay, () {
            if (!mounted || pointer != e.pointer || start == null) return;
            if (delta.distance >= directionSlop) return;
            _boosted = true;
            final message = widget.onBoostStart?.call();
            if (message != null && mounted) _flash(message);
          });
        },
        onPointerMove: (e) {
          if (pointer != e.pointer || start == null) return;
          delta = e.localPosition - start!;
          if (_holdTimer != null && delta.distance >= directionSlop) {
            _holdTimer!.cancel();
            _holdTimer = null;
          }
          if (horizontal == null && delta.distance < directionSlop) return;
          horizontal ??= delta.dx.abs() > delta.dy.abs();
          if (horizontal!) {
            final duration = widget.duration();
            if (duration <= Duration.zero) return;
            final ms =
                (origin.inMilliseconds +
                        delta.dx /
                            box.maxWidth *
                            seekSpan.inMilliseconds)
                    .round()
                    .clamp(0, duration.inMilliseconds);
            target = Duration(milliseconds: ms);
            setState(() => hint = '${time(target)} / ${time(duration)}');
          } else {
            setState(
              () => hint = delta.dy.abs() < episodeThreshold
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
