import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

/// 播放信息快照。把 [PlayerState] 里可用的字段整理成可直接展示的键值对。
///
/// 刻意只展示确实拿得到的字段：媒体库没有暴露丢帧计数，因此这里不列出，
/// 也不以估算值代替。
class PlaybackInfo {
  const PlaybackInfo(this.rows);

  factory PlaybackInfo.fromState(PlayerState state) {
    final video = state.videoParams;
    final audio = state.audioParams;
    final rows = <(String, String)>[];

    void add(String label, String? value) {
      final text = (value ?? '').trim();
      if (text.isEmpty || text == 'null') return;
      rows.add((label, text));
    }

    final decodeWidth = video.w, decodeHeight = video.h;
    if (decodeWidth != null && decodeHeight != null) {
      add('解码分辨率', '$decodeWidth × $decodeHeight');
    }
    final displayWidth = video.dw, displayHeight = video.dh;
    if (displayWidth != null && displayHeight != null) {
      add('显示分辨率', '$displayWidth × $displayHeight');
    }
    add('宽高比', _ratio(video.aspect));
    add('像素格式', video.pixelformat);
    add(
      '解码方式',
      (video.hwPixelformat ?? '').isEmpty
          ? '软解（CPU）'
          : '硬解 · ${video.hwPixelformat}',
    );
    add('色彩矩阵', video.colormatrix);
    add('色彩范围', video.colorlevels);
    add('原色', video.primaries);
    add('Gamma', video.gamma);
    if ((video.sigPeak ?? 0) > 0) add('峰值亮度', '${video.sigPeak!.round()} nit');
    if ((video.rotate ?? 0) != 0) add('旋转', '${video.rotate}°');
    if ((video.averageBpp ?? 0) > 0) {
      add('平均 bpp', video.averageBpp!.toStringAsFixed(3));
    }

    add('音频格式', audio.format);
    if ((audio.sampleRate ?? 0) > 0) add('采样率', '${audio.sampleRate} Hz');
    add('声道', audio.channels ?? audio.channelCount?.toString());
    if ((state.audioBitrate ?? 0) > 0) {
      add('音频码率', '${state.audioBitrate!.round()} kbps');
    }

    add('已缓冲', _clock(state.buffer));
    if (state.buffering) {
      final percent = (state.bufferingPercentage * 100).round();
      add('缓冲状态', '缓冲中 $percent%');
    }
    add(
      '音轨 / 字幕',
      '${state.tracks.audio.length} / ${state.tracks.subtitle.length}',
    );
    add('倍速', '${state.rate}x');
    add('音量', '${(state.volume).round()}%');
    add('引擎', 'libmpv · media_kit');
    return PlaybackInfo(rows);
  }

  final List<(String, String)> rows;

  static String _clock(Duration d) {
    final minutes = d.inMinutes;
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  static String? _ratio(double? value) {
    if (value == null || value <= 0) return null;
    return value.toStringAsFixed(3);
  }
}

/// 播放信息浮层：默认不显示，点控制栏的信息按钮打开，不遮挡画面主体。
class PlaybackInfoPanel extends StatelessWidget {
  const PlaybackInfoPanel({
    super.key,
    required this.info,
    required this.onClose,
  });

  final PlaybackInfo info;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Container(
      margin: const EdgeInsets.all(12),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .78),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                '播放信息',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              InkWell(
                onTap: onClose,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close_rounded,
                    color: Colors.white70,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (info.rows.isEmpty)
            const Text(
              '正在读取媒体信息…',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            )
          else
            ...info.rows.map(
              (row) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 84,
                      child: Text(
                        row.$1,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        row.$2,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
