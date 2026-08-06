/// 만화 피드 — 만든 만화를 크게, 아래로 쭉.
///
/// **왜 목록이 아니라 피드인가**: 만화는 보는 것이 전부다. 한 줄에 썸네일과 제목만
/// 있는 목록에서는 무슨 만화인지 알 수 없어서, 보려면 한 장씩 눌러 들어가고 다시
/// 나와야 했다. 만들어 둔 것을 화면 폭으로 크게 놓고 아래로 넘기게 한다.
///
/// 그림은 **화면에 들어온 카드만** 받는다. 만화 PNG는 단기 서명 URL로만 받을 수
/// 있어서 목록을 받을 때 전부 발급하면 보지도 않는 만화의 URL이 그 사이 만료된다.
/// 한 번 받은 그림은 [_images]에 남겨 스크롤을 오르내려도 다시 받지 않는다.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../ui/widgets.dart';
import 'comic_comment_sheet.dart';
import 'comic_controller.dart';
import 'comic_gateway.dart';
import 'comic_screen.dart';
import 'comic_script.dart';
import 'comic_viewer.dart';
import 'panel_subtitle.dart';

class ComicFeed extends StatefulWidget {
  const ComicFeed({
    super.key,
    required this.api,
    required this.comics,
    required this.videoById,
    this.onChanged,
    this.gateway,
  });

  final ApiClient api;
  final List<VaultComic> comics;

  /// 그림을 받아 오는 통로. 주입되면 그대로 쓴다 — 위젯 테스트가 네트워크를
  /// 건드리지 않는 통로다(주입하지 않으면 실서버 통로를 만든다).
  final ComicGateway? gateway;

  /// 원본 영상을 찾는 통로. 만화를 열거나 다시 만들 때 필요하다.
  final VideoMemory? Function(String videoId) videoById;

  /// 좋아요·댓글·제목이 바뀌어 목록을 다시 받아야 할 때.
  final Future<void> Function()? onChanged;

  @override
  State<ComicFeed> createState() => _ComicFeedState();
}

/// 카드 한 장이 그림 자리에 무엇을 그려야 하는가.
///
/// 예전에는 `Map<String, Uint8List?>` 하나로 "아직 안 받음(키 없음)"과 "못
/// 받음(null)"만 갈랐다. 그래서 두 가지가 같은 칸으로 떨어졌다 — 서버가 아직
/// 그리는 중인 만화와, 회선이 끊겨 못 받은 만화가 똑같이 '만화를 불러오지
/// 못했어요'로 보였다. 게다가 실패를 null로 **영구히 기억**해서 다시 받을 길이
/// 없었다. 화면을 벗어났다 돌아와도 그 카드만 계속 비어 있었다.
enum _PanelPhase {
  /// 받는 중. 처음 한 번이거나 사용자가 다시 시도를 눌렀다.
  loading,

  /// 서버가 아직 그리는 중이다. 실패가 아니라 기다리면 되는 상태다.
  drawing,

  /// 그림이 있다.
  ready,

  /// 못 받았다. 다시 시도할 수 있다.
  failed,
}

class _ComicFeedState extends State<ComicFeed> {
  /// videoId → 받아 둔 그림. 성공한 것만 들어간다.
  final Map<String, Uint8List> _images = {};

  /// videoId → 그림 자리 상태. 없으면 아직 청하지 않았다.
  final Map<String, _PanelPhase> _phase = {};

  /// 그림과 함께 온 저장 구성. 대사를 크게 보기에서 그리는 데 쓴다 — 따로
  /// 청하지 않는다(구성 만들기 호출은 과금이고, 사용자가 고친 대사를 덮는다).
  final Map<String, List<ComicCut>> _cuts = {};
  final Set<String> _loading = {};

  /// 화면에서 손으로 바꾼 값. 목록을 다시 받기 전까지 이것이 이긴다 — 좋아요를
  /// 누를 때마다 목록 전체를 다시 받으면 스크롤이 튄다.
  final Map<String, VaultComic> _edited = {};

