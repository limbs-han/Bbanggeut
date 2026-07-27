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
                top: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _HomeHeader(
                      controller: controller,
                      device: device,
                      status: status,
                    ),
                    const SizedBox(height: 18),
                    const _HomeSectionTitle(
                      title: '지금 우리 집은',
                      icon: Icons.cottage_rounded,
                    ),
                    const SizedBox(height: 12),
                    _LivePreviewCard(
                      controller: controller,
                      device: device,
                      status: status,
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
                            icon: Icons.archive_rounded,
                            label: '자동 저장',
                            value: '${summary?.savedCount ?? 0}',
                            unit: '개',
                            color: AppColors.greenCard,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StatCard(
                            icon: Icons.note_alt_rounded,
                            label: '작성한 메모',
                            value: '${summary?.memoCount ?? 0}',
                            unit: '개',
                            color: AppColors.pink,
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
  Widget build(BuildContext context) => SizedBox(
    height: 94,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          top: 19,
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
              Icons.nest_cam_wired_stand_rounded,
              color: AppColors.sageDark,
              size: 30,
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
                device.name,
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
                      status?.isOnline == true
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
                builder: (_) => NotificationsScreen(controller: controller),
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
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      boxShadow: [
        BoxShadow(
          color: Color(0x329D6A32),
          blurRadius: 24,
          offset: Offset(0, 11),
        ),
      ],
    ),
    child: CustomPaint(
      painter: const _HouseBorderPainter(),
      foregroundPainter: const _HouseAccentPainter(),
      child: Padding(
        padding: const EdgeInsets.all(7),
        child: ClipPath(
          clipper: const _HouseFrameClipper(),
          child: EmbeddedLivePlayer(
            controller: controller,
            device: device,
            status: status,
            houseMode: true,
          ),
        ),
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
  });
  final IconData icon;
  final String label;
  final String value;
  final String unit;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
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

class _HouseFrameClipper extends CustomClipper<Path> {
  const _HouseFrameClipper();

  @override
  Path getClip(Size size) => _housePath(size);

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _HouseBorderPainter extends CustomPainter {
  const _HouseBorderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = _housePath(size);
    final fill = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFFFFE8BC), Color(0xFFF3BC70)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Offset.zero & size);
    canvas.drawPath(path, fill);

    final highlight = Paint()
      ..color = const Color(0xFFFFF3D8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;
    canvas.drawPath(path, highlight);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _HouseAccentPainter extends CustomPainter {
  const _HouseAccentPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final chimneyBody = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width - 78, 13, 32, 24),
      const Radius.circular(7),
    );
    canvas.drawRRect(chimneyBody, Paint()..color = const Color(0xFFFFC092));
    final chimneyCap = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width - 83, 9, 42, 11),
      const Radius.circular(6),
    );
    canvas.drawRRect(chimneyCap, Paint()..color = AppColors.coral);

    final heartPaint = Paint()..color = AppColors.coral;
    final center = Offset(size.width / 2, 17);
    final heart = Path()
      ..moveTo(center.dx, center.dy + 6)
      ..cubicTo(
        center.dx - 12,
        center.dy - 3,
        center.dx - 11,
        center.dy - 12,
        center.dx,
        center.dy - 5,
      )
      ..cubicTo(
        center.dx + 11,
        center.dy - 12,
        center.dx + 12,
        center.dy - 3,
        center.dx,
        center.dy + 6,
      );
    canvas.drawPath(heart, heartPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

Path _housePath(Size size) {
  const edge = 2.0;
  const roofY = 34.0;
  const peakY = 13.0;
  const corner = 25.0;
  final center = size.width / 2;

  return Path()
    ..moveTo(edge, roofY + corner)
    ..quadraticBezierTo(edge, roofY, edge + corner, roofY)
    ..lineTo(center - 96, roofY)
    ..cubicTo(center - 58, roofY, center - 34, peakY + 4, center, peakY)
    ..cubicTo(center + 34, peakY + 4, center + 58, roofY, center + 96, roofY)
    ..lineTo(size.width - 78, roofY)
    ..lineTo(size.width - 78, 18)
    ..quadraticBezierTo(size.width - 78, 13, size.width - 73, 13)
    ..lineTo(size.width - 51, 13)
    ..quadraticBezierTo(size.width - 46, 13, size.width - 46, 18)
    ..lineTo(size.width - 46, roofY)
    ..lineTo(size.width - edge - corner, roofY)
    ..quadraticBezierTo(
      size.width - edge,
      roofY,
      size.width - edge,
      roofY + corner,
    )
    ..lineTo(size.width - edge, size.height - corner)
    ..quadraticBezierTo(
      size.width - edge,
      size.height - edge,
      size.width - edge - corner,
      size.height - edge,
    )
    ..lineTo(edge + corner, size.height - edge)
    ..quadraticBezierTo(edge, size.height - edge, edge, size.height - corner)
    ..close();
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
