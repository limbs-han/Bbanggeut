import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

/// Month calendar backed by the date-filtered video list. Days with saved
/// moments show a marker; tapping a day lists that day's memories.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late DateTime month; // first day of the visible month
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
      if (!mounted) return;
      setState(() => monthVideos = page.items);
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

  Map<int, int> get _countsByDay {
    final counts = <int, int>{};
    for (final v in monthVideos) {
      final day = (v.capturedStartAt ?? v.createdAt)?.day;
      if (day != null) counts[day] = (counts[day] ?? 0) + 1;
    }
    return counts;
  }

  List<VideoMemory> get _selectedVideos {
    final day = selected;
    if (day == null) return const [];
    return monthVideos.where((v) {
      final at = v.capturedStartAt ?? v.createdAt;
      return at != null && DateUtils.isSameDay(at, day);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
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
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        DateFormat('yyyy년 M월').format(month),
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                    ),
                    IconButton(
                      onPressed: () => _shiftMonth(-1),
                      icon: const Icon(Icons.chevron_left_rounded),
                    ),
                    IconButton(
                      onPressed: () => _shiftMonth(1),
                      icon: const Icon(Icons.chevron_right_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
                    child: _MonthGrid(
                      month: month,
                      selected: selected,
                      countsByDay: _countsByDay,
                      onSelect: (day) => setState(() => selected = day),
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (error != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text('달력을 불러오지 못했어요. $error'),
                    ),
                  )
                else if (loading)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  SectionHeader(
                    selected == null
                        ? '날짜를 선택하세요'
                        : DateFormat('M월 d일 (E)', 'ko').format(selected!),
                  ),
                  const SizedBox(height: 6),
                  if (_selectedVideos.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '이 날 저장된 순간이 없어요.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  else
                    ..._selectedVideos.map(
                      (video) => MemoryTile(
                        video: video,
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => VideoDetailScreen(
                              controller: widget.controller,
                              video: video,
                            ),
                          ),
                        ),
                        onFavorite: () => widget.controller.toggleFavorite(video),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        ],
      ),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.selected,
    required this.countsByDay,
    required this.onSelect,
  });
  final DateTime month;
  final DateTime? selected;
  final Map<int, int> countsByDay;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    const weekdays = ['일', '월', '화', '수', '목', '금', '토'];
    final daysInMonth = DateUtils.getDaysInMonth(month.year, month.month);
    // Dart weekday: Mon=1..Sun=7; grid starts on Sunday.
    final leadingBlanks = DateTime(month.year, month.month).weekday % 7;
    final today = DateTime.now();
    final cells = <Widget>[
      for (final w in weekdays)
        Center(
          child: Text(
            w,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.muted,
            ),
          ),
        ),
      for (var i = 0; i < leadingBlanks; i++) const SizedBox.shrink(),
      for (var day = 1; day <= daysInMonth; day++)
        _DayCell(
          day: day,
          count: countsByDay[day] ?? 0,
          isSelected:
              selected != null &&
              DateUtils.isSameDay(selected, DateTime(month.year, month.month, day)),
          isToday: DateUtils.isSameDay(today, DateTime(month.year, month.month, day)),
          onTap: () => onSelect(DateTime(month.year, month.month, day)),
        ),
    ];
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: .82,
      children: cells,
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.count,
    required this.isSelected,
    required this.isToday,
    required this.onTap,
  });
  final int day;
  final int count;
  final bool isSelected;
  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected
                ? AppColors.primary
                : (isToday ? AppColors.mint : Colors.transparent),
            shape: BoxShape.circle,
          ),
          child: Text(
            '$day',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: isSelected ? AppColors.surface : AppColors.ink,
            ),
          ),
        ),
        const SizedBox(height: 3),
        Container(
          width: 5,
          height: 5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: count > 0 ? AppColors.live : Colors.transparent,
          ),
        ),
      ],
    ),
  );
}
