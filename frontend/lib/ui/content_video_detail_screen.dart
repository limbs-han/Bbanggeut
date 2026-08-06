import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import '../core/video_gallery_saver.dart';
import '../core/video_source_cache.dart';
import '../editor/edit_recommendation_client.dart';
import '../features/comic/comic_screen.dart';
import 'local_edit_screen.dart';
import 'media_player_surface.dart';
import 'video_comments_section.dart';
import 'widgets.dart';

class ContentVideoDetailScreen extends StatefulWidget {
  const ContentVideoDetailScreen({
    super.key,
    required this.controller,
    required this.video,
  });

  final AppController controller;
  final VideoMemory video;

  @override
  State<ContentVideoDetailScreen> createState() =>
      _ContentVideoDetailScreenState();
}

class _ContentVideoDetailScreenState extends State<ContentVideoDetailScreen> {
  late VideoMemory _video;
  VideoPlayerController? _player;
  bool _loading = true;
  bool _saving = false;
  double? _saveProgress;
  bool _deleting = false;
  String? _error;

  /// 편집·저장 대비 미리받기를 시작했는가.
  ///
  /// **왜 재생 중에는 안 받나**: 스트리밍 재생과 미리받기가 같은 원본
  /// (수십 MB)을 **동시에** 받으면 서로 대역폭을 나눠 써서 재생 버퍼링도
  /// 미리받기도 함께 느려진다. 다 봤거나 일시정지한 틈 — 대개 편집·저장
  /// 버튼을 누르기 직전 — 에 시작하면 한 번에 한 전송만 돈다.
  bool _prefetchStarted = false;
  bool _hasPlayed = false;
  Timer? _idlePrefetchTimer;

  /// 저장해 둔 편집 초안이 있는가. 버튼 문구와 '초안 삭제'를 가른다.
  bool _hasDraft = false;
  bool _discardingDraft = false;
  final _editClient = EditRecommendationClient();

  @override
  void initState() {
    super.initState();
    _video = widget.video;
    _loadPlayer();
    _loadDraftState();
  }

  /// 초안이 있는지 조용히 확인한다. 실패하면 없는 것으로 둔다 — 편집 자체는
  /// 초안이 있든 없든 되므로 오류를 띄울 이유가 없다.
  Future<void> _loadDraftState() async {
    if (!EditRecommendationClient.networkAllowed) return;
    try {
      final draft = await _editClient.loadDraft(_video.id);
      if (mounted) setState(() => _hasDraft = draft != null);
    } catch (_) {
      // 초안 유무를 모르면 없는 쪽으로 둔다.
    }
  }

