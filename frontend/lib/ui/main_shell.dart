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

/// 아직 펼치지 않은 탭 자리. 크기를 0으로 두어 배치 비용도 남기지 않는다.
const _closedTab = SizedBox.shrink();

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  /// 가운데 홈 탭. 앱을 켜면 여기서 시작하고, 뒤로가기도 여기로 돌아온다.
  static const _homeTab = 2;

  // Home and family show the camera's online state, which expires with its
  // heartbeat TTL, so both re-read presence on entry.
  static const _presenceTabs = {_homeTab, 3};

  int index = _homeTab;
  String? _lastDeviceId;

  /// 한 번이라도 펼친 탭.
  ///
  /// **왜 세는가**: [IndexedStack]은 자식을 **모두** 만들어 두고 고른 하나만
  /// 그린다. 그래서 앱을 켜면 보고 있지도 않은 캘린더·추억·가족·설정 화면이 함께
  /// 세워졌다. 그 화면들이 목록을 그리면 각 항목의 [MemoryThumbnail]이 재생 URL을
  /// 받아 원격 프레임을 뽑기 시작한다 — 아무도 보지 않는 탭 때문에 켜는 순간
  /// 네트워크 요청이 여러 개 나가고 홈 화면이 그만큼 늦어졌다.
  ///
  /// 처음 펼칠 때까지는 빈 자리를 두고, 한 번 펼친 탭은 그대로 남겨 둔다 —
  /// IndexedStack을 쓰는 이유(탭을 옮겨도 스크롤 위치와 상태가 남는 것)는 그대로다.
  final _openedTabs = <int>{};

  /// 지난번에 세워 둔 탭 위젯.
  ///
  /// **왜 붙잡아 두는가**: 앱 전체가 [AppController] 하나를 보고 다시 그려진다.
  /// 즐겨찾기를 하나 누르거나 목록을 새로 고칠 때마다 [notifyListeners]가 돌고,
  /// 그때 캘린더·추억·홈·가족·설정 다섯 화면이 **전부** 다시 세워졌다. 보고
  /// 있는 화면은 하나인데 다섯 개 분량의 build와 layout을 치르니 누를 때마다
  /// 한두 프레임씩 밀렸다 — "전체적으로 버벅거린다"의 한 축이다.
  ///
  /// 위젯 인스턴스를 그대로 돌려주면 Flutter가 그 자리(`Element.updateChild`)
  /// 에서 같은 위젯임을 알아보고 하위 트리를 통째로 건너뛴다. 보고 있는 탭만
  /// 새로 세우고, 나머지는 다시 펼칠 때 세운다 — 탭을 옮기면 [_cachedIndex]가
  /// 달라져 캐시를 버리므로 옮겨 간 화면은 언제나 최신이다.
  final _tabCache = <int, Widget>{};
  int? _cachedIndex;
  String? _cachedVariant;

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
    if (state == AppLifecycleState.resumed && _presenceTabs.contains(index)) {
      widget.controller.refreshPresence().catchError((_) {});
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.controller.consumeOpenHomeAfterDeviceClaim()) {
      index = _homeTab;
    } else if (widget.controller.pendingMembershipRequestPreview != null) {
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
    final openHome = widget.controller.consumeOpenHomeAfterDeviceClaim();
    final openFamily =
        widget.controller.pendingMembershipRequestPreview != null;
    if (!mounted) return;
    if ((deviceWasReleased || openHome) && index != _homeTab) {
      setState(() => index = _homeTab);
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

  Widget _buildTab(int tab) => switch (tab) {
    0 => CalendarScreen(
      controller: widget.controller,
      onBack: () => _selectIndex(_homeTab),
    ),
    1 => VideosScreen(controller: widget.controller),
    _homeTab => HomeScreen(
      controller: widget.controller,
      isActive: index == _homeTab,
      openVideos: () => _selectIndex(1),
      openCalendar: () => _selectIndex(0),
    ),
    3 =>
      widget.controller.selectedVault == null
          ? NoDeviceFamilyScreen(controller: widget.controller)
          : FamilyScreen(controller: widget.controller),
    _ =>
      widget.controller.selectedDevice == null
          ? NoDeviceSettingsScreen(controller: widget.controller)
          : SettingsScreen(controller: widget.controller),
  };

  /// 보고 있는 탭만 새로 세우고 나머지는 지난번 위젯을 그대로 돌려준다.
  /// 자세한 이유는 [_tabCache] 설명을 참고.
  Widget _tab(int tab) {
    if (tab != index) {
      final cached = _tabCache[tab];
      if (cached != null) return cached;
    }
    return _tabCache[tab] = _buildTab(tab);
  }

  @override
  Widget build(BuildContext context) {
    _openedTabs.add(index);
    // 기기·금고가 붙거나 떨어지면 3·4번 탭이 아예 다른 화면이 된다.
    // 그때는 캐시를 믿을 수 없다.
    final variant =
        '${widget.controller.selectedVault == null}'
        '|${widget.controller.selectedDevice == null}';
    if (_cachedIndex != index || _cachedVariant != variant) {
      _tabCache.clear();
      _cachedIndex = index;
      _cachedVariant = variant;
    }
    return PopScope(
      // 탭은 Navigator 이력에 쌓이지 않는다. 그래서 캘린더·추억·가족·설정 어디에
      // 있든 뒤로가기 한 번이 곧바로 앱 종료였다 — 탭을 하나 눌러 본 것뿐인데
      // 앱이 꺼지니 실수로 나가지는 일이 잦았다. 홈이 아니면 뒤로가기를 가로채
      // 홈으로 돌린다. 홈에서는 그대로 나간다(안드로이드의 기본 기대).
      canPop: index == _homeTab,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || index == _homeTab) return;
        _selectIndex(_homeTab);
      },
      child: Scaffold(
        body: RefreshIndicator(
          onRefresh: widget.controller.selectedVault == null
              ? widget.controller.refreshAll
              : widget.controller.selectedDevice == null
              ? widget.controller.refreshVaultData
              : widget.controller.refreshDeviceData,
          child: IndexedStack(
            index: index,
            children: [
              for (var tab = 0; tab < 5; tab++)
                if (_openedTabs.contains(tab)) _tab(tab) else _closedTab,
            ],
          ),
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
      ),
    );
  }
}
