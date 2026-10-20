import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';
import 'app_controller.dart';
import 'domain/discovery.dart';
import 'domain/drama.dart';
import 'playback_controller.dart';
import 'playback_gestures.dart';
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
        bottomButtonBar: [
          const MaterialPositionIndicator(),
          const Spacer(),
          _speedButton(),
          const MaterialFullscreenButton(),
        ],
      );

  Widget _controls(VideoState state) => Builder(
    builder: (context) {
      final themed = MaterialVideoControlsTheme(
        normal: _controlsTheme(),
        fullscreen: _controlsTheme(fullscreen: true),
        child: MaterialVideoControls(state),
      );
      if (desktop) return themed;
      if (!isFullscreen(context) ||
          MediaQuery.orientationOf(context) != Orientation.landscape) {
        return themed;
      }
      final player = _native!.player;
      return PlaybackGestures(
        position: () => player.state.position,
        duration: () => player.state.duration,
        seek: player.seek,
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
    if (widget.controller == null) {
      _native = NativePlaybackEngine();
      _video = VideoController(_native!.player);
    }
    c = widget.controller ??
        PlaybackController(
          engine: _native!,
          initialRate: widget.tasks.playbackRate,
        );
    if (c.drama == null) unawaited(c.load(widget.summary.id));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(c.engine.pause());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.controller == null) c.dispose();
    first.dispose();
    last.dispose();
    super.dispose();
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
                                        borderRadius: BorderRadius.circular(16),
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
                                  c.variants.any((v) => v.quality == c.quality)
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
                                    c.toggleSelection(episodes[c.index].number);
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
                              MediaQuery.textScalerOf(context).scale(13) / 13;
                          final columns = (constraints.maxWidth / (80 * scale))
                              .floor()
                              .clamp(1, 10);
                          final start = rangePage * 50;
                          final count = (episodes.length - start).clamp(0, 50);
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
                                      borderRadius: BorderRadius.circular(12),
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
