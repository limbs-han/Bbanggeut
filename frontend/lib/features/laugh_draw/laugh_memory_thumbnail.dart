import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/video_thumbnail_cache.dart';

/// 뽑힌 영상의 첫 화면.
///
/// **왜 목록의 [MemoryThumbnail]을 쓰지 않는가**: 그쪽은 프레임을 못 뽑았을 때
/// 참고용 가족 사진(`family_live_reference.png`)을 깐다. 뽑기 결과에서 그 그림이
/// 나오면 "우리 집에서 이런 일이 있었다"는 거짓말이 된다. 여기서는 실제 프레임만
/// 쓰고, 못 뽑으면 영상과 무관한 중립 자리표시를 그린다.
///
/// 프레임 지점은 [VideoThumbnailCache.previewTimeMs]가 영상 길이에서 계산한다 —
/// 몇 초짜리 웃음 영상에서 1분 지점을 찾다 실패하지 않게.
class LaughMemoryThumbnail extends StatelessWidget {
  const LaughMemoryThumbnail({
    super.key,
    required this.api,
    required this.video,
  });

  final ApiClient api;
  final VideoMemory video;

  @override
  Widget build(BuildContext context) {
    // 이미 뽑아 둔 프레임이 있으면 FutureBuilder를 태우지 않는다 — 다시 그릴 때
    // 자리표시가 한 프레임 스쳐 보이지 않게.
    final ready = VideoThumbnailCache.readyPreviewPath(video.id);
    if (ready != null) return _frame(context, ready);
    return FutureBuilder<String?>(
      future: VideoThumbnailCache.frameForMemory(api, video),
      builder: (context, snapshot) {
        final path = snapshot.data;
        if (path != null) return _frame(context, path);
        return _Placeholder(
          loading: snapshot.connectionState == ConnectionState.waiting,
        );
      },
    );
  }

  Widget _frame(BuildContext context, String path) => Image.file(
    File(path),
    fit: BoxFit.cover,
    // 같은 그림을 다시 그릴 때 한 프레임 비었다가 채워지는 깜빡임을 없앤다.
    gaplessPlayback: true,
    cacheWidth:
        (MediaQuery.sizeOf(context).width *
                MediaQuery.devicePixelRatioOf(context))
            .round(),
    errorBuilder: (_, _, _) => const _Placeholder(loading: false),
  );
}

/// 프레임을 못 뽑았을 때. 영상과 무관한 사진을 채우지 않고 "영상"이라는 것만 알린다.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.loading});

  final bool loading;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF4A4038), Color(0xFF2C2621)],
      ),
    ),
    child: Center(
      child: loading
          ? const SizedBox.square(
              dimension: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: AppColors.coralSoft,
              ),
            )
          : const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.movie_creation_outlined,
                  size: 34,
                  color: Color(0x99FFFFFF),
                ),
                SizedBox(height: 6),
                Text(
                  '미리보기를 준비하지 못했어요',
                  style: TextStyle(fontSize: 11, color: Color(0x99FFFFFF)),
                ),
              ],
            ),
    ),
  );
}
