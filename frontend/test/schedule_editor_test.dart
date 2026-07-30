import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/ui/content_state.dart';
import 'package:william_james_app/ui/schedule_editor_screen.dart';

void main() {
  testWidgets('선택한 이모지를 일정 데이터에 저장한다', (tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = ContentState.instance;
    for (final schedule in [...state.schedules]) {
      state.removeSchedule(schedule.id);
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: ScheduleEditorScreen(
          initialDate: DateTime(2026, 7, 28),
          state: state,
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('schedule-title-field')),
      '가족 생일',
    );
    await tester.tap(find.byKey(const ValueKey('schedule-emoji-🎂')));
    await tester.tap(find.text('저장'));
    await tester.pump();

    expect(state.schedules, hasLength(1));
    expect(state.schedules.single.title, '가족 생일');
    expect(state.schedules.single.emoji, '🎂');
    expect(state.schedules.single.date, DateTime(2026, 7, 28));
  });
}
