import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'calendar_screen.dart';
import 'device_registration_screen.dart';
import 'family_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'videos_screen.dart';
import 'vault_archive_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.controller});
  final AppController controller;
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int index = 2;

  @override
  void initState() {
    super.initState();
    if (widget.controller.consumeOpenFamilyAfterDeviceClaim() ||
        widget.controller.pendingMembershipRequestPreview != null) {
      index = 3;
    }
    widget.controller.addListener(_handleRequestedRoute);
  }

  void _handleRequestedRoute() {
    final openFamily =
        widget.controller.consumeOpenFamilyAfterDeviceClaim() ||
        widget.controller.pendingMembershipRequestPreview != null;
    if (mounted && openFamily && index != 3) setState(() => index = 3);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleRequestedRoute);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller.selectedVault == null) {
      return DeviceRegistrationScreen(
        controller: widget.controller,
        canGoBack: false,
      );
    }
    if (widget.controller.selectedDevice == null) {
      return VaultArchiveScreen(controller: widget.controller);
    }
    final pages = [
      CalendarScreen(
        controller: widget.controller,
        onBack: () => setState(() => index = 2),
      ),
      VideosScreen(controller: widget.controller),
      HomeScreen(
        controller: widget.controller,
        openVideos: () => setState(() => index = 1),
        openCalendar: () => setState(() => index = 0),
      ),
      FamilyScreen(controller: widget.controller),
      SettingsScreen(controller: widget.controller),
    ];
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: widget.controller.refreshDeviceData,
        child: IndexedStack(index: index, children: pages),
      ),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          border: Border(top: BorderSide(color: AppColors.line)),
          boxShadow: [
            BoxShadow(
              color: Color(0x176B4C2D),
              blurRadius: 18,
              offset: Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: NavigationBar(
            key: const ValueKey('main-bottom-navigation'),
            selectedIndex: index,
            onDestinationSelected: (value) => setState(() => index = value),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.calendar_month_outlined),
                selectedIcon: Icon(Icons.calendar_month_rounded),
                label: '캘린더',
              ),
              NavigationDestination(
                icon: Icon(Icons.play_circle_outline_rounded),
                selectedIcon: Icon(Icons.play_circle_fill_rounded),
                label: '추억',
              ),
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                selectedIcon: Icon(Icons.home_rounded),
                label: '홈',
              ),
              NavigationDestination(
                icon: Icon(Icons.family_restroom_outlined),
                selectedIcon: Icon(Icons.family_restroom_rounded),
                label: '가족',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings_rounded),
                label: '설정',
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: widget.controller.busy
          ? const FloatingActionButton.small(
              onPressed: null,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : null,
    );
  }
}
