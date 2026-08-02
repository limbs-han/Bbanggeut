import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/device_registration_screen.dart';
import 'package:william_james_app/ui/no_device_screens.dart';
import 'package:william_james_app/ui/password_change_screen.dart';

void main() {
  testWidgets('기기가 없는 설정에는 필요한 계정 메뉴만 표시한다', (tester) async {
    final controller = AppController()
      ..authenticated = true
      ..user = const UserProfile(
        id: 'user-1',
        email: 'owner@example.com',
        displayName: 'Demo Owner',
      )
      ..devices = const []
      ..selectedDevice = null;
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: NoDeviceSettingsScreen(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.text('Demo Owner'), findsOneWidget);
    expect(find.text('owner@example.com'), findsOneWidget);
    expect(find.text('새 기기 연결'), findsOneWidget);
    expect(find.text('비밀번호 변경'), findsOneWidget);
    expect(find.text('로그아웃'), findsOneWidget);
    expect(find.text('웃음 리포트'), findsNothing);
  });

  testWidgets('기기가 없는 설정에서 연결 및 비밀번호 화면으로 이동한다', (tester) async {
    final controller = AppController()
      ..authenticated = true
      ..user = const UserProfile(
        id: 'user-1',
        email: 'owner@example.com',
        displayName: 'Demo Owner',
      );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: NoDeviceSettingsScreen(controller: controller),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('no-device-connect')));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceRegistrationScreen), findsOneWidget);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('비밀번호 변경'));
    await tester.pumpAndSettle();
    expect(find.byType(PasswordChangeScreen), findsOneWidget);
  });
}
