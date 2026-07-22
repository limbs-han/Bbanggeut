import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/auth_screen.dart';
import 'package:william_james_app/ui/main_shell.dart';

void main() {
  setUpAll(() => initializeDateFormatting('ko'));

  testWidgets('로그인과 회원가입 화면을 전환한다', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: AuthScreen(controller: controller),
      ),
    );

    expect(find.widgetWithText(FilledButton, '로그인'), findsOneWidget);

    final signUpButton = find.widgetWithText(OutlinedButton, '회원가입');
    await tester.ensureVisible(signUpButton);
    await tester.tap(signUpButton);
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '가족에게 보일 이름',
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, '회원가입 완료'), findsOneWidget);
    expect(find.textContaining('로그인 없이 둘러보기'), findsNothing);
    controller.dispose();
  });

  testWidgets('메인 화면에 다섯 개 하단 네비게이션을 표시한다', (tester) async {
    final controller = AppController(api: _FakeApiClient())
      ..selectedDevice = const DeviceSummary(
        id: 'test-device',
        name: '테스트 홈캠',
        model: 'test',
        status: 'ONLINE',
        myRole: 'OWNER',
        retentionDays: 30,
      )
      ..deviceStatus = const DeviceStatus(
        status: 'ONLINE',
        recording: true,
        uploadQueueDepth: 0,
      );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MainShell(controller: controller),
      ),
    );

    final navigation = find.byKey(const ValueKey('main-bottom-navigation'));
    expect(navigation, findsOneWidget);
    for (final label in ['홈', '캘린더', '추억', '가족', '설정']) {
      expect(
        find.descendant(of: navigation, matching: find.text(label)),
        findsOneWidget,
      );
    }

    await tester.tap(
      find.descendant(of: navigation, matching: find.text('추억')),
    );
    await tester.pump();
    expect(find.text('전체 추억'), findsOneWidget);
    expect(find.text('홈캠'), findsOneWidget);
    expect(find.text('웃음 감지'), findsOneWidget);
    expect(find.text('편집 완료'), findsOneWidget);
    expect(find.text('최신순'), findsOneWidget);
    controller.dispose();
  });
}

class _FakeApiClient extends ApiClient {
  @override
  Future<VideoPage> listVideos(
    String deviceId, {
    String? triggerType,
    String? cursor,
    DateTime? from,
    DateTime? to,
    int size = 30,
  }) async => const VideoPage(items: [], hasNext: false);
}