  Future<void> _discardDraft() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('discard-draft-dialog'),
        title: const Text('편집 초안을 지울까요?'),
        content: const Text(
          '저장해 둔 편집이 사라져요. 원본 영상과 이미 완성한 편집본은 그대로 있어요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('지우기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _discardingDraft = true);
    try {
      await _editClient.deleteDraft(_video.id);
      if (!mounted) return;
      setState(() {
        _hasDraft = false;
        _discardingDraft = false;
      });
      showAppSnack(context, '편집 초안을 지웠어요.');
    } catch (failure) {
      if (!mounted) return;
      setState(() => _discardingDraft = false);
      showAppSnack(context, '초안을 지우지 못했어요: $failure', error: true);
    }
  }

  Future<void> _loadPlayer() async {
    if (_video.status != 'READY') {
      setState(() {
        _loading = false;
        _error = '영상 처리가 완료된 후 재생할 수 있습니다.';
      });
      return;
    }
    try {
      // 이미 받아 둔 원본이 있으면 그걸로 튼다. 재생 URL 왕복도, 스트리밍
      // 트래픽도 없어진다 — 같은 파일을 저장·편집도 그대로 쓴다.
      final cached = await VideoSourceCache.cachedPath(_video.id);
      final player = cached != null
          ? VideoPlayerController.file(File(cached))
          : VideoPlayerController.networkUrl(
              Uri.parse(
                (await widget.controller.api.createPlayUrl(_video.id)).url,
              ),
            );
      await player.initialize();
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _loading = false;
      });
      if (cached == null) {
        player.addListener(_prefetchWhenPlaybackRests);
        // 재생하지 않고 훑어보기만 하는 사람도 있다. 몇 초 기다려도 재생이
        // 시작되지 않으면 회선이 놀고 있는 것이니 그때 미리받는다.
        _idlePrefetchTimer = Timer(const Duration(seconds: 5), () {
          if (!_hasPlayed) _startPrefetch();
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '영상을 불러오지 못했어요. $failure';
        });
      }
    }
  }

  /// 재생이 쉬는 틈에 원본 미리받기를 시작한다.
  void _prefetchWhenPlaybackRests() {
    final player = _player;
    if (player == null || _prefetchStarted) return;
    final value = player.value;
    if (value.isPlaying) {
      _hasPlayed = true;
      return;
    }
    final ended =
        value.duration > Duration.zero && value.position >= value.duration;
    // 한 번이라도 재생했다가 멈췄거나(일시정지) 끝까지 봤다 — 다음 행동은
    // 대개 편집이나 저장이고, 회선은 지금 비어 있다.
    if (_hasPlayed || ended) _startPrefetch();
  }

  void _startPrefetch() {
    if (_prefetchStarted || !mounted) return;
    _prefetchStarted = true;
    _idlePrefetchTimer?.cancel();
    _player?.removeListener(_prefetchWhenPlaybackRests);
    VideoSourceCache.prefetch(api: widget.controller.api, videoId: _video.id);
  }

  @override
  void dispose() {
    _idlePrefetchTimer?.cancel();
    _player?.dispose();
    super.dispose();
  }

  Future<void> _editMetadata() async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _TitleEditorDialog(initialTitle: _video.title),
    );
    if (title == null) return;
    final ok = await widget.controller.renameVideo(_video, title);
    if (!mounted) return;
    if (ok) {
      setState(() => _video = _video.copyWith(title: title));
      showAppSnack(context, '제목을 저장했습니다.');
    } else {
      showAppSnack(
        context,
        widget.controller.errorMessage ?? '제목을 저장하지 못했어요.',
        error: true,
      );
    }
  }

  Future<void> _saveVideo() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _saveProgress = null;
    });
    try {
      await VideoGallerySaver.save(
        api: widget.controller.api,
        videoId: _video.id,
        title: _video.title,
        onProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _saveProgress = received / total);
        },
      );
      if (mounted) showAppSnack(context, '휴대폰 갤러리에 영상을 저장했어요.');
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveProgress = null;
        });
      }
    }
  }

  Future<void> _openEditor() async {
    // 편집 진입 다운로드가 회선을 독차지하도록 재생기를 **완전히** 놓아준다.
    // 일시정지로는 부족하다 — 재생기는 멈춰 있어도 버퍼를 계속 채워서
    // 편집 원본 다운로드와 대역폭을 나눠 쓴다.
    final player = _player;
    if (player != null) {
      setState(() {
        _player = null;
        _loading = true;
      });
      await player.dispose();
    }
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            LocalEditScreen(controller: widget.controller, video: _video),
      ),
    );
    // 돌아오면 다시 만든다. 편집기가 원본을 받아 뒀으므로 이번에는
    // 네트워크 없이 캐시 파일로 열린다.
    if (mounted) await _loadPlayer();
    // 편집기는 나올 때 초안을 저장한다. 방금 생겼을 수 있으니 다시 본다.
    if (mounted) await _loadDraftState();
  }

  Future<void> _deleteVideo() async {
    if (_deleting || widget.controller.busy) return;
    final confirmed = await confirmVideoDeletion(context);
    if (!mounted || !confirmed) return;
    setState(() => _deleting = true);
    final ok = await widget.controller.removeVideo(_video);
    if (!mounted) return;
    if (ok) {
      showAppSnack(context, '영상을 삭제했어요.');
      Navigator.pop(context);
      return;
    }
    setState(() => _deleting = false);
    showAppSnack(
      context,
      widget.controller.errorMessage ?? '영상을 삭제하지 못했어요.',
      error: true,
    );
  }

  Future<void> _openComic() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ComicScreen(api: widget.controller.api, video: _video),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFFFF8EE),
    body: AppBackdrop(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 36),
          children: [
            SizedBox(
              height: 60,
              child: Row(
                children: [
                  RoundIconButton(
                    icon: Icons.chevron_left_rounded,
                    onPressed: () => Navigator.maybePop(context),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: _video.favorite ? '즐겨찾기 해제' : '즐겨찾기',
                    onPressed: () async {
                      final ok = await widget.controller.toggleFavorite(_video);
                      if (!mounted || !ok) return;
                      final refreshed = await widget.controller.api.getVideo(
                        _video.id,
                      );
                      if (mounted) setState(() => _video = refreshed);
                    },
                    iconSize: 31,
                    icon: Icon(
                      _video.favorite
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      color: AppColors.coral,
                    ),
                  ),
                  // 목록 카드와 같은 기준으로 가린다. 서버는 원본을 OWNER만,
                  // 편집본을 OWNER 또는 만든 사람만 지우게 한다
                  // (VideoCommandService.delete). 여기만 조건 없이 버튼을
                  // 띄우고 있어서 MEMBER가 누르면 403을 받았다.
                  if (canManageVideo(_video, isOwner: widget.controller.isOwner))
                    IconButton(
                      tooltip: '영상 삭제',
                      onPressed: _deleting ? null : _deleteVideo,
                      iconSize: 30,
                      icon: _deleting
                          ? const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(
                              Icons.delete_outline_rounded,
                              color: AppColors.coral,
                            ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: _player != null
                    ? MediaPlayerSurface(controller: _player!)
                    : ColoredBox(
                        color: Colors.black,
                        child: Center(
                          child: _loading
                              ? const CircularProgressIndicator()
                              : Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text(
                                    _error ?? '영상을 재생할 수 없습니다.',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 18),
            _MemoryDetailCard(
              video: _video,
              onEdit: _editMetadata,
              canRename: canManageVideo(
                _video,
                isOwner: widget.controller.isOwner,
              ),
            ),
            const SizedBox(height: 18),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                backgroundColor: const Color(0xB3FFF9F1),
                side: const BorderSide(color: Color(0xFFF1D9C8)),
                minimumSize: const Size.fromHeight(58),
              ),
              onPressed: _saving ? null : _saveVideo,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded),
              label: Text(
                _saving
                    ? _saveProgress == null
                          ? '다운로드 중…'
                          : '저장 중 ${(_saveProgress! * 100).round()}%'
                    : '갤러리에 저장',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            if (_saving) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _saveProgress),
            ],
            const SizedBox(height: 12),
            // 편집 기록이 있으면 "이어서"라고 말해 준다. 예전에는 초안이 있어도
            // 같은 '영상 편집하기'였고, 초안은 '편집 중' 탭에서만 보였다 —
            // 여기서 눌러도 이어서 열리는데 그걸 알 길이 없었다.
            FilledButton.icon(
              key: const ValueKey('open-editor'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(62),
                elevation: 5,
                shadowColor: const Color(0x55F47B61),
              ),
              onPressed: _openEditor,
              icon: Icon(
                _hasDraft ? Icons.edit_note_rounded : Icons.content_cut_rounded,
                size: 27,
              ),
              label: Text(_hasDraft ? '이어서 편집하기' : '영상 편집하기'),
            ),
            if (_hasDraft) ...[
              const SizedBox(height: 6),
              // 초안을 버릴 길. 없으면 잘못 저장한 편집을 이어서 여는 것 말고는
              // 방법이 없어서, 원본부터 다시 시작하려면 편집기에서 되돌리기를
              // 끝까지 눌러야 했다.
              TextButton.icon(
                key: const ValueKey('discard-draft'),
                onPressed: _discardingDraft ? null : _discardDraft,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                style: TextButton.styleFrom(foregroundColor: AppColors.muted),
                label: Text(_discardingDraft ? '지우는 중' : '편집 초안 삭제'),
              ),
            ],
            const SizedBox(height: 12),
            // 처리가 끝나기 전에는 전사문이 없어 만화를 만들 수 없다.
            OutlinedButton.icon(
              key: const ValueKey('open-comic'),
              style: OutlinedButton.styleFrom(
                backgroundColor: const Color(0xB3FFF9F1),
                side: const BorderSide(color: Color(0xFFF1D9C8)),
                minimumSize: const Size.fromHeight(58),
              ),
              onPressed: _video.status == 'READY' ? _openComic : null,
              icon: const Icon(Icons.auto_stories_rounded),
              label: const Text(
                '4컷 만화 만들기',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
              ),
            ),
            const Divider(height: 28),
            // 원본에도 가족 댓글을 남긴다. 백엔드는 원본과 편집본을 구별하지
            // 않으므로(둘 다 videos 행 + video_comments) 편집본 화면과 같은
            // 위젯을 쓴다. 바깥이 ListView라 안에서 또 스크롤하지 않는다.
            VideoCommentsSection(
              api: widget.controller.api,
              videoId: _video.id,
              myUserId: widget.controller.user?.id,
              isOwner: widget.controller.isOwner,
            ),
          ],
        ),
      ),
    ),
  );
}

