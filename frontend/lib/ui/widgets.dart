import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_theme.dart';
import '../core/models.dart';

class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: AppColors.cream,
      gradient: LinearGradient(
        begin: Alignment.topRight,
        end: Alignment.bottomLeft,
        colors: [Color(0xFFFFFBF1), AppColors.cream, Color(0xFFF1F6E8)],
        stops: [0, .62, 1],
      ),
    ),
    child: Stack(
      children: [
        const Positioned(
          right: -64,
          top: -70,
          child: _SoftCircle(size: 210, color: Color(0x3AFFF1C9)),
        ),
        const Positioned(
          left: -80,
          bottom: 80,
          child: _SoftCircle(size: 240, color: Color(0x42DFE9CF)),
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
    elevation: 2,
    shadowColor: const Color(0x18000000),
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
            backgroundColor: AppColors.surface,
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
          CircleAvatar(
            radius: 36,
            backgroundColor: AppColors.sageSoft,
            child: Icon(icon, size: 34, color: AppColors.sageDark),
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
  });
  final String label;
  final bool positive;
  final Color? color;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color ?? (positive ? AppColors.greenCard : AppColors.pink),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
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
  'WAKE_WORD' => '호출',
  'TOUCH' => '일상',
  'MANUAL' => '직접 저장',
  'USER_UPLOAD' => '업로드',
  'EDIT' => '편집본',
  _ => value,
};

IconData triggerIcon(String value) => switch (value) {
  'LAUGHTER' => Icons.sentiment_very_satisfied_rounded,
  'WAKE_WORD' => Icons.graphic_eq_rounded,
  'TOUCH' => Icons.waving_hand_rounded,
  'MANUAL' => Icons.bookmark_rounded,
  _ => Icons.videocam_rounded,
};

Color triggerColor(String value) => switch (value) {
  'LAUGHTER' => AppColors.yellowSoft,
  'WAKE_WORD' => AppColors.sageSoft,
  'TOUCH' => AppColors.greenCard,
  _ => AppColors.pink,
};

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
    required this.video,
    this.width = 92,
    this.height = 68,
  });
  final VideoMemory video;
  final double width;
  final double height;
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(13),
    child: SizedBox(
      width: width,
      height: height,
      child: video.thumbnailUrl != null
          ? Image.network(
              video.thumbnailUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  const FamilyReferenceImage(borderRadius: 0),
            )
          : const FamilyReferenceImage(borderRadius: 0),
    ),
  );
}

class MemoryTile extends StatelessWidget {
  const MemoryTile({
    super.key,
    required this.video,
    required this.onTap,
    this.onFavorite,
    this.onDelete,
    this.compact = false,
  });
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
          StatusPill(
            label: triggerLabel(video.triggerType),
            color: triggerColor(video.triggerType),
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
