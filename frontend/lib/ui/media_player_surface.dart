import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../app/app_theme.dart';

class MediaPlayerSurface extends StatefulWidget {
  const MediaPlayerSurface({
    super.key,
    required this.controller,
    this.isLive = false,
    this.isFullscreen = false,
  });

  final VideoPlayerController controller;
  final bool isLive;
  final bool isFullscreen;

  @override
  State<MediaPlayerSurface> createState() => _MediaPlayerSurfaceState();
}

class _MediaPlayerSurfaceState extends State<MediaPlayerSurface> {
  Timer? _hideTimer;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onPlayerChanged);
    _scheduleHide();
  }

  @override
  void didUpdateWidget(covariant MediaPlayerSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onPlayerChanged);
      widget.controller.addListener(_onPlayerChanged);
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    widget.controller.removeListener(_onPlayerChanged);
    super.dispose();
  }

  void _onPlayerChanged() {
    if (mounted) setState(() {});
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!widget.controller.value.isPlaying) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _showTemporarily() {
    setState(() => _showControls = true);
    _scheduleHide();
  }

  Future<void> _togglePlayback() async {
    final controller = widget.controller;
    if (controller.value.isPlaying) {
      await controller.pause();
      _hideTimer?.cancel();
      if (mounted) setState(() => _showControls = true);
      return;
    }
    if (!widget.isLive &&
        controller.value.duration > Duration.zero &&
        controller.value.position >= controller.value.duration) {
      await controller.seekTo(Duration.zero);
    }
    await controller.play();
    _hideTimer?.cancel();
    if (mounted) setState(() => _showControls = false);
  }

  Future<void> _seekBy(Duration delta) async {
    final value = widget.controller.value;
    var target = value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > value.duration) target = value.duration;
    await widget.controller.seekTo(target);
    if (mounted) _showTemporarily();
  }

  Future<void> _toggleMute() async {
    await widget.controller.setVolume(
      widget.controller.value.volume == 0 ? 1 : 0,
    );
    if (mounted) _showTemporarily();
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  Future<void> _openFullscreen() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    try {
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => _FullscreenPlayer(
            controller: widget.controller,
            isLive: widget.isLive,
          ),
        ),
      );
    } finally {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (mounted) _showTemporarily();
    }
  }

  Future<void> _returnToLive() async {
    final duration = widget.controller.value.duration;
    if (duration > Duration.zero) {
      await widget.controller.seekTo(duration);
    }
    await widget.controller.play();
    if (mounted) _showTemporarily();
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.controller.value;
    final ended =
        !widget.isLive &&
        value.duration > Duration.zero &&
        value.position >= value.duration;
    return ColoredBox(
      color: Colors.black,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: AspectRatio(
                aspectRatio: value.aspectRatio == 0
                    ? 16 / 9
                    : value.aspectRatio,
                child: VideoPlayer(widget.controller),
              ),
            ),
            AnimatedOpacity(
              opacity: _showControls ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IgnorePointer(
                ignoring: !_showControls,
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black26,
                              Colors.transparent,
                              Colors.black87,
                            ],
                            stops: [0, .48, 1],
                          ),
                        ),
                      ),
                    ),
                    Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!widget.isLive)
                            _RoundControl(
                              icon: Icons.replay_10_rounded,
                              onPressed: () =>
                                  _seekBy(const Duration(seconds: -10)),
                            ),
                          if (!widget.isLive) const SizedBox(width: 18),
                          _RoundControl(
                            icon: ended
                                ? Icons.replay_rounded
                                : value.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 58,
                            iconSize: 38,
                            onPressed: _togglePlayback,
                          ),
                          if (!widget.isLive) const SizedBox(width: 18),
                          if (!widget.isLive)
                            _RoundControl(
                              icon: Icons.forward_10_rounded,
                              onPressed: () =>
                                  _seekBy(const Duration(seconds: 10)),
                            ),
                        ],
                      ),
                    ),
                    Positioned(
                      left: 12,
                      right: 8,
                      bottom: 4,
                      child: widget.isLive
                          ? _LiveControls(
                              muted: value.volume == 0,
                              fullscreen: widget.isFullscreen,
                              onLiveEdge: _returnToLive,
                              onMute: _toggleMute,
                              onFullscreen: widget.isFullscreen
                                  ? () => Navigator.of(context).pop()
                                  : _openFullscreen,
                            )
                          : _RecordedControls(
                              value: value,
                              fullscreen: widget.isFullscreen,
                              onSeek: (milliseconds) {
                                widget.controller.seekTo(
                                  Duration(milliseconds: milliseconds.round()),
                                );
                                _showTemporarily();
                              },
                              onFullscreen: widget.isFullscreen
                                  ? () => Navigator.of(context).pop()
                                  : _openFullscreen,
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
}

class _RecordedControls extends StatelessWidget {
  const _RecordedControls({
    required this.value,
    required this.fullscreen,
    required this.onSeek,
    required this.onFullscreen,
  });

  final VideoPlayerValue value;
  final bool fullscreen;
  final ValueChanged<double> onSeek;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context) {
    final duration = value.duration.inMilliseconds;
    final position = value.position.inMilliseconds.clamp(0, duration);
    return Row(
      children: [
        Text(_timeLabel(value.position), style: _timeStyle),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.peach,
              inactiveTrackColor: Colors.white30,
              thumbColor: AppColors.peach,
              overlayColor: AppColors.peach.withValues(alpha: .2),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              min: 0,
              max: duration <= 0 ? 1 : duration.toDouble(),
              value: duration <= 0 ? 0 : position.toDouble(),
              onChanged: duration <= 0 ? null : onSeek,
            ),
          ),
        ),
        Text(_timeLabel(value.duration), style: _timeStyle),
        IconButton(
          tooltip: fullscreen ? '전체화면 종료' : '전체화면',
          onPressed: onFullscreen,
          color: Colors.white,
          icon: Icon(
            fullscreen
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
          ),
        ),
      ],
    );
  }
}

