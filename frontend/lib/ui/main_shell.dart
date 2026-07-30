import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'calendar_screen.dart';
import 'family_screen.dart';
import 'home_screen.dart';
import 'no_device_screens.dart';
import 'settings_screen.dart';
import 'videos_screen.dart';

class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.controller});
  final AppController controller;
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  // Home and family show the camera's online state, which expires with its
  // heartbeat TTL, so both re-read presence on entry.
  static const _presenceTabs = {2, 3};

  int index = 2;
  String? _lastDeviceId;

  void _selectIndex(int value) {
    if (value == 1 && widget.controller.authenticated) {
      final refresh = widget.controller.selectedDevice == null
          ? widget.controller.refreshVaultData()
          : widget.controller.refreshDeviceData();
      refresh.catchError((_) {});
    } else if (_presenceTabs.contains(value)) {
      widget.controller.refreshPresence().catchError((_) {});
    }
    if (mounted) setState(() => index = value);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _presenceTabs.contains(index)) {
      widget.controller.refreshPresence().catchError((_) {});
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.controller.consumeOpenFamilyAfterDeviceClaim() ||
        widget.controller.pendingMembershipRequestPreview != null) {
      index = 3;
    }
    _lastDeviceId = widget.controller.selectedDevice?.id;
    widget.controller.addListener(_handleRequestedRoute);
    WidgetsBinding.instance.addObserver(this);
  }

  void _handleRequestedRoute() {
    final currentDeviceId = widget.controller.selectedDevice?.id;
    final deviceWasReleased = _lastDeviceId != null && currentDeviceId == null;
    _lastDeviceId = currentDeviceId;
    final openFamily =
        widget.controller.consumeOpenFamilyAfterDeviceClaim() ||
        widget.controller.pendingMembershipRequestPreview != null;
    if (!mounted) return;
    if (deviceWasReleased && index != 2) {
      setState(() => index = 2);
    } else if (openFamily && index != 3) {
      setState(() => index = 3);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_handleRequestedRoute);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      CalendarScreen(
        controller: widget.controller,
        onBack: () => _selectIndex(2),
      ),
      VideosScreen(controller: widget.controller),
      HomeScreen(
        controller: widget.controller,
        openVideos: () => _selectIndex(1),
        openCalendar: () => _selectIndex(0),
      ),
      if (widget.controller.selectedVault == null)
        NoDeviceFamilyScreen(controller: widget.controller)
      else
        FamilyScreen(controller: widget.controller),
      if (widget.controller.selectedDevice == null)
        NoDeviceSettingsScreen(controller: widget.controller)
      else
        SettingsScreen(controller: widget.controller),
    ];
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: widget.controller.selectedVault == null
            ? widget.controller.refreshAll
            : widget.controller.selectedDevice == null
            ? widget.controller.refreshVaultData
            : widget.controller.refreshDeviceData,
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
            onDestinationSelected: _selectIndex,
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
