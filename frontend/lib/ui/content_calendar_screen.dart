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
            SizedBox(
              height: 68,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  RoundIconButton(
                    icon: Icons.chevron_left_rounded,
                    onPressed:
                        widget.onBack ?? () => Navigator.maybePop(context),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '캘린더',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _openEditor,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('일정 추가'),
                  ),
                  const SizedBox(width: 16),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                children: [
                  SoftCard(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            IconButton(
                              onPressed: () => _changeMonth(-1),
                              icon: const Icon(Icons.chevron_left_rounded),
                            ),
                            Expanded(
                              child: Text(
                                DateFormat('yyyy년 M월').format(_month),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            IconButton(
                              onPressed: () => _changeMonth(1),
                              icon: const Icon(Icons.chevron_right_rounded),
                            ),
                          ],
                        ),
                        const _WeekdayHeader(),
                        _MonthGrid(
                          month: _month,
                          selected: _selected,
                          videosOn: _videosOn,
                          schedulesOn: _schedulesOn,
                          onSelected: (date) =>
                              setState(() => _selected = date),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${DateFormat('M월 d일').format(_selected)} 일정',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (selectedSchedules.isEmpty)
                    const Text(
                      '등록된 일정이 없습니다',
                      style: TextStyle(color: AppColors.muted),
                    )
                  else
                    ...selectedSchedules.map(
                      (schedule) => Card(
                        child: ListTile(
                          leading: const Icon(Icons.event_rounded),
                          title: Text(schedule.title),
                          subtitle: Text(
                            '${schedule.memo.isEmpty ? '등록된 내용이 없습니다' : schedule.memo}'
                            ' · ${dDayLabel(schedule.yearly ? nextYearlyOccurrence(schedule.date) : schedule.date)}',
                          ),
                          trailing: IconButton(
                            tooltip: '일정 수정',
                            onPressed: () => _openEditor(schedule: schedule),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    '${DateFormat('M월 d일').format(_selected)}의 추억',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_loading)
                    const Center(child: CircularProgressIndicator())
                  else if (_error != null)
                    Text('영상을 불러오지 못했어요. $_error')
                  else if (selectedVideos.isEmpty)
                    const Text(
                      '등록된 영상이 없습니다',
                      style: TextStyle(color: AppColors.muted),
                    )
                  else
                    ...selectedVideos.map(
                      (video) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _CalendarVideoCard(
                          video: video,
                          onTap: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) => VideoDetailScreen(
                                controller: widget.controller,
                                video: video,
                              ),
                            ),
                          ),
                        ),
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
}

class _WeekdayHeader extends StatelessWidget {
  const _WeekdayHeader();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final day in ['일', '월', '화', '수', '목', '금', '토'])
        Expanded(
          child: Center(
            child: Text(
              day,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
    ],
  );
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.month,
    required this.selected,
    required this.videosOn,
    required this.schedulesOn,
    required this.onSelected,
  });

  final DateTime month;
  final DateTime selected;
  final List<VideoMemory> Function(DateTime) videosOn;
  final List<CalendarSchedule> Function(DateTime) schedulesOn;
  final ValueChanged<DateTime> onSelected;

  @override
  Widget build(BuildContext context) {
    final blankCount = month.weekday % 7;
    final dayCount = DateUtils.getDaysInMonth(month.year, month.month);
    return GridView.builder(
      padding: const EdgeInsets.only(top: 8),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        childAspectRatio: .82,
      ),
      itemCount: blankCount + dayCount,
      itemBuilder: (_, index) {
        if (index < blankCount) return const SizedBox.shrink();
        final date = DateTime(month.year, month.month, index - blankCount + 1);
        final videos = videosOn(date);
        final schedules = schedulesOn(date);
        final isToday = DateUtils.isSameDay(date, DateTime.now());
        final isSelected = DateUtils.isSameDay(date, selected);
        return InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onSelected(date),
          child: Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppColors.yellowSoft
                  : isToday
                  ? AppColors.sageSoft
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
              border: isToday ? Border.all(color: AppColors.sageDark) : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '${date.day}',
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                if (videos.isNotEmpty)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        videos.any((video) => video.triggerType == 'LAUGHTER')
                            ? Icons.sentiment_very_satisfied_rounded
                            : Icons.videocam_outlined,
                        size: 13,
                        color: AppColors.sageDark,
                      ),
                      if (videos.length > 1)
                        Text(
                          '${videos.length}',
                          style: const TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                    ],
                  )
                else if (schedules.isNotEmpty)
                  const Icon(
                    Icons.event_rounded,
                    size: 12,
                    color: AppColors.sageDark,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CalendarVideoCard extends StatelessWidget {
  const _CalendarVideoCard({required this.video, required this.onTap});

  final VideoMemory video;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SoftCard(
    padding: EdgeInsets.zero,
    child: ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.all(10),
      leading: MemoryThumbnail(video: video, width: 92, height: 70),
      title: Text(video.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${durationLabel(video.durationMs)}\n'
        '${video.description?.trim().isNotEmpty == true ? video.description!.trim() : '등록된 메모가 없습니다'}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right_rounded),
    ),
  );
}
