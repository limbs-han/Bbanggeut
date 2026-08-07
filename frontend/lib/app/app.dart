import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/push_notification_service.dart';
import '../ui/auth_screen.dart';
import '../ui/content_notifications_screen.dart';
import '../ui/device_registration_screen.dart';
import '../ui/main_shell.dart';
import '../ui/notification_routing.dart';
import '../ui/onboarding_screen.dart';
import '../ui/widgets.dart';
import 'app_controller.dart';
import 'app_theme.dart';

class WilliamJamesApp extends StatefulWidget {
  const WilliamJamesApp({super.key});
  @override
  State<WilliamJamesApp> createState() => _WilliamJamesAppState();
}

class _WilliamJamesAppState extends State<WilliamJamesApp> {
  static const _storage = FlutterSecureStorage();
  static const _onboardingKey = 'bbanggeut_onboarding_v4';
  late final AppController controller;
  late final AppLinks appLinks;
  final navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<Uri>? linkSubscription;
  StreamSubscription<PushMessageData>? openedPushSubscription;
  PushMessageData? pendingPush;
  bool handlingPush = false;
  bool? onboardingSeen;

  @override
  void initState() {
    super.initState();
    controller = AppController(
      pushNotifications: PushNotificationService.shared,
    );
    controller.addListener(_handleControllerState);
    unawaited(controller.initialize());
    appLinks = AppLinks();
    // 앱이 떠 있을 때 온 알림도 휴대폰 알림 표시줄에 뜬다
    // (`PushNotificationService._showSystemNotification`). 그래서 여기서는
    // 도착이 아니라 '눌렀을 때'만 듣는다 — 앱을 켜 두고 있었든 아니든 같은
    // 경로로 들어온다.
    openedPushSubscription = PushNotificationService.shared.openedMessages
        .listen(_queuePushNavigation);
    final initialPush = PushNotificationService.shared.takeInitialMessage();
    if (initialPush != null) pendingPush = initialPush;
    _listenForMembershipRequests();
    _loadOnboarding();
  }

  void _handleControllerState() {
    if (controller.authenticated && pendingPush != null && !handlingPush) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_openPendingPush()),
      );
    }
  }

  void _queuePushNavigation(PushMessageData message) {
    pendingPush = message;
    _handleControllerState();
  }

  Future<void> _openPendingPush() async {
    final message = pendingPush;
    final navigator = navigatorKey.currentState;
    if (message == null ||
        navigator == null ||
        !controller.authenticated ||
        handlingPush) {
      return;
    }
    handlingPush = true;
    pendingPush = null;
    try {
      if (message.type == 'LAUGHTER_VIDEO_READY') {
        // 새 영상이 저장됐다는 알림이다. 홈의 '오늘의 웃음'과 '최근 저장된
        // 추억'이 그 영상을 아직 모르므로 함께 새로 받는다 — 상세를 닫고
        // 돌아왔을 때 방금 본 영상이 목록에 없으면 사라진 것처럼 보인다.
        // 화면 전환을 붙잡지 않게 기다리지 않는다.
        unawaited(controller.refreshHome(force: true));
      }
      // 목적지 결정은 알림함과 같은 곳에서 한다. 갈라져 있던 동안 `AI 분석이
      // 끝났어요`를 알림함에서 누르면 그 영상 상세가 열리는데 푸시로 누르면
      // 알림함만 열려, 사용자가 목록에서 같은 알림을 한 번 더 찾아 눌러야 했다.
      // 만화 완성·대사 준비·편집본 댓글도 같은 구멍에 빠져 있었다.
      await openNotificationTarget(
        navigator.context,
        controller: controller,
        type: message.type,
        resourceId: message.resourceId,
        // 푸시로 들어온 길에는 탭을 바꿔 줄 수단이 없다. 갈 곳을 모르는
        // 알림은 알림함으로 보낸다 — 아무 일도 일어나지 않는 것보다 낫다.
        onOpenDevices: () => unawaited(
          navigator.push<void>(
            MaterialPageRoute(
              builder: (_) => ContentNotificationsScreen(controller: controller),
            ),
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      await navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => ContentNotificationsScreen(controller: controller),
        ),
      );
    } finally {
      handlingPush = false;
      if (pendingPush != null) _handleControllerState();
    }
  }

  Future<void> _loadOnboarding() async {
    try {
      final value = await _storage.read(key: _onboardingKey);
      if (mounted) setState(() => onboardingSeen = value == 'seen');
    } catch (_) {
      if (mounted) setState(() => onboardingSeen = false);
    }
  }

  Future<void> _finishOnboarding() async {
    try {
      await _storage.write(key: _onboardingKey, value: 'seen');
    } catch (_) {
      // 저장소를 사용할 수 없어도 현재 실행에서는 계속 진행한다.
    }
    if (mounted) setState(() => onboardingSeen = true);
  }

  Future<void> _listenForMembershipRequests() async {
    try {
      final initial = await appLinks.getInitialLink();
      if (initial != null) {
        await controller.setMembershipRequestLink(initial);
      }
      linkSubscription = appLinks.uriLinkStream.listen(
        controller.setMembershipRequestLink,
        onError: (_) {
          // 잘못된 외부 링크는 현재 화면을 유지하고 무시한다.
        },
      );
    } catch (_) {
      // 딥링크 플러그인을 사용할 수 없는 환경에서도 앱 실행은 계속한다.
    }
  }

  @override
  void dispose() {
    linkSubscription?.cancel();
    openedPushSubscription?.cancel();
    controller.removeListener(_handleControllerState);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigatorKey,
    // 홈 위로 다른 화면이 덮이면 실시간 스트리밍을 멈추기 위한 관찰자.
    navigatorObservers: [mainShellRouteObserver],
    title: '빵긋',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    // 화면 대부분이 고정 px 치수로 짜여 있어 아주 큰 시스템 글자 배율에서는
    // 글자가 잘린다. 1.3배까지는 기기 설정을 그대로 따르고 그 위만 묶는다 —
    // 가족이 함께 쓰는 앱이라 큰 글씨 수요를 아예 막지는 않는다. 개별 화면이
    // 더 좁으면 그 화면에서 다시 조인다(예: 홈의 '오늘의 기록' 카드).
    builder: (context, child) => MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: child!,
    ),
    home: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.initialized || onboardingSeen == null) {
          return const _SplashScreen();
        }
        if (onboardingSeen == false) {
          return OnboardingScreen(onFinished: _finishOnboarding);
        }
        if (!controller.authenticated) {
          return AuthScreen(controller: controller);
        }
        if (controller.requiresInitialDeviceRegistration) {
          return DeviceRegistrationScreen(
            controller: controller,
            canGoBack: false,
          );
        }
        return MainShell(controller: controller);
      },
    ),
  );
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();
  @override
  Widget build(BuildContext context) => Scaffold(
    body: DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment.topLeft,
          radius: 1.4,
          colors: [Color(0xFFFFEEDC), AppColors.cream],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 240,
              height: 90,
              child: Image.asset(
                'assets/images/bbanggeut_logo.png',
                fit: BoxFit.cover,
                alignment: Alignment.center,
                cacheWidth: decodePixels(context, 240),
                semanticLabel: '빵긋 로딩 로고',
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              '지나간 웃음도,\n다시 만나면 추억이 됩니다.',
              textAlign: TextAlign.center,
              style: TextStyle(
                height: 1.6,
                fontWeight: FontWeight.w700,
                color: AppColors.inkSoft,
              ),
            ),
            const SizedBox(height: 34),
            const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ],
        ),
      ),
    ),
  );
}
