import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:william_james_app/app/app_controller.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/banuba_video_editor.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/ui/auth_screen.dart';
import 'package:william_james_app/ui/local_edit_screen.dart';
import 'package:william_james_app/ui/main_shell.dart';
import 'package:william_james_app/ui/video_detail_screen.dart';

void main() {
  setUpAll(() => initializeDateFormatting('ko'));

  testWidgets('로컬 Banuba 토큰 설정을 자동으로 불러온다', (tester) async {
    expect(await BanubaVideoEditor().isConfigured, isTrue);
  });

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

    final editButton = find.widgetWithText(FilledButton, '영상 편집하기');
    await tester.ensureVisible(editButton);
    await tester.tap(editButton);
    await tester.pumpAndSettle();

    expect(find.byType(LocalEditScreen), findsOneWidget);
    expect(find.text('편집'), findsOneWidget);
    controller.dispose();
  });
}

class _FakeApiClient extends ApiClient {
  static const failedStream = StreamSession(
    id: 'test-stream',
    status: 'FAILED',
    heartbeatIntervalSeconds: 15,
    failureCode: '테스트에서는 라이브를 연결하지 않아요.',
  );

  @override
  Future<StreamSession> createStream(String deviceId) async => failedStream;

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
