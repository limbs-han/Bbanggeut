import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

class VideosScreen extends StatefulWidget {
  const VideosScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<VideosScreen> createState() => _VideosScreenState();
}

class _VideosScreenState extends State<VideosScreen> {
  String? filter;
  String search = '';

  List<VideoMemory> get items => widget.controller.videos.where((video) {
    final matchesFilter = filter == null || video.triggerType == filter;
    final matchesSearch =
        search.isEmpty ||
        video.title.toLowerCase().contains(search.toLowerCase());
    return matchesFilter && matchesSearch;
  }).toList();

  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      SliverAppBar(
        floating: true,
        title: const Text('추억 보관함'),
        actions: [
          IconButton(
            onPressed: () => _showSearch(context),
            icon: const Icon(Icons.search_rounded),
            tooltip: '검색',
          ),
          const SizedBox(width: 8),
        ],
      ),
      SliverToBoxAdapter(
        child: PagePadding(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${widget.controller.videos.length}개의 소중한 순간',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (search.isNotEmpty) ...[
                const SizedBox(height: 8),
                InputChip(
                  label: Text('검색: $search'),
                  onDeleted: () => setState(() => search = ''),
                ),
              ],
              const SizedBox(height: 16),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _FilterChip(
                      label: '전체',
                      selected: filter == null,
                      onTap: () => setState(() => filter = null),
                    ),
                    _FilterChip(
                      label: '웃음',
                      selected: filter == 'LAUGHTER',
                      onTap: () => setState(() => filter = 'LAUGHTER'),
                    ),
                    _FilterChip(
                      label: '호출',
                      selected: filter == 'WAKE_WORD',
                      onTap: () => setState(() => filter = 'WAKE_WORD'),
                    ),
                    _FilterChip(
                      label: '터치',
                      selected: filter == 'TOUCH',
                      onTap: () => setState(() => filter = 'TOUCH'),
                    ),
                    _FilterChip(
                      label: '직접 저장',
                      selected: filter == 'MANUAL',
                      onTap: () => setState(() => filter = 'MANUAL'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (items.isEmpty)
                const SizedBox(
                  height: 420,
                  child: EmptyState(
                    icon: Icons.video_library_outlined,
                    title: '조건에 맞는 추억이 없어요',
                    message: '다른 필터를 선택하거나 검색어를 바꿔보세요.',
                  ),
                )
              else
                ...items.map(
                  (video) => MemoryTile(
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
                    onFavorite: () => widget.controller.toggleFavorite(video),
                    onDelete: () => _confirmDelete(video),
                  ),
                ),
            ],
          ),
        ),
      ),
    ],
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
          decoration: const InputDecoration(hintText: '영상 제목을 입력하세요'),
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
    if (value != null) {
      setState(() => search = value);
    }
  }

  Future<void> _confirmDelete(VideoMemory video) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('영상을 삭제할까요?'),
        content: const Text('저장소에서도 삭제되며 되돌릴 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
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

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: AppColors.primary,
      labelStyle: TextStyle(
        color: selected ? Colors.white : AppColors.ink,
        fontWeight: FontWeight.w700,
      ),
      side: BorderSide.none,
    ),
  );
}
