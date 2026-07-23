import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'extra_screens.dart';
import 'live_screen.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.openVideos,
    required this.openCalendar,
  });
  final AppController controller;
  final VoidCallback openVideos;
  final VoidCallback openCalendar;

  @override
  Widget build(BuildContext context) {
    final device = controller.selectedDevice!;
    final status = controller.deviceStatus;
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
                top: 18,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _HomeHeader(
                      controller: controller,
                      device: device,
                      status: status,
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      '지금 우리 집은',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1,
                      ),
                    ),
                    const SizedBox(height: 10),
                    _LivePreviewCard(
                      controller: controller,
                      device: device,
                      status: status,
                    ),
                    const SizedBox(height: 22),
                    const SectionHeader('오늘의 기록'),
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        Expanded(
                          child: _StatCard(
                            label: '오늘 웃음',
                            value:
                                '${controller.videoStats?.byTriggerType['LAUGHTER'] ?? 0}',
                            unit: '회',
                            color: AppColors.yellowSoft,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StatCard(
                            label: '자동 저장',
                            value: '${summary?.savedCount ?? 0}',
                            unit: '개',
                            color: AppColors.greenCard,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StatCard(
                            label: '작성한 메모',
                            value: '${summary?.memoCount ?? 0}',
                            unit: '개',
                            color: AppColors.pink,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    const SectionHeader('최근 저장된 추억'),
                    const SizedBox(height: 10),
                    if (latest == null)
                      SoftCard(
                        child: Row(
                          children: [
                            const SizedBox(
                              width: 88,
                              child: FamilyReferenceImage(borderRadius: 13),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                '첫 웃음 영상이 저장되면 여기에 보여드릴게요.',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                            const Icon(
                              Icons.add_rounded,
                              size: 30,
                              color: AppColors.muted,
                            ),
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
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            children: [
                              MemoryThumbnail(
                                video: latest,
                                width: 76,
                                height: 58,
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
                              const Icon(
                                Icons.add_rounded,
                                size: 30,
                                color: AppColors.muted,
                              ),
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
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.controller,
    required this.device,
    required this.status,
  });
  final AppController controller;
  final DeviceSummary device;
  final DeviceStatus? status;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: AppColors.greenCard,
          borderRadius: BorderRadius.circular(13),
        ),
        child: const Icon(
          Icons.eco_outlined,
          color: AppColors.sageDark,
          size: 28,
        ),
      ),
      const SizedBox(width: 11),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              device.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Row(
              children: [
                CircleAvatar(
                  radius: 3.5,
                  backgroundColor: status?.isOnline == true
                      ? AppColors.online
                      : AppColors.muted,
                ),
                const SizedBox(width: 7),
                Text(
                  status?.isOnline == true
                      ? '온라인 · 안전하게 연결됨'
                      : '오프라인 · 연결을 확인해 주세요',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ],
        ),
      ),
      RoundIconButton(
        icon: Icons.notifications_none_rounded,
        badge: controller.joinRequests.isNotEmpty,
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NotificationsScreen(controller: controller),
          ),
        ),
      ),
    ],
  );
}

class _LivePreviewCard extends StatelessWidget {
  const _LivePreviewCard({
    required this.controller,
    required this.device,
    required this.status,
  });
  final AppController controller;
  final DeviceSummary device;
  final DeviceStatus? status;
  @override
  Widget build(BuildContext context) => EmbeddedLivePlayer(
    controller: controller,
    device: device,
    status: status,
  );
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });
  final String label;
  final String value;
  final String unit;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    height: 76,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Column(
      children: [
        Text(
          label,
          maxLines: 1,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: AppColors.inkSoft,
          ),
        ),
        const Spacer(),
        RichText(
          text: TextSpan(
            style: const TextStyle(color: AppColors.ink),
            children: [
              TextSpan(
                text: value,
                style: const TextStyle(
                  fontSize: 25,
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
      ],
    ),
  );
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
