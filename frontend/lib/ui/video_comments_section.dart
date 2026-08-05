import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_theme.dart';
import '../core/api_client.dart';
import '../core/models.dart';
import 'widgets.dart';

/// 영상 한 건의 가족 댓글. 원본과 편집본이 같은 위젯을 쓴다.
///
/// 백엔드는 두 종류를 구별하지 않는다 — 편집본도 `videos` 행이고 댓글도
/// `video_comments`의 같은 경로다(API-83~86). 그래서 화면만 나눠 두면 같은
/// 코드가 두 벌이 된다.
///
/// 레이아웃이 두 가지다. 편집본 화면은 댓글이 화면의 본문이라 남은 높이를
/// 채우고 스스로 스크롤해야 하고([expanded] = true), 원본 상세 화면은 이미
/// 바깥이 `ListView`라서 안에서 또 스크롤하면 안 된다([expanded] = false).
class VideoCommentsSection extends StatefulWidget {
  const VideoCommentsSection({
    super.key,
    required this.api,
    required this.videoId,
    required this.myUserId,
    required this.isOwner,
    this.expanded = false,
    this.showHeader = true,
    this.onCountChanged,
  });

  final ApiClient api;
  final String videoId;

  /// 지금 로그인한 사용자. 자기 댓글에만 수정을 띄우기 위해 받는다.
  final String? myUserId;

  /// 금고 OWNER인가. OWNER는 남의 댓글도 지울 수 있다(수정은 못 한다).
  final bool isOwner;

  final bool expanded;

  /// 스스로 '댓글 N' 머리줄을 그릴지. 이미 바깥에 개수를 적는 화면은 끈다.
  final bool showHeader;

  /// 개수가 바뀔 때 알린다 — 머리줄을 바깥에서 그리는 화면을 위해.
  final ValueChanged<int>? onCountChanged;

  @override
  State<VideoCommentsSection> createState() => _VideoCommentsSectionState();
}

class _VideoCommentsSectionState extends State<VideoCommentsSection> {
  final _input = TextEditingController();
  List<VideoComment> _comments = const [];
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final comments = await widget.api.listVideoComments(widget.videoId);
      if (!mounted) return;
      setState(() => _comments = comments);
      widget.onCountChanged?.call(comments.length);
    } catch (_) {
      // 댓글을 못 불러와도 재생은 계속한다.
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.api.addVideoComment(widget.videoId, text);
      _input.clear();
      await _load();
    } catch (_) {
      if (mounted) showAppSnack(context, '댓글을 남기지 못했어요.', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// 내가 쓴 댓글인가. 수정은 쓴 사람만 할 수 있다.
  bool _isMine(VideoComment comment) =>
      widget.myUserId != null && widget.myUserId == comment.authorId;

  Future<void> _edit(VideoComment comment) async {
    final edited = await showDialog<String>(
      context: context,
      builder: (_) => _CommentEditorDialog(initialBody: comment.body),
    );
    if (edited == null || edited == comment.body) return;
    try {
      await widget.api.updateVideoComment(widget.videoId, comment.id, edited);
      await _load();
      if (mounted) showAppSnack(context, '댓글을 고쳤어요.');
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
    }
  }

  Future<void> _delete(VideoComment comment) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('댓글을 지울까요?'),
        content: const Text('지운 댓글은 되돌릴 수 없어요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.deleteVideoComment(widget.videoId, comment.id);
      await _load();
      if (mounted) showAppSnack(context, '댓글을 지웠어요.');
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
    }
  }

  Widget _commentRow(VideoComment comment) {
    final createdAt = comment.createdAt?.toLocal();
    final author = comment.authorName?.isNotEmpty == true
        ? comment.authorName!
        : '가족';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 15,
          backgroundColor: AppColors.sage.withValues(alpha: 0.35),
          child: Text(
            author.characters.first,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    author,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (createdAt != null)
                    Text(
                      DateFormat('M.d HH:mm').format(createdAt),
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppColors.muted,
                      ),
                    ),
                ],
              ),
              Text(comment.body, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
        // 내 댓글은 고치고 지운다. OWNER는 남의 댓글도 지울 수 있지만 고치지는
        // 못한다 — 남의 말을 고쳐 쓰는 것과 지우는 것은 다른 일이다.
        if (_isMine(comment) || widget.isOwner)
          PopupMenuButton<String>(
            key: Key('comment-menu-${comment.id}'),
            icon: const Icon(
              Icons.more_horiz_rounded,
              size: 18,
              color: AppColors.muted,
            ),
            onSelected: (value) =>
                value == 'edit' ? _edit(comment) : _delete(comment),
            itemBuilder: (_) => [
              if (_isMine(comment))
                const PopupMenuItem(value: 'edit', child: Text('수정')),
              const PopupMenuItem(value: 'delete', child: Text('삭제')),
            ],
          ),
      ],
    );
  }

  Widget _emptyHint() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 18),
    child: Center(
      child: Text(
        '첫 댓글을 남겨 보세요!',
        style: TextStyle(color: AppColors.muted),
      ),
    ),
  );

  Widget _inputRow() => Padding(
    padding: EdgeInsets.fromLTRB(
      12,
      6,
      12,
      8 + (widget.expanded ? MediaQuery.viewInsetsOf(context).bottom : 0),
    ),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: _input,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _send(),
            decoration: const InputDecoration(
              hintText: '따뜻한 한마디를 남겨 주세요',
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          onPressed: _sending ? null : _send,
          icon: _sending
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_rounded),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final header = widget.showHeader
        ? Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Row(
              children: [
                const Icon(
                  Icons.mode_comment_outlined,
                  size: 18,
                  color: AppColors.muted,
                ),
                const SizedBox(width: 6),
                Text(
                  '댓글 ${_comments.length}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          )
        : null;

    if (widget.expanded) {
      return Column(
        children: [
          ?header,
          Expanded(
            child: _comments.isEmpty
                ? _emptyHint()
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    itemCount: _comments.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (_, index) => _commentRow(_comments[index]),
                  ),
          ),
          _inputRow(),
        ],
      );
    }

    // 바깥이 이미 스크롤하는 화면. 목록을 스크롤하지 않고 그대로 펼친다 —
    // 댓글 수는 많지 않고, 스크롤을 겹치면 손가락이 어느 쪽을 움직이는지
    // 알 수 없다.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ?header,
        if (_comments.isEmpty)
          _emptyHint()
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              children: [
                for (final comment in _comments) ...[
                  if (comment != _comments.first) const SizedBox(height: 10),
                  _commentRow(comment),
                ],
              ],
            ),
          ),
        _inputRow(),
      ],
    );
  }
}

/// 댓글 한 줄을 고치는 작은 입력창.
class _CommentEditorDialog extends StatefulWidget {
  const _CommentEditorDialog({required this.initialBody});

  final String initialBody;

  @override
  State<_CommentEditorDialog> createState() => _CommentEditorDialogState();
}

class _CommentEditorDialogState extends State<_CommentEditorDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialBody,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('댓글 수정'),
    content: TextField(
      controller: _controller,
      autofocus: true,
      maxLines: 4,
      minLines: 1,
      decoration: const InputDecoration(hintText: '댓글을 고쳐 주세요'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: () {
          final text = _controller.text.trim();
          if (text.isEmpty) return;
          Navigator.pop(context, text);
        },
        child: const Text('저장'),
      ),
    ],
  );
}
