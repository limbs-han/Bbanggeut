import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/profile_edit_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('프로필 수정에서 기본 캐릭터 9종을 선택할 수 있다', (tester) async {
    final controller = AppController()
      ..user = const UserProfile(
        id: 'user-1',
        email: 'user@example.com',
        displayName: '공계',
      );

    await tester.pumpWidget(
      MaterialApp(home: ProfileEditScreen(controller: controller)),
    );
    await tester.pumpAndSettle();

    expect(find.text('프로필 수정'), findsOneWidget);
    expect(find.text('공계'), findsOneWidget);
    expect(find.byKey(const Key('profile-email')), findsOneWidget);
    expect(find.text('user@example.com'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);

    await tester.tap(find.byKey(const Key('profile-avatar-change')));
    await tester.pumpAndSettle();
    expect(find.text('휴대폰 사진에서 선택'), findsOneWidget);
    expect(find.text('기본 이미지 선택'), findsOneWidget);

    await tester.tap(find.text('기본 이미지 선택'));
    await tester.pumpAndSettle();

    for (var index = 0; index < 9; index++) {
      expect(find.byKey(Key('profile-avatar-$index')), findsOneWidget);
    }

    await tester.tap(find.byKey(const Key('profile-avatar-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('profile-save')), findsOneWidget);
  });
}
