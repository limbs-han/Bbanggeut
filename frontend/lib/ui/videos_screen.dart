import 'package:flutter/material.dart';
import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'all_memories_screen.dart';
import 'extra_screens.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

enum _MemoryCategory { homeCam, laughter, edited }

enum _MemorySort { newest, oldest }

class VideosScreen extends StatelessWidget {
  const VideosScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) =>
      AllMemoriesScreen(controller: controller);
}

class _LegacyVideosScreen extends StatefulWidget {
  const _LegacyVideosScreen({required this.controller});
  final AppController controller;

  @override
  State<_LegacyVideosScreen> createState() => _VideosScreenState();
}

class _VideosScreenState extends State<_LegacyVideosScreen> {
  _MemoryCategory category = _MemoryCategory.homeCam;
  _MemorySort sort = _MemorySort.newest;
  String search = '';

  List<VideoMemory> get items {
    final needle = search.toLowerCase();
    final result = widget.controller.videos.where((video) {
      final matchesCategory = switch (category) {
        _MemoryCategory.homeCam =>
          video.triggerType != 'LAUGHTER' &&
              video.triggerType != 'EDIT' &&
              video.sourceType != 'EDIT_OUTPUT',
        _MemoryCategory.laughter => video.triggerType == 'LAUGHTER',
        _MemoryCategory.edited =>
          video.triggerType == 'EDIT' || video.sourceType == 'EDIT_OUTPUT',
      };
      final matchesSearch =
          needle.isEmpty ||
          video.title.toLowerCase().contains(needle) ||
          (video.description?.toLowerCase().contains(needle) ?? false);
      return matchesCategory && matchesSearch;
    }).toList();
    result.sort((a, b) {
      final aDate = a.capturedStartAt ?? a.createdAt ?? DateTime(1970);
      final bDate = b.capturedStartAt ?? b.createdAt ?? DateTime(1970);
      return sort == _MemorySort.newest
          ? bDate.compareTo(aDate)
          : aDate.compareTo(bDate);
    });
    return result;
  }