class _MemoryDetailCard extends StatelessWidget {
  const _MemoryDetailCard({
    required this.video,
    required this.onEdit,
    required this.canRename,
  });

  final VideoMemory video;
  final VoidCallback onEdit;

  /// 원본 영상의 제목은 OWNER만 바꾼다. 못 바꾸는 사람에게는 버튼을 감춘다.
  final bool canRename;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      decoration: BoxDecoration(
        color: const Color(0xEFFFFAF4),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFF1E0D2)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x180D0905),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFFA48C),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Text(
              '오늘의 추억  🌱',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  videoDisplayTitle(video),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
              if (canRename) const SizedBox(width: 10),
              if (canRename)
                IconButton.outlined(
                  tooltip: '제목 수정',
                  onPressed: onEdit,
                  style: IconButton.styleFrom(
                    foregroundColor: AppColors.coralDark,
                    side: const BorderSide(color: Color(0xFFFFD5C5)),
                    minimumSize: const Size.square(48),
                  ),
                  icon: const Icon(Icons.edit_rounded),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                memoryDate(video.capturedStartAt ?? video.createdAt),
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              VideoEventTypePills(video: video),
            ],
          ),
        ],
      ),
    );
  }
}

class _TitleEditorDialog extends StatefulWidget {
  const _TitleEditorDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_TitleEditorDialog> createState() => _TitleEditorDialogState();
}

