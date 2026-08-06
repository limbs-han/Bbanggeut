import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_theme.dart';
import '../core/api_client.dart';
import '../core/models.dart';
import '../core/video_thumbnail_cache.dart';

/// 그림을 **그릴 크기만큼만** 풀도록 [Image]에 넘길 픽셀 수.
///
/// **왜 필요한가**: 이 앱의 일러스트는 대부분 1254×1254 PNG인데 화면에서는
/// 100dp 안팎으로 그린다. 정해 주지 않으면 한 장이 RGBA로 6MB를 차지한다.
/// 열 장이면 Flutter 이미지 캐시(기본 100MB)가 그것만으로 차고, 그때부터는
/// 화면을 옮길 때마다 밀려난 그림을 다시 푼다 — 여기저기서 툭툭 걸리는
/// 정체다. 그릴 크기로 풀면 같은 그림이 수십 분의 일로 줄어든다.
int decodePixels(BuildContext context, double logicalSize) =>
    (logicalSize * MediaQuery.devicePixelRatioOf(context)).ceil();

class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: AppColors.cream,
      gradient: RadialGradient(
        center: Alignment(1.05, -1.0),
        radius: 1.35,
        colors: [Color(0xFFFFEEDB), AppColors.cream],
        stops: [0, .72],
      ),
    ),
    child: Stack(
      children: [
        const Positioned(
          right: -58,
          top: -54,
          child: _SoftCircle(size: 190, color: Color(0x55FFD9B8)),
        ),
        const Positioned(
          left: -92,
          bottom: 42,
          child: _SoftCircle(size: 230, color: Color(0x3FDDE4BD)),
        ),
        child,
      ],
    ),
  );
}

class _SoftCircle extends StatelessWidget {
  const _SoftCircle({required this.size, required this.color});
  final double size;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class PagePadding extends StatelessWidget {
  const PagePadding({
    super.key,
    required this.child,
    this.top = 12,
    this.bottom = 28,
  });
  final Widget child;
  final double top;
  final double bottom;
  @override
  Widget build(BuildContext context) =>
      Padding(padding: EdgeInsets.fromLTRB(16, top, 16, bottom), child: child);
}

class SoftCard extends StatelessWidget {
  const SoftCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color = AppColors.surface,
    this.borderColor = AppColors.line,
    this.radius = 22,
  });
  final Widget child;
  final EdgeInsets padding;
  final Color color;
  final Color borderColor;
  final double radius;

  @override
  Widget build(BuildContext context) => Material(
    color: color,
    elevation: 3,
    shadowColor: const Color(0x1C6B4C2D),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: borderColor),
    ),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.badge = false,
    this.size = 48,
  });
  final IconData icon;
  final VoidCallback? onPressed;
  final bool badge;
  final double size;

  @override
  Widget build(BuildContext context) => Stack(
    clipBehavior: Clip.none,
    children: [
      SizedBox.square(
        dimension: size,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            minimumSize: Size.square(size),
            padding: EdgeInsets.zero,
            backgroundColor: AppColors.surfaceWarm,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          child: Icon(icon, color: AppColors.inkSoft, size: 25),
        ),
      ),
      if (badge)
        const Positioned(
          right: 6,
          top: 6,
          child: CircleAvatar(radius: 4, backgroundColor: AppColors.coral),
        ),
    ],
  );
}

class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.action, this.onAction});
  final String title;
  final String? action;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleLarge),
      ),
      if (action != null) TextButton(onPressed: onAction, child: Text(action!)),
    ],
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 74,
            height: 74,
            decoration: BoxDecoration(
              color: AppColors.coralSoft,
              borderRadius: BorderRadius.circular(25),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 34, color: AppColors.coral),
          ),
          const SizedBox(height: 18),
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 7),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (action != null) ...[const SizedBox(height: 22), action!],
        ],
      ),
    ),
  );
}

class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    this.positive = true,
    this.color,
    this.compact = false,
  });
  final String label;
  final bool positive;
  final Color? color;
  final bool compact;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color ?? (positive ? AppColors.greenCard : AppColors.pink),
      borderRadius: BorderRadius.circular(99),
    ),
    child: Padding(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 12,
        vertical: compact ? 4 : 7,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: compact ? 10 : 12,
          fontWeight: FontWeight.w800,
          color: positive ? AppColors.sageDark : AppColors.danger,
        ),
      ),
    ),
  );
}

/// Uses the exact family photograph embedded in the supplied final live board.
/// The screenshot itself is kept as the immutable source and clipped at runtime.
class FamilyReferenceImage extends StatelessWidget {
  const FamilyReferenceImage({super.key, this.borderRadius = 20});
  final double borderRadius;

