import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'widgets.dart';

class LaughReportContentScreen extends StatelessWidget {
  const LaughReportContentScreen({super.key, required this.controller});

  final AppController controller;

  Map<DateTime, int> get _countsByDay {
    final result = <DateTime, int>{};
    for (final video in controller.videos.where(
      (item) => item.hasEventType('LAUGHTER'),
    )) {
      final at = video.capturedStartAt ?? video.createdAt;
      if (at == null) continue;
      final day = DateUtils.dateOnly(at);
      result[day] = (result[day] ?? 0) + 1;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final counts = _countsByDay;
    final today = DateUtils.dateOnly(DateTime.now());
    final monday = today.subtract(Duration(days: today.weekday - 1));
    final days = List.generate(7, (index) => monday.add(Duration(days: index)));
    final weeklyCounts = days.map((day) => counts[day] ?? 0).toList();
    final weeklyTotal = weeklyCounts.fold<int>(0, (sum, count) => sum + count);
    final previousTotal = List.generate(
      7,
      (index) => counts[monday.subtract(Duration(days: 7 - index))] ?? 0,
    ).fold<int>(0, (sum, count) => sum + count);
    final difference = weeklyTotal - previousTotal;
    final busiestIndex = _busiestIndex(weeklyCounts, today.weekday - 1);
    final sharedCount = controller.members.length;

    return Scaffold(
      backgroundColor: const Color(0xFFFFF9F1),
      body: Stack(
        children: [
          const Positioned.fill(child: _ReportBackground()),
          SafeArea(
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  sliver: SliverList.list(
                    children: [
                      _ReportHeader(onBack: () => Navigator.maybePop(context)),
                      const SizedBox(height: 22),
                      _LuckyPouchCard(
                        count: weeklyTotal,
                        difference: difference,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: _MiniStatCard(
                              icon: Icons.calendar_month_rounded,
                              label: '가장 많이 웃은 날',
                              value: _weekdayLabel(busiestIndex),
                              color: const Color(0xFFFFE9CC),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _MiniStatCard(
                              icon: Icons.sentiment_very_satisfied_rounded,
                              label: '웃음 횟수',
                              value: '$weeklyTotal회',
                              color: const Color(0xFFFFF5E7),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _MiniStatCard(
                              icon: Icons.family_restroom_rounded,
                              label: '가족 공유',
                              value: '$sharedCount개',
                              color: const Color(0xFFFFE8E1),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      _WeekPouchCard(
                        counts: weeklyCounts,
                        highlightedIndex: busiestIndex,
                      ),
                      const SizedBox(height: 14),
                      _OneLineReport(
                        busiestIndex: busiestIndex,
                        count: weeklyCounts[busiestIndex],
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
}

int _busiestIndex(List<int> counts, int todayIndex) {
  var result = todayIndex.clamp(0, 6);
  for (var index = 0; index < counts.length; index++) {
    if (counts[index] > counts[result]) result = index;
  }
  return result;
}

String _weekdayLabel(int index) =>
    const ['월요일', '화요일', '수요일', '목요일', '금요일', '토요일', '일요일'][index];

class _ReportBackground extends StatelessWidget {
  const _ReportBackground();

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFFFFBF5), Color(0xFFFFF4E8), Color(0xFFFFFAF4)],
      ),
    ),
    child: const Stack(
      children: [
        Positioned(
          right: -90,
          top: -70,
          child: _GlowCircle(size: 260, color: Color(0x24FFB48F)),
        ),
        Positioned(
          left: -100,
          bottom: 70,
          child: _GlowCircle(size: 240, color: Color(0x1AF4C56E)),
        ),
      ],
    ),
  );
}

class _GlowCircle extends StatelessWidget {
  const _GlowCircle({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _ReportHeader extends StatelessWidget {
  const _ReportHeader({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 128,
    child: Stack(
      children: [
        Positioned(
          top: 4,
          left: 0,
          child: IconButton.filledTonal(
            key: const Key('laugh-report-back'),
            onPressed: onBack,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFFFF8EE),
              foregroundColor: AppColors.ink,
              side: const BorderSide(color: AppColors.line),
            ),
            icon: const Icon(Icons.chevron_left_rounded),
          ),
        ),
        Positioned(
          left: 4,
          bottom: 8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '웃음 리포트',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontSize: 30,
                      letterSpacing: -1.4,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    '♥',
                    style: TextStyle(fontSize: 25, color: AppColors.coral),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                '우리 집 웃음이 복처럼 차곡차곡 쌓이고 있어요  🍃',
                style: TextStyle(fontSize: 13, color: AppColors.inkSoft),
              ),
            ],
          ),
        ),
        Positioned(
          right: -8,
          bottom: 0,
          child: Image.asset(
            'assets/images/laugh_report_mascot.png',
            width: 122,
            height: 122,
            fit: BoxFit.contain,
            cacheWidth: decodePixels(context, 122),
          ),
        ),
      ],
    ),
  );
}

class _LuckyPouchCard extends StatelessWidget {
  const _LuckyPouchCard({required this.count, required this.difference});

  final int count;
  final int difference;

  @override
  Widget build(BuildContext context) {
    final comparison = difference == 0
        ? '지난주와 같아요'
        : '지난주보다 ${difference > 0 ? '+' : ''}$difference ${difference > 0 ? '↑' : '↓'}';
    return _ReportCard(
      height: 280,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 2,
            top: 2,
            bottom: 2,
            child: SizedBox(
              width: 170,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '이번 주 웃음 복주머니 ♥',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
                  ),
                  const Spacer(),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '$count',
                          style: const TextStyle(
                            fontSize: 56,
                            height: 0.9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: -2,
                            color: AppColors.ink,
                          ),
                        ),
                        const TextSpan(
                          text: '개',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppColors.coralSoft,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      child: Text(
                        comparison,
                        style: const TextStyle(
                          color: AppColors.coralDark,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '웃음이 많았던 날일수록\n복주머니가 더 빵빵해져요 ♥',
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: AppColors.inkSoft,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            right: -10,
            top: 3,
            bottom: -8,
            child: Image.asset(
              'assets/images/laugh_report_lucky_pouch.png',
              width: 225,
              fit: BoxFit.contain,
              cacheWidth: decodePixels(context, 225),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStatCard extends StatelessWidget {
  const _MiniStatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    height: 106,
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x140D0905),
          blurRadius: 14,
          offset: Offset(0, 5),
        ),
      ],
    ),
    child: Column(
      children: [
        Icon(icon, size: 25, color: AppColors.coralDark),
        const SizedBox(height: 6),
        FittedBox(
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          child: Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
        ),
      ],
    ),
  );
}

class _WeekPouchCard extends StatelessWidget {
  const _WeekPouchCard({required this.counts, required this.highlightedIndex});

  final List<int> counts;
  final int highlightedIndex;

  @override
  Widget build(BuildContext context) {
    final maxCount = math.max(1, counts.reduce(math.max));
    return _ReportCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '요일별 웃음복 ♥',
            style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(7, (index) {
              final highlighted = index == highlightedIndex;
              final ratio = counts[index] / maxCount;
              return Expanded(
                child: Column(
                  children: [
                    Text(
                      const ['월', '화', '수', '목', '금', '토', '일'][index],
                      style: TextStyle(
                        fontWeight: highlighted
                            ? FontWeight.w900
                            : FontWeight.w600,
                        color: highlighted ? AppColors.ink : AppColors.inkSoft,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 70,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: Transform.scale(
                          scale: highlighted ? 1.12 : 0.78 + ratio * 0.16,
                          child: Image.asset(
                            'assets/images/laugh_report_lucky_pouch.png',
                            width: 56,
                            height: 64,
                            fit: BoxFit.contain,
                            // 1.12배까지 커지므로 그만큼 여유를 두고 푼다.
                            cacheWidth: decodePixels(context, 72),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${counts[index]}',
                      style: TextStyle(
                        fontSize: highlighted ? 20 : 16,
                        fontWeight: FontWeight.w900,
                        color: highlighted ? AppColors.coral : AppColors.ink,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _OneLineReport extends StatelessWidget {
  const _OneLineReport({required this.busiestIndex, required this.count});

  final int busiestIndex;
  final int count;

  @override
  Widget build(BuildContext context) => _ReportCard(
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '한 줄 리포트 🍃',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 9),
              Text(
                count == 0
                    ? '이번 주 첫 웃음이 복주머니를 기다리고 있어요.'
                    : '${_weekdayLabel(busiestIndex)}에 가족이 함께 웃은\n순간이 가장 많았어요.',
                style: const TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: const Color(0xFFFFF4E8),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(
            Icons.favorite_rounded,
            color: AppColors.coral,
            size: 29,
          ),
        ),
      ],
    ),
  );
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.child, this.height});

  final Widget child;
  final double? height;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: const Color(0xF5FFFDF9),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: Colors.white, width: 1.5),
      boxShadow: const [
        BoxShadow(
          color: Color(0x180D0905),
          blurRadius: 20,
          offset: Offset(0, 7),
        ),
      ],
    ),
    child: child,
  );
}
