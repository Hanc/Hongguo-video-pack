import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import 'app_controller.dart';
import 'domain/discovery.dart';
import 'domain/drama.dart';
import 'playback_controller.dart';
import 'playback_gestures.dart';
import 'playback_info.dart';
import 'services/playback_engine.dart';

class PlaybackScreen extends StatefulWidget {
  const PlaybackScreen({
    super.key,
    required this.summary,
    required this.tasks,
    required this.onStitch,
    required this.onTasks,
    this.onCloseWindow,
    this.controller,
    this.videoBuilder,
  });
  final DramaSummary summary;
  final StudioController tasks;
  final Future<bool> Function(Drama, Set<int>, int) onStitch;
  final VoidCallback onTasks;
  final Future<void> Function()? onCloseWindow;
  final PlaybackController? controller;
  final Widget Function()? videoBuilder;
  @override
  State<PlaybackScreen> createState() => _PlaybackScreenState();
}

class _PlaybackScreenState extends State<PlaybackScreen>
    with WidgetsBindingObserver {
  NativePlaybackEngine? _native;
  VideoController? _video;
  late final PlaybackController c;
  final first = TextEditingController(text: '1'),
      last = TextEditingController(text: '1');
  bool choosing = false, preparing = false;
  bool _showInfo = false;
  bool _fullscreen = false;
  StreamSubscription<VideoParams>? _videoParams;
  static const _platform = MethodChannel('dev.hongguo.studio/platform');

  /// 倍速属于播放器自身能力，放进控制栏，不占用页面布局。
  Widget _speedButton() => AnimatedBuilder(
    animation: c,
    builder: (context, _) => PlaybackSpeedButton(
      rate: c.rate,
      onChanged: (value) => unawaited(_setRate(value)),
    ),
  );

  MaterialVideoControlsThemeData _controlsTheme({bool fullscreen = false}) =>
      MaterialVideoControlsThemeData(
        volumeGesture: !fullscreen,
        brightnessGesture: !fullscreen,
        seekGesture: !fullscreen,
        // 默认进度条只有 2.4 像素厚，几乎看不见。这里加粗、贴到底边，
        // 并把可点击区域和滑块一起放大，方便拖动。
        seekBarHeight: 8,
        seekBarContainerHeight: 30,
        seekBarThumbSize: 15,
        seekBarThumbColor: Colors.white,
        seekBarPositionColor: const Color(0xFFE23A55),
        seekBarBufferColor: Colors.white38,
        seekBarColor: Colors.white12,
        seekBarMargin: EdgeInsets.zero,
        seekBarAlignment: Alignment.bottomCenter,
        // 全屏时左上角提供明确的退出入口，不必再去右下角找切换按钮。
        topButtonBar: fullscreen ? [_fullscreenBackButton()] : const [],
        bottomButtonBar: [
          const MaterialPositionIndicator(),
          const Spacer(),
          IconButton(
            tooltip: '播放信息 (I)',
            iconSize: 20,
            color: Colors.white,
            onPressed: () => _setInfo(!_showInfo),
            icon: const Icon(Icons.info_outline_rounded),
          ),
          _speedButton(),
          const MaterialFullscreenButton(),
        ],
      );

  /// 全屏路由里的返回按钮。
  ///
  /// 组件内部用 [Builder] 取全屏路由内的 context：`exitFullscreen` 依赖
  /// `FullscreenInheritedWidget`，播放页 State 的 context 在路由之外，
  /// 直接用它会让 `isFullscreen` 永远为 false。
  Widget _fullscreenBackButton() => const FullscreenBackButton();

  Widget _controls(VideoState state) => Builder(
    builder: (context) {
      // 全屏是 media_kit push 的独立路由，只有这里能拿到准确的 isFullscreen。
      final fullscreen = isFullscreen(context);
      final themed = MaterialVideoControlsTheme(
        normal: _controlsTheme(),
        fullscreen: _controlsTheme(fullscreen: true),
        child: MaterialVideoControls(state),
      );
      if (desktop) return themed;
      // 竖屏短剧全屏后仍然是竖屏，此时同样需要手势。
      if (!fullscreen) return themed;
      final player = _native!.player;
      return PlaybackGestures(
        position: () => player.state.position,
        duration: () => player.state.duration,
        seek: player.seek,
        onTogglePlay: () => unawaited(_togglePlay()),
        changeEpisode: (step) {
          final next = c.index + step;
          if (!c.loading &&
              next >= 0 &&
              next < (c.drama?.episodes.length ?? 0)) {
            unawaited(c.play(next));
          }
        },
        levels: () async {
          final values = await _platform.invokeMapMethod<String, dynamic>(
            'playbackLevels',
          );
          return (
            (values?['brightness'] as num?)?.toDouble() ?? .5,
            (values?['volume'] as num?)?.toDouble() ?? .5,
          );
        },
        setLevel: (light, value) => _platform.invokeMethod<void>(
          light ? 'playbackBrightness' : 'playbackVolume',
          {'value': value},
        ),
        onDispose: () => unawaited(
          _platform
              .invokeMethod<void>('resetPlaybackBrightness')
              .catchError((Object _) {}),
        ),
        child: themed,
      );
    },
  );
  int episodePage = 0;
  bool get desktop => {
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  }.contains(Theme.of(context).platform);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 全局监听：全屏是独立路由，子树里的 Shortcuts 拿不到焦点。
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    if (widget.controller == null) {
      _native = NativePlaybackEngine();
      _video = VideoController(_native!.player);
    }
    // 全屏状态下切到不同比例的剧集时，方向要跟着内容走。
    _videoParams = _native?.player.stream.videoParams.listen((_) {
      if (_fullscreen) unawaited(_applyOrientation(true));
    });
    c =
        widget.controller ??
        PlaybackController(
          engine: _native!,
          initialRate: widget.tasks.playbackRate,
          onProgress: (episode, position) {
            widget.tasks.saveProgress(
              widget.summary.id,
              episode + 1,
              position,
            );
            // 看过就进追剧列表，下次从首页直接继续。
            widget.tasks.followDrama(
              widget.summary.id,
              widget.summary.title,
              widget.summary.cover,
            );
          },
        );
    if (c.drama == null) {
      // 有上次观看位置就接着看，否则从第一集开始。
      final resume = widget.tasks.progressFor(widget.summary.id);
      unawaited(
        c.load(
          widget.summary.id,
          resumeEpisode: resume?.episode,
          resumePosition: resume?.position ?? Duration.zero,
        ),
      );
      if (resume != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text('已从 ${resume.label} 继续播放'),
              duration: const Duration(seconds: 3),
            ),
          );
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(c.engine.pause());
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    _infoTimer?.cancel();
    unawaited(_videoParams?.cancel());
    // 离开播放页时不能把设备锁在横屏。
    if (_fullscreen) unawaited(_applyOrientation(false));
    if (widget.controller == null) c.dispose();
    first.dispose();
    last.dispose();
    super.dispose();
  }

  /// 播放器快捷键。全屏是 media_kit push 的独立路由，子树里的
  /// `CallbackShortcuts` 拿不到焦点，所以这里用全局键盘监听。
  bool _onKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (_editingText()) return false;
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    if (key == LogicalKeyboardKey.space) {
      unawaited(_togglePlay());
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      unawaited(_seekBy(Duration(seconds: shift ? -15 : -5)));
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      unawaited(_seekBy(Duration(seconds: shift ? 15 : 5)));
      return true;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      unawaited(_changeVolume(.05));
      return true;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      unawaited(_changeVolume(-.05));
      return true;
    }
    if (key == LogicalKeyboardKey.keyM) {
      unawaited(_mute());
      return true;
    }
    if (key == LogicalKeyboardKey.keyI) {
      _setInfo(!_showInfo);
      return true;
    }
    if (key == LogicalKeyboardKey.comma) {
      unawaited(_frameStep(-1));
      return true;
    }
    if (key == LogicalKeyboardKey.period) {
      unawaited(_frameStep(1));
      return true;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (!_fullscreen) return false;
      // 全屏是 push 出来的路由，直接关闭它，避免误退整个播放页。
      Navigator.of(context, rootNavigator: true).maybePop();
      return true;
    }
    if (key == LogicalKeyboardKey.keyF) {
      unawaited(toggleFullscreen(context));
      return true;
    }
    return false;
  }

  /// 在文本输入框里打字时不要抢按键。
  bool _editingText() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) return false;
    var editing = false;
    focusContext.visitAncestorElements((element) {
      if (element.widget is EditableText) {
        editing = true;
        return false;
      }
      return true;
    });
    return editing;
  }

  /// 全屏转横屏、退出转回竖屏；顺带切换沉浸式状态栏。
  ///
  /// 红果短剧多数是竖屏视频（1080×1920），对这类内容强行横屏只会得到两侧
  /// 大片黑边。所以这里按视频自身比例决定：竖屏内容全屏时保持竖屏，只把
  /// 系统栏藏起来；只有横屏内容才真的转成横屏。
  ///
  /// 只在移动端执行。这里用 [Platform] 而不是 `Theme.of(context).platform`，
  /// 因为回调发生在全屏路由里，那个位置的主题未必可靠。
  Future<void> _applyOrientation(bool fullscreen) async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await SystemChrome.setPreferredOrientations(
        orientationsFor(fullscreen: fullscreen, landscape: _videoLandscape()),
      );
      await SystemChrome.setEnabledSystemUIMode(
        fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    } catch (_) {
      /* 不允许旋转的容器里静默跳过。 */
    }
  }

  /// 优先用来源返回的像素尺寸（开播前就有），退回播放器实际解码尺寸。
  bool? _videoLandscape() {
    if (c.variants.isNotEmpty) {
      final bySource = chooseQuality(c.variants, c.quality).isLandscape;
      if (bySource != null) return bySource;
    }
    final width = _native?.player.state.width ?? 0;
    final height = _native?.player.state.height ?? 0;
    if (width <= 0 || height <= 0) return null;
    return width > height;
  }

  Future<void> _togglePlay() async {
    final player = _native?.player;
    if (player == null) return;
    await player.playOrPause();
  }

  Future<void> _seekBy(Duration delta) async {
    final player = _native?.player;
    if (player == null) return;
    final total = player.state.duration;
    final target = player.state.position + delta;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (total > Duration.zero && target > total ? total : target);
    await player.seek(clamped);
  }

  Future<void> _changeVolume(double delta) async {
    final player = _native?.player;
    if (player == null) return;
    final next = (player.state.volume + delta * 100).clamp(0.0, 100.0);
    await player.setVolume(next);
  }

  Future<void> _mute() async {
    final player = _native?.player;
    if (player == null) return;
    final next = player.state.volume > 0 ? 0.0 : 100.0;
    await player.setVolume(next);
  }

  /// 帧步进依赖 mpv 命令；不支持的平台静默忽略。
  Future<void> _frameStep(int direction) async {
    final platform = _native?.player.platform;
    if (platform is! NativePlayer) return;
    try {
      await platform.command([
        direction > 0 ? 'frame-step' : 'frame-back-step',
      ]);
    } catch (_) {
      /* 平台不支持帧步进时不影响其它操作。 */
    }
  }

  /// 播放信息面板打开时刷新一次，关闭后不再定时读取。
  Timer? _infoTimer;
  void _setInfo(bool value) {
    setState(() => _showInfo = value);
    _infoTimer?.cancel();
    if (!value) return;
    _infoTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _showInfo) setState(() {});
    });
  }

  Future<void> _setRate(double value) async {
    await c.setRate(value);
    // 倍速记忆在工作台设置里，下次进入播放页继续生效。
    widget.tasks.setPlaybackRate(c.rate);
  }

  Future<void> _stitch() async {
    if (preparing ||
        widget.tasks.busy ||
        widget.tasks.loading ||
        c.drama == null ||
        c.selected.isEmpty) {
      return;
    }
    setState(() => preparing = true);
    try {
      final ok = await widget.onStitch(c.drama!, {...c.selected}, c.quality);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '拼接任务已开始，可在任务管理查看进度。' : '无法准备拼接任务，请重试。')),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('准备拼接任务失败，请稍后重试。')));
      }
    } finally {
      if (mounted) setState(() => preparing = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([c, widget.tasks]),
    builder: (context, _) {
      final episodes = c.drama?.episodes ?? <Episode>[];
      final pages = ((episodes.length + 49) ~/ 50).clamp(1, 10000);
      final rangePage = episodePage.clamp(0, pages - 1);
      final width = MediaQuery.sizeOf(context).width;
      return Scaffold(
        backgroundColor: const Color(0xFFF6F6F8),
            appBar: AppBar(
              backgroundColor: const Color(0xFFF6F6F8),
              title: desktop
                  ? DragToMoveArea(
                      child: SizedBox(
                        width: double.infinity,
                        child: Text(
                          c.drama?.title ?? widget.summary.title,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                  : Text(
                      c.drama?.title ?? widget.summary.title,
                      overflow: TextOverflow.ellipsis,
                    ),
              actions: [
                TextButton.icon(
                  onPressed: widget.onTasks,
                  icon: const Icon(Icons.downloading_outlined),
                  label: const Text('任务管理'),
                ),
                if (desktop) ...[
                  WindowCaptionButton.minimize(
                    onPressed: () => windowManager.minimize(),
                    brightness: Brightness.light,
                  ),
                  WindowCaptionButton.maximize(
                    onPressed: () async {
                      await windowManager.isMaximized()
                          ? await windowManager.unmaximize()
                          : await windowManager.maximize();
                    },
                    brightness: Brightness.light,
                  ),
                  WindowCaptionButton.close(
                    onPressed: widget.onCloseWindow,
                    brightness: Brightness.light,
                  ),
                ],
              ],
            ),
            body: SafeArea(
              child: ListView(
                padding: EdgeInsets.all(width < 600 ? 12 : 24),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1100),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: AspectRatio(
                              aspectRatio: width < 600 ? 9 / 12 : 16 / 9,
                              child: ColoredBox(
                                color: Colors.black,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (widget.videoBuilder != null)
                                      widget.videoBuilder!()
                                    else
                                      Video(
                                        controller: _video!,
                                        controls: _controls,
                                        // 这两个回调是 media_kit 明确的一次性事件：
                                        // enterFullscreen 在 push 路由后调用，
                                        // 退出时由 FullscreenInheritedWidget 调用。
                                        onEnterFullscreen: () async {
                                          if (mounted) {
                                            setState(() => _fullscreen = true);
                                          }
                                          await _applyOrientation(true);
                                        },
                                        onExitFullscreen: () async {
                                          if (mounted) {
                                            setState(
                                              () => _fullscreen = false,
                                            );
                                          }
                                          await _applyOrientation(false);
                                        },
                                      ),
                                    if (_showInfo && _native != null)
                                      PlaybackInfoPanel(
                                        info: PlaybackInfo.fromState(
                                          _native!.player.state,
                                        ),
                                        onClose: () => _setInfo(false),
                                      ),
                                    if (c.loading)
                                      const IgnorePointer(
                                        child: Center(
                                          child: CircularProgressIndicator(),
                                        ),
                                      ),
                                    if (c.error != null)
                                      Center(
                                        child: Container(
                                          margin: const EdgeInsets.all(16),
                                          padding: const EdgeInsets.all(20),
                                          decoration: BoxDecoration(
                                            color: Colors.black87,
                                            borderRadius: BorderRadius.circular(
                                              16,
                                            ),
                                          ),
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                c.error!,
                                                textAlign: TextAlign.center,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                ),
                                              ),
                                              const SizedBox(height: 12),
                                              FilledButton(
                                                onPressed: () => c.drama == null
                                                    ? c.load(widget.summary.id)
                                                    : c.play(c.index),
                                                child: const Text('重试播放'),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 12,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                episodes.isEmpty
                                    ? '正在读取完整分集…'
                                    : '第 ${episodes[c.index].number} 集 / 共 ${episodes.length} 集',
                                style: const TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              IconButton(
                                tooltip: '上一集',
                                onPressed: c.loading || c.index <= 0
                                    ? null
                                    : () => c.play(c.index - 1),
                                icon: const Icon(Icons.skip_previous_rounded),
                              ),
                              IconButton(
                                tooltip: '下一集',
                                onPressed:
                                    c.loading || c.index + 1 >= episodes.length
                                    ? null
                                    : () => c.play(c.index + 1),
                                icon: const Icon(Icons.skip_next_rounded),
                              ),
                              if (c.variants.isNotEmpty)
                                DropdownButton<int>(
                                  value:
                                      c.variants.any(
                                        (v) => v.quality == c.quality,
                                      )
                                      ? c.quality
                                      : 0,
                                  items: [
                                    const DropdownMenuItem(
                                      value: 0,
                                      child: Text('自动画质'),
                                    ),
                                    ...c.variants.map(
                                      (v) => DropdownMenuItem(
                                        value: v.quality,
                                        child: Text(v.label),
                                      ),
                                    ),
                                  ],
                                  onChanged: c.loading
                                      ? null
                                      : (v) {
                                          if (v != null) c.setQuality(v);
                                        },
                                ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text('自动连播'),
                                  Switch(
                                    value: c.autoAdvance,
                                    onChanged: c.setAutoAdvance,
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 18),
                          Wrap(
                            spacing: 12,
                            runSpacing: 10,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              SegmentedButton<bool>(
                                style: const ButtonStyle(
                                  side: WidgetStatePropertyAll(BorderSide.none),
                                ),
                                segments: const [
                                  ButtonSegment(
                                    value: false,
                                    label: Text('播放选集'),
                                    icon: Icon(Icons.play_arrow_rounded),
                                  ),
                                  ButtonSegment(
                                    value: true,
                                    label: Text('选择拼接'),
                                    icon: Icon(Icons.video_library_outlined),
                                  ),
                                ],
                                selected: {choosing},
                                onSelectionChanged: (value) =>
                                    setState(() => choosing = value.first),
                              ),
                              FilledButton.icon(
                                onPressed:
                                    preparing ||
                                        widget.tasks.busy ||
                                        widget.tasks.loading ||
                                        c.selected.isEmpty
                                    ? null
                                    : _stitch,
                                icon: const Icon(Icons.merge_rounded),
                                label: Text(
                                  preparing
                                      ? '准备任务…'
                                      : '拼接所选 ${c.selected.length} 集',
                                ),
                              ),
                            ],
                          ),
                          if (widget.tasks.busy)
                            Padding(
                              padding: const EdgeInsets.only(top: 14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  LinearProgressIndicator(
                                    value: widget.tasks.progress,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(widget.tasks.status),
                                ],
                              ),
                            ),
                          if (choosing)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  TextButton(
                                    onPressed: () {
                                      c.selectAll(false);
                                      if (episodes.isNotEmpty) {
                                        c.toggleSelection(
                                          episodes[c.index].number,
                                        );
                                      }
                                    },
                                    child: const Text('只选当前集'),
                                  ),
                                  TextButton(
                                    onPressed: () => c.selectAll(true),
                                    child: const Text('全选'),
                                  ),
                                  TextButton(
                                    onPressed: () => c.selectAll(false),
                                    child: const Text('清空'),
                                  ),
                                  SizedBox(
                                    width: 72,
                                    child: TextField(
                                      controller: first,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                        labelText: '起始',
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 72,
                                    child: TextField(
                                      controller: last,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                        labelText: '结束',
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      final a = int.tryParse(first.text),
                                          b = int.tryParse(last.text);
                                      if (a == null ||
                                          b == null ||
                                          a < 1 ||
                                          b < a ||
                                          episodes.isEmpty ||
                                          b > episodes.last.number) {
                                        return;
                                      }
                                      c.selectRange(a, b);
                                    },
                                    child: const Text('选择范围'),
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 12),
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final scale =
                                  MediaQuery.textScalerOf(context).scale(13) /
                                  13;
                              final columns =
                                  (constraints.maxWidth / (80 * scale))
                                      .floor()
                                      .clamp(1, 10);
                              final start = rangePage * 50;
                              final count = (episodes.length - start).clamp(
                                0,
                                50,
                              );
                              return GridView.builder(
                                shrinkWrap: true,
                                padding: EdgeInsets.zero,
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columns,
                                      crossAxisSpacing: 8,
                                      mainAxisSpacing: 8,
                                      mainAxisExtent: 48 * scale,
                                    ),
                                itemCount: count,
                                itemBuilder: (context, offset) {
                                  final i = start + offset;
                                  final number = episodes[i].number;
                                  final selected = choosing
                                      ? c.selected.contains(number)
                                      : i == c.index;
                                  final colors = Theme.of(context).colorScheme;
                                  return Semantics(
                                    selected: selected,
                                    child: TextButton(
                                      key: ValueKey('episode-$number'),
                                      style: TextButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                        ),
                                        backgroundColor: selected
                                            ? colors.secondaryContainer
                                            : Colors.white,
                                        foregroundColor: selected
                                            ? colors.onSecondaryContainer
                                            : const Color(0xFF24242D),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                      ),
                                      onPressed: () => choosing
                                          ? c.toggleSelection(number)
                                          : c.play(i),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          Center(
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              child: Text(
                                                '第 $number 集',
                                                style: const TextStyle(
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ),
                                          ),
                                          if (selected)
                                            const Positioned(
                                              right: 0,
                                              top: 2,
                                              child: Icon(
                                                Icons.check_rounded,
                                                size: 12,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                          if (pages > 1)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                TextButton(
                                  onPressed: rangePage == 0
                                      ? null
                                      : () => setState(
                                          () => episodePage = rangePage - 1,
                                        ),
                                  child: const Text('前 50 集'),
                                ),
                                Text('${rangePage + 1} / $pages'),
                                TextButton(
                                  onPressed: rangePage + 1 == pages
                                      ? null
                                      : () => setState(
                                          () => episodePage = rangePage + 1,
                                        ),
                                  child: const Text('后 50 集'),
                                ),
                              ],
                            ),
                          const SizedBox(height: 20),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
    },
  );
}

/// 播放器控制栏里的倍速入口：显示当前倍速，点击选择新档位。
/// 全屏方向：竖屏短剧保持竖屏，横屏内容才转横屏。
///
/// [landscape] 为 null 表示宽高未知（还没取到媒体信息），此时不强行旋转，
/// 只维持竖屏以免在竖屏短剧上转出黑边。
@visibleForTesting
List<DeviceOrientation> orientationsFor({
  required bool fullscreen,
  required bool? landscape,
}) {
  if (!fullscreen) return const [DeviceOrientation.portraitUp];
  if (landscape == true) {
    return const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ];
  }
  return const [DeviceOrientation.portraitUp];
}

/// 全屏左上角的返回按钮。
///
/// 优先按 media_kit 的方式退出全屏；拿不到全屏上下文时直接关闭承载全屏的
/// 路由。两条路都能退出，避免出现「按钮在但点了没反应」。
class FullscreenBackButton extends StatelessWidget {
  const FullscreenBackButton({super.key});

  @override
  Widget build(BuildContext context) => Builder(
    builder: (context) => IconButton(
      tooltip: '退出全屏',
      color: Colors.white,
      onPressed: () {
        if (isFullscreen(context)) {
          unawaited(exitFullscreen(context));
        } else {
          Navigator.of(context, rootNavigator: true).maybePop();
        }
      },
      icon: const Icon(Icons.arrow_back_rounded),
    ),
  );
}

class PlaybackSpeedButton extends StatelessWidget {
  const PlaybackSpeedButton({
    super.key,
    required this.rate,
    required this.onChanged,
  });
  final double rate;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<double>(
    tooltip: '倍速',
    initialValue: rate,
    onSelected: onChanged,
    itemBuilder: (context) => [
      for (final value in PlaybackController.speeds)
        PopupMenuItem<double>(
          value: value,
          child: Text(PlaybackController.speedLabel(value)),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Center(
        child: Text(
          PlaybackController.speedLabel(rate),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    ),
  );
}
