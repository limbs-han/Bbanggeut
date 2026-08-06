import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../app/app_theme.dart';
import '../core/api_client.dart';
import 'media_player_surface.dart';
import 'video_comments_section.dart';
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
    this.myUserId,
    this.isOwner = false,
  });

  final String videoId;
  final String title;
  final DateTime? savedAt;

  /// 편집본·댓글을 다루는 백엔드 클라이언트.
  final ApiClient api;

  /// 지금 로그인한 사용자. 자기 댓글에만 수정·삭제를 띄우기 위해 받는다.
  final String? myUserId;

  /// 금고 OWNER인가. OWNER는 남의 댓글도 지울 수 있다(수정은 못 한다).
  final bool isOwner;

  @override
  State<EditedVideoScreen> createState() => _EditedVideoScreenState();
}

class _EditedVideoScreenState extends State<EditedVideoScreen> {
  VideoPlayerController? _player;

  /// 머리줄에 적을 댓글 수. 목록과 입력은 VideoCommentsSection이 들고 있고
  /// 개수만 콜백으로 받아 온다.
  int _commentCount = 0;

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

  @override
  void dispose() {
    _player?.dispose();
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
                    // 원본 상세 화면과 같은 재생 표면을 쓴다.
                    //
                    // 예전에는 여기만 손으로 만든 `VideoPlayer` + 눌러서
                    // 재생·정지였다. 진행 바가 없어서 편집한 영상은 처음부터
                    // 끝까지 보는 수밖에 없었다 — 몇 분 몇 초로 옮기거나
                    // 10초를 되감을 방법이 아예 없었고, 남은 길이도 알 수
                    // 없었다. `MediaPlayerSurface`는 탐색 바·시각 표시·
                    // ±10초·전체화면을 이미 갖고 있으므로 편집본이 원본과
                    // 다르게 동작할 이유가 없다.
                    : MediaPlayerSurface(controller: player),
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
                    '댓글 $_commentCount',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 16),
            // 목록·입력·수정·삭제는 원본 상세 화면과 같은 위젯을 쓴다.
            // 개수만 콜백으로 받아 위 머리줄에 적는다.
            Expanded(
              child: VideoCommentsSection(
                api: widget.api,
                videoId: widget.videoId,
                myUserId: widget.myUserId,
                isOwner: widget.isOwner,
                expanded: true,
                showHeader: false,
                onCountChanged: (count) {
                  if (mounted) setState(() => _commentCount = count);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
