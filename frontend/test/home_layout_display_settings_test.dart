/// 홈 화면이 기기 표시 설정(글자 크기·화면 크기)을 바꿔도 넘치거나 잘리지
/// 않는지 본다.
///
/// **왜 따로 두는가**: 실제 갤럭시 S24+에서 라이브 카드가 0.209px 넘치고
/// '오늘의 웃음'이 '오늘의 웃'으로 잘렸다. 두 증상은 원인이 다르다 — 넘침은
/// 화면 크기를 키워 논리 폭이 좁아질 때 나고, 잘림은 글자 배율이 오를 때 난다.
/// 기본 크기 한 번만 재면 둘 다 놓친다. 실제로 라이브 카드의 비율을 S24+ 기본
/// 폭에 맞춰 1.34로 손보고도 화면 크기를 키우면 다시 넘쳤다.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/home_screen.dart';

/// 갤럭시 S24+ 기본 논리 크기.
const _s24 = Size(411, 891);

/// 화면 크기를 키운 S24+. 같은 기기라도 논리 폭이 이만큼 줄어든다.
const _s24Zoomed = Size(360, 780);

/// 라벨이 잘리면 안 되는 '오늘의 기록' 카드의 글자들.
const _recordLabels = ['오늘의 웃음', '즐겨찾는 영상', '웃음 리포트'];

void main() {
  // 위젯 테스트는 번들 폰트를 자동으로 싣지 않는다. 기본 테스트 폰트는 글자 폭이
  // 실제와 달라 있지도 않은 넘침을 만들거나 있는 넘침을 가린다. 앱이 실제로 쓰는
  // 폰트를 심어야 이 측정이 기기와 같은 이야기를 한다.
  setUpAll(() async {
    final loader = FontLoader('NotoSansKR')
      ..addFont(rootBundle.load('assets/fonts/NotoSansKR-VF.ttf'));
    await loader.load();
  });

  const cases = <({String name, Size size, double textScale})>[
    (name: '기본', size: _s24, textScale: 1),
    (name: '화면 크기 크게', size: _s24Zoomed, textScale: 1),
    (name: '글자 크게', size: _s24, textScale: 1.5),
    (name: '화면과 글자 모두 크게', size: _s24Zoomed, textScale: 1.5),
  ];

  for (final testCase in cases) {
    testWidgets('${testCase.name} 설정에서 홈 화면이 넘치지 않는다', (tester) async {
      await _pumpHome(
        tester,
        size: testCase.size,
        textScale: testCase.textScale,
      );

      // 넘침은 예외로 올라온다. 라이브 카드의 소수점 오버플로가 여기서 걸린다.
      expect(tester.takeException(), isNull);
    });

    testWidgets('${testCase.name} 설정에서 오늘의 기록 라벨이 잘리지 않는다', (tester) async {
      await _pumpHome(
        tester,
        size: testCase.size,
        textScale: testCase.textScale,
      );

      for (final label in _recordLabels) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(label),
        );
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: '$label이 한 줄에 들어가지 못해 잘렸다',
        );
      }
    });
  }
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required Size size,
  required double textScale,
}) async {
  const devicePixelRatio = 3.0;
  tester.view.devicePixelRatio = devicePixelRatio;
  tester.view.physicalSize = size * devicePixelRatio;
  // 기기 글자 크기 설정과 같은 경로로 배율을 준다. 화면 안에서 MediaQuery를
  // 덮어써도 MaterialApp이 창 값으로 다시 만들기 때문에 여기서 넣어야 한다.
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(() {
    tester.view.reset();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });

  final vault = _vault();
  final controller = AppController()
    ..authenticated = true
    ..vaults = [vault]
    ..selectedVault = vault
    ..devices = const [_device]
    ..selectedDevice = _device
    ..deviceStatus = const DeviceStatus(
      status: 'ONLINE',
      recording: true,
      uploadQueueDepth: 0,
    )
    ..homeSummary = const HomeSummary(
      captureCount: 133,
      savedCount: 12,
      memoCount: 0,
    )
    ..videoStats = const VideoStats(totalCount: 205, byTriggerType: {});
  addTearDown(controller.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(),
      // 실제 앱(WilliamJamesApp)의 builder와 같은 상한을 둔다. 앱이 1.3배까지만
      // 그리므로 그보다 큰 배율을 그대로 재면 실제로 존재하지 않는 화면을 재는
      // 셈이 된다. 대신 상한이 사라지면 이 테스트가 먼저 깨진다.
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: child!,
      ),
      home: Scaffold(
        body: HomeScreen(
          controller: controller,
          isActive: false,
          openVideos: () {},
          openCalendar: () {},
        ),
      ),
    ),
  );
  await tester.pump();
}

const _device = DeviceSummary(
  id: 'device-1',
  name: '거실',
  model: 'test',
  status: 'ONLINE',
  myRole: 'OWNER',
  retentionDays: 30,
);

MemoryVault _vault() => MemoryVault(
  id: 'vault-1',
  name: '우리 집',
  status: 'ACTIVE',
  myRole: 'OWNER',
  retentionDays: 30,
  subscriptionActive: false,
  devices: const [
    VaultDevice(bindingId: 'binding-1', generation: 1, device: _device),
  ],
);
