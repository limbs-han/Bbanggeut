import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/auth_screen.dart';
import 'package:william_james_app/ui/home_screen.dart';
import 'package:william_james_app/ui/local_edit_screen.dart';
import 'package:william_james_app/ui/main_shell.dart';
import 'package:william_james_app/ui/onboarding_screen.dart';
import 'package:william_james_app/ui/video_detail_screen.dart';

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
    expect(find.textContaining('다시 만나면'), findsNothing);
    expect(find.textContaining('AI가 담은 우리 가족의 웃음'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().startsWith('지나간 웃음도,\n추억이 됩니다. '),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.favorite_rounded), findsOneWidget);
    expect(
      tester.getTopLeft(find.bySemanticsLabel('빵긋 로고')).dx,
      lessThan(tester.getTopLeft(find.text('웃음이 머무는 우리 집')).dx),
    );

    final signUpButton = find.widgetWithText(OutlinedButton, '회원가입');
    await tester.ensureVisible(signUpButton);
    await tester.tap(signUpButton);
    await tester.pumpAndSettle();

    expect(find.text('웃음이 머무는 우리 집'), findsNothing);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is RichText &&
            widget.text.toPlainText().startsWith('지나간 웃음도,\n추억이 됩니다. '),
      ),
      findsNothing,
    );
    expect(find.bySemanticsLabel('빵긋 로고'), findsOneWidget);
    expect(find.bySemanticsLabel('빵긋 캐릭터'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.hintText == '가족에게 보일 이름',
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == '10자 이상 입력해 주세요',
      ),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, '회원가입 완료'), findsOneWidget);
    expect(find.textContaining('로그인 없이 둘러보기'), findsNothing);
    controller.dispose();
  });

  testWidgets('로그인 비밀번호를 기본 숨김 처리하고 간편 로그인은 표시하지 않는다', (tester) async {
    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: AuthScreen(controller: controller),
      ),
    );

    final passwordField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '비밀번호를 입력하세요',
    );
    expect(tester.widget<TextField>(passwordField).obscureText, isTrue);
    expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    expect(find.text('또는 간편 로그인'), findsNothing);
    expect(find.text('Google'), findsNothing);
    expect(find.text('카카오'), findsNothing);
    expect(find.text('Apple'), findsNothing);

    await tester.tap(find.byIcon(Icons.visibility_off_outlined));
    await tester.pump();
    expect(tester.widget<TextField>(passwordField).obscureText, isFalse);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    controller.dispose();
  });

  testWidgets('온보딩 마지막 페이지에서 건너뛰기를 숨기고 로그인 버튼을 표시한다', (tester) async {
    var finished = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: OnboardingScreen(
          onFinished: () async {
            finished = true;
          },
        ),
      ),
    );

    for (var index = 0; index < 3; index++) {
      await tester.drag(find.byType(PageView), const Offset(-500, 0));
      await tester.pumpAndSettle();
    }

    expect(find.text('매일의 웃음이 우리집 보물이 돼요'), findsOneWidget);
    expect(find.text('건너뛰기'), findsNothing);
    final loginButton = find.widgetWithText(FilledButton, '로그인하러 가기');
    expect(loginButton, findsOneWidget);
    await tester.tap(loginButton);
    await tester.pump();
    expect(finished, isTrue);
  });

  testWidgets('작은 화면에서 키보드가 열려도 로그인과 회원가입 입력칸이 보인다', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    final controller = AppController();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: AuthScreen(controller: controller),
      ),
    );

    final passwordField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '비밀번호를 입력하세요',
    );
    final loginPassword = tester.widget<TextField>(passwordField);
    expect(loginPassword.decoration?.hintStyle?.color, AppColors.muted);
    expect(loginPassword.decoration?.hintStyle?.fontSize, 13);
    await tester.tap(passwordField);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();

    expect(tester.getBottomRight(passwordField).dy, lessThanOrEqualTo(380));
    expect(tester.takeException(), isNull);

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    final signUpButton = find.widgetWithText(OutlinedButton, '회원가입');
    await tester.ensureVisible(signUpButton);
    await tester.tap(signUpButton);
    await tester.pumpAndSettle();

    final terms = find.textContaining('로그인하면 서비스 이용약관');
    expect(tester.getBottomRight(terms).dy, lessThanOrEqualTo(700));
    expect(
      tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .physics,
      isA<NeverScrollableScrollPhysics>(),
    );

    final nameField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '가족에게 보일 이름',
    );
    await tester.tap(nameField);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    await tester.pumpAndSettle();

    expect(tester.getBottomRight(nameField).dy, lessThanOrEqualTo(380));
    expect(
      tester
          .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .physics,
      isA<ClampingScrollPhysics>(),
    );
    expect(tester.takeException(), isNull);
    controller.dispose();
  });

  testWidgets('메인 화면에 다섯 개 하단 네비게이션을 표시한다', (tester) async {
    final api = _FakeApiClient();
    const device = DeviceSummary(
      id: 'test-device',
      name: '테스트 홈캠',
      model: 'test',
      status: 'ONLINE',
      myRole: 'OWNER',
      retentionDays: 30,
    );
    final controller = AppController(api: api)
      ..selectedVault = const MemoryVault(
        id: 'vault-1',
        name: '우리 집',
        status: 'ACTIVE',
        myRole: 'OWNER',
        retentionDays: 30,
        subscriptionActive: false,
        devices: [
          VaultDevice(bindingId: 'binding-1', generation: 1, device: device),
        ],
      )
      ..selectedDevice = device
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
    expect(tester.widget<NavigationBar>(navigation).selectedIndex, 2);
    expect(api.streamCreationCount, 0);
    for (final label in ['홈', '캘린더', '추억', '커뮤니티', '설정']) {
      expect(
        find.descendant(of: navigation, matching: find.text(label)),
        findsOneWidget,
      );
    }

    // 아직 펼치지 않은 탭은 세우지 않는다. 세우면 그 화면의 목록이 재생 URL을
    // 받아 원격 프레임을 뽑기 시작해, 아무도 보지 않는 탭 때문에 켜는 순간
    // 네트워크 요청이 나간다.
    //
    // `skipOffstage: false`가 핵심이다. IndexedStack은 고르지 않은 자식을 화면
    // 밖으로 두므로, 기본 검색으로는 "세워졌지만 안 보이는" 것과 "아예 세우지
    // 않은" 것이 똑같이 안 잡힌다 — 그러면 이 테스트가 아무것도 지키지 못한다.
    expect(find.text('전체 추억', skipOffstage: false), findsNothing);

    await tester.tap(
      find.descendant(of: navigation, matching: find.text('추억')),
    );
    await tester.pump();
    expect(find.text('전체 추억'), findsOneWidget);
    expect(find.text('웃음 감지'), findsOneWidget);
    expect(find.text('편집 완료'), findsOneWidget);
    expect(find.text('만화'), findsOneWidget);
    // 정렬은 버튼 하나로 접혔다 — '최신순'·'오래된 순' 글자 버튼 둘이 좁은
    // 화면에서 카테고리 칩을 밀어냈다. 지금 값은 계속 보인다.
    expect(find.byKey(const ValueKey('memory-sort-button')), findsOneWidget);
    expect(find.text('최신'), findsOneWidget);

    // 한 번 펼친 탭은 다른 탭으로 옮겨도 남아 있다 — 스크롤 위치와 상태를
    // 지키려고 IndexedStack을 쓰는 것이므로 그 성질은 그대로여야 한다.
    await tester.tap(find.descendant(of: navigation, matching: find.text('홈')));
    await tester.pump();
    expect(
      find.text('전체 추억', skipOffstage: false),
      findsOneWidget,
      reason: '펼친 탭이 사라지면 되돌아올 때 스크롤 위치가 초기화된다',
    );
    controller.dispose();
  });

  // 탭 위젯 캐시(보고 있는 탭만 새로 세운다)와 라우트 감시(덮이면 실시간을
  // 멈춘다)는 서로 다른 브랜치에서 왔다. 캐시가 낡은 `isActive`를 붙들고 있으면
  // 덮인 홈이 계속 스트리밍하는데, 화면상으로는 아무 표시도 나지 않는다.
  testWidgets('상세 화면이 홈을 덮는 동안 실시간을 멈추고 돌아오면 다시 켠다', (tester) async {
    final controller = AppController(api: _FakeApiClient());
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [mainShellRouteObserver],
        theme: buildTheme(),
        home: MainShell(controller: controller),
      ),
    );

    bool homeIsActive() => tester
        .widget<HomeScreen>(find.byType(HomeScreen, skipOffstage: false))
        .isActive;
    expect(homeIsActive(), isTrue);

    unawaited(
      navigatorKey.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('상세'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(homeIsActive(), isFalse, reason: '덮인 홈이 계속 스트리밍하면 대역폭을 먹는다');

    // 덮여 있는 동안 컨트롤러가 알려도 다시 켜지면 안 된다 — 캐시가 아니라
    // 실제 상태를 보고 그리는지 확인한다.
    controller.notifyListeners();
    await tester.pump();
    expect(homeIsActive(), isFalse);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(homeIsActive(), isTrue, reason: '돌아왔는데 실시간이 꺼져 있으면 검은 화면이다');
    controller.dispose();
  });

  testWidgets('다른 탭에서 뒤로가기를 누르면 앱을 나가지 않고 홈으로 돌아온다', (tester) async {
    final controller = AppController(api: _FakeApiClient());
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MainShell(controller: controller),
      ),
    );

    final navigation = find.byKey(const ValueKey('main-bottom-navigation'));
    int selectedTab() => tester.widget<NavigationBar>(navigation).selectedIndex;

    for (final tab in ['캘린더', '추억', '커뮤니티', '설정']) {
      await tester.tap(
        find.descendant(of: navigation, matching: find.text(tab)),
      );
      await tester.pumpAndSettle();
      expect(selectedTab(), isNot(2), reason: '$tab 탭으로 옮겨지지 않았다');

      // 시스템 뒤로가기. 가로채지 않으면 여기서 앱이 그대로 닫힌다.
      final popped = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(popped, isTrue, reason: '$tab 탭에서 뒤로가기가 앱을 닫았다');
      expect(selectedTab(), 2, reason: '$tab 탭에서 뒤로가기가 홈으로 오지 않았다');
    }

    // 홈에서는 가로채지 않는다 — 뒤로가기로 앱을 나가는 것은 기본 기대다.
    expect(await tester.binding.handlePopRoute(), isFalse);
    controller.dispose();
  });

  testWidgets('연결 기기가 없어도 추억 금고와 과거 영상을 표시한다', (tester) async {
    final controller = AppController(api: _FakeApiClient())
      ..selectedVault = const MemoryVault(
        id: 'vault-archive',
        name: '우리 집 추억',
        status: 'ACTIVE',
        myRole: 'OWNER',
        retentionDays: 30,
        subscriptionActive: false,
        devices: [],
      )
      ..videos = const [
        VideoMemory(
          id: 'memory-1',
          deviceId: 'old-device',
          triggerType: 'LAUGHTER',
          title: '기기 해제 전 추억',
          status: 'READY',
          favorite: false,
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: MainShell(controller: controller),
      ),
    );

    expect(
      find.byKey(const ValueKey('main-bottom-navigation')),
      findsOneWidget,
    );
    expect(find.text('연결된 기기가 없습니다'), findsWidgets);
    expect(find.text('기기 연결하기'), findsOneWidget);

    await tester.tap(find.text('추억'));
    await tester.pumpAndSettle();

    expect(find.text('기기 해제 전 추억'), findsOneWidget);
    controller.dispose();
  });

  testWidgets('영상 편집하기 버튼으로 편집 화면을 연다', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = AppController(api: _FakeApiClient());
    const video = VideoMemory(
      id: 'test-video',
      deviceId: 'test-device',
      triggerType: 'SMILE',
      title: '저녁 식사 웃음',
      status: 'PROCESSING',
      favorite: false,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: VideoDetailScreen(controller: controller, video: video),
      ),
    );
    await tester.pumpAndSettle();

    // 만화 버튼이 죽은 화면(_LegacyVideoDetailScreen)에 들어가면 빌드도 되고 위젯
    // 테스트도 통과하면서 실제 앱에는 안 보인다 — 실제로 그렇게 넣었던 적이 있다.
    // 실제로 뜨는 화면에 있는지, PROCESSING에서 잠기는지를 여기서 함께 잡는다.
    final comicButton = find.byKey(const ValueKey('open-comic'));
    expect(comicButton, findsOneWidget);
    expect(
      tester.widget<ButtonStyleButton>(comicButton).onPressed,
      isNull,
      reason: '전사문이 없으니 PROCESSING에서는 누를 수 없어야 한다',
    );

    expect(find.text('오늘의 추억  🌱'), findsOneWidget);
    expect(find.text('갤러리에 저장'), findsOneWidget);

    // 메모 기능은 걷어냈다. 되살아나면 여기서 잡힌다.
    // (마스코트 그림은 메모 상자에 붙어 있던 장식이라 함께 사라졌다 —
    //  그래서 이 화면에 Image가 있는지 보던 단정도 뺐다.)
    expect(find.text('등록된 메모가 없습니다'), findsNothing);
    expect(find.text('메모를 남겨보세요!'), findsNothing);

    // 이 컨트롤러는 금고를 소유하지 않는다 — 원본 영상의 제목은 OWNER만
    // 바꾸므로 수정 버튼이 보이지 않아야 한다.
    expect(find.byTooltip('제목 수정'), findsNothing);

    final editButton = find.widgetWithText(FilledButton, '영상 편집하기');
    await tester.ensureVisible(editButton);
    await tester.tap(editButton);
    await tester.pumpAndSettle();

    expect(find.byType(LocalEditScreen), findsOneWidget);
    controller.dispose();
  });
}

class _FakeApiClient extends ApiClient {
  int streamCreationCount = 0;
  static const failedStream = StreamSession(
    id: 'test-stream',
    status: 'FAILED',
    heartbeatIntervalSeconds: 15,
    failureCode: '테스트에서는 라이브를 연결하지 않아요.',
  );

  @override
  Future<StreamSession> createStream(String deviceId) async {
    streamCreationCount++;
    return failedStream;
  }

  @override
  Future<StreamSession> getStream(String id) async => failedStream;

  @override
  Future<void> heartbeatStream(String id) async {}

  @override
  Future<void> closeStream(String id) async {}

  @override
  Future<SignedUrl> createDownloadUrl(String id) async =>
      throw StateError('테스트에서는 영상을 내려받지 않아요.');

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
