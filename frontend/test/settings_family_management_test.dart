import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/settings_screen.dart';

void main() {
  // 구성원 카드가 넘치는지는 글자 폭에 달려 있다. 위젯 테스트는 번들 폰트를
  // 자동으로 싣지 않으므로, 실제 폰트를 심어야 기기와 같은 폭으로 잰다.
  setUpAll(() async {
    final loader = FontLoader('NotoSansKR')
      ..addFont(rootBundle.load('assets/fonts/NotoSansKR-VF.ttf'));
    await loader.load();
  });

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
    expect(find.text('받은 초대함'), findsNothing);
    expect(find.byKey(const Key('settings-owner-crown')), findsOneWidget);
    expect(find.text('👑'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is AssetImage &&
            (widget.image as AssetImage).assetName ==
                'assets/images/family_invite_ribbon.png',
      ),
      findsNothing,
    );
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

  /// 구성원이 셋이면 카드 폭은 화면 폭의 3분의 1이 된다. 그 폭에서 OWNER 배지와
  /// 왕관이 카드보다 넓어져 실제 갤럭시 S24+에서 0.172px 넘쳤다. 개발용
  /// 에뮬레이터는 논리 폭이 480dp로 더 넓어 이 폭에서만 드러난다.
  testWidgets('S24+ 폭에서 구성원 카드 셋과 OWNER 배지가 넘치지 않는다', (tester) async {
    // 갤럭시 S24+ 논리 폭. 세로는 설정 화면 전체가 한 번에 들어가도록 넉넉히 둔다.
    tester.view.physicalSize = const Size(411, 2600);
    tester.view.devicePixelRatio = 1;
    // 앱이 허용하는 가장 큰 글자 배율(WilliamJamesApp의 상한과 같은 값). 배지는
    // 고정 크기가 아니라 글자를 담고 있어 배율이 오르면 함께 넓어진다.
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

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
        email: 'e201@example.com',
        displayName: '공계',
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
            email: 'e201@example.com',
            displayName: '공계',
          ),
          role: 'OWNER',
          status: 'ACTIVE',
        ),
        DeviceMember(
          id: 'membership-2',
          user: UserProfile(
            id: 'member-1',
            email: 'cksgud@example.com',
            displayName: '박찬형',
          ),
          role: 'MEMBER',
          status: 'ACTIVE',
        ),
        DeviceMember(
          id: 'membership-3',
          user: UserProfile(
            id: 'member-2',
            email: 'jihan@example.com',
            displayName: '사지한',
          ),
          role: 'MEMBER',
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

    expect(find.text('가족 구성원 3명'), findsOneWidget);
    expect(find.byKey(const Key('settings-owner-crown')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
