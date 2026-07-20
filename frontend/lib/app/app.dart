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
  @override
  void initState() {
    super.initState();
    controller = AppController()..initialize();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'William James',
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
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome_rounded, size: 46, color: AppColors.primary),
          SizedBox(height: 18),
          Text(
            'WILLIAM JAMES',
            style: TextStyle(
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
              color: AppColors.primaryDark,
            ),
          ),
          SizedBox(height: 24),
          SizedBox.square(
            dimension: 24,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        ],
      ),
    ),
  );
}
