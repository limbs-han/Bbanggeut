import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'content_notifications_screen.dart';
import 'device_registration_screen.dart';
import 'favorite_videos_screen.dart';
import 'invitation_inbox_screen.dart';
import 'laugh_report_content_screen.dart';
import 'live_screen.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.isActive,
    required this.openVideos,
    required this.openCalendar,
  });
  final AppController controller;
  final bool isActive;
  final VoidCallback openVideos;
  final VoidCallback openCalendar;

  @override
  Widget build(BuildContext context) {
    final placeDevices = controller.devicesForSelectedPlace;
    final selectedDevice = controller.selectedDevice;
    final device = placeDevices
        .where((item) => item.id == selectedDevice?.id)
        .firstOrNull;
    final status = device == null ? null : controller.deviceStatus;
    final summary = controller.homeSummary;
    final latest = summary?.latestHighlight ?? controller.videos.firstOrNull;
    return AppBackdrop(
      child: CustomScrollView(
        key: const PageStorageKey('home-scroll'),
        slivers: [
          SliverSafeArea(
            bottom: false,
            sliver: SliverToBoxAdapter(
              child: PagePadding(
                top: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _HomeHeader(
                      controller: controller,
                      device: device,
                      status: status,
                      onSelect: () => _showHomeSelector(context),
                    ),
                    const SizedBox(height: 18),
                    _HomeSectionTitle(
                      title: placeHomeQuestion(controller.selectedPlaceName),
                      icon: Icons.cottage_rounded,
                    ),
                    const SizedBox(height: 12),
                    if (device == null)
                      _NoDeviceLiveCard(
                        controller: controller,
                        onConnect: () => _openDeviceRegistration(context),
                      )
                    else
                      _LiveDevicePager(
                        key: ValueKey(controller.selectedPlaceName),
                        controller: controller,
                        isActive: isActive,
                      ),
                    const SizedBox(height: 26),
                    _TodayRecordsCard(
                      laughCount: summary?.captureCount ?? 0,
                      favoriteCount: controller.videos
                          .where((video) => video.favorite)
                          .length,
                      reportCount: controller.videoStats?.totalCount ?? 0,
                      onLaughTap: openVideos,
                      onFavoriteTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              FavoriteVideosScreen(controller: controller),
                        ),
                      ),
                      onReportTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              LaughReportContentScreen(controller: controller),
                        ),
                      ),
                    ),
                    const SizedBox(height: 26),
                    const _HomeSectionTitle(
                      title: '최근 저장된 추억',
                      icon: Icons.favorite_rounded,
                    ),
                    const SizedBox(height: 12),
                    if (latest == null)
                      SoftCard(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 108,
                              child: FamilyReferenceImage(borderRadius: 13),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                '첫 웃음 영상이 저장되면 여기에 보여드릴게요.',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                            const _AddMemoryButton(),
                          ],
                        ),
                      )
                    else
                      InkWell(
                        borderRadius: BorderRadius.circular(22),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => VideoDetailScreen(
                              controller: controller,
                              video: latest,
                            ),
                          ),
                        ),
                        child: SoftCard(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              MemoryThumbnail(
                                api: controller.api,
                                video: latest,
                                width: 112,
                                height: 78,
                              ),
                              const SizedBox(width: 13),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      latest.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      memoryDate(
                                        latest.capturedStartAt ??
                                            latest.createdAt,
                                      ),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              ),
                              const _AddMemoryButton(),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 14),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openDeviceRegistration(BuildContext context) async {
    if (controller.videos.isNotEmpty) {
      final choice = await showMemoryConnectionChoice(context);
      if (!context.mounted || choice == null) return;
      if (choice == MemoryConnectionChoice.restart) {
        showAppSnack(context, '새로 시작 선택을 저장했어요. 실제 추억 삭제는 서버 API 연결 후 처리됩니다.');
      }
    }
    if (!context.mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DeviceRegistrationScreen(controller: controller),
      ),
    );
  }

  Future<void> _showHomeSelector(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: AppColors.surface,
      builder: (sheetContext) => _HomeSelectorSheet(
        controller: controller,
        sheetContext: sheetContext,
      ),
    );
  }
}

class _HomeSelectorSheet extends StatelessWidget {
  const _HomeSelectorSheet({
    required this.controller,
    required this.sheetContext,
  });

