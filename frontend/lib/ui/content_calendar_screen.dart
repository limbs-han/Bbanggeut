import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import '../editor/edit_recommendation_client.dart';
import 'content_state.dart';
import 'edited_video_screen.dart';
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

  /// 편집 완료 영상(editor-api). 편집한 날짜 기준으로 달력에 표시한다.
  List<Map<String, dynamic>> _edited = const [];
  final _editClient = EditRecommendationClient();
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
    // 일정은 서버가 원본이다(API-74). 실패해도 캘린더는 뜬다.
    unawaited(_state.ensureLoaded(widget.controller.api));
    final device = widget.controller.selectedDevice;
    if (device == null) {
      // 기기가 없으면(테스트 포함) 네트워크를 타지 않는다.
      setState(() => _videos = widget.controller.videos);
      return;
    }
    // 편집 완료 영상은 감지 영상과 별개로 불러온다. 실패해도 달력은 뜬다.
    if (EditRecommendationClient.networkAllowed) {
      unawaited(
        _editClient
            .listEditedVideos()
            .then((edited) {
              if (mounted) setState(() => _edited = edited);
            })
            .catchError((_) {}),
      );
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

  /// 편집본이 달력에 놓일 날짜 — **원본이 감지된 날**이다. 편집한 날이
  /// 아니라 그 추억이 만들어진 날에 함께 보여야 한다. 감지 시각이 없는
  /// 옛 데이터만 편집한 날로 돌아간다.
  DateTime? _editedAnchorDate(Map<String, dynamic> meta) {
    final captured = DateTime.tryParse(
      meta['capturedAt'] as String? ?? '',
    )?.toLocal();
    if (captured != null) return captured;
    // 메타에 감지 시각이 없으면 원본 영상 목록에서 찾아본다.
    final videoId = meta['videoId'] as String? ?? '';
    for (final video in _videos) {
      if (video.id == videoId) {
        return (video.capturedStartAt ?? video.createdAt)?.toLocal();
      }
    }
    return DateTime.tryParse(meta['savedAt'] as String? ?? '')?.toLocal();
  }

  /// 이 날짜(감지된 날)에 해당하는 편집 완료 영상들.
  List<Map<String, dynamic>> _editedOn(DateTime date) => _edited.where((meta) {
    final anchor = _editedAnchorDate(meta);
    return anchor != null && DateUtils.isSameDay(anchor, date);
  }).toList();

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

  /// 이 달에 편집 완료 영상이 있는 날(일) — 감지된 날 기준.
  Set<int> get _editedDays {
    final days = <int>{};
    for (final meta in _edited) {
      final anchor = _editedAnchorDate(meta);
      if (anchor == null) continue;
      if (anchor.year != _month.year || anchor.month != _month.month) {
        continue;
      }
      days.add(anchor.day);
    }
    return days;
  }

  @override
  Widget build(BuildContext context) {
    final selectedVideos = _videosOn(_selected);
    final selectedEdited = _editedOn(_selected);
    final selectedSchedules = _schedulesOn(_selected);
    return AppBackdrop(
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _CalendarHeroHeader(onAdd: _openEditor),
            Expanded(
              child: ListView(
                key: const PageStorageKey('calendar-scroll'),
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 28),
                children: [
                  _CalendarMonthCard(
                    month: _month,
                    selected: _selected,
                    videos: _videos,
                    editedDays: _editedDays,
                    schedules: _state.schedules,
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
                  if (selectedEdited.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _SelectedEditedCard(
                      date: _selected,
                      edited: selectedEdited,
                    ),
                  ],
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
  const _CalendarHeroHeader({required this.onAdd});

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
            cacheWidth: decodePixels(context, 122),
          ),
        ),
        Positioned(
          left: 16,
          top: 22,
          child: Row(
            children: [
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

class _CalendarMonthCard extends StatelessWidget {
  const _CalendarMonthCard({
    required this.month,
    required this.selected,
    required this.videos,
    required this.editedDays,
    required this.schedules,
    required this.onPrevious,
    required this.onNext,
    required this.onSelected,
  });

  final DateTime month;
  final DateTime selected;
  final List<VideoMemory> videos;

  /// 이 달에 편집 완료 영상이 있는 날(일).
  final Set<int> editedDays;
  final List<CalendarSchedule> schedules;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<DateTime> onSelected;

  /// 이 달에 영상이 있는 날(일).
  ///
  /// **왜 미리 갈라 두는가**: 예전에는 칸을 그릴 때마다 "이 날짜의 영상"을 물었고,
  /// 그 함수는 매번 목록 전체를 훑어 새 리스트를 만들었다. 한 달 칸이 35~42개니
  /// 한 프레임에 목록을 마흔 번 훑는 셈이다 — 한 달치 영상이 200개면 8천 번을 돌고
  /// 리스트를 마흔 개 만들어 곧바로 버린다. 달을 넘길 때마다, 위 화면이 다시 그려질
  /// 때마다 되풀이된다. 한 번 훑어 날짜로 갈라 두면 칸마다 조회 한 번으로 끝난다.
  Set<int> get _videoDays {
    final days = <int>{};
    for (final video in videos) {
      final startedAt = video.capturedStartAt ?? video.createdAt;
      if (startedAt == null) continue;
      if (startedAt.year != month.year || startedAt.month != month.month) {
        continue;
      }
      days.add(startedAt.day);
    }
    return days;
  }

  /// 이 달의 날(일)별 일정. 매년 반복하는 일정은 연도를 따지지 않는다.
  Map<int, List<CalendarSchedule>> get _schedulesByDay {
    final byDay = <int, List<CalendarSchedule>>{};
    for (final schedule in schedules) {
      final date = schedule.date;
      if (schedule.yearly) {
        if (date.month != month.month) continue;
      } else if (date.year != month.year || date.month != month.month) {
        continue;
      }
      (byDay[date.day] ??= <CalendarSchedule>[]).add(schedule);
    }
    return byDay;
  }

  @override
  Widget build(BuildContext context) {
    final videoDays = _videoDays;
    final schedulesByDay = _schedulesByDay;
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
                    fontSize: 24,
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
          const SizedBox(height: 10),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisExtent: 72,
            ),
            itemCount: cellCount,
            itemBuilder: (_, index) {
              if (index < blankCount || index >= blankCount + dayCount) {
                return const SizedBox.shrink();
              }
              final day = index - blankCount + 1;
              final date = DateTime(month.year, month.month, day);
              return _CalendarDayCell(
                date: date,
                selected: DateUtils.isSameDay(date, selected),
                hasVideos: videoDays.contains(day),
                hasEdited: editedDays.contains(day),
                schedules: schedulesByDay[day] ?? const <CalendarSchedule>[],
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
              height: 1.2,
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
    required this.hasEdited,
    required this.schedules,
    required this.onTap,
  });

  final DateTime date;
  final bool selected;
  final bool hasVideos;

  /// 이 날 편집 완료한 영상이 있는가 — 감지 영상과 다른 색으로 표시한다.
  final bool hasEdited;
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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 50,
            height: 58,
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
                      fontSize: selected ? 21 : 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (hasVideos || hasEdited)
                  Positioned(
                    bottom: 3,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hasVideos)
                          const Icon(
                            Icons.videocam_outlined,
                            size: 12,
                            color: Color(0xFF71943D),
                          ),
                        if (hasVideos && hasEdited) const SizedBox(width: 2),
                        if (hasEdited)
                          const Icon(
                            Icons.auto_awesome_rounded,
                            size: 11,
                            color: Color(0xFFFF725B),
                          ),
                      ],
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
    trailing: videos.isEmpty
        ? const Icon(Icons.favorite_border_rounded, color: Color(0xFFD4D9A6))
        : TextButton(
            key: const Key('calendar-memory-more'),
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => _DayMemoriesScreen(
                  date: date,
                  videos: videos,
                  controller: controller,
                ),
              ),
            ),
            child: const Text(
              '더보기',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
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
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: Colors.transparent,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    videos.first.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => VideoDetailScreen(
                        controller: controller,
                        video: videos.first,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
  );
}

class _DayMemoriesScreen extends StatelessWidget {
  const _DayMemoriesScreen({
    required this.date,
    required this.videos,
    required this.controller,
  });

  final DateTime date;
  final List<VideoMemory> videos;
  final AppController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('${DateFormat('M월 d일').format(date)}의 추억')),
    body: AppBackdrop(
      child: SafeArea(
        top: false,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
          itemCount: videos.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final video = videos[index];
            return SoftCard(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: MemoryTile(
                api: controller.api,
                video: video,
                onTap: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        VideoDetailScreen(controller: controller, video: video),
                  ),
                ),
                onFavorite: () => controller.toggleFavorite(video),
              ),
            );
          },
        ),
      ),
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
          child: Image.asset(
            iconAsset,
            fit: BoxFit.contain,
            cacheWidth: decodePixels(context, 54),
          ),
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

/// 선택한 날짜의 편집 완료 영상. 누르면 재생·댓글 화면으로 간다.
class _SelectedEditedCard extends StatelessWidget {
  const _SelectedEditedCard({required this.date, required this.edited});

  final DateTime date;
  final List<Map<String, dynamic>> edited;

  @override
  Widget build(BuildContext context) => _DaySummaryCard(
    tint: const Color(0xFFFFF4EE),
    borderColor: const Color(0xFFF3D9C6),
    iconAsset: 'assets/images/calendar_memory_card.png',
    title: '${DateFormat('M월 d일').format(date)}의 편집 영상',
    trailing: const Icon(Icons.auto_awesome_rounded, color: Color(0xFFFF725B)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final meta in edited)
          Material(
            color: Colors.transparent,
            child: ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(
                Icons.play_circle_outline_rounded,
                color: Color(0xFFFF725B),
              ),
              title: Text(
                (meta['title'] as String?)?.isNotEmpty == true
                    ? meta['title'] as String
                    : '편집한 영상',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '댓글을 남길 수 있어요',
                style: const TextStyle(fontSize: 11),
              ),
              trailing: const Icon(Icons.mode_comment_outlined, size: 18),
              onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => EditedVideoScreen(
                    videoId: meta['videoId'] as String? ?? '',
                    title: (meta['title'] as String?)?.isNotEmpty == true
                        ? meta['title'] as String
                        : '편집한 영상',
                    savedAt: DateTime.tryParse(
                      meta['savedAt'] as String? ?? '',
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
