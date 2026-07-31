import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/content_calendar_screen.dart';

void main() {
  testWidgets('선택한 날짜는 한 개만 보이고 더보기로 전체 페이지를 연다', (tester) async {
    await initializeDateFormatting('ko_KR');
    final today = DateTime.now();
    final videos = List.generate(
      5,
      (index) => VideoMemory(
        id: 'video-$index',
        deviceId: 'device-1',
        triggerType: 'LAUGHTER',
        title: '추억 ${index + 1}',
        status: 'READY',
        favorite: false,
        capturedStartAt: DateTime(today.year, today.month, today.day, 9, index),
      ),
    );
    final controller = AppController()..videos = videos;

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: ContentCalendarScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('calendar-memory-more')),
      250,
      scrollable: find.byType(Scrollable).last,
    );

    expect(find.text('추억 1'), findsOneWidget);
    expect(find.text('추억 2'), findsNothing);
    expect(find.text('더보기 (4)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('calendar-memory-more')));
    await tester.pumpAndSettle();

    expect(find.text('${today.month}월 ${today.day}일의 추억'), findsOneWidget);
    expect(find.text('추억 2'), findsOneWidget);
    expect(find.text('추억 5'), findsOneWidget);
    controller.dispose();
  });
}
