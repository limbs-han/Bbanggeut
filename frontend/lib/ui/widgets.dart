import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_theme.dart';
import '../core/api_client.dart';
import '../core/models.dart';
import '../core/video_thumbnail_cache.dart';

class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: AppColors.cream,
      gradient: RadialGradient(
        center: Alignment(1.05, -1.0),
        radius: 1.35,
        colors: [Color(0xFFFFEEDB), AppColors.cream],
        stops: [0, .72],
      ),
    ),
    child: Stack(
      children: [
        const Positioned(
          right: -58,
          top: -54,
          child: _SoftCircle(size: 190, color: Color(0x55FFD9B8)),
        ),
        const Positioned(
          left: -92,
          bottom: 42,
          child: _SoftCircle(size: 230, color: Color(0x3FDDE4BD)),
        ),
        child,
      ],
    ),
  );
}

class _SoftCircle extends StatelessWidget {
  const _SoftCircle({required this.size, required this.color});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class PagePadding extends StatelessWidget {
  const PagePadding({
    super.key,
    required this.child,
    this.top = 12,
    this.bottom = 28,
  });
  final Widget child;
  final double top;
  final double bottom;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.fromLTRB(16, top, 16, bottom), child: child);
}

class SoftCard extends StatelessWidget {
  const SoftCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color = AppColors.surface,
    this.borderColor = AppColors.line,
    this.radius = 22,
  });
  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final Color borderColor;
  final double radius;

  @override
  Widget build(BuildContext context) => Material(
    color: color,
    elevation: 3,
    shadowColor: const Color(0x1C6B4C2D),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: borderColor),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.badge = false,
    this.size = 48,
  });
  final IconData icon;
  final VoidCallback? onPressed;
  final bool badge;
  final double size;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      SizedBox.square(
        dimension: size,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            minimumSize: Size.square(size),
            padding: EdgeInsets.zero,
            backgroundColor: AppColors.surfaceWarm,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: Icon(icon, color: AppColors.inkSoft, size: 25),
        ),
      ),
      if (badge)
        const Positioned(
          right: 6,
          top: 6,
          child: CircleAvatar(radius: 4, backgroundColor: AppColors.coral),
        ),
    ],
  );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
    ],
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              color: AppColors.coralSoft,
              borderRadius: BorderRadius.circular(25),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 34, color: AppColors.coral),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 7),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (action != null) ...[const SizedBox(height: 22), action!],
        ],
      ),
    ),
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    this.positive = true,
    this.color,
    this.compact = false,
  });
  final String label;
  final bool positive;
  final Color? color;
  final bool compact;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color ?? (positive ? AppColors.greenCard : AppColors.pink),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 12,
        vertical: compact ? 4 : 7,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: compact ? 10 : 12,
          fontWeight: FontWeight.w800,
          color: positive ? AppColors.sageDark : AppColors.danger,
        ),
      ),
    ),
  );
}

/// Uses the exact family photograph embedded in the supplied final live board.
/// The screenshot itself is kept as the immutable source and clipped at runtime.
class FamilyReferenceImage extends StatelessWidget {
  const FamilyReferenceImage({super.key, this.borderRadius = 20});
  final double borderRadius;

