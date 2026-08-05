import 'package:flutter/material.dart';
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

  /// 형식 하나를 만들 때마다 패턴을 파싱하고 로케일을 찾는다. 목록을 넘길 때
  /// 카드마다 두 개씩 새로 만들던 것을 한 번만 만들어 나눠 쓴다.
  static final _dayTime = DateFormat('M월 d일 HH:mm');
  static final _time = DateFormat('HH:mm');

  DateTime get _start =>
      video.capturedStartAt ?? video.createdAt ?? DateTime.now();

  /// **왜 길이를 다시 재는가**: 끝 시각을 시작 + 2분으로 박아 두었더니 30초
  /// 클립도 "09:27 - 09:29"로 보였다. 길이를 아는 영상은 그 길이로 끝을 잡고,
  /// 모르는 영상은 끝을 아예 적지 않는다 — 틀린 범위보다 없는 편이 낫다.
  String get _timeRange {
    final start = _start;
    final durationMs = video.durationMs;
    if (durationMs == null || durationMs <= 0) return _dayTime.format(start);
    final end = start.add(Duration(milliseconds: durationMs));
    // 30초 클립은 시작과 끝이 같은 분에 든다. "09:27 - 09:27"은 범위가 아니라
    // 잡음이므로 그때는 시작만 적는다.
    if (_time.format(end) == _time.format(start)) return _dayTime.format(start);
    return '${_dayTime.format(start)} - ${_time.format(end)}';
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
                          videoDisplayTitle(video),
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
                  const SizedBox(height: 5),
                  VideoEventTypePills(video: video, compact: true),
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
