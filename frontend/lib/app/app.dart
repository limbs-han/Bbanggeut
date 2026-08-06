import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/notification_visuals.dart';
import '../core/push_notification_service.dart';
import '../ui/auth_screen.dart';
import '../ui/content_calendar_screen.dart';
import '../ui/content_notifications_screen.dart';
import '../ui/device_registration_screen.dart';
import '../ui/invitation_inbox_screen.dart';
import '../ui/laugh_report_content_screen.dart';
import '../ui/main_shell.dart';
import '../ui/onboarding_screen.dart';
import '../ui/video_detail_screen.dart';
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
  StreamSubscription<PushMessageData>? foregroundPushSubscription;
  StreamSubscription<PushMessageData>? openedPushSubscription;
  OverlayEntry? pushBanner;
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
    foregroundPushSubscription = PushNotificationService
        .shared
        .foregroundMessages
        .listen(_showPushBanner);
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
    pushBanner?.remove();
    pushBanner = null;
    try {
      if (message.type == 'LAUGHTER_VIDEO_READY' &&
          message.resourceId != null) {
        // 새 웃음이 저장됐다는 알림이다. 홈의 '오늘의 웃음'과 '최근 저장된
        // 추억'이 그 영상을 아직 모르므로 함께 새로 받는다 — 상세를 닫고
        // 돌아왔을 때 방금 본 영상이 목록에 없으면 사라진 것처럼 보인다.
        // 화면 전환을 붙잡지 않게 기다리지 않는다.
        unawaited(controller.refreshHome(force: true));
        final video = await controller.api.getVideo(message.resourceId!);
        if (!mounted) return;
        await navigator.push<void>(
          MaterialPageRoute(
            builder: (_) =>
                VideoDetailScreen(controller: controller, video: video),
          ),
        );
      } else if (message.type == 'ANNIVERSARY') {
        // 기념일 푸시는 그 일정이 있는 캘린더로 보낸다.
        await navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => ContentCalendarScreen(controller: controller),
          ),
        );
      } else if (message.type == 'WEEKLY_REPORT') {
        await navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => LaughReportContentScreen(controller: controller),
          ),
        );
      } else if (message.type == 'INVITATION_RECEIVED') {
        await controller.refreshMyInvitations();
        if (!mounted) return;
        await navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => InvitationInboxScreen(controller: controller),
          ),
        );
      } else {
        await navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => ContentNotificationsScreen(controller: controller),
          ),
        );
      }
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

  void _showPushBanner(PushMessageData message) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showPushBanner(message),
      );
      return;
    }
    pushBanner?.remove();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _PushBanner(
        message: message,
        onTap: () {
          if (identical(pushBanner, entry)) pushBanner = null;
          entry.remove();
          _queuePushNavigation(message);
        },
        onClose: () {
          if (identical(pushBanner, entry)) pushBanner = null;
          entry.remove();
        },
      ),
    );
    pushBanner = entry;
    overlay.insert(entry);
    Timer(const Duration(seconds: 6), () {
      if (identical(pushBanner, entry)) {
        pushBanner = null;
        entry.remove();
      }
    });
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
    foregroundPushSubscription?.cancel();
    openedPushSubscription?.cancel();
    pushBanner?.remove();
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

class _PushBanner extends StatelessWidget {
  const _PushBanner({
    required this.message,
    required this.onTap,
    required this.onClose,
  });

  final PushMessageData message;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final visual = notificationVisualFor(message.type);
    return Positioned(
      top: MediaQuery.paddingOf(context).top + 10,
      left: 14,
      right: 14,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBF6),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: const Color(0xFFFFD6C6)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x286B4C2D),
                  blurRadius: 18,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: visual.background,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Text(
                    visual.emoji,
                    style: const TextStyle(fontSize: 25),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 눈썹에 앱 이름('빵긋')을 고정해 두면 어떤 알림이든
                      // 같은 줄이 뜬다 — 배너는 한 번에 하나만 보이므로 그
                      // 한 줄이 갈래를 말해 주는 쪽이 쓸모 있다.
                      Text(
                        visual.category,
                        style: TextStyle(
                          color: visual.accent,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        message.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.ink,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        message.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.inkSoft,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '알림 닫기',
                  onPressed: onClose,
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
