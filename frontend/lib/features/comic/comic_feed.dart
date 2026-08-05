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
import 'comic_gateway.dart';
import 'comic_screen.dart';
import 'comic_script.dart';
import 'comic_viewer.dart';

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

class _ComicFeedState extends State<ComicFeed> {
  /// videoId → 받아 둔 PNG. 값이 없으면 아직 안 받았고, null이면 받지 못했다.
  final Map<String, Uint8List?> _images = {};

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

  /// 그림을 한 번만 받는다. 실패도 기억한다 — 안 그러면 매 프레임 다시 시도한다.
  Future<void> _ensureImage(String videoId) async {
    if (_images.containsKey(videoId) || _loading.contains(videoId)) return;
    _loading.add(videoId);
    Uint8List? bytes;
    try {
      final status = await _gateway.jobStatus(videoId);
      final cuts = status.cuts;
      if (cuts != null && cuts.isNotEmpty) _cuts[videoId] = cuts;
      if (status.done && status.imageUrl != null) {
        bytes = await _gateway.download(status.imageUrl!);
      }
    } catch (_) {
      // 못 받은 것도 결과다. 카드가 "볼 수 없어요"를 보여 준다.
    }
    _loading.remove(videoId);
    if (mounted) setState(() => _images[videoId] = bytes);
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
          // 크게 보다가 대사를 고치고 싶을 수 있다. 뷰어를 닫고 편집으로 넘긴다.
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

  /// 만화 화면을 연다 — 대사를 고쳐 다시 만들거나 저장·공유하는 곳이다.
  Future<void> _open(VaultComic comic) async {
    final video = widget.videoById(comic.videoId);
    if (video == null) {
      showAppSnack(context, '원본 영상을 찾지 못했어요.');
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ComicScreen(api: widget.api, video: video),
      ),
    );
    if (!mounted) return;
    // 다시 만들었을 수 있으니 그림을 버리고 다시 받는다.
    setState(() => _images.remove(comic.videoId));
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
          loaded: _images.containsKey(comic.videoId),
          madeAtLabel: comic.madeAt == null
              ? null
              : _dayTime.format(comic.madeAt!.toLocal()),
          onView: () => _view(comic),
          onOpen: () => _open(comic),
          onLike: () => _toggleLike(comic),
          onComments: () => _openComments(comic),
          onRename: () => _rename(comic),
        );
      },
    );
  }
}

class _ComicCard extends StatelessWidget {
  const _ComicCard({
    super.key,
    required this.comic,
    required this.image,
    required this.loaded,
    required this.madeAtLabel,
    required this.onView,
    required this.onOpen,
    required this.onLike,
    required this.onComments,
    required this.onRename,
  });

  final VaultComic comic;
  final Uint8List? image;

  /// 받기를 이미 마쳤는가. [image]가 null인 것은 "아직"과 "못 받았다" 둘 다일 수
  /// 있어서, 진행 표시와 오류 표시를 가르려면 이 값이 필요하다.
  final bool loaded;
  final String? madeAtLabel;

  /// 크게 보기 — 그림과 대사만 보여 준다.
  final VoidCallback onView;

  /// 대사 고치기 — 편집 화면으로 간다.
  final VoidCallback onOpen;
  final VoidCallback onLike;
  final VoidCallback onComments;
  final VoidCallback onRename;

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
              child: image != null
                  ? Image.memory(image!, fit: BoxFit.contain)
                  : Center(
                      child: loaded
                          ? const Text(
                              '만화를 불러오지 못했어요',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.muted,
                              ),
                            )
                          : const SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                    ),
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
                label: const Text('대사 고치기'),
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
