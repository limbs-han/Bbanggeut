import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/laugh_report_content_screen.dart';

void main() {
  testWidgets('웃음 리포트를 복주머니 주간 요약으로 표시한다', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final today = DateUtils.dateOnly(DateTime.now());
    final controller = AppController()
      ..videos = [
        VideoMemory(
          id: 'laugh-1',
          deviceId: 'device-1',
          triggerType: 'LAUGHTER',
          title: '웃음 1',
          status: 'READY',
          favorite: false,
          capturedStartAt: today,
        ),
        VideoMemory(
          id: 'laugh-2',
          deviceId: 'device-1',
          triggerType: 'LAUGHTER',
          title: '웃음 2',
          status: 'READY',
          favorite: false,
          capturedStartAt: today,
        ),
        VideoMemory(
          id: 'laugh-and-clap',
          deviceId: 'device-1',
          triggerType: 'CLAP',
          eventTypes: const ['LAUGHTER', 'CLAP'],
          title: '웃음과 박수',
          status: 'READY',
          favorite: false,
          capturedStartAt: today,
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: LaughReportContentScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('웃음 리포트'), findsOneWidget);
    expect(find.text('가족 전체'), findsNothing);
    expect(find.text('이 기기만'), findsNothing);
    expect(find.text('이번 주 웃음 복주머니 ♥'), findsOneWidget);
    expect(find.text('웃음 횟수'), findsOneWidget);
    expect(find.text('3회'), findsOneWidget);
    expect(find.text('요일별 웃음복 ♥'), findsOneWidget);
    expect(find.text('한 줄 리포트 🍃'), findsOneWidget);
    expect(find.text('웃음 잔디'), findsNothing);
    expect(tester.takeException(), isNull);
    controller.dispose();
  });
}