  final AppController controller;
  final BuildContext sheetContext;

  void _reorder(List<DeviceSummary> devices, int oldIndex, int newIndex) {
    final remaining = List<DeviceSummary>.of(devices)..removeAt(oldIndex);
    final movedDeviceId = devices[oldIndex].id;
    final beforeDeviceId = newIndex < remaining.length
        ? remaining[newIndex].id
        : null;
    controller.reorderDeviceForSelectedPlace(
      deviceId: movedDeviceId,
      beforeDeviceId: beforeDeviceId,
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final devices = controller.devicesForSelectedPlace;
        return ReorderableListView.builder(
          key: const Key('home-device-reorder-list'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
          buildDefaultDragHandles: false,
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('장소와 기기 선택', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              const Text('장소', style: TextStyle(fontWeight: FontWeight.w900)),
              ...controller.placeNames.map(
                (place) => ListTile(
                  leading: Icon(
                    place == controller.selectedPlaceName
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    color: place == controller.selectedPlaceName
                        ? AppColors.coral
                        : AppColors.muted,
                  ),
                  title: Text(place),
                  onTap: () {
                    controller.selectPlace(place);
                    Navigator.pop(sheetContext);
                  },
                ),
              ),
              if (devices.isNotEmpty) ...[
                const Divider(height: 24),
                const Text('기기', style: TextStyle(fontWeight: FontWeight.w900)),
              ],
            ],
          ),
          itemCount: devices.length,
          onReorderItem: (oldIndex, newIndex) =>
              _reorder(devices, oldIndex, newIndex),
          proxyDecorator: (child, _, animation) => AnimatedBuilder(
            animation: animation,
            child: child,
            builder: (_, child) => Material(
              color: AppColors.surfaceWarm,
              elevation: 4 * animation.value,
              shadowColor: const Color(0x335A4635),
              borderRadius: BorderRadius.circular(18),
              child: child,
            ),
          ),
          itemBuilder: (context, index) {
            final device = devices[index];
            final selected = device.id == controller.selectedDevice?.id;
            return Material(
              key: ValueKey('home-device-order-${device.id}'),
              color: Colors.transparent,
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      key: Key('home-device-select-${device.id}'),
                      borderRadius: BorderRadius.circular(16),
                      onTap: () {
                        Navigator.pop(sheetContext);
                        controller.selectDevice(device);
                      },
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 68),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              Icon(
                                selected
                                    ? Icons.radio_button_checked_rounded
                                    : Icons.radio_button_off_rounded,
                                color: selected
                                    ? AppColors.coral
                                    : AppColors.muted,
                              ),
                              const SizedBox(width: 28),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      device.name,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    Text(
                                      device.isOnline ? '온라인' : '오프라인',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: '${device.name} 순서 변경',
                    child: ReorderableDragStartListener(
                      key: Key('home-device-drag-${device.id}'),
                      index: index,
                      child: const Tooltip(
                        message: '순서 변경',
                        child: SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(
                            Icons.drag_handle_rounded,
                            color: AppColors.muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    ),
  );
}

String placeHomeQuestion(String placeName) {
  final normalized = placeName.trim().isEmpty ? '집' : placeName.trim();
  final lastCodeUnit = normalized.codeUnitAt(normalized.length - 1);
  final hasFinalConsonant =
      lastCodeUnit >= 0xAC00 &&
      lastCodeUnit <= 0xD7A3 &&
      (lastCodeUnit - 0xAC00) % 28 != 0;
  return '지금 우리 $normalized${hasFinalConsonant ? '은' : '는'}?';
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.controller,
    required this.device,
    required this.status,
    required this.onSelect,
  });
  final AppController controller;
  final DeviceSummary? device;
  final DeviceStatus? status;
  final VoidCallback onSelect;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 94,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          top: 19,
          child: InkWell(
            key: const Key('home-place-device-selector'),
            borderRadius: BorderRadius.circular(20),
            onTap: onSelect,
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: AppColors.surfaceWarm,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.line, width: 1.4),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x166B4C2D),
                    blurRadius: 12,
                    offset: Offset(0, 5),
                  ),
                ],
              ),
              child: const Icon(
                Icons.camera_indoor_rounded,
                color: AppColors.sageDark,
                size: 30,
              ),
            ),
          ),
        ),
        Positioned(
          left: 70,
          right: 132,
          top: 22,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                device?.name ?? '연결된 기기가 없습니다',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontSize: 20,
                  color: const Color(0xFF5A3E28),
                ),
              ),
              const SizedBox(height: 5),
              Row(
                children: [
                  CircleAvatar(
                    radius: 4,
                    backgroundColor: status?.isOnline == true
                        ? AppColors.online
                        : AppColors.muted,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      device == null
                          ? '기기를 연결하면 라이브를 볼 수 있어요'
                          : status?.isOnline == true
                          ? '온라인 · 안전하게 연결됨'
                          : '오프라인 · 연결 확인 필요',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Positioned(
          right: 47,
          top: -8,
          child: Image.asset(
            'assets/images/bbanggeut_mascot.png',
            width: 100,
            height: 102,
            fit: BoxFit.contain,
            cacheWidth: decodePixels(context, 102),
          ),
        ),
        Positioned(
          right: 0,
          top: 23,
          child: RoundIconButton(
            icon: Icons.notifications_none_rounded,
            badge: controller.receivedInvitations.any(
              (invitation) => invitation.isPending,
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ContentNotificationsScreen(
                  controller: controller,
                  onOpenInvitations: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          InvitationInboxScreen(controller: controller),
                    ),
                  ),
                  onOpenDevices: controller.canRegisterDevice
                      ? () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => DeviceRegistrationScreen(
                              controller: controller,
                            ),
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
        ),
        const Positioned(
          left: -16,
          right: -16,
          bottom: 0,
          child: _StitchedDivider(),
        ),
      ],
    ),
  );
}

