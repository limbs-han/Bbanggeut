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
                    SectionHeader(
                      '오늘의 기록',
                      action: '전체 보기',
                      onAction: openVideos,
                    ),
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
                    const SectionHeader('다가오는 기념일'),
                    const SizedBox(height: 10),
                    InkWell(
                      borderRadius: BorderRadius.circular(22),
                      onTap: openCalendar,
                      child: SoftCard(
                        padding: const EdgeInsets.all(13),
                        borderColor: AppColors.yellow,
                        child: Row(
                          children: [
                            Container(
                              width: 54,
                              height: 54,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppColors.yellowSoft,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    '${DateTime.now().add(const Duration(days: 3)).day}',
                                    style: const TextStyle(
                                      fontSize: 23,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const Text(
                                    'JUL',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 14),
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '엄마 생일',
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  SizedBox(height: 3),
                                  Text(
                                    '수요일 · 3일 뒤',
                                    style: TextStyle(
                                      color: AppColors.muted,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const CircleAvatar(
                              radius: 18,
                              backgroundColor: AppColors.sageSoft,
                              child: Icon(
                                Icons.chevron_right_rounded,
                                color: AppColors.inkSoft,
                              ),
                            ),
                          ],
                        ),
                      ),
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
  Widget build(BuildContext context) => SoftCard(
    padding: EdgeInsets.zero,
    radius: 24,
    borderColor: Colors.transparent,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Column(
        children: [
          InkWell(
            onTap: status?.isOnline == true
                ? () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          LiveScreen(controller: controller, device: device),
                    ),
                  )
                : () => showAppSnack(
                    context,
                    '카메라가 오프라인이라 라이브를 시작할 수 없어요.',
                    error: true,
                  ),
            child: Stack(
              children: [
                const FamilyReferenceImage(borderRadius: 0),
                Positioned(
                  left: 12,
                  top: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xA82D312B),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: const Row(
                      children: [
                        CircleAvatar(
                          radius: 4,
                          backgroundColor: AppColors.live,
                        ),
                        SizedBox(width: 7),
                        Text(
                          'LIVE',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: 12,
                  top: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xA82D312B),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: const Text(
                      '1080p',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        status?.personCount == null
                            ? '${status?.isOnline == true ? '온라인' : '오프라인'} · 감지 인원 확인 중'
                            : '온라인 · 가족 ${status!.personCount}명 감지',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.muted,
                  size: 30,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
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
