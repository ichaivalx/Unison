import 'dart:async';

import 'package:flutter/material.dart';

import '../control/clock.dart';
import '../control/console.dart';
import '../control/models.dart';
import '../control/protocol.dart';
import 'theme.dart';

/// 音源设备上正在播放的媒体：标题、可拖动的进度、播放控制
class MediaCard extends StatefulWidget {
  const MediaCard({super.key, required this.console, required this.media});

  final Console console;
  final MediaView? media;

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  Timer? _ticker;

  /// 拖动中的位置（微秒）
  double? _dragging;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(MediaCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker() {
    final playing = widget.media?.playing ?? false;
    if (playing && _ticker == null) {
      _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
    } else if (!playing) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// 按更新时刻外推的当前位置
  int _position(MediaView media) {
    var position = media.positionUs;
    if (media.playing) {
      final elapsed = nowUs - widget.console.localTimeOf(media.positionAtUs);
      position += (elapsed * media.speed).round();
    }
    final duration = media.durationUs;
    if (position < 0) return 0;
    return duration != null && position > duration ? duration : position;
  }

  void _media(String action) => widget.console.command(Command.media, {'action': action});

  static String _time(int us) {
    final total = us ~/ 1000000;
    final h = total ~/ 3600;
    final m = (total ~/ 60) % 60;
    final s = (total % 60).toString().padLeft(2, '0');
    return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.media;
    final colors = context.colors;
    final texts = context.texts;
    return Container(
      padding: const EdgeInsets.fromLTRB(Grid.panelPadding, 18, Grid.panelPadding, 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(Grid.panelRadius),
      ),
      child: media == null
          ? SizedBox(
              height: 72,
              child: Center(
                child: Text('音源设备上没有正在播放的媒体', style: texts.bodyMedium?.copyWith(color: colors.onSurfaceVariant)),
              ),
            )
          : _content(media, colors, texts),
    );
  }

  Widget _content(MediaView media, ColorScheme colors, TextTheme texts) {
    final duration = media.durationUs;
    final position = _dragging?.round() ?? _position(media);
    final seekable = media.canSeek && duration != null && duration > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.graphic_eq_rounded, size: 16, color: media.playing ? colors.primary : colors.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                media.appName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: texts.labelMedium?.copyWith(color: colors.onSurfaceVariant, letterSpacing: 0.3),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Text(
          media.title?.isNotEmpty == true ? media.title! : '未知标题',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: texts.titleLarge?.copyWith(fontWeight: FontWeight.w600, height: 1.3),
        ),
        if (media.artist?.isNotEmpty == true) ...[
          const SizedBox(height: 4),
          Text(
            media.artist!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: texts.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
          ),
        ],
        const SizedBox(height: 12),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: seekable ? 6 : 0, elevation: 0, pressedElevation: 0),
          ),
          child: Slider(
            padding: EdgeInsets.zero,
            value: duration == null || duration == 0 ? 0 : position.clamp(0, duration).toDouble(),
            max: duration == null || duration == 0 ? 1 : duration.toDouble(),
            onChanged: seekable ? (value) => setState(() => _dragging = value) : null,
            onChangeEnd: seekable
                ? (value) {
                    widget.console.command(Command.seek, {'positionUs': value.round()});
                    setState(() => _dragging = null);
                  }
                : null,
          ),
        ),
        const SizedBox(height: 6),
        DefaultTextStyle(
          style: texts.labelSmall!.copyWith(color: colors.onSurfaceVariant, fontFeatures: tabular),
          child: Row(
            children: [
              Text(_time(position)),
              const Spacer(),
              if (duration != null) Text(_time(duration)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              iconSize: 30,
              tooltip: '上一首',
              onPressed: () => _media('previous'),
              icon: const Icon(Icons.skip_previous_rounded),
            ),
            const SizedBox(width: 20),
            SizedBox.square(
              dimension: 64,
              child: IconButton.filled(
                iconSize: 34,
                tooltip: media.playing ? '暂停' : '播放',
                onPressed: () => _media(media.playing ? 'pause' : 'play'),
                icon: Icon(media.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
            ),
            const SizedBox(width: 20),
            IconButton(
              iconSize: 30,
              tooltip: '下一首',
              onPressed: () => _media('next'),
              icon: const Icon(Icons.skip_next_rounded),
            ),
          ],
        ),
      ],
    );
  }
}