  static const _sourceWidth = 780.0;
  static const _cropLeft = 31.0;
  static const _cropTop = 288.0;
  static const _cropWidth = 717.0;
  static const _cropHeight = 405.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = constraints.maxWidth / _cropWidth;
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: SizedBox(
          width: constraints.maxWidth,
          height: _cropHeight * scale,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: -_cropLeft * scale,
                top: -_cropTop * scale,
                width: _sourceWidth * scale,
                child: Image.asset(
                  'assets/images/family_live_reference.png',
                  fit: BoxFit.fitWidth,
                  // 이 그림은 추억 목록에서 썸네일이 아직 없는 카드마다 깔린다.
                  // 780×1688 원본을 그대로 풀면 한 장에 5MB고, 목록을 넘기는
                  // 내내 그걸 132dp로 줄여 그린다. 그릴 크기로 풀고 보간도
                  // 한 단계 낮춘다 — 줄여 그리는 그림에서 cubic은 값만 비싸다.
                  cacheWidth: decodePixels(context, _sourceWidth * scale),
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

String triggerLabel(String value) => switch (value) {
  'LAUGHTER' => '웃음',
  'CLAP' => '박수',
  'WAKE_WORD' => '호출',
  'TOUCH' => '일상',
  'MANUAL' => '직접 저장',
  'USER_UPLOAD' => '업로드',
  'EDIT' => '편집본',
  _ => value,
};

IconData triggerIcon(String value) => switch (value) {
  'LAUGHTER' => Icons.sentiment_very_satisfied_rounded,
  'CLAP' => Icons.back_hand_rounded,
  'WAKE_WORD' => Icons.graphic_eq_rounded,
  'TOUCH' => Icons.waving_hand_rounded,
  'MANUAL' => Icons.bookmark_rounded,
  _ => Icons.videocam_rounded,
};

Color triggerColor(String value) => switch (value) {
  'LAUGHTER' => AppColors.yellowSoft,
  'CLAP' => AppColors.coralSoft,
  'WAKE_WORD' => AppColors.sageSoft,
  'TOUCH' => AppColors.greenCard,
  _ => AppColors.pink,
};

class VideoEventTypePills extends StatelessWidget {
  const VideoEventTypePills({
    super.key,
    required this.video,
    this.compact = false,
    this.alignment = WrapAlignment.start,
  });

  final VideoMemory video;
  final bool compact;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: alignment,
    spacing: compact ? 4 : 6,
    runSpacing: compact ? 4 : 6,
    children: [
      for (final eventType in video.effectiveEventTypes)
        StatusPill(
          label: triggerLabel(eventType),
          color: triggerColor(eventType),
          compact: compact,
        ),
    ],
  );
}

String durationLabel(int? durationMs) {
  if (durationMs == null) return '--:--';
  final seconds = durationMs ~/ 1000;
  return '${(seconds ~/ 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// 날짜 형식은 만들 때마다 패턴을 파싱하고 로케일을 찾는다. 목록 한 화면에서
/// 수십 번 부르는 자리라 한 번만 만들어 나눠 쓴다.
final _koreanClock = DateFormat('a h:mm', 'ko');
final _clock = DateFormat('HH:mm');
final _dayClock = DateFormat('M월 d일 HH:mm');
final _titleClock = DateFormat('M월 d일(E) a h:mm', 'ko');

/// 기기가 이벤트 종류만 보고 붙이는 기본 제목들.
///
/// 웃음 클립 스무 개의 제목이 스무 번 같은 문구라 목록에서 영상을 구분할 수
/// 없었다. 이 목록에 있는 제목은 화면에서 날짜·시각·종류를 담은 제목으로
/// 바꿔 그린다.
///
/// 사용자가 직접 붙인 이름은 이 목록에 없으므로 그대로 나간다 — 제목은 상세
/// 화면에서 편집할 수 있고, 자동 생성이 그걸 덮으면 사용자가 지은 이름이
/// 사라진다.
///
/// 기기 쪽 원본은 `ai/yolo/segment_clip_uploader.py`의 `EVENT_TITLES`와
/// `MIXED_EVENT_TITLES`다. 거기서 새 문구가 생기면 여기에도 더해야 한다.
/// 빠뜨려도 고장은 아니고 그 종류만 예전처럼 고정 제목으로 보인다.
const deviceDefaultVideoTitles = <String>{
  '웃음이 담긴 순간',
  '박수가 시작된 순간',
  '카메라를 부른 순간',
  '웃음과 박수가 함께 포착됐어요',
  '이름 없는 추억',
};

/// 제목 수정·삭제 버튼을 띄울지.
///
/// 기기가 담아 온 원본은 가족 공동의 기록이라 이름을 정하고 지우는 것은
/// OWNER만 한다. 편집본은 만든 구성원의 결과물이므로 구성원에게도 띄운다.
///
/// 편집본 삭제는 서버에서 "만든 사람 또는 OWNER"로 한 번 더 걸러진다. 앱은
/// 누가 만들었는지 모르므로(응답에 없다) 버튼을 띄우고 판정을 서버에 맡긴다 —
/// 남의 편집본이면 서버가 이유를 담아 거절한다. 반대로 원본은 역할만 보고
/// 가릴 수 있으니, 눌러 봐야 403이 오는 버튼을 미리 감춘다.
bool canManageVideo(VideoMemory video, {required bool isOwner}) =>
    isOwner || video.sourceType == 'EDIT_OUTPUT';

/// 목록·상세에 보여줄 제목. 저장된 제목은 건드리지 않는다.
///
/// [includeDate]를 끄면 시각과 종류만 남는다. 날짜가 이미 화면 맥락인 자리
/// (달력에서 고른 날의 목록)에서 날짜를 한 번 더 적으면 좁은 한 줄을 낭비한다.
String videoDisplayTitle(VideoMemory video, {bool includeDate = true}) {
  final stored = video.title.trim();
  if (stored.isNotEmpty && !deviceDefaultVideoTitles.contains(stored)) {
    return stored;
  }
  final kinds = video.effectiveEventTypes.map(triggerLabel).join('·');
  final at = video.capturedStartAt ?? video.createdAt;
  if (at == null) return kinds.isEmpty ? stored : kinds;
  final when = includeDate ? _titleClock.format(at) : _koreanClock.format(at);
  return kinds.isEmpty ? when : '$when · $kinds';
}

String memoryDate(DateTime? date) {
  if (date == null) return '시간 정보 없음';
  final now = DateTime.now();
  if (DateUtils.isSameDay(now, date)) {
    return '오늘 ${_koreanClock.format(date)}';
  }
  if (DateUtils.isSameDay(now.subtract(const Duration(days: 1)), date)) {
    return '어제 ${_clock.format(date)}';
  }
  return _dayClock.format(date);
}

class MemoryThumbnail extends StatelessWidget {
  const MemoryThumbnail({
    super.key,
    required this.api,
    required this.video,
    this.width = 92,
    this.height = 68,
  });
  final ApiClient api;
  final VideoMemory video;
  final double width;
  final double height;

  /// 몇 픽셀로 풀어 둘지.
  ///
  /// **왜 정해 주는가**: [VideoThumbnailCache]가 만드는 그림은 폭 720px인데
  /// 여기서 그리는 자리는 92×68dp다. 정해 주지 않으면 720px 그대로 풀려 한 장에
  /// 1MB 넘게 이미지 캐시를 차지한다 — 추억 목록처럼 수십 장이 스크롤되는 화면에서는
  /// 그게 수십 MB가 되고, 푸는 시간도 그만큼 들어 스크롤이 걸린다.
  ///
  /// [BoxFit.cover]는 원본 비율에 따라 가로·세로 중 한쪽이 기준이 된다. 원본이
  /// 세로 영상이면 가로가 기준이고, 가로 영상(16:9)이면 세로가 기준이라 그때 필요한
  /// 가로 픽셀이 더 크다. 둘 중 큰 쪽으로 잡아 어느 비율이 와도 흐려지지 않게 한다.
  int _decodeWidth(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return (math.max(width, height * 16 / 9) * ratio).round();
  }

  /// 서버가 만들어 둔 미리보기. 없거나 실패하면 [onMissing]으로 넘어간다.
  ///
  /// **왜 이것을 먼저 쓰는가**: 예전에는 기기가 원본을 열어 프레임을 뽑는 쪽이
  /// 먼저였고, 이 값은 그게 실패했을 때의 대체였다(그런데 서버가 늘 null을
  /// 보내서 한 번도 쓰이지 않았다). 기기가 뽑으려면 원본 MP4를 받아야 하는데
  /// 실측(2026-08-06, 운영 로그) 한 장에 **6.5MB**다. 서버가 만든 JPEG은 그
  /// 300분의 1이라, 있으면 이쪽이 언제나 낫다.
  Widget _serverThumbnail(BuildContext context, Widget Function() onMissing) {
    final url = video.thumbnailUrl;
    if (url == null) return onMissing();
    return Image.network(
      url,
      fit: BoxFit.cover,
      cacheWidth: _decodeWidth(context),
      // 아직 안 만들어진 영상은 404다. 그때만 기기에서 뽑는 예전 길로 간다 —
      // 서버가 URL을 줄 때 존재를 확인하지 않기 때문에 정상 경로다.
      errorBuilder: (_, _, _) => onMissing(),
    );
  }

  Widget _fallback(BuildContext context) =>
      const FamilyReferenceImage(borderRadius: 0);

  Widget _frame(BuildContext context, String path) => Image.file(
    File(path),
    fit: BoxFit.cover,
    cacheWidth: _decodeWidth(context),
    // 같은 그림을 다시 그릴 때 한 프레임 비었다가 채워지는 깜빡임을 없앤다.
    gaplessPlayback: true,
    errorBuilder: (_, _, _) => _fallback(context),
  );

  @override
  Widget build(BuildContext context) {
    // 기기에서 뽑는 길. 서버 그림이 없을 때만 탄다.
    //
    // 이미 뽑아 둔 프레임이 있으면 [FutureBuilder]를 태우지 않는다. 스크롤을
    // 되돌릴 때마다 한 프레임 대체 이미지가 스쳤고, 그 대체 이미지가 원격
    // 썸네일이면 스크롤 도중에 네트워크 요청까지 새로 나갔다.
    Widget extractOnDevice() {
      final ready = VideoThumbnailCache.readyPath(video.id);
      if (ready != null) return _frame(context, ready);
      return FutureBuilder<String?>(
        future: VideoThumbnailCache.frameAtOneMinute(api, video),
        builder: (context, snapshot) {
          final path = snapshot.data;
          return path == null ? _fallback(context) : _frame(context, path);
        },
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(13),
      child: SizedBox(
        width: width,
        height: height,
        child: _serverThumbnail(context, extractOnDevice),
      ),
    );
  }
}

class MemoryTile extends StatelessWidget {
  const MemoryTile({
    super.key,
    required this.api,
    required this.video,
    required this.onTap,
    this.onFavorite,
    this.onDelete,
    this.compact = false,
  });
  final ApiClient api;
  final VideoMemory video;
  final VoidCallback onTap;
  final VoidCallback? onFavorite;
  final VoidCallback? onDelete;
  final bool compact;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(16),
    onTap: onTap,
    child: Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 6 : 9),
      child: Row(
        children: [
          MemoryThumbnail(
            api: api,
            video: video,
            width: compact ? 72 : 88,
            height: compact ? 52 : 64,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  videoDisplayTitle(video),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  '${memoryDate(video.capturedStartAt ?? video.createdAt)} · ${durationLabel(video.durationMs)}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 130),
            child: VideoEventTypePills(
              video: video,
              compact: true,
              alignment: WrapAlignment.end,
            ),
          ),
          if (onFavorite != null || onDelete != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, color: AppColors.muted),
              onSelected: (value) =>
                  value == 'favorite' ? onFavorite?.call() : onDelete?.call(),
              itemBuilder: (_) => [
                if (onFavorite != null)
                  PopupMenuItem(
                    value: 'favorite',
                    child: Text(video.favorite ? '즐겨찾기 해제' : '즐겨찾기'),
                  ),
                if (onDelete != null)
                  const PopupMenuItem(value: 'delete', child: Text('삭제')),
              ],
            ),
        ],
      ),
    ),
  );
}

