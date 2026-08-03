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
                    const _HomeSectionTitle(
                      title: '오늘의 기록',
                      icon: Icons.eco_rounded,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _StatCard(
                            icon: Icons.sentiment_very_satisfied_rounded,
                            label: '오늘의 웃음',
                            value: '${summary?.captureCount ?? 0}',
                            unit: '회',
                            color: AppColors.yellowSoft,
                            onTap: openVideos,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StatCard(
                            icon: Icons.favorite_rounded,
                            label: '즐겨찾는 영상',
                            value:
                                '${controller.videos.where((video) => video.favorite).length}',
                            unit: '개',
                            color: AppColors.greenCard,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => FavoriteVideosScreen(
                                  controller: controller,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StatCard(
                            icon: Icons.bar_chart_rounded,
                            label: '웃음 리포트',
                            value: '${controller.videoStats?.totalCount ?? 0}',
                            unit: '회',
                            color: AppColors.pink,
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => LaughReportContentScreen(
                                  controller: controller,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
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
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
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
            if (controller.devicesForSelectedPlace.isNotEmpty) ...[
              const Divider(height: 24),
              const Text('기기', style: TextStyle(fontWeight: FontWeight.w900)),
              ...controller.devicesForSelectedPlace.map(
                (device) => ListTile(
                  leading: Icon(
                    device.id == controller.selectedDevice?.id
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    color: device.id == controller.selectedDevice?.id
                        ? AppColors.coral
                        : AppColors.muted,
                  ),
                  title: Text(device.name),
                  subtitle: Text(device.isOnline ? '온라인' : '오프라인'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    controller.selectDevice(device);
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
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

  @override
  Widget build(BuildContext context) {
    final devices = controller.devicesForSelectedPlace;
    if (devices.isEmpty) return const SizedBox.shrink();
    final selectedIndex = devices.indexWhere(
      (device) => device.id == controller.selectedDevice?.id,
    );
    return LayoutBuilder(
      builder: (context, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 4 / 3,
              child: PageView.builder(
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

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String value;
  final String unit;
  final Color color;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(24),
    onTap: onTap,
    child: Container(
      height: 112,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: .75)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x186B4C2D),
            blurRadius: 12,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .58),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 19, color: AppColors.inkSoft),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: AppColors.inkSoft,
                  ),
                ),
              ),
            ],
          ),
          const Spacer(),
          RichText(
            text: TextSpan(
              style: const TextStyle(color: AppColors.ink),
              children: [
                TextSpan(
                  text: value,
                  style: const TextStyle(
                    fontSize: 31,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                TextSpan(
                  text: unit,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.bottomRight,
            child: Icon(Icons.eco_rounded, size: 15, color: AppColors.sageDark),
          ),
        ],
      ),
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
