import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import '../editor/edit_recommendation_client.dart';
import '../features/comic/comic_screen.dart';
import 'edited_video_screen.dart';
import 'local_edit_screen.dart';
import 'memory_video_card.dart';
import 'widgets.dart';

enum MemoryCategory { laughter, editing, edited, comic }

enum MemorySort { newest, oldest }

/// 편집 목록 한 줄의 상태 설명.
///
/// 완성본은 업로드가 끝나기 전에도 목록에 나온다 — 알림을 껐거나 권한을 주지
/// 않은 기기에서는 상단 알림이 오지 않으므로, 이 줄이 진행 상황을 아는 유일한
/// 단서다. 끝내 실패한 것도 조용히 사라지지 않고 여기 남는다.
String editorEntrySubtitle({
  required bool isDraft,
  required bool uploading,
  required bool failed,
  required DateTime? savedAt,
}) {
  final state = isDraft
      ? '저장한 초안'
      : uploading
      ? '서버에 올리는 중'
      : failed
      ? '업로드 실패 — 다시 저장해 주세요'
      : '편집 완료';
  if (savedAt == null) {
    return isDraft ? '이어서 편집할 수 있어요' : state;
  }
  return '${DateFormat('M월 d일 HH:mm').format(savedAt)} $state';
}

/// 영상 한 건이 이 카테고리에 속하는가.
///
/// 편집본을 걸러내는 기준은 `sourceType`뿐이다. 서버가 편집본 행을 만들 때
/// 원본의 `trigger_type`과 `event_types`를 그대로 물려주므로
/// (`VideoMapper.insertEditOutput`) 웃음 클립의 편집본도 `LAUGHTER`를 들고
/// 있다. 예전 조건은 이벤트 종류로 판정해서, 편집본이 '웃음 감지'와
/// '편집 완료' 두 탭에 동시에 나왔다.
///
/// '웃음 감지'에서 이벤트 종류를 더 좁히지 않는 이유: 기기는 웃음 트리거로만
/// 녹화하므로 실제로 원본 = 웃음 감지다. 반대로 종류를 걸면 박수만 잡힌
/// 클립이 세 탭 어디에도 없어 사라진다.
bool matchesMemoryCategory(VideoMemory video, MemoryCategory category) =>
    switch (category) {
      MemoryCategory.laughter => !video.isEditOutput,
      // 편집 중(초안)은 editor-api 목록으로 따로 그린다 — 초안 레시피는 아직
      // 그쪽에 있다(ADR-001의 남은 부채). 영상 행으로는 판정하지 않는다.
      MemoryCategory.editing => false,
      MemoryCategory.edited => video.isEditOutput,
      // 만화도 영상 행에 없다. 금고 만화 목록(GET /api/vaults/{id}/comics)으로
      // 따로 그린다.
      MemoryCategory.comic => false,
    };

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

  /// 만들어 둔 만화 목록(videoId·madeAt). '만화' 탭이 그린다.
  List<Map<String, dynamic>> _comics = const [];

  /// 같은 응답에서 뽑아 둔 id 집합. 카드 배지가 목록의 매 줄마다 확인하므로
  /// 그릴 때마다 다시 만들지 않는다.
  Set<String> _comicVideoIds = const {};

  /// 올라가는 중인 편집본을 뒤따라가는 재조회. 5초 간격으로 최대 5분.
  Timer? _uploadFollowUp;
  int _uploadFollowUpCount = 0;
  static const _maxUploadFollowUps = 60;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    _loadEditorLists();
  }

  /// 초안 목록과 완성본 목록은 서로의 결과를 쓰지 않는다. 차례로 부르면
  /// 왕복이 한 번 더 늘고, 그 시간만큼 '편집 중'·'편집 완료' 탭이 비어 있다.
  Future<void> _loadEditorLists() async {
    if (!EditRecommendationClient.networkAllowed) return;
    await Future.wait([
      _editClient
          .listDrafts()
          .then((drafts) {
            if (mounted) setState(() => _drafts = drafts);
          })
          .catchError((Object _) {}),
      // 편집본은 금고 단위로 백엔드에서 받는다(API-82).
      if (widget.controller.selectedVault != null)
        widget.controller.api
            .listVaultEdits(widget.controller.selectedVault!.id)
            .then((edited) {
              if (mounted) setState(() => _edited = edited);
            })
            .catchError((Object _) {}),
      // 만화 목록과 배지. 실패해도 영상 목록은 그대로 보여야 하므로 조용히
      // 넘긴다 — 배지가 없는 것과 목록이 안 나오는 것은 무게가 다르다.
      if (widget.controller.selectedVault != null)
        widget.controller.api
            .listVaultComics(widget.controller.selectedVault!.id)
            .then((comics) {
              if (!mounted) return;
              setState(() {
                _comics = comics;
                _comicVideoIds = {
                  for (final comic in comics) comic['videoId'] as String,
                };
              });
            })
            .catchError((Object _) {}),
    ]);
    _scheduleUploadFollowUp();
  }

  /// 올라가는 중인 편집본이 있으면 잠시 뒤 목록을 스스로 다시 받아온다.
  ///
  /// 업로드는 앱 밖(WorkManager)에서 끝나고 서버가 도착을 훑어 승격하므로,
  /// 앱에는 "끝났다"고 알려 줄 통로가 없다. 그래서 목록을 한 번 받은 뒤로는
  /// 진행 표시가 영원히 돌았다 — 사용자가 당겨서 새로 고쳐야 완료로 바뀌었다.
  ///
  /// 무한히 물어보지는 않는다. 업로드가 끝내 실패하면 서버가 30분 뒤 FAILED로
  /// 내리는데 그때까지 5초마다 두드릴 이유가 없다. 한도를 넘기면 멈추고,
  /// 그 뒤에는 당겨서 새로 고치는 쪽에 맡긴다.
  void _scheduleUploadFollowUp() {
    _uploadFollowUp?.cancel();
    _uploadFollowUp = null;
    final uploading = _edited.any((entry) => entry['status'] == 'UPLOADING');
    if (!uploading || !mounted) {
      _uploadFollowUpCount = 0;
      return;
    }
    if (_uploadFollowUpCount >= _maxUploadFollowUps) return;
    _uploadFollowUpCount++;
    _uploadFollowUp = Timer(
      const Duration(seconds: 5),
      () {
        if (mounted) _loadEditorLists();
      },
    );
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
          api: widget.controller.api,
          videoId: videoId,
          title: (meta['title'] as String?)?.isNotEmpty == true
              ? meta['title'] as String
              : original?.title ?? '편집한 영상',
          savedAt: DateTime.tryParse(meta['savedAt'] as String? ?? ''),
          myUserId: widget.controller.user?.id,
          isOwner: widget.controller.isOwner,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _uploadFollowUp?.cancel();
    widget.controller.removeListener(_refresh);
    _searchController.dispose();
    super.dispose();
  }

  List<VideoMemory>? _seenVideos;
  bool? _seenLoading;
  String? _seenError;

  /// 이 화면이 실제로 읽는 값이 바뀌었을 때만 다시 그린다.
  ///
  /// **왜 걸러야 하는가**: [AppController]는 즐겨찾기·기기 상태·바쁨 표시 등
  /// 무엇이 바뀌어도 같은 알림 하나를 보낸다. 이 화면은 다른 탭에 가려져
  /// 있어도 알림을 받는데, [IndexedStack]은 가려진 자식도 배치까지 마친다 —
  /// 홈 탭에서 기기 상태를 새로 읽을 때마다 보이지도 않는 영상 목록이 통째로
  /// 다시 세워지고 있었다. 목록·로딩·오류만 보고, 그대로면 넘긴다.
  void _refresh() {
    if (!mounted) return;
    final videos = widget.controller.videos;
    final loading = widget.controller.videosLoading;
    final error = widget.controller.videosError;
    if (identical(videos, _seenVideos) &&
        loading == _seenLoading &&
        error == _seenError) {
      return;
    }
    // 당겨서 새로 고치기는 MainShell이 화면 전체를 감싸며 한 번만 제공한다.
    // 그 새로고침은 백엔드 영상만 다시 받으므로, 여기서 한 번 더 편집 목록을
    // 받아 주지 않으면 '편집 중'·'편집 완료' 탭에서 당겨도 아무것도 바뀌지
    // 않는다. 영상 로딩이 끝나는 순간을 새로고침 완료 신호로 쓴다.
    final refreshFinished = _seenLoading == true && loading == false;
    _seenVideos = videos;
    _seenLoading = loading;
    _seenError = error;
    setState(() {});
    if (refreshFinished) _loadEditorLists();
  }

  List<VideoMemory> get _items {
    final keyword = _searchController.text.trim().toLowerCase();
    final result = widget.controller.videos.where((video) {
      final matchesCategory = matchesMemoryCategory(video, category);
      // 화면에 보이는 제목으로도 찾을 수 있어야 한다. 기기 기본 제목은 날짜·
      // 시각·종류를 담은 제목으로 바꿔 그리므로, 저장된 제목만 보면 사용자가
      // 읽은 글자로 검색해도 걸리지 않는다.
      final matchesKeyword =
          keyword.isEmpty ||
          video.title.toLowerCase().contains(keyword) ||
          videoDisplayTitle(video).toLowerCase().contains(keyword);
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
    // RefreshIndicator를 여기 두지 않는다 — MainShell이 이미 화면 전체를
    // 감싸고 있어서 겹치면 당길 때 새로고침 표시가 두 개 뜬다. 대신 바깥
    // 새로고침이 끝나면 _refresh가 이 목록도 다시 받는다.
    return ListView.separated(
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
        // 원본을 아직 못 받았을 때 videoId(UUID)를 그대로 띄우면 사용자에게는
        // 아무 뜻이 없는 글자다. 편집본은 자기 제목이 있으니 그것을 쓰고,
        // 초안은 원본 제목을 쓰되 없으면 사람이 읽을 수 있는 문구로 대신한다.
        final originalTitle = original == null
            ? null
            : videoDisplayTitle(original);
        final title = isDraft
            ? originalTitle ?? '원본을 불러오는 중'
            : (entry['title'] as String?)?.isNotEmpty == true
            ? entry['title'] as String
            : originalTitle ?? '편집한 영상';
        // 완성본은 업로드가 끝나기 전에도 목록에 나온다. 상태를 모르는
        // 응답(구버전 서버)은 예전처럼 완료로 본다.
        final status = isDraft
            ? 'READY'
            : (entry['status'] as String? ?? 'READY');
        final uploading = status == 'UPLOADING';
        final failed = status == 'FAILED';
        final playable = !isDraft && !uploading && !failed;
        return Card(
          child: ListTile(
            // 원본을 아는 항목은 그 썸네일을 보여 준다 — 편집 목록에서 아이콘만
            // 보이면 어떤 영상을 편집하던 것인지 알 수 없었다.
            leading: uploading
                ? const SizedBox.square(
                    dimension: 40,
                    child: Center(
                      child: SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : original != null && !failed
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: MemoryThumbnail(
                      api: widget.controller.api,
                      video: original,
                      width: 56,
                      height: 40,
                    ),
                  )
                : CircleAvatar(
                    backgroundColor: failed
                        ? AppColors.danger.withValues(alpha: 0.15)
                        : AppColors.sage.withValues(alpha: 0.3),
                    child: Icon(
                      isDraft
                          ? Icons.edit_note_rounded
                          : failed
                          ? Icons.error_outline_rounded
                          : Icons.play_arrow_rounded,
                      color: failed ? AppColors.danger : AppColors.sageDark,
                    ),
                  ),
            title: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  editorEntrySubtitle(
                    isDraft: isDraft,
                    uploading: uploading,
                    failed: failed,
                    savedAt: savedAt,
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    color: failed ? AppColors.danger : null,
                  ),
                ),
                // 편집본은 제목이 원본과 달라서 제목만으로는 무엇을 편집한
                // 것인지 알 수 없다. 원본을 아는 항목에만 한 줄 덧붙인다.
                if (!isDraft && originalTitle != null)
                  Text(
                    '원본 · $originalTitle',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.muted,
                    ),
                  ),
              ],
            ),
            trailing: uploading || failed
                ? null
                : Icon(
                    isDraft
                        ? Icons.chevron_right_rounded
                        : Icons.mode_comment_outlined,
                    color: AppColors.muted,
                  ),
            onTap: () {
              if (isDraft) {
                _openDraft(entry);
              } else if (playable) {
                _openEdited(entry);
              } else if (uploading) {
                showAppSnack(context, '아직 올라가는 중이에요. 끝나면 바로 볼 수 있어요.');
              } else {
                showAppSnack(
                  context,
                  '업로드가 끝나지 못했어요. 편집기에서 다시 저장해 주세요.',
                  error: true,
                );
              }
            },
          ),
        );
      },
    );
  }

  /// 만들어 둔 4컷 만화 목록. 누르면 그 만화를 다시 본다.
  ///
  /// 영상 목록에서 배지만 보여 주던 동안에는, 만화를 보려면 그 원본을 목록에서
  /// 찾아 상세로 들어가야 했다. 만화가 어느 영상에서 나왔는지 기억해야 하는
  /// 일이라 사실상 다시 열 길이 없었다.
  Widget _comicList() {
    if (_comics.isEmpty) {
      return const EmptyState(
        icon: Icons.auto_stories_outlined,
        title: '만든 만화가 없어요',
        message: '영상 상세 화면에서 4컷 만화를 만들면 여기 모여요.',
      );
    }
    final entries = [..._comics];
    entries.sort((left, right) {
      final leftAt =
          DateTime.tryParse(left['madeAt'] as String? ?? '') ?? DateTime(1970);
      final rightAt =
          DateTime.tryParse(right['madeAt'] as String? ?? '') ?? DateTime(1970);
      return sort == MemorySort.newest
          ? rightAt.compareTo(leftAt)
          : leftAt.compareTo(rightAt);
    });
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final entry = entries[index];
        final videoId = entry['videoId'] as String;
        final original = _videoById(videoId);
        final madeAt = DateTime.tryParse(
          entry['madeAt'] as String? ?? '',
        )?.toLocal();
        return Card(
          child: ListTile(
            leading: original != null
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: MemoryThumbnail(
                      api: widget.controller.api,
                      video: original,
                      width: 56,
                      height: 40,
                    ),
                  )
                : CircleAvatar(
                    backgroundColor: AppColors.sage.withValues(alpha: 0.3),
                    child: const Icon(
                      Icons.auto_stories_rounded,
                      color: AppColors.sageDark,
                    ),
                  ),
            title: Text(
              original == null ? '원본을 불러오는 중' : videoDisplayTitle(original),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              madeAt == null
                  ? '4컷 만화'
                  : '${DateFormat('M월 d일 HH:mm').format(madeAt)}에 만든 4컷 만화',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.muted,
            ),
            onTap: () {
              if (original == null) {
                showAppSnack(context, '원본 영상을 찾지 못했어요.');
                return;
              }
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ComicScreen(
                    api: widget.controller.api,
                    video: original,
                  ),
                ),
              );
            },
          ),
        );
      },
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
                          hintText: '영상 제목 검색',
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
                  // 카테고리가 넷이라 좁은 화면에서는 다 안 들어간다.
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
                          const SizedBox(width: 8),
                          _CategoryButton(
                            label: '만화',
                            selected: category == MemoryCategory.comic,
                            onPressed: () {
                              setState(() => category = MemoryCategory.comic);
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
              child: category == MemoryCategory.comic
                  ? _comicList()
                  : category != MemoryCategory.laughter
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
                        hasComic: _comicVideoIds.contains(items[index].id),
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
