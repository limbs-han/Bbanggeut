import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import '../editor/edit_recommendation_client.dart';
import 'edited_video_screen.dart';
import 'local_edit_screen.dart';
import 'memory_video_card.dart';
import 'widgets.dart';

enum MemoryCategory { laughter, editing, edited }

enum MemorySort { newest, oldest }

class AllMemoriesScreen extends StatefulWidget {
  const AllMemoriesScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<AllMemoriesScreen> createState() => _AllMemoriesScreenState();
}

class _AllMemoriesScreenState extends State<AllMemoriesScreen> {
  final _searchController = TextEditingController();
  final _editClient = EditRecommendationClient();
  MemoryCategory category = MemoryCategory.laughter;
  MemorySort sort = MemorySort.newest;
  DateTimeRange? dateRange;
  bool searchExpanded = false;

  /// 편집 중(초안)·편집 완료 목록. 로컬 편집 서버(editor-api)에서 온다.
  List<Map<String, dynamic>> _drafts = const [];
  List<Map<String, dynamic>> _edited = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    _loadEditorLists();
  }

  Future<void> _loadEditorLists() async {
    if (!EditRecommendationClient.networkAllowed) return;
    try {
      final drafts = await _editClient.listDrafts();
      if (mounted) setState(() => _drafts = drafts);
    } catch (_) {}
    try {
      final edited = await _editClient.listEditedVideos();
      if (mounted) setState(() => _edited = edited);
    } catch (_) {}
  }

  VideoMemory? _videoById(String id) {
    for (final video in widget.controller.videos) {
      if (video.id == id) return video;
    }
    return null;
  }

  Future<void> _openDraft(Map<String, dynamic> draft) async {
    final video = _videoById(draft['videoId'] as String? ?? '');
    if (video == null) {
      showAppSnack(context, '원본 영상을 찾지 못했어요.');
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LocalEditScreen(
          controller: widget.controller,
          video: video,
          openDrafts: true,
        ),
      ),
    );
    await _loadEditorLists();
  }

  Future<void> _openEdited(Map<String, dynamic> meta) async {
    final videoId = meta['videoId'] as String? ?? '';
    final original = _videoById(videoId);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditedVideoScreen(
          videoId: videoId,
          title: (meta['title'] as String?)?.isNotEmpty == true
              ? meta['title'] as String
              : original?.title ?? '편집한 영상',
          savedAt: DateTime.tryParse(meta['savedAt'] as String? ?? ''),
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _searchController.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  List<VideoMemory> get _items {
    final keyword = _searchController.text.trim().toLowerCase();
    final result = widget.controller.videos.where((video) {
      final matchesCategory = switch (category) {
        MemoryCategory.laughter => video.triggerType == 'LAUGHTER',
        // 편집 중·편집 완료는 editor-api 목록으로 따로 그린다.
        MemoryCategory.editing || MemoryCategory.edited => false,
      };
      final matchesKeyword =
          keyword.isEmpty ||
          video.title.toLowerCase().contains(keyword) ||
          (video.description?.toLowerCase().contains(keyword) ?? false);
      final startedAt = video.capturedStartAt ?? video.createdAt;
      final matchesDate =
          dateRange == null ||
          (startedAt != null &&
              !DateUtils.dateOnly(startedAt).isBefore(dateRange!.start) &&
              !DateUtils.dateOnly(startedAt).isAfter(dateRange!.end));
      return matchesCategory && matchesKeyword && matchesDate;
    }).toList();
    result.sort((left, right) {
      final leftAt = left.capturedStartAt ?? left.createdAt ?? DateTime(1970);
      final rightAt =
          right.capturedStartAt ?? right.createdAt ?? DateTime(1970);
      return sort == MemorySort.newest
          ? rightAt.compareTo(leftAt)
          : leftAt.compareTo(rightAt);
    });
    return result;
  }

  /// 편집 중(초안)·편집 완료 목록. editor-api에 저장된 것을 그린다.
  Widget _editorList() {
    final isDraft = category == MemoryCategory.editing;
    final entries = isDraft ? _drafts : _edited;
    if (entries.isEmpty) {
      return EmptyState(
        icon: isDraft ? Icons.edit_note_rounded : Icons.movie_filter_outlined,
        title: isDraft ? '편집 중인 영상이 없어요' : '편집 완료한 영상이 없어요',
        message: isDraft
            ? '편집기에서 나오면 자동으로 초안이 저장돼 여기 나타나요.'
            : '편집기에서 저장하면 완성본이 여기 올라와요.',
      );
    }
    return RefreshIndicator(
      onRefresh: _loadEditorLists,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        itemCount: entries.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final entry = entries[index];
          final videoId = entry['videoId'] as String? ?? '';
          final original = _videoById(videoId);
          final savedAt = DateTime.tryParse(
            entry['savedAt'] as String? ?? '',
          )?.toLocal();
          final title = isDraft
              ? original?.title ?? videoId
              : (entry['title'] as String?)?.isNotEmpty == true
              ? entry['title'] as String
              : original?.title ?? videoId;
          return Card(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: AppColors.sage.withValues(alpha: 0.3),
                child: Icon(
                  isDraft
                      ? Icons.edit_note_rounded
                      : Icons.play_arrow_rounded,
                  color: AppColors.sageDark,
                ),
              ),
              title: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                savedAt == null
                    ? (isDraft ? '이어서 편집할 수 있어요' : '편집 완료')
                    : '${DateFormat('M월 d일 HH:mm').format(savedAt)} '
                          '${isDraft ? "저장한 초안" : "편집 완료"}',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Icon(
                isDraft
                    ? Icons.chevron_right_rounded
                    : Icons.mode_comment_outlined,
                color: AppColors.muted,
              ),
              onTap: () =>
                  isDraft ? _openDraft(entry) : _openEdited(entry),
            ),
          );
        },
      ),
    );
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: dateRange,
      helpText: '날짜 또는 기간 선택',
      saveText: '적용',
    );
    if (picked != null && mounted) setState(() => dateRange = picked);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return AppBackdrop(
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: searchExpanded
                    ? TextField(
                        key: const ValueKey('memory-search'),
                        controller: _searchController,
                        autofocus: true,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: '영상 제목과 메모 검색',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: IconButton(
                            tooltip: '검색어 초기화',
                            onPressed: () {
                              if (_searchController.text.isEmpty) {
                                setState(() => searchExpanded = false);
                              } else {
                                _searchController.clear();
                                setState(() {});
                              }
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                        ),
                      )
                    : Row(
                        key: const ValueKey('memory-title'),
                        children: [
                          Expanded(
                            child: Text(
                              '전체 추억',
                              style: Theme.of(context).textTheme.headlineMedium,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _pickDateRange,
                            icon: const Icon(Icons.date_range_outlined),
                            label: Text(
                              dateRange == null
                                  ? '날짜'
                                  : DateUtils.isSameDay(
                                      dateRange!.start,
                                      dateRange!.end,
                                    )
                                  ? DateFormat('M.d').format(dateRange!.start)
                                  : '${DateFormat('M.d').format(dateRange!.start)}'
                                        '–${DateFormat('M.d').format(dateRange!.end)}',
                            ),
                          ),
                          if (dateRange != null)
                            IconButton(
                              tooltip: '날짜 필터 초기화',
                              onPressed: () => setState(() => dateRange = null),
                              icon: const Icon(Icons.close_rounded, size: 18),
                            ),
                          RoundIconButton(
                            icon: Icons.search_rounded,
                            onPressed: () =>
                                setState(() => searchExpanded = true),
                          ),
                        ],
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  // 카테고리가 셋이라 좁은 화면에서는 다 안 들어간다.
                  // 카테고리 묶음만 옆으로 밀어 보게 한다.
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _CategoryButton(
                            label: '웃음 감지',
                            selected: category == MemoryCategory.laughter,
                            onPressed: () => setState(
                              () => category = MemoryCategory.laughter,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _CategoryButton(
                            label: '편집 중',
                            selected: category == MemoryCategory.editing,
                            onPressed: () {
                              setState(
                                () => category = MemoryCategory.editing,
                              );
                              _loadEditorLists();
                            },
                          ),
                          const SizedBox(width: 8),
                          _CategoryButton(
                            label: '편집 완료',
                            selected: category == MemoryCategory.edited,
                            onPressed: () {
                              setState(() => category = MemoryCategory.edited);
                              _loadEditorLists();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  _SortButton(
                    label: '최신순',
                    selected: sort == MemorySort.newest,
                    onPressed: () => setState(() => sort = MemorySort.newest),
                  ),
                  _SortButton(
                    label: '오래된 순',
                    selected: sort == MemorySort.oldest,
                    onPressed: () => setState(() => sort = MemorySort.oldest),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: category != MemoryCategory.laughter
                  ? _editorList()
                  : widget.controller.videosLoading &&
                        widget.controller.videos.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : widget.controller.videosError != null
                  ? EmptyState(
                      icon: Icons.cloud_off_rounded,
                      title: '영상을 불러오지 못했어요',
                      message: widget.controller.videosError!,
                      action: FilledButton(
                        onPressed: widget.controller.videosLoading
                            ? null
                            : widget.controller.selectedDevice == null
                            ? widget.controller.refreshVaultData
                            : widget.controller.refreshDeviceData,
                        child: const Text('다시 시도'),
                      ),
                    )
                  : items.isEmpty
                  ? EmptyState(
                      icon: searchExpanded || dateRange != null
                          ? Icons.search_off_rounded
                          : Icons.video_library_outlined,
                      title: searchExpanded || dateRange != null
                          ? '검색 결과가 없어요'
                          : '아직 영상이 없어요',
                      message: '검색어나 날짜, 카테고리를 바꿔보세요.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (_, index) => MemoryVideoCard(
                        controller: widget.controller,
                        video: items[index],
                        onChanged: _refresh,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryButton extends StatelessWidget {
  const _CategoryButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(label),
    selected: selected,
    onSelected: (_) => onPressed(),
  );
}

class _SortButton extends StatelessWidget {
  const _SortButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      foregroundColor: selected ? AppColors.sageDark : AppColors.muted,
      textStyle: TextStyle(
        fontSize: 11,
        fontWeight: selected ? FontWeight.w900 : FontWeight.w500,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      minimumSize: const Size(0, 36),
    ),
    child: Text(label),
  );
}