  late final ComicGateway _gateway =
      widget.gateway ?? defaultComicGateway(widget.api);

  static final _dayTime = DateFormat('M월 d일 HH:mm');

  VaultComic _comicAt(int index) {
    final comic = widget.comics[index];
    return _edited[comic.videoId] ?? comic;
  }

  /// 그림을 한 번 받는다.
  ///
  /// 결과를 [_phase]에 기억해 매 프레임 다시 시도하지 않는다. 다만 **실패는
  /// 끝이 아니다** — [_retry]가 기록을 지우고 이 함수를 다시 부른다. 회선이
  /// 잠깐 끊겨 못 받은 카드를 영영 빈 채로 두면 사용자가 할 수 있는 일이
  /// 없어진다(앱을 껐다 켜는 것 말고는).
  Future<void> _ensureImage(String videoId) async {
    if (_phase.containsKey(videoId) || _loading.contains(videoId)) return;
    _loading.add(videoId);
    Uint8List? bytes;
    _PanelPhase phase;
    try {
      final status = await _gateway.jobStatus(videoId);
      final cuts = status.cuts;
      if (cuts != null && cuts.isNotEmpty) _cuts[videoId] = cuts;
      if (status.done && status.imageUrl != null) {
        bytes = await _gateway.download(status.imageUrl!);
        phase = _PanelPhase.ready;
      } else {
        // 아직 그리는 중인 것과 그림이 없는 것을 가른다. 앞은 기다리면 되고,
        // 뒤는 목록에는 있는데 그림이 사라진 경우라 다시 시도가 맞다.
        phase = status.working ? _PanelPhase.drawing : _PanelPhase.failed;
      }
    } catch (_) {
      // 못 받은 것도 결과다. 카드가 다시 시도 버튼을 보여 준다.
      phase = _PanelPhase.failed;
    }
    _loading.remove(videoId);
    if (!mounted) return;
    setState(() {
      if (bytes != null) _images[videoId] = bytes;
      _phase[videoId] = phase;
    });
  }

  /// 못 받았거나 아직 그리는 중이던 카드를 다시 청한다.
  void _retry(String videoId) {
    setState(() {
      _phase.remove(videoId);
      _images.remove(videoId);
    });
    _ensureImage(videoId);
  }

  Future<void> _toggleLike(VaultComic comic) async {
    // 먼저 화면을 바꾼다. 좋아요는 누른 즉시 반응해야 하는 동작이고, 실패하면
    // 되돌린다.
    final optimistic = comic.copyWith(
      likedByMe: !comic.likedByMe,
      likeCount: comic.likeCount + (comic.likedByMe ? -1 : 1),
    );
    setState(() => _edited[comic.videoId] = optimistic);
    try {
      final result = await widget.api.setComicLiked(
        comic.videoId,
        optimistic.likedByMe,
      );
      if (!mounted) return;
      setState(
        () => _edited[comic.videoId] = optimistic.copyWith(
          likeCount: result.likeCount,
          likedByMe: result.likedByMe,
        ),
      );
    } catch (failure) {
      if (!mounted) return;
      setState(() => _edited[comic.videoId] = comic);
      showAppSnack(context, '$failure', error: true);
    }
  }

  Future<void> _rename(VaultComic comic) async {
    final title = await promptForTitle(
      context,
      title: '만화 제목',
      initial: comic.customTitle ? comic.title : '',
      hint: comic.customTitle ? null : '비워 두면 영상 제목을 써요',
    );
    if (title == null || !mounted) return;
    try {
      final updated = await widget.api.updateComicTitle(comic.videoId, title);
      if (!mounted) return;
      setState(() => _edited[comic.videoId] = updated);
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
    }
  }

  Future<void> _openComments(VaultComic comic) => showComicCommentSheet(
    context,
    api: widget.api,
    videoId: comic.videoId,
    title: comic.title,
    onCount: (count) {
      if (mounted) {
        setState(
          () => _edited[comic.videoId] = _comicFor(
            comic.videoId,
          ).copyWith(commentCount: count),
        );
      }
    },
  );

