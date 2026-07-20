import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_theme.dart';
import '../core/models.dart';

class PagePadding extends StatelessWidget {
  const PagePadding({super.key, required this.child, this.top = 12});
  final Widget child;
  final double top;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.fromLTRB(20, top, 20, 24), child: child);
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
          DecoratedBox(
            decoration: const BoxDecoration(
              color: AppColors.mint,
              shape: BoxShape.circle,
            ),
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Icon(icon, size: 34, color: AppColors.primaryDark),
            ),
          ),
          const SizedBox(height: 20),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
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
  const StatusPill({super.key, required this.label, this.positive = true});
  final String label;
  final bool positive;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: positive ? AppColors.mint : const Color(0xFFF6E9E4),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: positive ? AppColors.primaryDark : AppColors.danger,
        ),
      ),
    ),
  );
}

String triggerLabel(String value) => switch (value) {
  'LAUGHTER' => '웃음',
  'WAKE_WORD' => '호출',
  'TOUCH' => '터치',
  'MANUAL' => '직접 저장',
  _ => value,
};

IconData triggerIcon(String value) => switch (value) {
  'LAUGHTER' => Icons.sentiment_very_satisfied_rounded,
  'WAKE_WORD' => Icons.graphic_eq_rounded,
  'TOUCH' => Icons.touch_app_rounded,
  _ => Icons.videocam_rounded,
};

String durationLabel(int? durationMs) {
  if (durationMs == null) {
    return '--:--';
  }
  final seconds = durationMs ~/ 1000;
  return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String memoryDate(DateTime? date) {
  if (date == null) {
    return '시간 정보 없음';
  }
  final now = DateTime.now();
  if (DateUtils.isSameDay(now, date)) {
    return '오늘 ${DateFormat('HH:mm').format(date)}';
  }
  if (DateUtils.isSameDay(now.subtract(const Duration(days: 1)), date)) {
    return '어제 ${DateFormat('HH:mm').format(date)}';
  }
  return DateFormat('M월 d일 HH:mm').format(date);
}

class MemoryTile extends StatelessWidget {
  const MemoryTile({
    super.key,
    required this.video,
    required this.onTap,
    this.onFavorite,
    this.onDelete,
  });
  final VideoMemory video;
  final VoidCallback onTap;
  final VoidCallback? onFavorite;
  final VoidCallback? onDelete;
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(18),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: SizedBox(
              width: 92,
              height: 68,
              child: video.thumbnailUrl == null
                  ? ColoredBox(
                      color: AppColors.mint,
                      child: Icon(
                        triggerIcon(video.triggerType),
                        color: AppColors.primary,
                      ),
                    )
                  : Image.network(
                      video.thumbnailUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: AppColors.mint,
                        child: Icon(Icons.movie_rounded),
                      ),
                    ),
            ),
          ),
          const SizedBox(width: 14),
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
                const SizedBox(height: 5),
                Text(
                  '${memoryDate(video.capturedStartAt ?? video.createdAt)} · ${durationLabel(video.durationMs)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Icon(
                      triggerIcon(video.triggerType),
                      size: 15,
                      color: AppColors.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      triggerLabel(video.triggerType),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primaryDark,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (value) =>
                value == 'favorite' ? onFavorite?.call() : onDelete?.call(),
            itemBuilder: (_) => [
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
    ),
  );
}
