import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'device_registration_screen.dart';
import 'live_screen.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

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
    final latest = controller.videos.firstOrNull;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          floating: true,
          title: InkWell(
            onTap: () => _showDevicePicker(context),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(device.name),
                  const SizedBox(width: 4),
                  const Icon(Icons.keyboard_arrow_down_rounded),
                ],
              ),
            ),
          ),
          actions: [
            IconButton(
              tooltip: '새 기기 연결',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      DeviceRegistrationScreen(controller: controller),
                ),
              ),
              icon: const Icon(Icons.add_circle_outline_rounded),
            ),
            const SizedBox(width: 8),
          ],
        ),
        SliverToBoxAdapter(
          child: PagePadding(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '안녕하세요${controller.user == null ? '' : ', ${controller.user!.displayName}님'}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '오늘도 따뜻한 순간을\n모아볼까요?',
                            style: Theme.of(context).textTheme.headlineMedium,
                          ),
                        ],
                      ),
                    ),
                    StatusPill(
                      label: device.isOnline ? '온라인' : '오프라인',
                      positive: device.isOnline,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _HeroMemory(
                  video: latest,
                  onTap: latest == null
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => VideoDetailScreen(
                              controller: controller,
                              video: latest,
                            ),
                          ),
                        ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: _MetricCard(
                        icon: Icons.auto_awesome_rounded,
                        label: '모아둔 추억',
                        value:
                            '${controller.videoStats?.totalCount ?? controller.videos.length}개',
                        accent: AppColors.peach,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricCard(
                        icon: Icons.history_rounded,
                        label: '보관 기간',
                        value: '${device.retentionDays}일',
                        accent: AppColors.mint,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                SectionHeader('최근 추억', action: '모두 보기', onAction: openVideos),
                const SizedBox(height: 6),
                if (controller.videos.isEmpty)
                  const Card(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        '아직 저장된 영상이 없어요. 기기가 첫 순간을 저장하면 여기에 나타납니다.',
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
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: !device.isOnline
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => LiveScreen(
                              controller: controller,
                              device: device,
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.videocam_rounded),
                  label: Text(device.isOnline ? '지금 우리 집 보기' : '기기가 오프라인이에요'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  void _showDevicePicker(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SectionHeader('기기 선택'),
            ...controller.devices.map(
              (device) => ListTile(
                leading: CircleAvatar(
                  backgroundColor: AppColors.mint,
                  child: Icon(
                    Icons.videocam_rounded,
                    color: device.isOnline
                        ? AppColors.primary
                        : AppColors.muted,
                  ),
                ),
                title: Text(device.name),
                subtitle: Text(
                  '${device.myRole} · ${device.isOnline ? '온라인' : '오프라인'}',
                ),
                trailing: device.id == controller.selectedDevice?.id
                    ? const Icon(
                        Icons.check_circle_rounded,
                        color: AppColors.primary,
                      )
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  controller.selectDevice(device);
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _HeroMemory extends StatelessWidget {
  const _HeroMemory({required this.video, this.onTap});
  final VideoMemory? video;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(26),
    child: Container(
      height: 230,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        color: AppColors.primaryDark,
        image: video?.thumbnailUrl == null
            ? null
            : DecorationImage(
                image: NetworkImage(video!.thumbnailUrl!),
                fit: BoxFit.cover,
              ),
        gradient: video?.thumbnailUrl == null
            ? const LinearGradient(
                colors: [Color(0xFF153D37), Color(0xFF3B8E80)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: .68),
                  ],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .92),
                shape: BoxShape.circle,
              ),
              child: const Padding(
                padding: EdgeInsets.all(17),
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: 34,
                  color: AppColors.primaryDark,
                ),
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 18,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  video?.title ?? '첫 번째 추억을 기다리고 있어요',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  video == null
                      ? '기기가 소중한 순간을 저장하면 바로 만날 수 있어요.'
                      : '${memoryDate(video!.capturedStartAt)} · ${durationLabel(video!.durationMs)}',
                  style: const TextStyle(color: Color(0xFFE7F1EF)),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });
  final IconData icon;
  final String label;
  final String value;
  final Color accent;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(17),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(icon, size: 19, color: AppColors.primaryDark),
            ),
          ),
          const SizedBox(height: 14),
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 3),
          Text(value, style: Theme.of(context).textTheme.titleLarge),
        ],
      ),
    ),
  );
}