  /// 지금 화면이 들고 있는 값. 손으로 바꾼 것이 있으면 그것이다.
  VaultComic _comicFor(String videoId) =>
      _edited[videoId] ??
      widget.comics.firstWhere((comic) => comic.videoId == videoId);

  /// 만화를 크게 본다. 그림과 대사만 보여 주는 화면이라 편집과 섞이지 않는다.
  Future<void> _view(VaultComic comic) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ComicViewerScreen(
          title: comic.title,
          image: _images[comic.videoId],
          cuts: _cuts[comic.videoId],
          // 크게 보다가 고치고 싶을 수 있다. 뷰어를 닫고 편집으로 넘긴다.
          onEdit: widget.videoById(comic.videoId) == null
              ? null
              : () {
                  Navigator.pop(context);
                  _open(comic);
                },
        ),
      ),
    );
  }

  /// 만화를 지운다. 그림·구성과 좋아요·댓글이 함께 사라지고 원본 영상은 남는다.
  ///
  /// 낙관적으로 지우지 않는다 — 좋아요와 달리 되돌릴 수 없는 동작이라, 서버가
  /// 지웠다고 답한 뒤에 목록에서 없애야 "사라졌다 다시 나타나는" 일이 없다.
  Future<void> _delete(VaultComic comic) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('comic-delete-dialog'),
        title: const Text('만화를 지울까요?'),
        content: Text(
          '‘${comic.title}’ 만화와 거기 달린 좋아요·댓글이 사라져요.\n'
          '원본 영상은 그대로 있어요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('comic-delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('지우기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.api.deleteComic(comic.videoId);
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
      return;
    }
    if (!mounted) return;
    // 받아 둔 그림과 구성도 버린다. 남겨 두면 같은 영상으로 만화를 다시 만들
    // 때까지 지운 그림이 캐시에서 되살아난다.
    setState(() {
      _images.remove(comic.videoId);
      _phase.remove(comic.videoId);
      _cuts.remove(comic.videoId);
      _edited.remove(comic.videoId);
    });
    showAppSnack(context, '만화를 지웠어요.');
    await widget.onChanged?.call();
  }

  /// 만화 화면을 연다 — 대사를 고쳐 다시 만들거나 저장·공유하는 곳이다.
  Future<void> _open(VaultComic comic) async {
    final video = widget.videoById(comic.videoId);
    if (video == null) {
      showAppSnack(context, '원본 영상을 찾지 못했어요.');
      return;
    }
    // 카드를 그리려고 이미 받아 둔 그림과 구성을 들려 보낸다. 안 그러면 편집
    // 화면이 같은 상태 조회와 같은 그림을 처음부터 다시 받는다.
    final image = _images[comic.videoId];
    final cuts = _cuts[comic.videoId];
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ComicScreen(
          api: widget.api,
          video: video,
          seed: image == null || cuts == null || cuts.isEmpty
              ? null
              : ComicSeed(image: image, cuts: cuts, savedAt: comic.madeAt),
        ),
      ),
    );
    if (!mounted) return;
    // 다시 만들었을 수 있으니 그림을 버리고 다시 받는다. 구성도 함께 버린다 —
    // 남겨 두면 방금 고친 대사가 아니라 예전 대사가 그림 위에 계속 얹힌다.
    setState(() {
      _images.remove(comic.videoId);
      _phase.remove(comic.videoId);
      _cuts.remove(comic.videoId);
    });
    await widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.comics.isEmpty) {
      return const EmptyState(
        icon: Icons.auto_stories_outlined,
        title: '만든 만화가 없어요',
        message: '영상 상세 화면에서 4컷 만화를 만들면 여기 모여요.',
      );
    }
    return ListView.separated(
      key: const ValueKey('comic-feed'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 28),
      itemCount: widget.comics.length,
      separatorBuilder: (_, _) => const SizedBox(height: 18),
      itemBuilder: (context, index) {
        final comic = _comicAt(index);
        // 카드를 세울 때 그림을 청한다. ListView.builder는 화면에 보이는 것만
        // 세우므로, 이것이 곧 "보이는 것만 받는다"가 된다.
        _ensureImage(comic.videoId);
        return _ComicCard(
          key: ValueKey('comic-card-${comic.videoId}'),
          comic: comic,
          image: _images[comic.videoId],
          cuts: _cuts[comic.videoId],
          phase: _phase[comic.videoId] ?? _PanelPhase.loading,
          onRetry: () => _retry(comic.videoId),
          madeAtLabel: comic.madeAt == null
              ? null
              : _dayTime.format(comic.madeAt!.toLocal()),
          onView: () => _view(comic),
          onOpen: () => _open(comic),
          onLike: () => _toggleLike(comic),
          onComments: () => _openComments(comic),
          onRename: () => _rename(comic),
          // 지울 수 있는지는 서버가 만화마다 판정해 준다(만든 사람 또는 OWNER).
          // 앱이 역할로 다시 계산하면 규칙이 두 곳에 생긴다.
          onDelete: comic.canDelete ? () => _delete(comic) : null,
        );
      },
    );
  }
}

