import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/notification_destination.dart';
import 'package:william_james_app/core/notification_visuals.dart';

/// 알림을 눌렀을 때 어디로 가는지 못박는다.
///
/// 예전에는 이 결정이 두 벌 있었다 — 알림함(`content_notifications_screen`)과
/// 푸시 처리(`app.dart`). 푸시 쪽은 웃음 영상·기념일·주간 리포트·초대만 알고
/// 나머지는 전부 알림함으로 떨어뜨려서, `AI 분석이 끝났어요`를 알림함에서
/// 누르면 그 영상 상세가 열리는데 푸시로 누르면 알림함만 열렸다. 사용자는
/// 목록에서 같은 알림을 한 번 더 찾아 눌러야 했다.
///
/// 결정을 한 함수로 모았으니, 종류마다 어디로 가는지 여기서 고정한다.
void main() {
  group('알림 목적지', () {
    test('AI 분석 완료는 그 영상 상세로 간다', () {
      expect(
        notificationDestinationFor('EDIT_ANALYSIS_READY', hasResource: true),
        NotificationDestination.videoDetail,
      );
    });

    test('감지 영상 도착도 그 영상 상세로 간다', () {
      expect(
        notificationDestinationFor('LAUGHTER_VIDEO_READY', hasResource: true),
        NotificationDestination.videoDetail,
      );
    });

    test('만화 대사 준비와 그림 완성은 만화 화면으로 간다', () {
      expect(
        notificationDestinationFor('COMIC_SCRIPT_READY', hasResource: true),
        NotificationDestination.comic,
      );
      expect(
        notificationDestinationFor('COMIC_READY', hasResource: true),
        NotificationDestination.comic,
      );
    });

    test('편집본 댓글은 편집본 화면으로 간다', () {
      // 원본 상세로 보내면 댓글이 어디 달렸는지 찾을 수 없다.
      expect(
        notificationDestinationFor('EDIT_COMMENT_ADDED', hasResource: true),
        NotificationDestination.editedVideo,
      );
    });

    test('초대 수락 소식은 가족 화면으로 간다', () {
      // 예전에는 갈 곳이 없어 기본 경로로 떨어졌고, 그 기본 경로가 기기 등록
      // 화면이라 "가족이 됐어요"를 누르면 카메라를 등록하라는 화면이 열렸다.
      expect(
        notificationDestinationFor('INVITATION_ACCEPTED', hasResource: true),
        NotificationDestination.family,
      );
    });

    test('주기 소식은 각자의 화면으로 간다', () {
      expect(
        notificationDestinationFor('ANNIVERSARY', hasResource: false),
        NotificationDestination.calendar,
      );
      expect(
        notificationDestinationFor('WEEKLY_REPORT', hasResource: false),
        NotificationDestination.laughReport,
      );
      expect(
        notificationDestinationFor('INVITATION_RECEIVED', hasResource: false),
        NotificationDestination.invitations,
      );
    });

    test('리소스 id가 없으면 영상·만화·편집본으로 가지 않는다', () {
      // id 없이는 열 화면이 없다. 빈 화면을 여는 것보다 알림함이 낫다.
      for (final type in const [
        'EDIT_ANALYSIS_READY',
        'LAUGHTER_VIDEO_READY',
        'COMIC_READY',
        'COMIC_SCRIPT_READY',
        'EDIT_COMMENT_ADDED',
      ]) {
        expect(
          notificationDestinationFor(type, hasResource: false),
          NotificationDestination.fallback,
          reason: '$type은 리소스가 없으면 갈 곳이 없다',
        );
      }
    });

    test('모르는 종류는 기본 경로로 떨어진다', () {
      expect(
        notificationDestinationFor('SOMETHING_NEW', hasResource: true),
        NotificationDestination.fallback,
      );
    });

    /// 화면에 이름을 가진 알림은 갈 곳도 있어야 한다.
    ///
    /// 알림 종류가 늘 때 시각(이모지·카테고리)만 더하고 목적지를 빠뜨리면,
    /// 사용자는 이름이 붙은 알림을 눌렀는데 아무 데도 가지 않는 것을 본다.
    test('시각이 정의된 종류는 모두 목적지가 있다', () {
      for (final type in knownNotificationTypes) {
        expect(
          notificationDestinationFor(type, hasResource: true),
          isNot(NotificationDestination.fallback),
          reason: '$type에 시각은 있는데 목적지가 없다',
        );
      }
    });
  });
}