class _TitleEditorDialogState extends State<_TitleEditorDialog> {
  late final TextEditingController _title;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.initialTitle)
      ..addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _title
      ..removeListener(_refresh)
      ..dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    Navigator.pop(context, title);
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    backgroundColor: Colors.transparent,
    child: SingleChildScrollView(
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFAF3),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: const Color(0xFFF1D9C8)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x330D0905),
              blurRadius: 28,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: const BoxDecoration(
                    color: AppColors.coralSoft,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.edit_note_rounded,
                    color: AppColors.coralDark,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '추억 제목 바꾸기',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w900,
                          color: AppColors.ink,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '이 순간을 부를 이름을 정해 보세요.',
                        style: TextStyle(fontSize: 12, color: AppColors.muted),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '닫기',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('memory-title-input'),
              controller: _title,
              maxLength: 120,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: '추억 제목',
                hintText: '어떤 순간이었나요?',
                prefixIcon: Icon(Icons.auto_awesome_rounded),
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: IgnorePointer(
                child: Opacity(
                  opacity: .92,
                  child: Image.asset(
                    'assets/images/memory_peek_mascot.png',
                    width: 104,
                    height: 78,
                    fit: BoxFit.contain,
                    cacheWidth: decodePixels(context, 104),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    key: const Key('memory-metadata-save'),
                    onPressed: _title.text.trim().isEmpty ? null : _save,
                    icon: const Icon(Icons.favorite_rounded, size: 19),
                    label: const Text('제목 저장하기'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
