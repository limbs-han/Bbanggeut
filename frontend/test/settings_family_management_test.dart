import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/settings_screen.dart';

void main() {
  testWidgets('설정에서 가족 구성원과 초대 카드를 직접 표시한다', (tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const device = DeviceSummary(
      id: 'device-1',
      name: '거실 카메라',
      model: 'Jetson-Orin-Nano',
      status: 'ONLINE',
      myRole: 'OWNER',
      retentionDays: 30,
    );
    const vault = MemoryVault(
      id: 'vault-1',
      name: '우리 가족',
      status: 'ACTIVE',
      myRole: 'OWNER',
      retentionDays: 30,
      subscriptionActive: false,
      devices: [
        VaultDevice(bindingId: 'binding-1', generation: 1, device: device),
      ],
    );
    final controller = AppController()
      ..user = const UserProfile(
        id: 'owner-1',
        email: 'owner@example.com',
        displayName: '소유자',
      )
      ..vaults = const [vault]
      ..selectedVault = vault
      ..devices = const [device]
      ..selectedDevice = device
      ..members = const [
        DeviceMember(
          id: 'membership-1',
          user: UserProfile(
            id: 'owner-1',
            email: 'owner@example.com',
            displayName: '소유자',
          ),
          role: 'OWNER',
          status: 'ACTIVE',
        ),
      ];
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SettingsScreen(controller: controller),
      ),
    );
    await tester.pump();

    expect(find.text('가족 구성원 1명'), findsOneWidget);
    expect(find.text('owner@example.com'), findsNWidgets(2));
    expect(find.text('함께할 가족을 초대해요'), findsOneWidget);
    expect(
      find.byKey(const Key('settings-family-invite-email')),
      findsOneWidget,
    );

    final familyTop = tester.getTopLeft(find.text('가족 구성원 1명')).dy;
    final notificationLabels = find.text('알림 설정').evaluate().toList();
    expect(notificationLabels, hasLength(2));
    for (final label in notificationLabels) {
      expect(
        tester.getTopLeft(find.byWidget(label.widget)).dy,
        greaterThan(familyTop),
      );
    }
    expect(tester.takeException(), isNull);
  });
}