class _NoDeviceLiveCard extends StatelessWidget {
  const _NoDeviceLiveCard({required this.controller, required this.onConnect});

  final AppController controller;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) => SoftCard(
    padding: EdgeInsets.zero,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Column(
        children: [
          AspectRatio(
            aspectRatio: 4 / 3,
            child: ColoredBox(
              color: const Color(0xFF4D493F),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.videocam_off_outlined,
                      color: Colors.white70,
                      size: 40,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '연결된 기기가 없습니다',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (controller.canRegisterDevice) ...[
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: onConnect,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white70),
                        ),
                        child: const Text('기기 연결하기'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _LiveDevicePager extends StatefulWidget {
  const _LiveDevicePager({
    super.key,
    required this.controller,
    required this.isActive,
  });

  final AppController controller;
  final bool isActive;

  @override
  State<_LiveDevicePager> createState() => _LiveDevicePagerState();
}

class _LiveDevicePagerState extends State<_LiveDevicePager> {
  late final PageController _pageController;
  bool _pageSyncScheduled = false;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    final selectedId = controller.selectedDevice?.id;
    final initial = controller.devicesForSelectedPlace.indexWhere(
      (device) => device.id == selectedId,
    );
    _pageController = PageController(initialPage: initial < 0 ? 0 : initial);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _syncPageToSelectedDevice(int selectedIndex) {
    if (selectedIndex < 0 || _pageSyncScheduled) return;
    final currentPage = _pageController.hasClients
        ? _pageController.page?.round()
        : null;
    if (currentPage == selectedIndex) return;
    _pageSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pageSyncScheduled = false;
      if (!mounted || !_pageController.hasClients) return;
      final latestDevices = controller.devicesForSelectedPlace;
      final selectedId = controller.selectedDevice?.id;
      final latestIndex = latestDevices.indexWhere(
        (device) => device.id == selectedId,
      );
      if (latestIndex >= 0 && _pageController.page?.round() != latestIndex) {
        _pageController.jumpToPage(latestIndex);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final devices = controller.devicesForSelectedPlace;
    if (devices.isEmpty) return const SizedBox.shrink();
    final selectedIndex = devices.indexWhere(
      (device) => device.id == controller.selectedDevice?.id,
    );
    _syncPageToSelectedDevice(selectedIndex);
    return LayoutBuilder(
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: PageView.builder(
                key: const Key('home-live-device-pager'),
                controller: _pageController,
                physics: devices.length > 1
                    ? const PageScrollPhysics()
                    : const NeverScrollableScrollPhysics(),
                itemCount: devices.length,
                onPageChanged: (index) =>
                    controller.selectDevice(devices[index]),
                itemBuilder: (_, index) {
                  final device = devices[index];
                  return _LivePreviewCard(
                    controller: controller,
                    device: device,
                    isActive: widget.isActive && index == selectedIndex,
                    status: device.id == controller.selectedDevice?.id
                        ? controller.deviceStatus
                        : null,
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 5,
                    backgroundColor: controller.deviceStatus?.isOnline == true
                        ? AppColors.online
                        : AppColors.muted,
                  ),
                  const SizedBox(width: 9),
                  Text(
                    controller.deviceStatus?.isOnline == true
                        ? '라이브 중  ·  마지막 업데이트: 방금 전'
                        : '오프라인  ·  연결 확인 필요',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            if (devices.length > 1) ...[
              const SizedBox(height: 9),
              Semantics(
                label: '${selectedIndex + 1}/${devices.length}번째 기기',
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    devices.length,
                    (index) => AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: index == selectedIndex ? 20 : 7,
                      height: 7,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: index == selectedIndex
                            ? AppColors.coral
                            : AppColors.line,
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _LivePreviewCard extends StatelessWidget {
  const _LivePreviewCard({
    required this.controller,
    required this.device,
    required this.isActive,
    required this.status,
  });
  final AppController controller;
  final DeviceSummary device;
  final bool isActive;
  final DeviceStatus? status;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: Colors.white, width: 3),
      boxShadow: const [
        BoxShadow(
          color: Color(0x24765337),
          blurRadius: 22,
          offset: Offset(0, 9),
        ),
      ],
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(25),
      child: EmbeddedLivePlayer(
        key: ValueKey('live-${device.id}'),
        controller: controller,
        device: device,
        isActive: isActive,
        status: status,
        houseMode: true,
      ),
    ),
  );
}

class _TodayRecordsCard extends StatelessWidget {
  const _TodayRecordsCard({
    required this.laughCount,
    required this.favoriteCount,
    required this.reportCount,
    required this.onLaughTap,
    required this.onFavoriteTap,
    required this.onReportTap,
  });

  final int laughCount;
  final int favoriteCount;
  final int reportCount;
  final VoidCallback onLaughTap;
  final VoidCallback onFavoriteTap;
  final VoidCallback onReportTap;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('today-records-card'),
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
    decoration: BoxDecoration(
      color: AppColors.surface.withValues(alpha: .92),
      borderRadius: BorderRadius.circular(32),
      border: Border.all(color: Colors.white, width: 1.4),
      boxShadow: const [
        BoxShadow(
          color: Color(0x1C765337),
          blurRadius: 24,
          offset: Offset(0, 9),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text(
              '오늘의 기록',
              style: TextStyle(
                color: AppColors.ink,
                fontSize: 20,
                height: 1.2,
                fontWeight: FontWeight.w900,
                letterSpacing: -.7,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.eco_rounded, size: 17, color: AppColors.sageDark),
            const Spacer(),
            Icon(Icons.spa_rounded, size: 19, color: AppColors.yellow),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 154,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 11,
                child: _TodayLaughCard(count: laughCount, onTap: onLaughTap),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 10,
                child: Column(
                  children: [
                    Expanded(
                      child: _TodayCompactStatCard(
                        icon: Icons.favorite_rounded,
                        label: '즐겨찾는 영상',
                        value: favoriteCount,
                        unit: '개',
                        colors: const [Color(0xFFF2F4E9), Color(0xFFE4E9D2)],
                        borderColor: const Color(0xFFC9D2AD),
                        onTap: onFavoriteTap,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _TodayCompactStatCard(
                        icon: Icons.bar_chart_rounded,
                        label: '웃음 리포트',
                        value: reportCount,
                        unit: '회',
                        colors: const [Color(0xFFFFF1ED), Color(0xFFF3DDD6)],
                        borderColor: const Color(0xFFDEC3BA),
                        onTap: onReportTap,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _TodayLaughCard extends StatelessWidget {
  const _TodayLaughCard({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(18),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.fromLTRB(10, 11, 10, 9),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFCED), Color(0xFFFFE7A8)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFECCB76), width: 1.2),
      ),
      child: Stack(
        children: [
          const Positioned(
            left: -34,
            bottom: 28,
            child: _LaughGlowOrb(size: 105),
          ),
          const Positioned(
            right: -26,
            top: -32,
            child: _LaughGlowOrb(size: 90),
          ),
          const Positioned(
            right: 3,
            bottom: 3,
            child: Icon(
              Icons.local_florist_rounded,
              size: 25,
              color: AppColors.sage,
            ),
          ),
          const Positioned(
            right: 9,
            top: 48,
            child: Icon(
              Icons.auto_awesome_rounded,
              size: 14,
              color: AppColors.yellow,
            ),
          ),
          const Positioned(
            left: 3,
            bottom: 8,
            child: Icon(Icons.eco_rounded, size: 19, color: AppColors.sage),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      gradient: const RadialGradient(
                        colors: [Colors.white, Color(0xFFFFF7D1)],
                      ),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x66F3C44E),
                          blurRadius: 13,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.sentiment_very_satisfied_rounded,
                      color: Color(0xFFF4B72E),
                      size: 39,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Flexible(
                              child: Text(
                                '오늘의 웃음',
                                maxLines: 1,
                                style: TextStyle(
                                  color: AppColors.inkSoft,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            SizedBox(width: 3),
                            Icon(
                              Icons.eco_rounded,
                              size: 13,
                              color: AppColors.sageDark,
                            ),
                          ],
                        ),
                        const SizedBox(height: 1),
                        RichText(
                          text: TextSpan(
                            style: const TextStyle(color: Color(0xFF6E4D20)),
                            children: [
                              TextSpan(
                                text: '$count',
                                style: const TextStyle(
                                  fontSize: 36,
                                  height: 1,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              const TextSpan(
                                text: '회',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .64),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withValues(alpha: .9)),
                ),
                child: const Text(
                  '오늘도 방긋한\n순간이 쌓였어요!',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF765A32),
                    fontSize: 11,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _LaughGlowOrb extends StatelessWidget {
  const _LaughGlowOrb({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.white.withValues(alpha: .18),
    ),
  );
}

class _TodayCompactStatCard extends StatelessWidget {
  const _TodayCompactStatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.colors,
    required this.borderColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final int value;
  final String unit;
  final List<Color> colors;
  final Color borderColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(17),
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: borderColor, width: 1.1),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: .86),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 19, color: AppColors.inkSoft),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.inkSoft,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                _TodayValue(value: value, unit: unit),
              ],
            ),
          ),
          Container(
            width: 27,
            height: 27,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.chevron_right_rounded,
              size: 21,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
    ),
  );
}

class _TodayValue extends StatelessWidget {
  const _TodayValue({required this.value, required this.unit});

  final int value;
  final String unit;

  @override
  Widget build(BuildContext context) => RichText(
    text: TextSpan(
      style: const TextStyle(color: AppColors.ink),
      children: [
        TextSpan(
          text: '$value',
          style: const TextStyle(
            fontSize: 24,
            height: 1.05,
            fontWeight: FontWeight.w900,
          ),
        ),
        TextSpan(
          text: unit,
          style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900),
        ),
      ],
    ),
  );
}

class _HomeSectionTitle extends StatelessWidget {
  const _HomeSectionTitle({required this.title, required this.icon});
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(
        title,
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontSize: 25,
          color: const Color(0xFF5A3E28),
        ),
      ),
      const SizedBox(width: 8),
      Icon(icon, size: 23, color: AppColors.coral),
      const Spacer(),
    ],
  );
}

class _AddMemoryButton extends StatelessWidget {
  const _AddMemoryButton();

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(
      color: AppColors.surfaceWarm,
      shape: BoxShape.circle,
      border: Border.all(color: AppColors.line),
    ),
    child: const Icon(Icons.add_rounded, color: AppColors.sageDark),
  );
}

class _StitchedDivider extends StatelessWidget {
  const _StitchedDivider();

  @override
  Widget build(BuildContext context) => Row(
    children: List.generate(
      22,
      (index) => Expanded(
        child: Container(
          height: 3,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: index.isEven ? AppColors.yellowSoft : AppColors.line,
            borderRadius: BorderRadius.circular(99),
          ),
        ),
      ),
    ),
  );
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
