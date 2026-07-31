import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'content_state.dart';
import 'schedule_editor_screen.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

class ContentCalendarScreen extends StatefulWidget {
  const ContentCalendarScreen({
    super.key,
    required this.controller,
    this.onBack,
    this.contentState,
  });

  final AppController controller;
  final VoidCallback? onBack;
  final ContentState? contentState;

  @override
  State<ContentCalendarScreen> createState() => _ContentCalendarScreenState();
}

class _ContentCalendarScreenState extends State<ContentCalendarScreen> {
  late DateTime _month;
  late DateTime _selected;
  List<VideoMemory> _videos = const [];
  bool _loading = false;
  String? _error;

  ContentState get _state => widget.contentState ?? ContentState.instance;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _selected = dateOnly(now);
    _state.addListener(_refresh);
    _load();
  }

  @override
  void dispose() {
    _state.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final device = widget.controller.selectedDevice;
    if (device == null) {
      setState(() => _videos = widget.controller.videos);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final videos = await widget.controller.api.listAllVideos(
        device.id,
        from: _month,
        to: DateTime(_month.year, _month.month + 1),
      );
      if (mounted) setState(() => _videos = videos);
    } catch (failure) {
      if (mounted) setState(() => _error = '$failure');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<VideoMemory> _videosOn(DateTime date) => _videos.where((video) {
    final startedAt = video.capturedStartAt ?? video.createdAt;
    return startedAt != null && DateUtils.isSameDay(startedAt, date);
  }).toList();

  List<CalendarSchedule> _schedulesOn(DateTime date) => _state.schedules.where((
    schedule,
  ) {
    if (schedule.yearly) {
      return schedule.date.month == date.month && schedule.date.day == date.day;
    }
    return DateUtils.isSameDay(schedule.date, date);
  }).toList();

  void _changeMonth(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _selected = DateTime(_month.year, _month.month, 1);
      _videos = const [];
    });
    _load();
  }

  Future<void> _openEditor({CalendarSchedule? schedule}) async {
    await Navigator.push<CalendarSchedule>(
      context,
      MaterialPageRoute(
        builder: (_) => ScheduleEditorScreen(
          initialDate: schedule == null ? _selected : null,
          schedule: schedule,
          state: _state,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selectedVideos = _videosOn(_selected);
    final selectedSchedules = _schedulesOn(_selected);
    return AppBackdrop(
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _CalendarHeroHeader(
              onBack: widget.onBack ?? () => Navigator.maybePop(context),
              onAdd: _openEditor,
            ),
            Expanded(
              child: ListView(
                key: const PageStorageKey('calendar-scroll'),
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 28),
                children: [
                  _CalendarMonthCard(
                    month: _month,
                    selected: _selected,
                    videosOn: _videosOn,
                    schedulesOn: _schedulesOn,
                    onPrevious: () => _changeMonth(-1),
                    onNext: () => _changeMonth(1),
                    onSelected: (date) => setState(() => _selected = date),
                  ),
                  const SizedBox(height: 14),
                  _SelectedScheduleCard(
                    date: _selected,
                    schedules: selectedSchedules,
                    onAdd: _openEditor,
                    onEdit: (schedule) => _openEditor(schedule: schedule),
                  ),
                  const SizedBox(height: 10),
                  _SelectedMemoryCard(
                    date: _selected,
                    videos: selectedVideos,
                    loading: _loading,
                    error: _error,
                    controller: widget.controller,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarHeroHeader extends StatelessWidget {
  const _CalendarHeroHeader({required this.onBack, required this.onAdd});

  final VoidCallback onBack;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 104,
    child: Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.bottomCenter,
      children: [
        Positioned(
          bottom: -3,
          child: Image.asset(
            'assets/images/calendar_header_mascot.png',
            width: 122,
            height: 104,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
          ),
        ),
        Positioned(
          left: 16,
          top: 22,
          child: Row(
            children: [
              _HeaderButton(
                onPressed: onBack,
                child: const Icon(
                  Icons.chevron_left_rounded,
                  color: Color(0xFF533722),
                  size: 30,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                '캘린더',
                style: TextStyle(
                  color: Color(0xFF4A2E1B),
                  fontSize: 27,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -1.2,
                ),
              ),
              const SizedBox(width: 6),
              const Text('🌱', style: TextStyle(fontSize: 17)),
            ],
          ),
        ),
        Positioned(
          right: 16,
          top: 22,
          child: FilledButton.icon(
            onPressed: onAdd,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 48),
              padding: const EdgeInsets.symmetric(horizontal: 15),
              backgroundColor: const Color(0xFFFF806C),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(19),
                side: const BorderSide(color: Colors.white, width: 1.5),
              ),
              elevation: 3,
              shadowColor: const Color(0x55E88974),
            ),
            icon: const Icon(Icons.add_rounded, size: 24),
            label: const Text(
              '일정 추가',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ],
    ),
  );
}

class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.onPressed, required this.child});

  final VoidCallback onPressed;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xFFFFFCF7),
    elevation: 4,
    shadowColor: const Color(0x22A8734E),
    borderRadius: BorderRadius.circular(18),
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onPressed,
      child: SizedBox(width: 48, height: 48, child: Center(child: child)),
    ),
  );
}

class _CalendarMonthCard extends StatelessWidget {
  const _CalendarMonthCard({
    required this.month,
    required this.selected,
    required this.videosOn,
    required this.schedulesOn,
    required this.onPrevious,
    required this.onNext,
    required this.onSelected,
  });

  final DateTime month;
  final DateTime selected;
  final List<VideoMemory> Function(DateTime) videosOn;
  final List<CalendarSchedule> Function(DateTime) schedulesOn;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final blankCount = month.weekday % 7;
    final dayCount = DateUtils.getDaysInMonth(month.year, month.month);
    final cellCount = ((blankCount + dayCount + 6) ~/ 7) * 7;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 15),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFEFB),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: const Color(0xFFF1DFCF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x167B5636),
            blurRadius: 18,
            offset: Offset(0, 7),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: onPrevious,
                icon: const Icon(Icons.chevron_left_rounded, size: 31),
                color: const Color(0xFF563923),
              ),
              Expanded(
                child: Text(
                  DateFormat('yyyy년 M월').format(month),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF513521),
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -.5,
                  ),
                ),
              ),
              IconButton(
                onPressed: onNext,
                icon: const Icon(Icons.chevron_right_rounded, size: 31),
                color: const Color(0xFF563923),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const _WeekdayHeader(),
          const SizedBox(height: 7),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisExtent: 49,
            ),
            itemCount: cellCount,
            itemBuilder: (_, index) {
              if (index < blankCount || index >= blankCount + dayCount) {
                return const SizedBox.shrink();
              }
              final date = DateTime(
                month.year,
                month.month,
                index - blankCount + 1,
              );
              return _CalendarDayCell(
                date: date,
                selected: DateUtils.isSameDay(date, selected),
                hasVideos: videosOn(date).isNotEmpty,
                schedules: schedulesOn(date),
                onTap: () => onSelected(date),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var index = 0; index < 7; index++)
        Expanded(
          child: Text(
            const ['일', '월', '화', '수', '목', '금', '토'][index],
            textAlign: TextAlign.center,
            style: TextStyle(
              color: index == 0
                  ? const Color(0xFFFF7B68)
                  : index == 6
                  ? const Color(0xFF6E9339)
                  : const Color(0xFF755E4B),
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
    ],
  );
}

class _CalendarDayCell extends StatelessWidget {
  const _CalendarDayCell({
    required this.date,
    required this.selected,
    required this.hasVideos,
    required this.schedules,
    required this.onTap,
  });

  final DateTime date;
  final bool selected;
  final bool hasVideos;
  final List<CalendarSchedule> schedules;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final sunday = date.weekday == DateTime.sunday;
    final saturday = date.weekday == DateTime.saturday;
    final numberColor = sunday
        ? const Color(0xFFFF7B68)
        : saturday
        ? const Color(0xFF6E9339)
        : const Color(0xFF715A48);
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 42,
          height: 46,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFFFFF3E5) : Colors.transparent,
            borderRadius: BorderRadius.circular(15),
            border: selected
                ? Border.all(color: const Color(0xFFF49A7C), width: 1.7)
                : null,
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x25DC8A68),
                      blurRadius: 7,
                      offset: Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (selected)
                const Positioned(
                  right: 5,
                  top: -8,
                  child: Icon(
                    Icons.eco_rounded,
                    color: Color(0xFF8FAA4F),
                    size: 14,
                  ),
                ),
              Positioned(
                top: selected ? 7 : 5,
                child: Text(
                  '${date.day}',
                  style: TextStyle(
                    color: selected ? const Color(0xFFFF725E) : numberColor,
                    fontSize: selected ? 18 : 15,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              if (hasVideos)
                const Positioned(
                  bottom: 3,
                  child: Icon(
                    Icons.videocam_outlined,
                    size: 12,
                    color: Color(0xFF71943D),
                  ),
                )
              else if (schedules.isNotEmpty)
                Positioned(
                  bottom: 0,
                  child: Text(
                    schedules.first.emoji,
                    style: const TextStyle(fontSize: 13, height: 1),
                  ),
                )
              else if (selected)
                const Positioned(
                  bottom: 4,
                  child: Text(
                    '•ᴗ•',
                    style: TextStyle(
                      color: Color(0xFF8A5E49),
                      fontSize: 7,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SelectedScheduleCard extends StatelessWidget {
  const _SelectedScheduleCard({
    required this.date,
    required this.schedules,
    required this.onAdd,
    required this.onEdit,
  });

  final DateTime date;
  final List<CalendarSchedule> schedules;
  final VoidCallback onAdd;
  final ValueChanged<CalendarSchedule> onEdit;

  @override
  Widget build(BuildContext context) => _DaySummaryCard(
    tint: const Color(0xFFFFF8F1),
    borderColor: const Color(0xFFF2DCCA),
    iconAsset: 'assets/images/calendar_schedule_card.png',
    title: '${DateFormat('M월 d일').format(date)} 일정',
    trailing: IconButton(
      tooltip: '일정 추가',
      onPressed: onAdd,
      icon: const Icon(Icons.favorite_border_rounded, color: Color(0xFFFFC4B4)),
    ),
    child: schedules.isEmpty
        ? const Text('등록된 일정이 없습니다', style: TextStyle(color: Color(0xFF806B5A)))
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final schedule in schedules)
                InkWell(
                  onTap: () => onEdit(schedule),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '${schedule.emoji}  ${schedule.title} · '
                      '${dDayLabel(schedule.yearly ? nextYearlyOccurrence(schedule.date) : schedule.date)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF72523D),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
  );
}

class _SelectedMemoryCard extends StatelessWidget {
  const _SelectedMemoryCard({
    required this.date,
    required this.videos,
    required this.loading,
    required this.error,
    required this.controller,
  });

  final DateTime date;
  final List<VideoMemory> videos;
  final bool loading;
  final String? error;
  final AppController controller;

  @override
  Widget build(BuildContext context) => _DaySummaryCard(
    tint: const Color(0xFFF9FAEE),
    borderColor: const Color(0xFFE3E1C2),
    iconAsset: 'assets/images/calendar_memory_card.png',
    title: '${DateFormat('M월 d일').format(date)}의 추억',
    trailing: const Icon(
      Icons.favorite_border_rounded,
      color: Color(0xFFD4D9A6),
    ),
    child: loading
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : error != null
        ? const Text('영상을 불러오지 못했습니다', style: TextStyle(color: AppColors.coral))
        : videos.isEmpty
        ? const Text('등록된 영상이 없습니다', style: TextStyle(color: Color(0xFF806B5A)))
        : Column(
            children: [
              for (final video in videos.take(3))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    video.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => VideoDetailScreen(
                        controller: controller,
                        video: video,
                      ),
                    ),
                  ),
                ),
            ],
          ),
  );
}

class _DaySummaryCard extends StatelessWidget {
  const _DaySummaryCard({
    required this.tint,
    required this.borderColor,
    required this.iconAsset,
    required this.title,
    required this.trailing,
    required this.child,
  });

  final Color tint;
  final Color borderColor;
  final String iconAsset;
  final String title;
  final Widget trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 92),
    padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
    decoration: BoxDecoration(
      color: tint,
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: borderColor),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0E7C5B3C),
          blurRadius: 12,
          offset: Offset(0, 4),
        ),
      ],
    ),
    child: Row(
      children: [
        Container(
          width: 64,
          height: 64,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .72),
            borderRadius: BorderRadius.circular(17),
          ),
          child: Image.asset(iconAsset, fit: BoxFit.contain),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Color(0xFF573A27),
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              child,
            ],
          ),
        ),
        const SizedBox(width: 6),
        trailing,
      ],
    ),
  );
}