void showAppSnack(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.of(context)
    // 새 안내가 오면 이전 것부터 걷는다. 안내가 줄줄이 쌓여 화면을 가리는
    // 것이 "창이 거슬린다"의 정체였다.
    ..hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      // 누르면 바로 사라진다.
      content: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: messenger.hideCurrentSnackBar,
        child: Text(message),
      ),
      duration: const Duration(seconds: 2),
      dismissDirection: DismissDirection.horizontal,
      backgroundColor: error ? AppColors.danger : AppColors.ink,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );
}

enum MemoryConnectionChoice { keep, restart }

Future<MemoryConnectionChoice?> showMemoryConnectionChoice(
  BuildContext context,
) async {
  final choice = await showDialog<MemoryConnectionChoice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('이전 기기의 추억을 유지하시겠습니까?'),
      content: const Text('새로 시작할 경우 이전에 저장된 추억이 삭제됩니다.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('취소'),
        ),
        OutlinedButton(
          onPressed: () =>
              Navigator.pop(dialogContext, MemoryConnectionChoice.keep),
          child: const Text('유지하기'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: () =>
              Navigator.pop(dialogContext, MemoryConnectionChoice.restart),
          child: const Text('새로 시작하기'),
        ),
      ],
    ),
  );
  if (!context.mounted || choice != MemoryConnectionChoice.restart) {
    return choice;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('정말 새로 시작할까요?'),
      content: const Text('이전 추억 삭제는 되돌릴 수 없습니다. 기기 연결 후 서버에서 삭제 처리가 필요합니다.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('취소'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('새로 시작'),
        ),
      ],
    ),
  );
  return confirmed == true ? choice : null;
}

