/// 알림을 눌렀을 때 어디로 가는지 한곳에서 정한다.
///
/// **왜 한곳인가**: 목적지 결정이 두 벌 있었다. 알림함
/// (`content_notifications_screen.dart`)은 영상 상세·만화·편집본까지 갈라
/// 보냈고, 푸시를 눌렀을 때 도는 쪽(`app.dart`)은 웃음 영상·기념일·주간
/// 리포트·초대만 알고 나머지는 전부 알림함으로 떨어뜨렸다. 그래서 같은
/// 알림이 어디서 눌렀느냐에 따라 다른 곳으로 갔다 — `AI 분석이 끝났어요`를
/// 알림함에서 누르면 그 영상 상세가 열리는데, 푸시로 누르면 알림함만 열려
/// 사용자가 목록에서 그 알림을 한 번 더 찾아 눌러야 했다.
///
/// 종류가 늘 때 한 벌만 고치면 다른 한 벌이 조용히 뒤처진다. 같은 이유로
/// 이모지·카테고리도 `core/notification_visuals.dart`에 모아 두었다.
library;

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../core/models.dart';
import '../core/notification_destination.dart';
import '../features/comic/comic_screen.dart';
import 'content_calendar_screen.dart';
import 'edited_video_screen.dart';
import 'family_screen.dart';
import 'invitation_inbox_screen.dart';
import 'laugh_report_content_screen.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

/// 알림이 가리키는 화면을 연다.
///
/// [onOpenInvitations]·[onOpenDevices]는 알림함처럼 이미 탭 전환 수단을 쥔
/// 화면이 넘긴다. 없으면 해당 화면을 새로 밀어 올린다.
///
/// 목적지를 열 수 없으면(영상이 지워졌다든지) 스낵으로 알리고 아무 데도 가지
/// 않는다 — 알림을 눌렀는데 엉뚱한 화면이 열리는 것보다 낫다.
Future<void> openNotificationTarget(
  BuildContext context, {
  required AppController controller,
  required String type,
  String? resourceId,
  VoidCallback? onOpenInvitations,
  VoidCallback? onOpenDevices,
}) async {
  final navigator = Navigator.of(context);

  Future<void> push(Widget screen) =>
      navigator.push<void>(MaterialPageRoute(builder: (_) => screen));

  /// 알림이 가리키는 영상. 이미 받아 둔 목록에 있으면 그것을 쓰고, 없으면 한
  /// 건만 받아 온다 — 목록에 없는 영상(다른 기기·오래된 것)도 열려야 한다.
  Future<VideoMemory> videoFor(String videoId) async {
    final matches = controller.videos.where(
      (candidate) => candidate.id == videoId,
    );
    return matches.isNotEmpty
        ? matches.first
        : await controller.api.getVideo(videoId);
  }

  Future<void> pushWithVideo(Widget Function(VideoMemory) build) async {
    try {
      final video = await videoFor(resourceId!);
      if (!context.mounted) return;
      await push(build(video));
    } catch (failure) {
      if (context.mounted) showAppSnack(context, '$failure', error: true);
    }
  }

  final destination = notificationDestinationFor(
    type,
    hasResource: resourceId != null,
  );
  switch (destination) {
    case NotificationDestination.editedVideo:
      await push(
        EditedVideoScreen(
          api: controller.api,
          videoId: resourceId!,
          title: '',
          myUserId: controller.user?.id,
          isOwner: controller.isOwner,
        ),
      );

    case NotificationDestination.comic:
      await pushWithVideo(
        (video) => ComicScreen(api: controller.api, video: video),
      );

    case NotificationDestination.videoDetail:
      await pushWithVideo(
        (video) => VideoDetailScreen(controller: controller, video: video),
      );

    case NotificationDestination.calendar:
      await push(ContentCalendarScreen(controller: controller));

    case NotificationDestination.laughReport:
      await push(LaughReportContentScreen(controller: controller));

    case NotificationDestination.invitations:
      await controller.refreshMyInvitations();
      if (!context.mounted) return;
      if (onOpenInvitations != null) {
        onOpenInvitations();
      } else {
        await push(InvitationInboxScreen(controller: controller));
      }

    case NotificationDestination.family:
      await push(FamilyScreen(controller: controller));

    case NotificationDestination.fallback:
      onOpenDevices?.call();
  }
}