  static const _sourceWidth = 780.0;
  static const _cropLeft = 31.0;
  static const _cropTop = 288.0;
  static const _cropWidth = 717.0;
  static const _cropHeight = 405.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = constraints.maxWidth / _cropWidth;
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: SizedBox(
          width: constraints.maxWidth,
          height: _cropHeight * scale,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: -_cropLeft * scale,
                top: -_cropTop * scale,
                width: _sourceWidth * scale,
                child: Image.asset(
                  'assets/images/family_live_reference.png',
                  fit: BoxFit.fitWidth,
                  filterQuality: FilterQuality.high,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

String triggerLabel(String value) => switch (value) {
  'LAUGHTER' => '웃음',
  'CLAP' => '박수',
  'WAKE_WORD' => '호출',
  'TOUCH' => '일상',
  'MANUAL' => '직접 저장',
  'USER_UPLOAD' => '업로드',
  'EDIT' => '편집본',
  _ => value,
};

IconData triggerIcon(String value) => switch (value) {
  'LAUGHTER' => Icons.sentiment_very_satisfied_rounded,
  'CLAP' => Icons.back_hand_rounded,
  'WAKE_WORD' => Icons.graphic_eq_rounded,
  'TOUCH' => Icons.waving_hand_rounded,
  'MANUAL' => Icons.bookmark_rounded,
  _ => Icons.videocam_rounded,
};

Color triggerColor(String value) => switch (value) {
  'LAUGHTER' => AppColors.yellowSoft,
  'CLAP' => AppColors.coralSoft,
  'WAKE_WORD' => AppColors.sageSoft,
  'TOUCH' => AppColors.greenCard,
  _ => AppColors.pink,
};

class VideoEventTypePills extends StatelessWidget {
  const VideoEventTypePills({
    super.key,
    required this.video,
    this.compact = false,
    this.alignment = WrapAlignment.start,
  });

  final VideoMemory video;
  final bool compact;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: alignment,
    spacing: compact ? 4 : 6,
    runSpacing: compact ? 4 : 6,
    children: [
      for (final eventType in video.effectiveEventTypes)
        StatusPill(
          label: triggerLabel(eventType),
          color: triggerColor(eventType),
          compact: compact,
        ),
    ],
  );
}

String durationLabel(int? durationMs) {
  if (durationMs == null) return '--:--';
  final seconds = durationMs ~/ 1000;
  return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String memoryDate(DateTime? date) {
  if (date == null) return '시간 정보 없음';
  final now = DateTime.now();
  if (DateUtils.isSameDay(now, date)) {
    return '오늘 ${DateFormat('a h:mm', 'ko').format(date)}';
  }
  if (DateUtils.isSameDay(now.subtract(const Duration(days: 1)), date)) {
    return '어제 ${DateFormat('HH:mm').format(date)}';
  }
  return DateFormat('M월 d일 HH:mm').format(date);
}

class MemoryThumbnail extends StatelessWidget {
  const MemoryThumbnail({
    super.key,
    required this.api,
    required this.video,
    this.width = 92,
    this.height = 68,
  });
  final ApiClient api;
  final VideoMemory video;
  final double width;
  final double height;

  /// 몇 픽셀로 풀어 둘지.
  ///
  /// **왜 정해 주는가**: [VideoThumbnailCache]가 만드는 그림은 폭 720px인데
  /// 여기서 그리는 자리는 92×68dp다. 정해 주지 않으면 720px 그대로 풀려 한 장에
  /// 1MB 넘게 이미지 캐시를 차지한다 — 추억 목록처럼 수십 장이 스크롤되는 화면에서는
  /// 그게 수십 MB가 되고, 푸는 시간도 그만큼 들어 스크롤이 걸린다.
  ///
  /// [BoxFit.cover]는 원본 비율에 따라 가로·세로 중 한쪽이 기준이 된다. 원본이
  /// 세로 영상이면 가로가 기준이고, 가로 영상(16:9)이면 세로가 기준이라 그때 필요한
  /// 가로 픽셀이 더 크다. 둘 중 큰 쪽으로 잡아 어느 비율이 와도 흐려지지 않게 한다.
  int _decodeWidth(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return (math.max(width, height * 16 / 9) * ratio).round();
  }

  Widget _fallback(BuildContext context) => video.thumbnailUrl != null
      ? Image.network(
          video.thumbnailUrl!,
          fit: BoxFit.cover,
          cacheWidth: _decodeWidth(context),
          errorBuilder: (_, _, _) =>
              const FamilyReferenceImage(borderRadius: 0),
        )
      : const FamilyReferenceImage(borderRadius: 0);

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(13),
    child: SizedBox(
      width: width,
      height: height,
      child: FutureBuilder<String?>(
        future: VideoThumbnailCache.frameAtOneMinute(api, video),
        builder: (context, snapshot) {
          final path = snapshot.data;
          if (path != null) {
            return Image.file(
              File(path),
              fit: BoxFit.cover,
              cacheWidth: _decodeWidth(context),
              errorBuilder: (_, _, _) => _fallback(context),
            );
          }
          return _fallback(context);
        },
      ),
    ),
  );
}

class MemoryTile extends StatelessWidget {
  const MemoryTile({
    super.key,
    required this.api,
    required this.video,
    required this.onTap,
    this.onFavorite,
    this.onDelete,
    this.compact = false,
  });
  final ApiClient api;
  final VideoMemory video;
  final VoidCallback onTap;
  final VoidCallback? onFavorite;
  final VoidCallback? onDelete;
  final bool compact;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(16),
    onTap: onTap,
    child: Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 6 : 9),
      child: Row(
        children: [
          MemoryThumbnail(
            api: api,
            video: video,
            width: compact ? 72 : 88,
            height: compact ? 52 : 64,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${memoryDate(video.capturedStartAt ?? video.createdAt)} · ${durationLabel(video.durationMs)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 130),
            child: VideoEventTypePills(
              video: video,
              compact: true,
              alignment: WrapAlignment.end,
            ),
          ),
          if (onFavorite != null || onDelete != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, color: AppColors.muted),
              onSelected: (value) =>
                  value == 'favorite' ? onFavorite?.call() : onDelete?.call(),
              itemBuilder: (_) => [
                if (onFavorite != null)
                  PopupMenuItem(
                    value: 'favorite',
                    child: Text(video.favorite ? '즐겨찾기 해제' : '즐겨찾기'),
                  ),
                if (onDelete != null)
                  const PopupMenuItem(value: 'delete', child: Text('삭제')),
              ],
            ),
        ],
      ),
    ),
  );
}

void showAppSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: error ? AppColors.danger : AppColors.ink,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

enum MemoryConnectionChoice { keep, restart }

Future<MemoryConnectionChoice?> showMemoryConnectionChoice(
  BuildContext context,
) async {
  final choice = await showDialog<MemoryConnectionChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('이전 기기의 추억을 유지하시겠습니까?'),
      content: const Text('새로 시작할 경우 이전에 저장된 추억이 삭제됩니다.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('취소'),
        ),
        OutlinedButton(
          onPressed: () =>
              Navigator.pop(dialogContext, MemoryConnectionChoice.keep),
          child: const Text('유지하기'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: () =>
              Navigator.pop(dialogContext, MemoryConnectionChoice.restart),
          child: const Text('새로 시작하기'),
        ),
      ],
    ),
  );
  if (!context.mounted || choice != MemoryConnectionChoice.restart) {
    return choice;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('정말 새로 시작할까요?'),
      content: const Text('이전 추억 삭제는 되돌릴 수 없습니다. 기기 연결 후 서버에서 삭제 처리가 필요합니다.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('취소'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('새로 시작'),
        ),
      ],
    ),
  );
  return confirmed == true ? choice : null;
}

Future<bool> confirmVideoDeletion(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('영상을 삭제할까요?'),
        content: const Text('삭제한 영상은 다시 복구할 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    ) ??
    false;
