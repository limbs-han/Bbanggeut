import 'package:flutter/material.dart';
import 'package:imgly_editor/imgly_editor.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'local_edit_screen.dart';
import 'media_player_surface.dart';
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
  late VideoMemory video;
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    video = widget.video;
    _load();
  }

  Future<void> _load() async {
    if (video.status != 'READY') {
      setState(() {
        loading = false;
        error = '영상 처리가 완료되면 재생할 수 있어요.';
      });
      return;
    }
    try {
      final signed = await widget.controller.api.createPlayUrl(video.id);
      final next = VideoPlayerController.networkUrl(Uri.parse(signed.url));
      await next.initialize();
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
      final signed = await widget.controller.api.createDownloadUrl(video.id);
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

  Future<void> _openImglyEditor() async {
    try {
      await player?.pause();
      final signed = await widget.controller.api.createDownloadUrl(video.id);
      const license = String.fromEnvironment('IMGLY_LICENSE');
      final result = await IMGLYEditor.openEditor(
        source: Source.fromVideo(signed.url),
        preset: EditorPreset.video,
        settings: EditorSettings(
          license: license.isEmpty ? null : license,
          userId: widget.controller.user?.id,
        ),
      );
      if (mounted && result?.artifact != null) {
        showAppSnack(context, '영상 편집을 완료했어요.');
      }
    } catch (failure) {
      if (mounted) {
        showAppSnack(context, '영상 편집기를 열지 못했어요. $failure', error: true);
      }
    }
  }

  Future<void> _editMetadata() async {
    final title = TextEditingController(text: video.title);
    final description = TextEditingController(text: video.description ?? '');
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('추억 편집'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              maxLength: 120,
              decoration: const InputDecoration(labelText: '제목'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: description,
              maxLength: 500,
              minLines: 3,
              maxLines: 5,
              decoration: const InputDecoration(labelText: '메모'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (save == true) {
      try {
        await widget.controller.api.updateVideo(
          video.id,
          title: title.text.trim(),
          description: description.text.trim(),
        );
        final refreshed = await widget.controller.api.getVideo(video.id);
        if (mounted) setState(() => video = refreshed);
        await widget.controller.refreshDeviceData();
      } catch (failure) {
        if (mounted) showAppSnack(context, '$failure', error: true);
      }
    }
    title.dispose();
    description.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AppBackdrop(
      child: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 380,
            pinned: true,
            leading: Padding(
              padding: const EdgeInsets.all(8),
              child: CircleAvatar(
                backgroundColor: const Color(0x9B2D312B),
                child: IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(
                    Icons.chevron_left_rounded,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            actions: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: CircleAvatar(
                  backgroundColor: const Color(0x9B2D312B),
                  child: IconButton(
                    onPressed: () async {
                      await widget.controller.toggleFavorite(video);
                      if (mounted) {
                        setState(
                          () => video = VideoMemory(
                            id: video.id,
                            deviceId: video.deviceId,
                            triggerType: video.triggerType,
                            sourceType: video.sourceType,
                            title: video.title,
                            status: video.status,
                            favorite: !video.favorite,
                            description: video.description,
                            durationMs: video.durationMs,
                            thumbnailUrl: video.thumbnailUrl,
                            capturedStartAt: video.capturedStartAt,
                            createdAt: video.createdAt,
                          ),
                        );
                      }
                    },
                    icon: Icon(
                      video.favorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(background: _media()),
          ),
          SliverToBoxAdapter(
            child: PagePadding(
              top: 18,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      StatusPill(
                        label: triggerLabel(video.triggerType),
                        color: triggerColor(video.triggerType),
                      ),
                      const Spacer(),
                      RoundIconButton(
                        icon: Icons.edit_outlined,
                        size: 42,
                        onPressed: _editMetadata,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    video.title,
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${memoryDate(video.capturedStartAt ?? video.createdAt)} · ${durationLabel(video.durationMs)}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const Divider(height: 28),
                  Text(
                    video.description?.isNotEmpty == true
                        ? video.description!
                        : '이때가 얼마나 예쁜 순간인지 몰라요. 메모를 남겨 가족과 함께 기억해 보세요.',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      StatusPill(
                        label: '#${triggerLabel(video.triggerType)}',
                        color: triggerColor(video.triggerType),
                      ),
                      const StatusPill(
                        label: '#우리집',
                        color: AppColors.yellowSoft,
                      ),
                      const StatusPill(label: '#추억', color: AppColors.pink),
                    ],
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: video.status == 'READY'
                        ? _openImglyEditor
                        : null,
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: const Text('IMG.LY로 영상 편집'),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _download,
                          icon: const Icon(Icons.download_rounded),
                          label: const Text('저장'),
                        ),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => LocalEditScreen(
                                controller: widget.controller,
                                video: video,
                              ),
                            ),
                          ),
                          icon: const Icon(Icons.content_cut_rounded),
                          label: const Text('구간 편집'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _media() {
    if (player != null) {
      return MediaPlayerSurface(controller: player!);
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        const FamilyReferenceImage(borderRadius: 0),
        if (loading)
          const Center(child: CircularProgressIndicator(color: Colors.white)),
        if (error != null)
          Center(
            child: Container(
              padding: const EdgeInsets.all(14),
              color: const Color(0x802D312B),
              child: Text(error!, style: const TextStyle(color: Colors.white)),
            ),
          ),
      ],
    );
  }
}
