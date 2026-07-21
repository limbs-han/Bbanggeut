import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'device_registration_screen.dart';
import 'live_screen.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

/// Home-cam first dashboard. The live camera is the hero of the primary tab;
/// today's capture summary and recent memories sit around it.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.openVideos,
  });
  final AppController controller;
  final VoidCallback openVideos;

  @override
  Widget build(BuildContext context) {
    final device = controller.selectedDevice!;
    final summary = controller.homeSummary;
    final status = controller.deviceStatus;
    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        slivers: [
        SliverToBoxAdapter(
          child: PagePadding(
            top: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(controller: controller, device: device),
                const SizedBox(height: 22),
                _SummaryCard(
                  summary: summary,
                  fallbackSaved:
                      controller.videoStats?.totalCount ??
                      controller.videos.length,
                  onReport: openVideos,
                ),
                const SizedBox(height: 26),
                _LiveSection(controller: controller, device: device, status: status),
                const SizedBox(height: 28),
                SectionHeader('최근 추억', action: '모두 보기', onAction: openVideos),
                const SizedBox(height: 6),
                if (controller.videos.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '아직 저장된 순간이 없어요. 홈캠이 첫 순간을 저장하면 여기에 나타납니다.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                else
                  ...controller.videos
                      .take(3)
                      .map(
                        (video) => MemoryTile(
                          video: video,
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => VideoDetailScreen(
                                controller: controller,
                                video: video,
                              ),
                            ),
                          ),
                          onFavorite: () => controller.toggleFavorite(video),
                        ),
                      ),
              ],
            ),
          ),
        ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.device});
  final AppController controller;
  final DeviceSummary device;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final stamp = DateFormat('EEEE · MMM d').format(now).toUpperCase();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                stamp,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: AppColors.muted,
                ),
              ),
              const SizedBox(height: 6),
              Text('오늘의 추억', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 6),
              Text(
                controller.user == null
                    ? '오늘도 행복한 하루 보내세요.'
                    : '${controller.user!.displayName}님, 오늘도 행복한 하루 보내세요.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _RoundIconButton(
          icon: controller.devices.length > 1
              ? Icons.unfold_more_rounded
              : Icons.add_rounded,
          tooltip: controller.devices.length > 1 ? '기기 전환' : '새 기기 연결',
          onTap: () => controller.devices.length > 1
              ? _showDeviceSheet(context, controller)
              : Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        DeviceRegistrationScreen(controller: controller),
                  ),
                ),
        ),
      ],
    );
  }
}

void _showDeviceSheet(BuildContext context, AppController controller) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SectionHeader('홈캠 선택'),
              ...controller.devices.map(
                (device) => ListTile(
                  leading: CircleAvatar(
                    backgroundColor: AppColors.mint,
                    child: Icon(
                      Icons.videocam_rounded,
                      color: device.isOnline ? AppColors.ink : AppColors.muted,
                    ),
                  ),
                  title: Text(device.name),
                  subtitle: Text(
                    '${device.myRole} · ${device.isOnline ? '온라인' : '오프라인'}',
                  ),
                  trailing: device.id == controller.selectedDevice?.id
                      ? const Icon(Icons.check_circle_rounded, color: AppColors.ink)
                      : null,
                  onTap: () {
                    Navigator.pop(context);
                    controller.selectDevice(device);
                  },
                ),
              ),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: AppColors.mint,
                  child: Icon(Icons.add_rounded, color: AppColors.ink),
                ),
                title: const Text('새 기기 연결'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          DeviceRegistrationScreen(controller: controller),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip ?? '',
    child: InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 48,
        height: 48,
        decoration: const BoxDecoration(
          color: AppColors.surface,
          shape: BoxShape.circle,
          border: Border.fromBorderSide(BorderSide(color: AppColors.line)),
        ),
        child: Icon(icon, color: AppColors.ink),
      ),
    ),
  );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.summary,
    required this.fallbackSaved,
    required this.onReport,
  });
  final HomeSummary? summary;
  final int fallbackSaved;
  final VoidCallback onReport;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 14, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '오늘의 순간 요약',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              TextButton(
                onPressed: onReport,
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('리포트'),
                    SizedBox(width: 2),
                    Icon(Icons.arrow_forward_rounded, size: 16),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              children: [
                Expanded(
                  child: _MetricTile(
                    label: '순간 포착',
                    value: '${summary?.captureCount ?? 0}',
                    unit: '회',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MetricTile(
                    label: '저장된 영상',
                    value: '${summary?.savedCount ?? fallbackSaved}',
                    unit: '개',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _MetricTile(
                    label: '작성한 메모',
                    value: '${summary?.memoCount ?? 0}',
                    unit: '개',
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.unit,
  });
  final String label;
  final String value;
  final String unit;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.mint,
      borderRadius: BorderRadius.circular(16),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.bodyMedium),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value, style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(width: 2),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(unit, style: Theme.of(context).textTheme.bodyMedium),
            ),
          ],
        ),
      ],
    ),
  );
}

