import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'local_edit_screen.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

class MemoryVideoCard extends StatelessWidget {
  const MemoryVideoCard({
    super.key,
    required this.controller,
    required this.video,
    this.onChanged,
    this.onDeleted,
  });

  final AppController controller;
  final VideoMemory video;
  final VoidCallback? onChanged;
  final VoidCallback? onDeleted;

  DateTime get _start =>
      video.capturedStartAt ?? video.createdAt ?? DateTime.now();

  String get _timeRange {
    final end = _start.add(const Duration(minutes: 2));
    return '${DateFormat('M월 d일 HH:mm').format(_start)}'
        ' - ${DateFormat('HH:mm').format(end)}';
  }

  Future<void> _toggleFavorite(BuildContext context) async {
    final ok = await controller.toggleFavorite(video);
    if (!context.mounted) return;
    if (!ok) {
      showAppSnack(
        context,
        controller.errorMessage ?? '즐겨찾기를 변경하지 못했어요.',
        error: true,
      );
      return;
    }
    onChanged?.call();
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await confirmVideoDeletion(context);
    if (!confirmed || !context.mounted || controller.busy) return;
    final ok = await controller.removeVideo(video);
    if (!context.mounted) return;
    if (ok) {
      onDeleted?.call();
      onChanged?.call();
      showAppSnack(context, '영상이 삭제되었습니다.');
    } else {
      showAppSnack(
        context,
        controller.errorMessage ?? '영상을 삭제하지 못했어요.',
        error: true,
      );
    }
  }

  Future<void> _share(BuildContext context) async {
    // TODO(content-share): share_plus가 승인되면 실제 시스템 공유 시트로 교체합니다.
    await Clipboard.setData(ClipboardData(text: '${video.title}\n$_timeRange'));
    if (context.mounted) {
      showAppSnack(context, '영상 정보가 복사되었습니다. 공유할 곳에 붙여 넣어 주세요.');
    }
  }

  Future<void> _edit(BuildContext context) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => LocalEditScreen(controller: controller, video: video),
      ),
    );
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) => SoftCard(
    padding: EdgeInsets.zero,
    child: InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              VideoDetailScreen(controller: controller, video: video),
        ),
      ).then((_) => onChanged?.call()),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                MemoryThumbnail(
                  api: controller.api,
                  video: video,
                  width: 132,
                  height: 100,
                ),
                Positioned(
                  right: 7,
                  bottom: 7,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .72),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      durationLabel(video.durationMs),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          video.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: video.favorite ? '즐겨찾기 해제' : '즐겨찾기',
                        onPressed: () => _toggleFavorite(context),
                        icon: Icon(
                          video.favorite
                              ? Icons.favorite_rounded
                              : Icons.favorite_border_rounded,
                          color: video.favorite
                              ? AppColors.coral
                              : AppColors.muted,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    _timeRange,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    video.description?.trim().isNotEmpty == true
                        ? video.description!.trim()
                        : '등록된 메모가 없습니다',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 5),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: '영상 편집하기',
                        onPressed: () => _edit(context),
                        icon: const Icon(Icons.content_cut_rounded),
                      ),
                      IconButton(
                        tooltip: '공유하기',
                        onPressed: () => _share(context),
                        icon: const Icon(Icons.share_outlined),
                      ),
                      IconButton(
                        tooltip: '삭제하기',
                        onPressed: () => _delete(context),
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          color: Colors.red,
                        ),
                      ),
                    ],
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
