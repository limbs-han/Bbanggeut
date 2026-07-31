import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ui/auth_screen.dart';
import '../ui/main_shell.dart';
import '../ui/onboarding_screen.dart';
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
  StreamSubscription<Uri>? linkSubscription;
  bool? onboardingSeen;

  @override
  void initState() {
    super.initState();
    controller = AppController()..initialize();
    appLinks = AppLinks();
    _listenForMembershipRequests();
    _loadOnboarding();
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
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '빵긋',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    home: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (!controller.initialized || onboardingSeen == null) {
          return const _SplashScreen();
        }
        if (onboardingSeen == false) {
          return OnboardingScreen(onFinished: _finishOnboarding);
        }
        return controller.authenticated
            ? MainShell(controller: controller)
            : AuthScreen(controller: controller);
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