class _LiveSection extends StatelessWidget {
  const _LiveSection({
    required this.controller,
    required this.device,
    required this.status,
  });
  final AppController controller;
  final DeviceSummary device;
  final DeviceStatus? status;

  @override
  Widget build(BuildContext context) {
    final online = device.isOnline;
    final people = status?.personCount;
    final openLive = !online
        ? null
        : () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => LiveScreen(controller: controller, device: device),
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'HOME CAM · LIVE',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '우리 집 실시간',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: openLive,
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('전체 화면'),
                  SizedBox(width: 2),
                  Icon(Icons.arrow_forward_rounded, size: 16),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _LivePreview(
          thumbnailUrl: controller.videos.firstOrNull?.thumbnailUrl,
          online: online,
          onTap: openLive,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 8,
                        color: online ? AppColors.online : AppColors.muted,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        online
                            ? (people == null
                                  ? '온라인'
                                  : '온라인 · 가족 $people명 감지')
                            : '오프라인',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const _QualityBadge(label: '1080p'),
          ],
        ),
      ],
    );
  }
}

class _LivePreview extends StatelessWidget {
  const _LivePreview({
    required this.thumbnailUrl,
    required this.online,
    this.onTap,
  });
  final String? thumbnailUrl;
  final bool online;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(24),
    child: AspectRatio(
      aspectRatio: 16 / 10,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumbnailUrl != null)
              Image.network(
                thumbnailUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const ColoredBox(color: AppColors.ink),
              )
            else
              const ColoredBox(color: AppColors.ink),
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black26, Colors.transparent, Colors.black45],
                ),
              ),
            ),
            Positioned(
              left: 14,
              top: 14,
              child: _LiveBadge(online: online),
            ),
            Positioned(
              right: 14,
              top: 14,
              child: Text(
                online ? '지금 · ${DateFormat('HH:mm').format(DateTime.now())}' : '연결 대기',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
            if (online)
              Positioned(
                right: 14,
                bottom: 14,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .55),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.open_in_full_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              )
            else
              const Center(
                child: Text(
                  '홈캠이 오프라인이에요',
                  style: TextStyle(
                    color: Colors.white70,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge({required this.online});
  final bool online;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: online ? AppColors.live : Colors.black54,
      borderRadius: BorderRadius.circular(8),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.circle, size: 8, color: Colors.white),
        const SizedBox(width: 5),
        Text(
          online ? 'LIVE' : 'OFF',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 11,
            letterSpacing: .5,
          ),
        ),
      ],
    ),
  );
}

class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: AppColors.mint,
      borderRadius: BorderRadius.circular(10),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: Text(
      label,
      style: const TextStyle(
        fontWeight: FontWeight.w800,
        color: AppColors.ink,
        fontSize: 13,
      ),
    ),
  );
}