/// 그림 자리에 놓는 안내 한 덩이 — 아이콘, 한 줄, 그리고 할 수 있는 일.
class _PanelNotice extends StatelessWidget {
  const _PanelNotice({
    required this.icon,
    required this.message,
    this.hint,
    this.action,
  });

  final IconData icon;
  final String message;
  final String? hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 28, color: AppColors.muted),
      const SizedBox(height: 8),
      Text(
        message,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.inkSoft,
        ),
      ),
      if (hint != null) ...[
        const SizedBox(height: 3),
        Text(
          hint!,
          style: const TextStyle(fontSize: 11, color: AppColors.muted),
        ),
      ],
      if (action != null) ...[const SizedBox(height: 4), action!],
    ],
  );
}

class _ComicCard extends StatelessWidget {
  const _ComicCard({
    super.key,
    required this.comic,
    required this.image,
    required this.cuts,
    required this.phase,
    required this.onRetry,
    required this.madeAtLabel,
    required this.onView,
    required this.onOpen,
    required this.onLike,
    required this.onComments,
    required this.onRename,
    required this.onDelete,
  });

  final VaultComic comic;
  final Uint8List? image;

  /// 저장된 4컷 구성. 대사가 여기 있다 — 그림 위에 자막 띠로 얹는다. 없으면
  /// 그림만 보여 준다(구성을 남기기 전에 만든 옛 만화).
  final List<ComicCut>? cuts;

  /// 그림 자리에 무엇을 그릴지. [image]가 null인 것만으로는 "아직", "그리는
  /// 중", "못 받았다"를 가를 수 없다.
  final _PanelPhase phase;

  /// 못 받았거나 그리는 중일 때 다시 청한다.
  final VoidCallback onRetry;
  final String? madeAtLabel;

  /// 크게 보기 — 그림과 대사만 보여 준다.
  final VoidCallback onView;

  /// 수정하기 — 편집 화면으로 간다.
  final VoidCallback onOpen;
  final VoidCallback onLike;
  final VoidCallback onComments;
  final VoidCallback onRename;

  /// 만화 지우기. null이면 버튼을 감춘다 — OWNER가 아닌 사람에게는 누를 수 없는
  /// 버튼을 보이지 않는다.
  final VoidCallback? onDelete;

  /// 그림이 아직 없을 때 그 자리에 놓는 것.
  ///
  /// 세 경우를 갈라 말한다. 예전에는 "받는 중"과 "못 받음" 둘뿐이었고, 못 받은
  /// 카드에는 아무 길이 없었다 — 회선이 잠깐 흔들려 한 장을 놓치면 그 카드만
  /// 계속 비어 있었다.
  Widget _placeholder() => switch (phase) {
    _PanelPhase.ready || _PanelPhase.loading => const SizedBox.square(
      dimension: 24,
      child: CircularProgressIndicator(strokeWidth: 2),
    ),
    _PanelPhase.drawing => const _PanelNotice(
      icon: Icons.brush_rounded,
      message: '그림을 그리고 있어요',
      hint: '다 되면 알림으로 알려 드려요',
    ),
    _PanelPhase.failed => _PanelNotice(
      icon: Icons.wifi_off_rounded,
      message: '만화를 불러오지 못했어요',
      // 버튼 하나가 "앱을 껐다 켜기" 말고 할 수 있는 유일한 길이다.
      action: TextButton.icon(
        key: ValueKey('comic-retry-${comic.videoId}'),
        onPressed: onRetry,
        icon: const Icon(Icons.refresh_rounded, size: 16),
        label: const Text('다시 시도'),
      ),
    ),
  };

