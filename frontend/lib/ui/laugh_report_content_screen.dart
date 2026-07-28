import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'memory_video_card.dart';
import 'widgets.dart';

class LaughReportContentScreen extends StatefulWidget {
  const LaughReportContentScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<LaughReportContentScreen> createState() =>
      _LaughReportContentScreenState();
}

class _LaughReportContentScreenState extends State<LaughReportContentScreen> {
  bool _showLawn = false;
  DateTime? _selectedDate;

  Map<DateTime, List<VideoMemory>> get _videosByDay {
    final result = <DateTime, List<VideoMemory>>{};
    for (final video in widget.controller.videos.where(
      (item) => item.triggerType == 'LAUGHTER',
    )) {
      final at = video.capturedStartAt ?? video.createdAt;
      if (at == null) continue;
      result.putIfAbsent(DateUtils.dateOnly(at), () => []).add(video);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final byDay = _videosByDay;
    final total = byDay.values.fold<int>(
      0,
      (sum, videos) => sum + videos.length,
    );
    final selectedVideos = _selectedDate == null
        ? const <VideoMemory>[]
        : byDay[_selectedDate] ?? const <VideoMemory>[];
    return Scaffold(
      body: AppBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 68,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    RoundIconButton(
                      icon: Icons.chevron_left_rounded,
                      onPressed: () => Navigator.maybePop(context),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '웃음 리포트',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: false, label: Text('리포트')),
                        ButtonSegment(value: true, label: Text('웃음 잔디')),
                      ],
                      selected: {_showLawn},
                      onSelectionChanged: (value) =>
                          setState(() => _showLawn = value.first),
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                  children: [
                    if (!_showLawn) ...[
                      Row(
                        children: [
                          Expanded(
                            child: _StatCard(
                              value: '$total회',
                              label: '전체 웃음 감지',
                              color: AppColors.sageSoft,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _StatCard(
                              value: '${byDay.length}일',
                              label: '웃음이 있던 날',
                              color: AppColors.greenCard,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SoftCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '최근 날짜별 웃음',
                              style: TextStyle(fontWeight: FontWeight.w900),
                            ),
                            const SizedBox(height: 12),
                            if (byDay.isEmpty)
                              const Text('아직 웃음 감지 기록이 없습니다')
                            else
                              for (final entry
                                  in (byDay.entries.toList()..sort(
                                        (a, b) => b.key.compareTo(a.key),
                                      ))
                                      .take(14))
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    DateFormat('M월 d일').format(entry.key),
                                  ),
                                  trailing: Text(
                                    '${entry.value.length}회',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  onTap: () => setState(() {
                                    _selectedDate = entry.key;
                                    _showLawn = true;
                                  }),
                                ),
                          ],
                        ),
                      ),
                    ] else ...[
                      _LaughLawn(
                        counts: {
                          for (final entry in byDay.entries)
                            entry.key: entry.value.length,
                        },
                        selected: _selectedDate,
                        onSelected: (date) =>
                            setState(() => _selectedDate = date),
                      ),
                      if (_selectedDate != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          '${DateFormat('M월 d일').format(_selectedDate!)} 웃음 영상',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (selectedVideos.isEmpty)
                          const Text('이 날짜에는 웃음 감지 영상이 없습니다')
                        else
                          for (final video in selectedVideos)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: MemoryVideoCard(
                                controller: widget.controller,
                                video: video,
                                onChanged: () => setState(() {}),
                              ),
                            ),
                      ],
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LaughLawn extends StatelessWidget {
  const _LaughLawn({
    required this.counts,
    required this.selected,
    required this.onSelected,
  });

  final Map<DateTime, int> counts;
  final DateTime? selected;
  final ValueChanged<DateTime> onSelected;

  Color _color(int count) {
    if (count == 0) return const Color(0xFFF0F3EC);
    if (count == 1) return const Color(0xFFDDECCB);
    if (count <= 3) return const Color(0xFFBCD99C);
    if (count <= 6) return const Color(0xFF8FBE72);
    return const Color(0xFF5E9550);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final start = DateTime(now.year, 1, 1);
    final days = now.difference(start).inDays + 1;
    return SoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${now.year}년 웃음 기록',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 14,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            itemCount: days,
            itemBuilder: (_, index) {
              final day = start.add(Duration(days: index));
              final count = counts[day] ?? 0;
              return Tooltip(
                message: '${DateFormat('M월 d일').format(day)} · $count회',
                child: InkWell(
                  onTap: () => onSelected(day),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: _color(count),
                      borderRadius: BorderRadius.circular(3),
                      border: DateUtils.isSameDay(day, selected)
                          ? Border.all(color: AppColors.ink, width: 2)
                          : null,
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              const Text('적음', style: TextStyle(fontSize: 11)),
              const SizedBox(width: 6),
              for (final count in [0, 1, 2, 4, 7])
                Container(
                  width: 16,
                  height: 16,
                  margin: const EdgeInsets.only(left: 3),
                  decoration: BoxDecoration(
                    color: _color(count),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              const SizedBox(width: 6),
              const Text('많음', style: TextStyle(fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.value,
    required this.label,
    required this.color,
  });

  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => SoftCard(
    color: color,
    child: Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 4),
        Text(label),
      ],
    ),
  );
}
