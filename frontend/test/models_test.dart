import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/models.dart';

void main() {
  test('서버 역할 표기를 OWNER와 MEMBER로 정규화한다', () {
    expect(normalizeRole('owner'), 'OWNER');
    expect(normalizeRole('소유자'), 'OWNER');
    expect(normalizeRole('viewer'), 'MEMBER');
    expect(normalizeRole('EDITOR'), 'MEMBER');
  });

  test('서버 웃음 이벤트 표기를 LAUGHTER로 정규화한다', () {
    for (final value in ['laugh', 'LAUGHTER', 'SMILE', '웃음', '웃음 감지']) {
      final video = VideoMemory.fromJson({
        'id': 'video-$value',
        'deviceId': 'device-id',
        'triggerType': value,
        'title': '웃음 영상',
        'status': 'READY',
      });
      expect(video.triggerType, 'LAUGHTER');
    }
  });

  test('백엔드 Video 응답을 앱 모델로 변환한다', () {
    final video = VideoMemory.fromJson({
      'id': 'video-id',
      'deviceId': 'device-id',
      'triggerType': 'LAUGHTER',
      'sourceType': 'IOT_CAPTURE',
      'title': '저녁 식사 웃음',
      'status': 'READY',
      'isFavorite': true,
      'durationMs': 120000,
      'capturedStartAt': '2026-07-20T10:00:00Z',
    });

    expect(video.triggerType, 'LAUGHTER');
    expect(video.sourceType, 'IOT_CAPTURE');
    expect(video.favorite, isTrue);
    expect(video.durationMs, 120000);
    expect(video.capturedStartAt, isNotNull);
  });

  test('백엔드 알림 payload의 화면 이동 식별자를 보존한다', () {
    final notification = AppNotification.fromJson({
      'id': 'notification-id',
      'type': 'LAUGHTER_VIDEO_READY',
      'title': '웃음 영상이 도착했어요',
      'body': '저녁 식사 웃음',
      'deviceId': 'device-id',
      'resourceId': 'video-id',
      'createdAt': '2026-07-30T10:00:00Z',
    });

    expect(notification.type, 'LAUGHTER_VIDEO_READY');
    expect(notification.deviceId, 'device-id');
    expect(notification.resourceId, 'video-id');
    expect(notification.isRead, isFalse);
    expect(notification.copyWith(readAt: DateTime.now()).isRead, isTrue);
  });

  test('영상 통계의 일별·피크 정보를 보존한다', () {
    final stats = VideoStats.fromJson({
      'totalCount': 4,
      'byTriggerType': [
        {'name': 'LAUGHTER', 'count': 3},
      ],
      'dailyCounts': [
        {'date': '2026-07-20', 'count': 2},
      ],
      'peakWeekday': {'name': 'MONDAY', 'count': 3},
      'peakHour': {'name': '19:00', 'count': 2},
    });

    expect(stats.dailyCounts.single.count, 2);
    expect(stats.peakWeekday?.name, 'MONDAY');
    expect(stats.peakHour?.name, '19:00');
  });

  test('영상 페이지의 커서 정보를 보존한다', () {
    final page = VideoPage.fromJson({
      'items': <Object>[],
      'nextCursor': 'next',
      'hasNext': true,
    });
    expect(page.items, isEmpty);
    expect(page.nextCursor, 'next');
    expect(page.hasNext, isTrue);
  });

  test('라이브 세션의 WHEP 재생 URL을 보존한다', () {
    final session = StreamSession.fromJson({
      'sessionId': 'session-id',
      'status': 'READY',
      'heartbeatIntervalSeconds': 15,
      'whepUrl': 'https://media.example/webrtc/live/stream-id/whep?token=test',
    });

    expect(session.isReady, isTrue);
    expect(session.whepUrl, contains('/whep'));
    expect(session.whepUrl, endsWith('token=test'));
  });

  test('whepUrl이 없으면 READY라도 재생 준비로 보지 않는다', () {
    final session = StreamSession.fromJson({
      'sessionId': 'session-id',
      'status': 'READY',
      'heartbeatIntervalSeconds': 15,
    });

    expect(session.isReady, isFalse);
  });
}