  @override
  Widget build(BuildContext context) => SoftCard(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      comic.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    if (madeAtLabel != null)
                      Text(
                        madeAtLabel!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.muted,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                key: ValueKey('comic-rename-${comic.videoId}'),
                tooltip: '제목 바꾸기',
                visualDensity: VisualDensity.compact,
                onPressed: onRename,
                icon: const Icon(
                  Icons.drive_file_rename_outline_rounded,
                  size: 20,
                  color: AppColors.muted,
                ),
              ),
              // 삭제는 아래 버튼 줄이 아니라 여기 둔다. 아래는 이미 '수정하기'와
              // '크게 보기'가 폭을 다 쓰고 있어서 셋째 버튼을 넣으면 좁은 기기에서
              // 글자가 꺾인다(만화 화면에서 겪은 문제다).
              if (onDelete != null)
                IconButton(
                  key: ValueKey('comic-delete-${comic.videoId}'),
                  tooltip: '만화 지우기',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDelete,
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    size: 20,
                    color: AppColors.muted,
                  ),
                ),
            ],
          ),
        ),
        // 만화는 정사각(2x2 격자)이다. 화면 폭을 그대로 쓰고 높이를 맞춰
        // 그림이 도착하기 전에도 카드 크기가 변하지 않게 한다 — 안 그러면
        // 스크롤 중에 아래 카드들이 튀어 오른다.
        AspectRatio(
          aspectRatio: 1,
          child: GestureDetector(
            onTap: onView,
            child: ColoredBox(
              color: AppColors.surfaceWarm,
              // 대사를 그림 위에 얹는다. 만화 그림에는 말풍선이 없어서(그림
              // 프롬프트가 막는다) 띠를 얹지 않으면 피드에서는 말 없는 그림
              // 넉 장으로만 보인다 — 편집 화면에 들어가야 대사가 보였다.
              child: image != null
                  ? (cuts == null || cuts!.isEmpty
                        ? Image.memory(image!, fit: BoxFit.contain)
                        : ComicCanvas(image: image!, cuts: cuts!))
                  : Center(child: _placeholder()),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 4, 14, 6),
          child: Row(
            children: [
              IconButton(
                key: ValueKey('comic-like-${comic.videoId}'),
                tooltip: comic.likedByMe ? '좋아요 취소' : '좋아요',
                onPressed: onLike,
                icon: Icon(
                  comic.likedByMe
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  color: comic.likedByMe ? AppColors.coral : AppColors.muted,
                ),
              ),
              if (comic.likeCount > 0)
                Text(
                  '${comic.likeCount}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              const SizedBox(width: 4),
              IconButton(
                key: ValueKey('comic-comments-${comic.videoId}'),
                tooltip: '댓글',
                onPressed: onComments,
                icon: const Icon(
                  Icons.mode_comment_outlined,
                  color: AppColors.muted,
                ),
              ),
              if (comic.commentCount > 0)
                Text(
                  '${comic.commentCount}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                ),
              const Spacer(),
              TextButton.icon(
                key: ValueKey('comic-edit-${comic.videoId}'),
                onPressed: onOpen,
                icon: const Icon(Icons.edit_rounded, size: 16),
                label: const Text('수정하기'),
              ),
              TextButton.icon(
                key: ValueKey('comic-view-${comic.videoId}'),
                onPressed: onView,
                icon: const Icon(Icons.open_in_full_rounded, size: 16),
                label: const Text('크게 보기'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
