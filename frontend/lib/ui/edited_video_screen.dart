import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../app/app_theme.dart';
import '../core/api_client.dart';
import '../core/models.dart';
import 'widgets.dart';

/// 편집 완료 영상 하나를 재생하고 가족 댓글을 다는 화면. 영상과 댓글 모두
/// 백엔드가 원본 영상과 같은 경로로 관리한다(EDIT_OUTPUT 행 + video_comments)
/// — 재생은 원본과 같은 presigned URL, 작성자 이름은 서버가 채운다.
class EditedVideoScreen extends StatefulWidget {
  const EditedVideoScreen({
    super.key,
    required this.videoId,
    required this.title,
    required this.api,
    this.savedAt,
  });

  final String videoId;
  final String title;
  final DateTime? savedAt;

  /// 편집본·댓글을 다루는 백엔드 클라이언트.
  final ApiClient api;

  @override
  State<EditedVideoScreen> createState() => _EditedVideoScreenState();
}

class _EditedVideoScreenState extends State<EditedVideoScreen> {
  final _commentInput = TextEditingController();
  VideoPlayerController? _player;
  List<VideoComment> _comments = const [];
  bool _sending = false;

  /// 갤러리 저장 진행률(0~1). null이면 저장 중이 아니다.
  double? _downloadProgress;
  String? _error;

  /// 편집 완료 영상을 내려받아 휴대폰 갤러리에 넣는다.
  ///
  /// 내보내기는 서버 저장까지만 한다 — 갤러리는 여기서 원할 때 받는다.
  Future<void> _saveToGallery() async {
    if (_downloadProgress != null) return;
    setState(() => _downloadProgress = 0);
    final directory = await getTemporaryDirectory();
    final savePath =
        '${directory.path}${Platform.pathSeparator}'
        'edited-${widget.videoId}.mp4';
    try {
      await widget.api.downloadVideoToFile(
        widget.videoId,
        savePath,
        onReceiveProgress: (received, total) {
          if (!mounted || total <= 0) return;
          setState(() => _downloadProgress = received / total);
        },
      );
      try {
        if (!await Gal.hasAccess()) await Gal.requestAccess();
      } catch (_) {
        // 권한 확인이 실패하는 기기도 있다. 저장은 그대로 시도한다.
      }
      await Gal.putVideo(savePath, album: '빵긋');
      if (mounted) showAppSnack(context, '갤러리에 저장했어요.');
    } catch (failure) {
      if (mounted) {
        showAppSnack(context, '갤러리에 저장하지 못했어요. $failure', error: true);
      }
    } finally {
      if (mounted) setState(() => _downloadProgress = null);
    }
  }

  @override
  void initState() {
    super.initState();
    _preparePlayer();
    _loadComments();
  }

  Future<void> _preparePlayer() async {
    try {
      // 원본 영상과 같은 경로다 — MinIO presigned URL로 직접 스트리밍한다
      // (서명이 URL에 있어 헤더가 필요 없다).
      final signed = await widget.api.createPlayUrl(widget.videoId);
      final player = VideoPlayerController.networkUrl(Uri.parse(signed.url));
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
      final comments = await widget.api.listVideoComments(widget.videoId);
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
      await widget.api.addVideoComment(widget.videoId, text);
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
        actions: [
          IconButton(
            key: const Key('edited-save-to-gallery'),
            tooltip: '갤러리에 저장',
            onPressed: _downloadProgress != null ? null : _saveToGallery,
            icon: _downloadProgress != null
                ? SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      value: _downloadProgress == 0 ? null : _downloadProgress,
                    ),
                  )
                : const Icon(Icons.download_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            AspectRatio(
              aspectRatio: player != null && player.value.aspectRatio > 0.1
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
                        final createdAt = comment.createdAt?.toLocal();
                        final author = comment.authorName?.isNotEmpty == true
                            ? comment.authorName!
                            : '가족';
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            CircleAvatar(
                              radius: 15,
                              backgroundColor: AppColors.sage.withValues(
                                alpha: 0.35,
                              ),
                              child: Text(
                                author.characters.first,
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
                                        author,
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
                                    comment.body,
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
