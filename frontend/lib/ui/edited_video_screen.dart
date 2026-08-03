import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:video_player/video_player.dart';

import '../app/app_theme.dart';
import '../editor/edit_recommendation_client.dart';
import 'widgets.dart';

/// 편집 완료 영상 하나를 서버(editor-api)에서 받아 재생하고, 가족 댓글을
/// 달 수 있는 화면. 댓글은 영상별 JSON으로 서버에 저장된다.
class EditedVideoScreen extends StatefulWidget {
  const EditedVideoScreen({
    super.key,
    required this.videoId,
    required this.title,
    this.savedAt,
    this.authorName = '가족',
  });

  final String videoId;
  final String title;
  final DateTime? savedAt;

  /// 댓글에 남길 이름. 로그인 프로필 이름을 넘긴다.
  final String authorName;

  @override
  State<EditedVideoScreen> createState() => _EditedVideoScreenState();
}

class _EditedVideoScreenState extends State<EditedVideoScreen> {
  final _client = EditRecommendationClient();
  final _commentInput = TextEditingController();
  VideoPlayerController? _player;
  List<Map<String, dynamic>> _comments = const [];
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _preparePlayer();
    _loadComments();
  }

  Future<void> _preparePlayer() async {
    try {
      // 실서버에서는 MinIO presigned URL로 직접 스트리밍한다(서명이 URL에
      // 있어 헤더 불필요). 로컬 등 presigned 미지원이면 editor-api 경유
      // /file + 인증 헤더로 폴백한다.
      String? playUrl;
      try {
        playUrl = await _client.editedVideoPlayUrl(widget.videoId);
      } catch (_) {
        playUrl = null;
      }
      final player = playUrl != null
          ? VideoPlayerController.networkUrl(Uri.parse(playUrl))
          : VideoPlayerController.networkUrl(
              Uri.parse(_client.editedVideoUrl(widget.videoId)),
              // video_player는 Dio 인터셉터를 거치지 않으므로 헤더를 직접 붙인다.
              httpHeaders: _client.authHeaders,
            );
      await player.initialize();
      await player.setLooping(true);
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() => _player = player);
      await player.play();
    } catch (failure) {
      if (mounted) setState(() => _error = '영상을 불러오지 못했어요: $failure');
    }
  }

  Future<void> _loadComments() async {
    try {
      final comments = await _client.listComments(widget.videoId);
      if (mounted) setState(() => _comments = comments);
    } catch (_) {
      // 댓글을 못 불러와도 재생은 계속한다.
    }
  }

  Future<void> _sendComment() async {
    final text = _commentInput.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _client.addComment(
        widget.videoId,
        text,
        author: widget.authorName,
      );
      _commentInput.clear();
      await _loadComments();
    } catch (_) {
      if (mounted) showAppSnack(context, '댓글을 남기지 못했어요.', error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    _commentInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.isEmpty ? '편집한 영상' : widget.title),
      ),
      body: SafeArea(
        child: Column(
          children: [
            AspectRatio(
              aspectRatio:
                  player != null && player.value.aspectRatio > 0.1
                  ? player.value.aspectRatio
                  : 16 / 9,
              child: ColoredBox(
                color: Colors.black,
                child: _error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ),
                      )
                    : player == null
                    ? const Center(child: CircularProgressIndicator())
                    : GestureDetector(
                        onTap: () => setState(() {
                          player.value.isPlaying
                              ? player.pause()
                              : player.play();
                        }),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            VideoPlayer(player),
                            if (!player.value.isPlaying)
                              const Icon(
                                Icons.play_circle_fill_rounded,
                                size: 64,
                                color: Colors.white70,
                              ),
                          ],
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: [
                  const Icon(
                    Icons.auto_awesome_rounded,
                    size: 16,
                    color: AppColors.sageDark,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      widget.savedAt == null
                          ? '가족과 함께 만든 편집 영상'
                          : '${DateFormat('M월 d일 HH:mm').format(widget.savedAt!.toLocal())}에 편집',
                      style: const TextStyle(
                        color: AppColors.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Text(
                    '댓글 ${_comments.length}',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 16),
            Expanded(
              child: _comments.isEmpty
                  ? const Center(
                      child: Text(
                        '첫 댓글을 남겨 보세요!',
                        style: TextStyle(color: AppColors.muted),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      itemCount: _comments.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final comment = _comments[index];
                        final createdAt = DateTime.tryParse(
                          comment['createdAt'] as String? ?? '',
                        )?.toLocal();
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(
                              radius: 15,
                              backgroundColor: AppColors.sage.withValues(
                                alpha: 0.35,
                              ),
                              child: Text(
                                (comment['author'] as String? ?? '가')
                                    .characters
                                    .first,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                ),
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
                                        comment['author'] as String? ?? '가족',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      if (createdAt != null)
                                        Text(
                                          DateFormat(
                                            'M.d HH:mm',
                                          ).format(createdAt),
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: AppColors.muted,
                                          ),
                                        ),
                                    ],
                                  ),
                                  Text(
                                    comment['text'] as String? ?? '',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                6,
                12,
                8 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _commentInput,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendComment(),
                      decoration: const InputDecoration(
                        hintText: '따뜻한 한마디를 남겨 주세요',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _sendComment,
                    icon: _sending
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
