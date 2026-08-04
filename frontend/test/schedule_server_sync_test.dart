import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/content_state.dart';
import 'package:william_james_app/ui/laugh_report_content_screen.dart';

class _FakeScheduleApi extends ApiClient {
  final List<CalendarSchedule> stored = [];
  int nextId = 1;
  String? deletedId;

  @override
  Future<List<CalendarSchedule>> listSchedules() async => List.of(stored);

  @override
  Future<CalendarSchedule> createSchedule(CalendarSchedule schedule) async {
    final saved = schedule.copyWith(id: 'server-${nextId++}');
    stored.add(saved);
    return saved;
  }

  @override
  Future<CalendarSchedule> updateSchedule(CalendarSchedule schedule) async {
    final index = stored.indexWhere((item) => item.id == schedule.id);
    if (index >= 0) stored[index] = schedule;
    return schedule;
  }

  @override
  Future<void> deleteSchedule(String scheduleId) async {
    deletedId = scheduleId;
    stored.removeWhere((item) => item.id == scheduleId);
  }
}

class _FakeStatsApi extends ApiClient {
  @override
  Future<EventStats> getEventStats(
    String deviceId, {
    DateTime? from,
    DateTime? to,
    String? type,
  }) async {
    final today = DateUtils.dateOnly(DateTime.now());
    return EventStats(
      detectedCount: 5,
      uploadedVideoCount: 5,
      byType: const {'LAUGHTER': 5},
      dailyCounts: [DailyVideoCount(date: today, count: 5)],
    );
  }
}

void main() {
  test('일정 저장은 서버가 발급한 id를 채택하고 삭제는 서버에도 반영한다', () async {
    final api = _FakeScheduleApi();
    final state = ContentState(api);

    final saved = await state.saveSchedule(
      CalendarSchedule(id: 'temp-1', title: '생일', date: DateTime(2026, 9, 1)),
      isNew: true,
    );

    expect(saved.id, 'server-1');
    expect(state.schedules.single.id, 'server-1');

    await state.removeSchedule('server-1');
    expect(api.deletedId, 'server-1');
    expect(state.schedules, isEmpty);
  });

  test('서버 목록은 최초 1회만 불러온다', () async {
    final api = _FakeScheduleApi()
      ..stored.add(
        CalendarSchedule(id: 's-1', title: '기념일', date: DateTime(2026, 5, 2)),
      );
    final state = ContentState();

    await state.ensureLoaded(api);
    expect(state.schedules.single.id, 's-1');

    api.stored.clear();
    await state.ensureLoaded(api);
    expect(state.schedules, hasLength(1), reason: '이미 불러왔으면 다시 요청하지 않는다');
  });

  testWidgets('웃음 리포트가 서버 일별 집계(type=LAUGHTER)를 표시한다', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController(api: _FakeStatsApi())
      ..selectedDevice = const DeviceSummary(
        id: 'device-1',
        name: '거실 홈캠',
        model: 'WJ-CAM',
        status: 'ONLINE',
        myRole: 'OWNER',
        retentionDays: 30,
      );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: LaughReportContentScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('웃음 횟수'), findsOneWidget);
    expect(find.text('5회'), findsOneWidget);
    controller.dispose();
  });
}
