import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';

import '../ui/auth_screen.dart';
import '../ui/main_shell.dart';
import 'app_controller.dart';
import 'app_theme.dart';

class WilliamJamesApp extends StatefulWidget {
  const WilliamJamesApp({super.key});
  @override
  State<WilliamJamesApp> createState() => _WilliamJamesAppState();
}

class _WilliamJamesAppState extends State<WilliamJamesApp> {
  late final AppController controller;
  late final AppLinks appLinks;
  StreamSubscription<Uri>? linkSubscription;
  @override
  void initState() {
    super.initState();
    controller = AppController()..initialize();
    appLinks = AppLinks();
    _listenForMembershipRequests();
  }

  Future<void> _listenForMembershipRequests() async {
    final initial = await appLinks.getInitialLink();
    if (initial != null) {
      await controller.setMembershipRequestLink(initial);
    }
    linkSubscription = appLinks.uriLinkStream.listen(
      controller.setMembershipRequestLink,
    );
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
        if (!controller.initialized) return const _SplashScreen();
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
  Widget build(BuildContext context) =>
      const Scaffold(backgroundColor: AppColors.cream);
}
