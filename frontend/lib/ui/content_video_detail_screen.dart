import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import '../core/video_gallery_saver.dart';
import 'local_edit_screen.dart';
import 'media_player_surface.dart';
import 'widgets.dart';

class ContentVideoDetailScreen extends StatefulWidget {
  const ContentVideoDetailScreen({
    super.key,
    required this.controller,
    required this.video,
  });

  final AppController controller;
  final VideoMemory video;

  @override
  State<ContentVideoDetailScreen> createState() =>
      _ContentVideoDetailScreenState();
}

class _ContentVideoDetailScreenState extends State<ContentVideoDetailScreen> {
  late VideoMemory _video;
  VideoPlayerController? _player;
  bool _loading = true;
  bool _saving = false;
  double? _saveProgress;
  String? _error;

  @override
  void initState() {
    super.initState();
    _video = widget.video;
    _loadPlayer();
  }

  Future<void> _loadPlayer() async {
    if (_video.status != 'READY') {
      setState(() {
        _loading = false;
        _error = '영상 처리가 완료된 후 재생할 수 있습니다.';
      });
      return;
    }
    try {
      final playUrl = await widget.controller.api.createPlayUrl(_video.id);
      final player = VideoPlayerController.networkUrl(Uri.parse(playUrl.url));
      await player.initialize();
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _loading = false;
      });
    } catch (failure) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '영상을 불러오지 못했어요. $failure';
        });
      }
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _editMetadata() async {
    final title = TextEditingController(text: _video.title);
    final memo = TextEditingController(text: _video.description ?? '');
    final shouldSave = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('제목과 메모 수정'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              maxLength: 120,
              decoration: const InputDecoration(labelText: '제목'),
            ),
            TextField(
              controller: memo,
              minLines: 3,
              maxLines: 6,
              maxLength: 500,
              decoration: const InputDecoration(labelText: '메모'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: title.text.trim().isEmpty
                ? null
                : () => Navigator.pop(dialogContext, true),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    if (shouldSave == true) {
      try {
        await widget.controller.api.updateVideo(
          _video.id,
          title: title.text.trim(),
          description: memo.text.trim(),
        );
        final refreshed = await widget.controller.api.getVideo(_video.id);
        await widget.controller.refreshDeviceData();
        if (mounted) {
          setState(() => _video = refreshed);
          showAppSnack(context, '제목과 메모를 저장했습니다.');
        }
      } catch (failure) {
        if (mounted) showAppSnack(context, '$failure', error: true);
      }
    }
    title.dispose();
    memo.dispose();
  }

  Future<void> _saveVideo() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveProgress = null;
    });
    try {
      await VideoGallerySaver.save(
        api: widget.controller.api,
        videoId: _video.id,
        onProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _saveProgress = received / total);
        },
      );
      if (mounted) showAppSnack(context, '휴대폰 갤러리에 영상을 저장했어요.');
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveProgress = null;
        });
      }
    }
  }

  Future<void> _openEditor() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            LocalEditScreen(controller: widget.controller, video: _video),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AppBackdrop(
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 60,
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  RoundIconButton(
                    icon: Icons.chevron_left_rounded,
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: _video.favorite ? '즐겨찾기 해제' : '즐겨찾기',
                    onPressed: () async {
                      final ok = await widget.controller.toggleFavorite(_video);
                      if (!mounted || !ok) return;
                      final refreshed = await widget.controller.api.getVideo(
                        _video.id,
                      );
                      if (mounted) setState(() => _video = refreshed);
                    },
                    icon: Icon(
                      _video.favorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: _video.favorite
                          ? AppColors.coral
                          : AppColors.muted,
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
            AspectRatio(
              aspectRatio: 16 / 9,
              child: _player != null
                  ? MediaPlayerSurface(controller: _player!)
                  : ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: _loading
                            ? const CircularProgressIndicator()
                            : Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  _error ?? '영상을 재생할 수 없습니다.',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                      ),
                    ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          _video.title,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: '제목과 메모 수정',
                        onPressed: _editMetadata,
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    memoryDate(_video.capturedStartAt ?? _video.createdAt),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const Divider(height: 28),
                  Text(
                    _video.description?.trim().isNotEmpty == true
                        ? _video.description!.trim()
                        : '등록된 메모가 없습니다',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 28),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _saveVideo,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_rounded),
                    label: Text(
                      _saving
                          ? _saveProgress == null
                                ? '다운로드 중…'
                                : '저장 중 ${(_saveProgress! * 100).round()}%'
                          : '갤러리에 저장',
                    ),
                  ),
                  if (_saving) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _saveProgress),
                  ],
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _openEditor,
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    icon: const Icon(Icons.content_cut_rounded),
                    label: const Text('영상 편집하기'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
