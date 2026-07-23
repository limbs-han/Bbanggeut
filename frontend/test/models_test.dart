import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/models.dart';

void main() {
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
}