/// 제목을 고치는 작은 입력 창. 만화와 편집본이 같은 것을 쓴다.
///
/// **빈 값으로 확인해도 취소가 아니다.** 만화는 빈 제목을 "붙인 제목을 지우고
/// 영상 제목으로 되돌린다"로 쓰므로, 지울 길을 없애면 한번 잘못 붙인 이름을
/// 되돌릴 수 없다. 취소는 null이고, 빈 문자열은 지우기다.
/// 제목을 물어보는 창. 취소하면 null, 저장하면 입력한 글이다.
///
/// **왜 컨트롤러를 창 위젯이 들고 있는가**: 예전에는 이 함수가
/// `TextEditingController`를 만들고 `finally`에서 버렸다. `showDialog`의
/// Future는 라우트를 pop하는 **순간** 끝나지만 창은 닫히는 애니메이션 동안
/// 아직 화면에 살아 있다. 그 사이에 컨트롤러를 버리면 살아 있는 TextField가
/// 죽은 컨트롤러를 붙잡은 채 정리되어 프레임 어서션으로 터졌다
/// (`_dependents.isEmpty`, 빨간 화면). 컨트롤러를 쓰는 위젯이 직접 들고
/// 자기 dispose에서 버리면 수명이 정확히 맞는다.
Future<String?> promptForTitle(
  BuildContext context, {
  required String title,
  String initial = '',
  String? hint,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TitlePromptDialog(title: title, initial: initial, hint: hint),
);

class _TitlePromptDialog extends StatefulWidget {
  const _TitlePromptDialog({
    required this.title,
    required this.initial,
    required this.hint,
  });

  final String title;
  final String initial;
  final String? hint;

  @override
  State<_TitlePromptDialog> createState() => _TitlePromptDialogState();
}

class _TitlePromptDialogState extends State<_TitlePromptDialog> {
  late final TextEditingController _field = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('title-prompt-dialog'),
    title: Text(widget.title),
    content: TextField(
      key: const Key('title-prompt-field'),
      controller: _field,
      autofocus: true,
      maxLength: 60,
      textInputAction: TextInputAction.done,
      onSubmitted: (value) => Navigator.pop(context, value),
      decoration: InputDecoration(hintText: widget.hint ?? '새 제목'),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        key: const Key('title-prompt-save'),
        onPressed: () => Navigator.pop(context, _field.text),
        child: const Text('저장'),
      ),
    ],
  );
}

