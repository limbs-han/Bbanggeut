import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/ui/content_calendar_screen.dart';
import 'package:william_james_app/ui/content_state.dart';

void main() {
  testWidgets('선택한 일정 이미지 에셋을 달력과 일정 목록에 표시한다', (tester) async {
    await initializeDateFormatting('ko_KR');
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final today = DateTime.now();
    final state = ContentState();
    await state.saveSchedule(
      CalendarSchedule(
        id: 'schedule-house',
        title: '우리 집 기념일',
        date: DateTime(today.year, today.month, today.day),
        emoji: '🏠',
      ),
      isNew: true,
    );
    final controller = AppController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: ContentCalendarScreen(
            controller: controller,
            contentState: state,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('schedule-emoji-image-🏠')),
      findsAtLeastNWidgets(2),
    );
    expect(find.text('우리 집 기념일 · D-Day'), findsOneWidget);
  });
}
