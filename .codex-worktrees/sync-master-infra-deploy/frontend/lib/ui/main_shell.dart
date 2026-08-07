import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import 'calendar_screen.dart';
import 'device_registration_screen.dart';
import 'family_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';
import 'videos_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.controller});
  final AppController controller;
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int index = 0;
  String? handledMembershipRequestToken;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_openMembershipRequest);
  }

  @override
  void didUpdateWidget(covariant MainShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_openMembershipRequest);
      widget.controller.addListener(_openMembershipRequest);
    }
  }

  void _openMembershipRequest() {
    final token = widget.controller.pendingMembershipRequestToken;
    final preview = widget.controller.pendingMembershipRequestPreview;
    if (!mounted ||
        token == null ||
        preview == null ||
        token == handledMembershipRequestToken) {
      return;
    }
    handledMembershipRequestToken = token;
    setState(() => index = 3);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_openMembershipRequest);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.controller.selectedDevice == null) {
      return DeviceRegistrationScreen(
        controller: widget.controller,
        canGoBack: false,
      );
    }
    final pages = [
      HomeScreen(
        controller: widget.controller,
        openVideos: () => setState(() => index = 2),
        openCalendar: () => setState(() => index = 1),
      ),
      CalendarScreen(
        controller: widget.controller,
        onBack: () => setState(() => index = 0),
      ),
      VideosScreen(controller: widget.controller),
      FamilyScreen(controller: widget.controller),
      SettingsScreen(controller: widget.controller),
    ];
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: widget.controller.refreshDeviceData,
        child: IndexedStack(index: index, children: pages),
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0xFFE4E5DC))),
        ),
        child: NavigationBar(
          key: const ValueKey('main-bottom-navigation'),
          selectedIndex: index,
          onDestinationSelected: (value) => setState(() => index = value),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home_rounded),
              label: '홈',
            ),
            NavigationDestination(
              icon: Icon(Icons.calendar_today_outlined),
              selectedIcon: Icon(Icons.calendar_today_rounded),
              label: '캘린더',
            ),
            NavigationDestination(
              icon: Icon(Icons.bookmark_border_rounded),
              selectedIcon: Icon(Icons.bookmark_rounded),
              label: '추억',
            ),
            NavigationDestination(
              icon: Icon(Icons.group_outlined),
              selectedIcon: Icon(Icons.group_rounded),
              label: '가족',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_outlined),
              selectedIcon: Icon(Icons.tune_rounded),
              label: '설정',
            ),
          ],
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