Future<bool> confirmVideoDeletion(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Dialog(
        key: const Key('video-delete-dialog'),
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(36),
            child: ColoredBox(
              color: AppColors.surface,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 22, 28, 20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          'assets/images/video_delete_mascot.png',
                          key: const Key('video-delete-mascot'),
                          width: 154,
                          height: 132,
                          fit: BoxFit.contain,
                          cacheWidth: decodePixels(dialogContext, 154),
                        ),
                        const SizedBox(height: 8),
                        Text.rich(
                          const TextSpan(
                            children: [
                              TextSpan(text: '영상 '),
                              TextSpan(
                                text: '삭제',
                                style: TextStyle(color: AppColors.coralDark),
                              ),
                              TextSpan(text: '할까요?'),
                            ],
                          ),
                          textAlign: TextAlign.center,
                          style: Theme.of(dialogContext).textTheme.headlineSmall
                              ?.copyWith(
                                color: AppColors.ink,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          '삭제한 영상은 다시 복구할 수 없어요.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.inkSoft,
                            fontSize: 15,
                            height: 1.45,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: AppColors.line),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 22, 24, 26),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            key: const Key('video-delete-cancel'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(58),
                              foregroundColor: AppColors.inkSoft,
                              side: const BorderSide(
                                color: AppColors.line,
                                width: 1.5,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            onPressed: () =>
                                Navigator.pop(dialogContext, false),
                            child: const Text('취소'),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: FilledButton(
                            key: const Key('video-delete-confirm'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(58),
                              backgroundColor: AppColors.danger,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            onPressed: () => Navigator.pop(dialogContext, true),
                            child: const Text('삭제'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ) ??
    false;
