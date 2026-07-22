import 'package:flutter/material.dart';
import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'extra_screens.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

enum _MemoryCategory { homeCam, laughter, edited }

enum _MemorySort { newest, oldest }

class VideosScreen extends StatefulWidget {
  const VideosScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<VideosScreen> createState() => _VideosScreenState();
}

class _VideosScreenState extends State<VideosScreen> {
  _MemoryCategory category = _MemoryCategory.homeCam;
  _MemorySort sort = _MemorySort.newest;
  String search = '';

  List<VideoMemory> get items {
    final needle = search.toLowerCase();
    final result = widget.controller.videos.where((video) {
      final matchesCategory = switch (category) {
        _MemoryCategory.homeCam =>
          video.triggerType != 'LAUGHTER' && video.triggerType != 'EDIT',
        _MemoryCategory.laughter => video.triggerType == 'LAUGHTER',
        _MemoryCategory.edited => video.triggerType == 'EDIT',
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
              top: 18,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '전체 추억',
                          textAlign: TextAlign.left,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      RoundIconButton(
                        icon: Icons.search_rounded,
                        size: 42,
                        onPressed: () => _showSearch(context),
                      ),
                      const SizedBox(width: 7),
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
                          height: 42,
                          padding: const EdgeInsets.symmetric(horizontal: 11),
                          decoration: BoxDecoration(
                            color: AppColors.surface,
                            border: Border.all(color: AppColors.line),
                            borderRadius: BorderRadius.circular(14),
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
                  const SizedBox(height: 14),
                  Text(
                    '우리 가족이 저장한 모든 순간을 모아봤어요.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 11),
                  SegmentedButton<_MemoryCategory>(
                    segments: const [
                      ButtonSegment(
                        value: _MemoryCategory.homeCam,
                        icon: Icon(Icons.videocam_outlined),
                        label: Text('홈캠'),
                      ),
                      ButtonSegment(
                        value: _MemoryCategory.laughter,
                        icon: Icon(Icons.sentiment_very_satisfied_outlined),
                        label: Text('웃음 감지'),
                      ),
                      ButtonSegment(
                        value: _MemoryCategory.edited,
                        icon: Icon(Icons.edit_note_rounded),
                        label: Text('편집 완료'),
                      ),
                    ],
                    selected: {category},
                    showSelectedIcon: false,
                    onSelectionChanged: (value) =>
                        setState(() => category = value.first),
                  ),
                  if (search.isNotEmpty) ...[
                    const SizedBox(height: 9),
                    InputChip(
                      label: Text('검색: $search'),
                      onDeleted: () => setState(() => search = ''),
                    ),
                  ],
                  const SizedBox(height: 13),
                  if (items.isEmpty)
                    const SoftCard(
                      child: EmptyState(
                        icon: Icons.video_library_outlined,
                        title: '이 탭에 저장된 영상이 없어요',
                        message: '새 영상이 저장되면 여기에 시간순으로 모여요.',
                      ),
                    )
                  else
                    SoftCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      child: Column(
                        children: items
                            .map(
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
                                onFavorite: () =>
                                    widget.controller.toggleFavorite(video),
                                onDelete:
                                    widget.controller.selectedDevice?.isOwner ==
                                        true
                                    ? () => _confirmDelete(video)
                                    : null,
                              ),
                            )
                            .toList(),
                      ),
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
                    child: const SoftCard(
                      color: AppColors.greenCard,
                      borderColor: AppColors.greenCard,
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '이번 주 기록',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.inkSoft,
                                  ),
                                ),
                                SizedBox(height: 3),
                                Text(
                                  '가족이 가장 많이 웃은 날',
                                  style: TextStyle(fontWeight: FontWeight.w900),
                                ),
                                Text(
                                  '7월 20일 · 웃음 18회',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: AppColors.inkSoft,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          CircleAvatar(
                            backgroundColor: AppColors.surface,
                            child: Icon(
                              Icons.chevron_right_rounded,
                              color: AppColors.sageDark,
                            ),
                          ),
                        ],
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
