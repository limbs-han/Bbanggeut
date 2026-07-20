import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'local_edit_screen.dart';
import 'widgets.dart';

class VideoDetailScreen extends StatefulWidget {
  const VideoDetailScreen({
    super.key,
    required this.controller,
    required this.video,
  });
  final AppController controller;
  final VideoMemory video;
  @override
  State<VideoDetailScreen> createState() => _VideoDetailScreenState();
}

class _VideoDetailScreenState extends State<VideoDetailScreen> {
  VideoPlayerController? player;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final signed = await widget.controller.api.createPlayUrl(widget.video.id);
      final next = VideoPlayerController.networkUrl(Uri.parse(signed.url));
      await next.initialize();
      await next.setLooping(false);
      if (!mounted) {
        await next.dispose();
        return;
      }
      setState(() {
        player = next;
        loading = false;
      });
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = '$failure';
          loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    player?.dispose();
    super.dispose();
  }

  Future<void> _download() async {
    try {
      final signed = await widget.controller.api.createDownloadUrl(
        widget.video.id,
      );
      final launched = await launchUrl(
        Uri.parse(signed.url),
        mode: LaunchMode.externalApplication,
      );
      if (mounted && !launched) {
        showAppSnack(context, '다운로드 앱을 열지 못했어요.', error: true);
      }
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('추억 보기'),
      actions: [
        IconButton(
          onPressed: () => widget.controller.toggleFavorite(widget.video),
          icon: Icon(
            widget.video.favorite
                ? Icons.favorite_rounded
                : Icons.favorite_border_rounded,
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        child: PagePadding(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: ColoredBox(color: AppColors.ink, child: _playerBody()),
                ),
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.video.title,
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                        const SizedBox(height: 7),
                        Text(
                          '${memoryDate(widget.video.capturedStartAt)} · ${durationLabel(widget.video.durationMs)}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  StatusPill(label: triggerLabel(widget.video.triggerType)),
                ],
              ),
              if (widget.video.description?.isNotEmpty == true) ...[
                const SizedBox(height: 18),
                Text(
                  widget.video.description!,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
              const SizedBox(height: 28),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        backgroundColor: AppColors.mint,
                        child: Icon(
                          Icons.shield_outlined,
                          color: AppColors.primaryDark,
                        ),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '안전한 단기 재생 링크',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '재생·다운로드 주소는 짧은 시간 뒤 자동 만료됩니다.',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: _download,
                icon: const Icon(Icons.download_rounded),
                label: const Text('원본 다운로드'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => LocalEditScreen(
                      controller: widget.controller,
                      video: widget.video,
                    ),
                  ),
                ),
                icon: const Icon(Icons.content_cut_rounded),
                label: const Text('구간 편집'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _playerBody() {
    if (loading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Text(
            error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }
    final current = player!;
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: current.value.aspectRatio,
            child: VideoPlayer(current),
          ),
        ),
        GestureDetector(
          onTap: () {
            setState(
              () => current.value.isPlaying ? current.pause() : current.play(),
            );
          },
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: .45),
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Icon(
                current.value.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                size: 34,
                color: Colors.white,
              ),
            ),
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 4,
          child: VideoProgressIndicator(
            current,
            allowScrubbing: true,
            colors: const VideoProgressColors(
              playedColor: AppColors.peach,
              bufferedColor: Colors.white38,
              backgroundColor: Colors.white24,
            ),
          ),
        ),
      ],
    );
  }
}