const _timeStyle = TextStyle(color: Colors.white, fontSize: 12);

class _LiveControls extends StatelessWidget {
  const _LiveControls({
    required this.muted,
    required this.fullscreen,
    required this.onLiveEdge,
    required this.onMute,
    required this.onFullscreen,
  });

  final bool muted;
  final bool fullscreen;
  final VoidCallback onLiveEdge;
  final VoidCallback onMute;
  final VoidCallback onFullscreen;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      TextButton.icon(
        onPressed: onLiveEdge,
        style: TextButton.styleFrom(
          foregroundColor: Colors.redAccent,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        icon: const Icon(Icons.circle, size: 10),
        label: const Text(
          'LIVE',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      const Spacer(),
      IconButton(
        tooltip: muted ? '소리 켜기' : '음소거',
        onPressed: onMute,
        color: Colors.white,
        icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded),
      ),
      IconButton(
        tooltip: fullscreen ? '전체화면 종료' : '전체화면',
        onPressed: onFullscreen,
        color: Colors.white,
        icon: Icon(
          fullscreen ? Icons.fullscreen_exit_rounded : Icons.fullscreen_rounded,
        ),
      ),
    ],
  );
}

class _RoundControl extends StatelessWidget {
  const _RoundControl({
    required this.icon,
    required this.onPressed,
    this.size = 46,
    this.iconSize = 28,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.black54,
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onPressed,
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(icon, color: Colors.white, size: iconSize),
      ),
    ),
  );
}

class _FullscreenPlayer extends StatefulWidget {
  const _FullscreenPlayer({required this.controller, required this.isLive});

  final VideoPlayerController controller;
  final bool isLive;

  @override
  State<_FullscreenPlayer> createState() => _FullscreenPlayerState();
}

class _FullscreenPlayerState extends State<_FullscreenPlayer> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(
        SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: SizedBox.expand(
      child: MediaPlayerSurface(
        controller: widget.controller,
        isLive: widget.isLive,
        isFullscreen: true,
      ),
    ),
  );
}

String _timeLabel(Duration value) {
  final totalSeconds = value.inSeconds;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