  @override
  Widget build(BuildContext context) => AppBackdrop(
    child: CustomScrollView(
      key: const PageStorageKey('videos-scroll'),
      slivers: [
        SliverSafeArea(
          bottom: false,
          sliver: SliverToBoxAdapter(
            child: PagePadding(
              top: 12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Image.asset(
                        'assets/images/bbanggeut_mascot.png',
                        width: 78,
                        height: 82,
                        fit: BoxFit.contain,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          '전체 추억',
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                fontSize: 31,
                                color: const Color(0xFF5A3E28),
                              ),
                        ),
                      ),
                      RoundIconButton(
                        icon: Icons.search_rounded,
                        size: 50,
                        onPressed: () => _showSearch(context),
                      ),
                      const SizedBox(width: 8),
                      PopupMenuButton<_MemorySort>(
                        initialValue: sort,
                        onSelected: (value) => setState(() => sort = value),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: _MemorySort.newest,
                            child: Text('최신순'),
                          ),
                          PopupMenuItem(
                            value: _MemorySort.oldest,
                            child: Text('오래된 순'),
                          ),
                        ],
                        child: Container(
                          height: 50,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceWarm,
                            border: Border.all(color: AppColors.line),
                            borderRadius: BorderRadius.circular(17),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.swap_vert_rounded,
                                size: 19,
                                color: AppColors.inkSoft,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                sort == _MemorySort.newest ? '최신순' : '오래된 순',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '우리 가족이 저장한 모든 순간을 모아봤어요.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(color: AppColors.muted),
                  ),
                  const SizedBox(height: 18),
                  _CategoryBar(
                    selected: category,
                    onSelected: (value) => setState(() => category = value),
                  ),
                  if (search.isNotEmpty) ...[
                    const SizedBox(height: 9),
                    InputChip(
                      label: Text('검색: $search'),
                      onDeleted: () => setState(() => search = ''),
                    ),
                  ],
                  const SizedBox(height: 18),
                  if (items.isEmpty)
                    const SoftCard(
                      child: EmptyState(
                        icon: Icons.video_library_outlined,
                        title: '이 탭에 저장된 영상이 없어요',
                        message: '새 영상이 저장되면 여기에 시간순으로 모여요.',
                      ),
                    )
                  else
                    Column(
                      children: items.map((video) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: _MemoryCard(
                            controller: widget.controller,
                            video: video,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => VideoDetailScreen(
                                  controller: widget.controller,
                                  video: video,
                                ),
                              ),
                            ),
                            onFavorite: () =>
                                widget.controller.toggleFavorite(video),
                            onDelete:
                                widget.controller.selectedDevice?.isOwner ==
                                    true
                                ? () => _confirmDelete(video)
                                : null,
                          ),
                        );
                      }).toList(),
                    ),
                  const SizedBox(height: 14),
                  InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            LaughReportScreen(controller: widget.controller),
                      ),
                    ),
                    child: SoftCard(
                      color: AppColors.surfaceWarm,
                      borderColor: AppColors.coralSoft,
                      padding: const EdgeInsets.fromLTRB(18, 16, 8, 8),
                      child: SizedBox(
                        height: 126,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(right: 128),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: const [
                                  Row(
                                    children: [
                                      _HeartBookmark(),
                                      SizedBox(width: 7),
                                      Text(
                                        '이번 주 기록',
                                        style: TextStyle(
                                          color: AppColors.coral,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 10),
                                  Text(
                                    '가족이 가장 많이 웃은 날',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  SizedBox(height: 7),
                                  Text(
                                    '7월 20일 · 웃음 18회',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: AppColors.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Positioned(
                              right: 28,
                              top: 2,
                              bottom: 0,
                              child: Image.asset(
                                'assets/images/bbanggeut_mascot.png',
                                width: 116,
                                fit: BoxFit.contain,
                                alignment: Alignment.bottomCenter,
                              ),
                            ),
                            const Positioned(
                              right: 2,
                              top: 4,
                              child: CircleAvatar(
                                radius: 19,
                                backgroundColor: AppColors.coral,
                                child: Icon(
                                  Icons.chevron_right_rounded,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Future<void> _showSearch(BuildContext context) async {
    final input = TextEditingController(text: search);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('추억 검색'),
        content: TextField(
          controller: input,
          autofocus: true,
          decoration: const InputDecoration(hintText: '영상 제목이나 메모를 입력하세요'),
          onSubmitted: Navigator.of(context).pop,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('검색'),
          ),
        ],
      ),
    );
    input.dispose();
    if (value != null) setState(() => search = value);
  }

  Future<void> _confirmDelete(VideoMemory video) async {
    final confirmed = await confirmVideoDeletion(context);
    if (confirmed && !widget.controller.busy) {
      final ok = await widget.controller.removeVideo(video);
      if (mounted) {
        showAppSnack(
          context,
          ok ? '영상을 삭제했어요.' : (widget.controller.errorMessage ?? '삭제하지 못했어요.'),
          error: !ok,
        );
      }
    }
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({required this.selected, required this.onSelected});
  final _MemoryCategory selected;
  final ValueChanged<_MemoryCategory> onSelected;

  @override
  Widget build(BuildContext context) => SoftCard(
    padding: const EdgeInsets.all(8),
    child: Row(
      children: [
        _CategoryButton(
          value: _MemoryCategory.homeCam,
          selected: selected,
          icon: Icons.videocam_rounded,
          label: '홈캠',
          onTap: onSelected,
        ),
        _CategoryButton(
          value: _MemoryCategory.laughter,
          selected: selected,
          icon: Icons.sentiment_very_satisfied_rounded,
          label: '웃음 감지',
          onTap: onSelected,
        ),
        _CategoryButton(
          value: _MemoryCategory.edited,
          selected: selected,
          icon: Icons.playlist_add_check_rounded,
          label: '편집 완료',
          onTap: onSelected,
        ),
      ],
    ),
  );
}

class _HeartBookmark extends StatelessWidget {
  const _HeartBookmark();

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 22,
    height: 28,
    child: Stack(
      alignment: Alignment.topCenter,
      children: [
        const Icon(Icons.bookmark_rounded, color: AppColors.coral, size: 28),
        Positioned(
          top: 6,
          left: 7.5,
          child: Icon(
            Icons.favorite_rounded,
            color: Colors.white.withValues(alpha: .96),
            size: 10,
          ),
        ),
      ],
    ),
  );
}

class _CategoryButton extends StatelessWidget {
  const _CategoryButton({
    required this.value,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final _MemoryCategory value;
  final _MemoryCategory selected;
  final IconData icon;
  final String label;
  final ValueChanged<_MemoryCategory> onTap;

  @override
  Widget build(BuildContext context) {
    final active = value == selected;
    return Expanded(
      child: InkWell(
        onTap: () => onTap(value),
        borderRadius: BorderRadius.circular(18),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          height: 54,
          decoration: BoxDecoration(
            color: active ? AppColors.greenCard : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 21,
                color: active ? AppColors.sageDark : AppColors.inkSoft,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    color: active ? AppColors.sageDark : AppColors.inkSoft,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({
    required this.controller,
    required this.video,
    required this.onTap,
    required this.onFavorite,
    this.onDelete,
  });
  final AppController controller;
  final VideoMemory video;
  final VoidCallback onTap;
  final VoidCallback onFavorite;
  final VoidCallback? onDelete;

  String get _tag => switch (video.triggerType) {
    'LAUGHTER' => '웃음',
    'EDIT' => '편집',
    'WAKE_WORD' => '호출',
    _ => '일상',
  };

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(24),
    child: SoftCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Stack(
            children: [
              MemoryThumbnail(
                api: controller.api,
                video: video,
                width: 136,
                height: 98,
              ),
              Positioned(
                left: 8,
                top: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xC92D241E),
                    borderRadius: BorderRadius.circular(99),
                  ),
                  child: const Text(
                    '● REC',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 6,
                bottom: 18,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.sageDark,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    durationLabel(video.durationMs),
                    textAlign: TextAlign.center,
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
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  '${memoryDate(video.capturedStartAt ?? video.createdAt)} · ${durationLabel(video.durationMs)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 10),
                StatusPill(
                  label: _tag,
                  color: video.triggerType == 'LAUGHTER'
                      ? AppColors.yellowSoft
                      : AppColors.greenCard,
                ),
              ],
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded, color: AppColors.inkSoft),
            onSelected: (value) {
              if (value == 'favorite') onFavorite();
              if (value == 'delete') onDelete?.call();
            },
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
