/// 만화 댓글 시트.
///
/// 영상 댓글과 **다른 스레드**다(`/comic/comments`). 만화에 단 말과 영상에 단 말은
/// 가리키는 대상이 다르므로, 한 스레드로 합치면 피드에 영상 얘기가 섞인다.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../ui/widgets.dart';

/// 댓글 시트를 연다.
///
/// 댓글이 늘 때마다 [onCount]로 **지금 댓글 수**를 알린다. 피드 카드가 그 숫자로
/// 자기 표시만 고치게 하려는 것이다 — 목록 전체를 다시 받으면 스크롤이 튄다.
/// 닫힘 결과로 돌려주지 않는 이유: 시트를 아래로 밀어 닫으면 결과가 null이라
/// 방금 쓴 댓글이 카드에 반영되지 않는다.
Future<void> showComicCommentSheet(
  BuildContext context, {
  required ApiClient api,
  required String videoId,
  required String title,
  required ValueChanged<int> onCount,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: AppColors.surface,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
  ),
  builder: (_) => _ComicCommentSheet(
    api: api,
    videoId: videoId,
    title: title,
    onCount: onCount,
  ),
);

class _ComicCommentSheet extends StatefulWidget {
  const _ComicCommentSheet({
    required this.api,
    required this.videoId,
    required this.title,
    required this.onCount,
  });

  final ApiClient api;
  final String videoId;
  final String title;
  final ValueChanged<int> onCount;

  @override
  State<_ComicCommentSheet> createState() => _ComicCommentSheetState();
}

class _ComicCommentSheetState extends State<_ComicCommentSheet> {
  final _field = TextEditingController();
  List<VideoComment>? _comments;
  String? _error;
  bool _sending = false;

  static final _dayTime = DateFormat('M월 d일 HH:mm');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final comments = await widget.api.listComicComments(widget.videoId);
      if (mounted) setState(() => _comments = comments);
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    }
  }

  Future<void> _send() async {
    final body = _field.text.trim();
    if (body.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final added = await widget.api.addComicComment(widget.videoId, body);
      if (!mounted) return;
      _field.clear();
      final next = [...?_comments, added];
      setState(() => _comments = next);
      widget.onCount(next.length);
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final comments = _comments;
    return Padding(
      // 키보드가 올라오면 입력칸이 그 위에 남아야 한다.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: AppColors.line,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              // 높이를 화면의 절반으로 고정한다. 댓글 수에 따라 시트가 커지면
              // 한 줄일 때는 너무 작고 스무 줄일 때는 화면을 덮는다.
              SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.4,
                child: _error != null
                    ? Center(
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.muted,
                          ),
                        ),
                      )
                    : comments == null
                    ? const Center(child: CircularProgressIndicator())
                    : comments.isEmpty
                    ? const Center(
                        child: Text(
                          '첫 댓글을 남겨 보세요.',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.muted,
                          ),
                        ),
                      )
                    : ListView.separated(
                        key: const ValueKey('comic-comment-list'),
                        itemCount: comments.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, index) {
                          final comment = comments[index];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    comment.authorName ?? '가족',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  if (comment.createdAt != null)
                                    Text(
                                      _dayTime.format(
                                        comment.createdAt!.toLocal(),
                                      ),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: AppColors.muted,
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                comment.body,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ],
                          );
                        },
                      ),
              ),
              const Divider(height: 18),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('comic-comment-field'),
                      controller: _field,
                      maxLength: 500,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: '댓글을 남겨 주세요',
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    key: const ValueKey('comic-comment-send'),
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

}
