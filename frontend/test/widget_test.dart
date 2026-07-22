import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/ui/auth_screen.dart';

void main() {
  testWidgets('로그인과 회원가입 화면을 전환한다', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: AuthScreen(controller: controller),
      ),
    );

    expect(find.text('오늘의 순간을\n다시 만나보세요'), findsOneWidget);
    expect(find.text('로그인'), findsOneWidget);

    await tester.tap(find.text('처음이신가요? 회원가입'));
    await tester.pumpAndSettle();

    expect(find.text('새로운 추억을\n함께 시작해요'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '이름'), findsOneWidget);
    controller.dispose();
  });
}
