import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'extra_screens.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime month;
  DateTime? selected;
  bool loading = false;
  String? error;
  List<VideoMemory> monthVideos = const [];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    month = DateTime(now.year, now.month);
    selected = DateTime(now.year, now.month, now.day);
    _load();
  }

  Future<void> _load() async {
    final device = widget.controller.selectedDevice;
    if (device == null) return;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.controller.api.listVideos(
        device.id,
        from: month,
        to: DateTime(month.year, month.month + 1),
        size: 200,
      );
      if (mounted) setState(() => monthVideos = page.items);
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _shiftMonth(int delta) {
    setState(() {
      month = DateTime(month.year, month.month + delta);
      selected = null;
      monthVideos = const [];
    });
    _load();
  }

  Map<int, int> get countsByDay {
    final result = <int, int>{};
    for (final video in monthVideos) {
      final day = (video.capturedStartAt ?? video.createdAt)?.day;
      if (day != null) result[day] = (result[day] ?? 0) + 1;
    }
    return result;
  }

  List<VideoMemory> get selectedVideos {
    final date = selected;
    if (date == null) return const [];
    return monthVideos.where((video) {
      final at = video.capturedStartAt ?? video.createdAt;
      return at != null && DateUtils.isSameDay(at, date);
    }).toList();
  }

  @override
  Widget build(BuildContext context) => AppBackdrop(
    child: CustomScrollView(
      key: const PageStorageKey('calendar-scroll'),
      slivers: [
        SliverSafeArea(
          bottom: false,
          sliver: SliverToBoxAdapter(
            child: Column(
              children: [
                _CalendarHeader(
                  onAdd: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AnniversaryEditorScreen(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                  child: _CalendarCard(
                    month: month,
                    selected: selected,
                    counts: countsByDay,
                    onSelect: (date) => setState(() => selected = date),
                    onPrevious: () => _shiftMonth(-1),
                    onNext: () => _shiftMonth(1),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _MemoriesOfDay(
                    date: selected,
                    videos: selectedVideos,
                    loading: loading,
                    error: error,
                    controller: widget.controller,
                  ),
                ),
                const SizedBox(height: 12),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: SoftCard(
                    padding: EdgeInsets.all(12),
                    child: Row(
                      children: [
                        CircleAvatar(
                          backgroundColor: AppColors.pink,
                          child: Icon(
                            Icons.favorite_rounded,
                            color: AppColors.coral,
                          ),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '오늘의 한 줄',
                                style: TextStyle(fontWeight: FontWeight.w900),
                              ),
                              SizedBox(height: 3),
                              Text(
                                '아빠가 메뉴 이름을 잘못 말해 모두 빵 터진 날',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppColors.inkSoft,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text('😄', style: TextStyle(fontSize: 24)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(22),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const AnniversaryEditorScreen(),
                      ),
                    ),
                    child: const SoftCard(
                      padding: EdgeInsets.all(12),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 25,
                            backgroundColor: AppColors.pinkSoft,
                            child: Icon(
                              Icons.cake_outlined,
                              color: AppColors.coral,
                            ),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '다가오는 기념일',
                                  style: TextStyle(fontWeight: FontWeight.w900),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  '엄마 생일    D-2    |    7월 13일 (일)',
                                  style: TextStyle(
                                    color: AppColors.inkSoft,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: AppColors.muted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _CalendarHeader extends StatelessWidget {
  const _CalendarHeader({required this.onAdd});
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 72,
    child: Row(
      children: [
        const SizedBox(width: 16),
        RoundIconButton(
          icon: Icons.chevron_left_rounded,
          onPressed: () {},
          size: 44,
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Text(
              '캘린더',
              textAlign: TextAlign.left,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
        ),
        OutlinedButton.icon(
          onPressed: onAdd,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 44),
            backgroundColor: AppColors.surface,
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          icon: const Icon(Icons.event_rounded),
          label: const Text('일정 추가'),
        ),
        const SizedBox(width: 16),
      ],
    ),
  );
}

class _CalendarCard extends StatelessWidget {
  const _CalendarCard({
    required this.month,
    required this.selected,
    required this.counts,
    required this.onSelect,
    required this.onPrevious,
    required this.onNext,
  });
  final DateTime month;
  final DateTime? selected;
  final Map<int, int> counts;
  final ValueChanged<DateTime> onSelect;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    const weekdays = ['일', '월', '화', '수', '목', '금', '토'];
    final days = DateUtils.getDaysInMonth(month.year, month.month);
    final blanks = month.weekday % 7;
    final cells = <Widget>[
      for (var i = 0; i < 7; i++)
        Text(
          weekdays[i],
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: i == 0
                ? AppColors.coral
                : i == 6
                ? AppColors.sageDark
                : AppColors.muted,
          ),
        ),
      for (var i = 0; i < blanks; i++) const SizedBox.shrink(),
      for (var day = 1; day <= days; day++)
        _DayCell(
          date: DateTime(month.year, month.month, day),
          selected: selected,
          count: counts[day] ?? 0,
          onTap: onSelect,
        ),
    ];
    return SoftCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        children: [
          Row(
            children: [
              RoundIconButton(
                icon: Icons.chevron_left_rounded,
                onPressed: onPrevious,
                size: 38,
              ),
              Expanded(
                child: Text(
                  DateFormat('yyyy년 M월').format(month),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              RoundIconButton(
                icon: Icons.chevron_right_rounded,
                onPressed: onNext,
                size: 38,
              ),
            ],
          ),
          const SizedBox(height: 10),
          GridView.count(
            crossAxisCount: 7,
            childAspectRatio: .98,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: cells,
          ),
          const SizedBox(height: 8),
          InkWell(
            borderRadius: BorderRadius.circular(15),
            onTap: () {},
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.pinkSoft,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(color: AppColors.pink),
              ),
              child: const Row(
                children: [
                  Icon(Icons.cake_outlined, color: AppColors.coral),
                  SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '7월 13일 · 다가오는 기념일',
                          style: TextStyle(
                            fontSize: 10,
                            color: AppColors.inkSoft,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          '엄마 생일    D-2',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: AppColors.muted),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.selected,
    required this.count,
    required this.onTap,
  });
  final DateTime date;
  final DateTime? selected;
  final int count;
  final ValueChanged<DateTime> onTap;
  @override
  Widget build(BuildContext context) {
    final isSelected = selected != null && DateUtils.isSameDay(date, selected);
    final isSunday = date.weekday == DateTime.sunday;
    final isSaturday = date.weekday == DateTime.saturday;
    return InkWell(
      borderRadius: BorderRadius.circular(99),
      onTap: () => onTap(date),
      child: Center(
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.yellow
                : count > 0
                ? AppColors.sageSoft
                : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Text(
            '${date.day}',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: isSunday
                  ? AppColors.coral
                  : isSaturday
                  ? AppColors.sageDark
                  : AppColors.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _MemoriesOfDay extends StatelessWidget {
  const _MemoriesOfDay({
    required this.date,
    required this.videos,
    required this.loading,
    required this.error,
    required this.controller,
  });
  final DateTime? date;
  final List<VideoMemory> videos;
  final bool loading;
  final String? error;
  final AppController controller;
  @override
  Widget build(BuildContext context) => SoftCard(
    padding: const EdgeInsets.all(12),
    child: Column(
      children: [
        Row(
          children: [
            const CircleAvatar(
              radius: 13,
              backgroundColor: AppColors.pink,
              child: Icon(
                Icons.favorite_rounded,
                color: AppColors.coral,
                size: 15,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                date == null
                    ? '날짜를 선택해 주세요'
                    : '${DateFormat('M월 d일').format(date!)}의 추억',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const StatusPill(label: '편집', color: AppColors.sageSoft),
          ],
        ),
        const SizedBox(height: 7),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(22),
            child: CircularProgressIndicator(),
          )
        else if (error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('불러오지 못했어요. $error'),
          )
        else if (videos.isEmpty)
          const Padding(
            padding: EdgeInsets.all(18),
            child: Text(
              '이 날 저장된 순간이 없어요.',
              style: TextStyle(color: AppColors.muted),
            ),
          )
        else
          ...videos
              .take(3)
              .map(
                (video) => MemoryTile(
                  compact: true,
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
  );
}
