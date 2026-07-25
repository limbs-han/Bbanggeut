import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  int filter = 0;
  bool allRead = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final latest = controller.videos
        .where((video) => filter == 0 || video.triggerType == 'LAUGHTER')
        .take(3)
        .toList();
    final showAnniversary = filter == 0 || filter == 1;
    final showSystem = filter == 0 || filter == 3;
    final hasNotices =
        (showSystem && controller.receivedInvitations.isNotEmpty) ||
        showAnniversary ||
        latest.isNotEmpty;
    return Scaffold(
      body: AppBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              _SubHeader(
                title: '알림',
                trailing: TextButton(
                  onPressed: allRead
                      ? null
                      : () => setState(() => allRead = true),
                  child: const Text('모두 읽음'),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
                  children: [
                    _FilterRow(
                      labels: const ['전체', '기념일', '웃음 감지', '시스템'],
                      selectedIndex: filter,
                      onSelected: (value) => setState(() => filter = value),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      '오늘',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.muted,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (showAnniversary)
                      _NoticeTile(
                        icon: Icons.cake_outlined,
                        color: AppColors.yellowSoft,
                        title: '기념일 알림',
                        message: '엄마 생일이 3일 앞으로 다가왔어요.',
                        time: '오전 9:00',
                        unread: !allRead,
                      ),
                    if (showSystem)
                      ...controller.receivedInvitations.map(
                        (invitation) => _NoticeTile(
                          icon: Icons.group_add_outlined,
                          color: AppColors.greenCard,
                          title: '새로운 가족 초대',
                          message:
                              '${invitation.inviter?.displayName ?? '가족'}님이 ${invitation.deviceName} 기기에 초대했어요.',
                          time: memoryDate(invitation.createdAt),
                          unread: !allRead,
                        ),
                      ),
                    ...latest.map(
                      (video) => _NoticeTile(
                        icon: triggerIcon(video.triggerType),
                        color: triggerColor(video.triggerType),
                        title: video.triggerType == 'LAUGHTER'
                            ? '웃음 포착'
                            : '새로운 추억',
                        message: '${video.title} 영상이 안전하게 저장됐어요.',
                        time: memoryDate(
                          video.capturedStartAt ?? video.createdAt,
                        ),
                        unread: !allRead && video == latest.firstOrNull,
                      ),
                    ),
                    if (!hasNotices)
                      const EmptyState(
                        icon: Icons.notifications_none_rounded,
                        title: '새 알림이 없어요',
                        message: '새로운 웃음과 가족 소식이 생기면 알려드릴게요.',
                      ),
                    const SizedBox(height: 18),
                    const SoftCard(
                      color: AppColors.sageSoft,
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: AppColors.surface,
                            child: Icon(
                              Icons.notifications_none_rounded,
                              color: AppColors.sageDark,
                            ),
                          ),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '필요한 알림만 받아보세요\n설정에서 알림 시간을 조정할 수 있어요.',
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.inkSoft,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: AppColors.muted,
                          ),
                        ],
                      ),
                    ),
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

class AnniversaryEditorScreen extends StatefulWidget {
  const AnniversaryEditorScreen({
    super.key,
    this.initialDate,
    this.screenTitle = '기념일 등록',
  });
  final DateTime? initialDate;
  final String screenTitle;
  @override
  State<AnniversaryEditorScreen> createState() =>
      _AnniversaryEditorScreenState();
}

class _AnniversaryEditorScreenState extends State<AnniversaryEditorScreen> {
  final title = TextEditingController(text: '엄마 생일');
  final memo = TextEditingController(text: '화이트 같은 날에 말해드려요');
  late DateTime date;
  bool yearly = true;

  @override
  void initState() {
    super.initState();
    date = widget.initialDate ?? DateTime.now().add(const Duration(days: 3));
  }

  @override
  void dispose() {
    title.dispose();
    memo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AppBackdrop(
      child: SafeArea(
        child: Column(
          children: [
            _SubHeader(
              title: widget.screenTitle,
              trailing: TextButton(
                onPressed: () {
                  showAppSnack(
                    context,
                    '기념일 저장 API가 없어 현재 화면에서는 저장되지 않아요.',
                    error: true,
                  );
                },
                child: const Text('저장'),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                children: [
                  const _FormLabel('기념일 이름'),
                  TextField(controller: title),
                  const SizedBox(height: 18),
                  const _FormLabel('날짜'),
                  InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                        initialDate: date,
                      );
                      if (picked != null) setState(() => date = picked);
                    },
                    child: SoftCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 15,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              DateFormat('yyyy년 M월 d일 (E)', 'ko').format(date),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.calendar_month_outlined,
                            color: AppColors.muted,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      '매년 반복',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: const Text('해마다 같은 날에 알려드려요'),
                    value: yearly,
                    onChanged: (value) => setState(() => yearly = value),
                  ),
                  const SizedBox(height: 14),
                  const _FormLabel('알림 시간'),
                  const SoftCard(
                    padding: EdgeInsets.symmetric(horizontal: 14, vertical: 15),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '오전 9:00',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        Icon(Icons.schedule_rounded, color: AppColors.muted),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  const _FormLabel('연결할 추억'),
                  const SoftCard(
                    padding: EdgeInsets.all(10),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 90,
                          child: FamilyReferenceImage(borderRadius: 12),
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '소원 빌던 생일 저녁',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: AppColors.muted,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: () => showAppSnack(
                      context,
                      '백엔드 기념일 저장 API가 필요해요.',
                      error: true,
                    ),
                    child: const Text('기념일 저장하기'),
                  ),
                  const SizedBox(height: 28),
                  const Center(
                    child: Text(
                      '알림은 설정에서 언제든 변경할 수 있어요.',
                      style: TextStyle(fontSize: 12, color: AppColors.muted),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class LaughReportScreen extends StatefulWidget {
  const LaughReportScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<LaughReportScreen> createState() => _LaughReportScreenState();
}

class _LaughReportScreenState extends State<LaughReportScreen> {
  int tab = 0;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: AppBackdrop(
      child: SafeArea(
        child: Column(
          children: [
            const _SubHeader(title: '웃음 리포트'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('리포트')),
                  ButtonSegment(value: 1, label: Text('웃음 잔디')),
                ],
                selected: {tab},
                onSelectionChanged: (value) =>
                    setState(() => tab = value.first),
                showSelectedIcon: false,
              ),
            ),
            Expanded(
              child: tab == 0
                  ? _ReportBody(controller: widget.controller)
                  : _LawnBody(controller: widget.controller),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ReportBody extends StatelessWidget {
  const _ReportBody({required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final stats = controller.videoStats;
    final laughs = stats?.byTriggerType['LAUGHTER'] ?? 0;
    final total = stats?.totalCount ?? 0;
    final dailyCounts = stats?.dailyCounts.isNotEmpty == true
        ? <String, int>{
            for (final day in stats!.dailyCounts)
              if (day.date != null)
                DateFormat('yyyy-MM-dd').format(day.date!): day.count,
          }
        : _videoCountsByDay(controller.videos);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SoftCard(
          color: const Color(0xFFF3E681),
          borderColor: const Color(0xFFF3E681),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                DateFormatPlaceholder.month,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              const Text(
                '이번 달 하루 평균 웃음',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              Text(
                '${(laughs / 30).toStringAsFixed(1)}회',
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Text(
                '가족의 행복한 순간을 차곡차곡 모았어요.',
                style: TextStyle(fontSize: 12, color: AppColors.inkSoft),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ReportStat(
                value: '$total회',
                label: '전체 포착',
                color: AppColors.yellowSoft,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ReportStat(
                value: '${dailyCounts.length}일',
                label: '웃은 날',
                color: AppColors.greenCard,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ReportStat(
                value: '${controller.homeSummary?.memoCount ?? 0}일',
                label: '기록한 날',
                color: AppColors.pink,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '주간 웃음 추이',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 18),
              SizedBox(
                height: 130,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: List.generate(4, (index) {
                    final weekStart = DateTime(
                      DateTime.now().year,
                      DateTime.now().month,
                      1 + index * 7,
                    );
                    final weekEnd = weekStart.add(const Duration(days: 7));
                    final value = dailyCounts.entries.fold<int>(0, (
                      sum,
                      entry,
                    ) {
                      final date = DateTime.tryParse(entry.key);
                      return date != null &&
                              !date.isBefore(weekStart) &&
                              date.isBefore(weekEnd)
                          ? sum + entry.value
                          : sum;
                    });
                    final height = 26.0 + value.clamp(0, 15) * 5;
                    return Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text(
                            '$value',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Container(
                            width: 28,
                            height: height,
                            decoration: BoxDecoration(
                              color: AppColors.sage,
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            '${index + 1}주',
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
              ),
            ],
          ),
        ),
        if (controller.videos.isNotEmpty) ...[
          const SizedBox(height: 14),
          InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => VideoDetailScreen(
                  controller: controller,
                  video: controller.videos.first,
                ),
              ),
            ),
            child: SoftCard(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  MemoryThumbnail(
                    video: controller.videos.first,
                    width: 80,
                    height: 56,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      controller.videos.first.title,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _LawnBody extends StatelessWidget {
  const _LawnBody({required this.controller});
  final AppController controller;
  @override
  Widget build(BuildContext context) {
    final stats = controller.videoStats;
    final counts = stats?.dailyCounts.isNotEmpty == true
        ? <String, int>{
            for (final day in stats!.dailyCounts)
              if (day.date != null)
                DateFormat('yyyy-MM-dd').format(day.date!): day.count,
          }
        : _videoCountsByDay(controller.videos);
    final start = DateTime(DateTime.now().year, 1, 1);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SoftCard(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${DateTime.now().year}년 웃음 기록',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(height: 16),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 18,
                  crossAxisSpacing: 3,
                  mainAxisSpacing: 3,
                ),
                itemCount: 180,
                itemBuilder: (_, index) {
                  final day = start.add(Duration(days: index));
                  final count =
                      counts[DateFormat('yyyy-MM-dd').format(day)] ?? 0;
                  return DecoratedBox(
                    decoration: BoxDecoration(
                      color: count == 0
                          ? AppColors.sageSoft
                          : count < 2
                          ? AppColors.yellowSoft
                          : count < 4
                          ? AppColors.greenCard
                          : AppColors.coral,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              Text(
                '함께 기록한 날 ${counts.length}일',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _ReportStat(
                value: '${counts.length}일',
                label: '함께 웃은 날',
                color: AppColors.sageSoft,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ReportStat(
                value: '${counts.values.fold<int>(0, (a, b) => a + b)}회',
                label: '웃음 포착',
                color: AppColors.yellowSoft,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const SoftCard(
          color: AppColors.sageSoft,
          child: Row(
            children: [
              Icon(Icons.favorite_border_rounded, color: AppColors.sageDark),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '작은 웃음이 모여\n우리 가족의 한 해가 되고 있어요.',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Map<String, int> _videoCountsByDay(Iterable<VideoMemory> videos) {
  final counts = <String, int>{};
  for (final video in videos) {
    final date = video.capturedStartAt ?? video.createdAt;
    if (date == null) continue;
    final key = DateFormat('yyyy-MM-dd').format(date);
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

class _SubHeader extends StatelessWidget {
  const _SubHeader({required this.title, this.trailing});
  final String title;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 66,
    child: Row(
      children: [
        const SizedBox(width: 14),
        RoundIconButton(
          icon: Icons.chevron_left_rounded,
          size: 44,
          onPressed: () => Navigator.pop(context),
        ),
        Expanded(
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        SizedBox(width: 88, child: trailing),
      ],
    ),
  );
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.labels,
    required this.selectedIndex,
    required this.onSelected,
  });
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  @override
  Widget build(BuildContext context) => Row(
    children: labels.indexed
        .map(
          (entry) => Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Material(
                color: entry.$1 == selectedIndex
                    ? AppColors.yellow
                    : AppColors.sageSoft,
                borderRadius: BorderRadius.circular(99),
                child: InkWell(
                  borderRadius: BorderRadius.circular(99),
                  onTap: () => onSelected(entry.$1),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 9),
                    child: Text(
                      entry.$2,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        )
        .toList(),
  );
}

class _NoticeTile extends StatelessWidget {
  const _NoticeTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.message,
    required this.time,
    required this.unread,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String message;
  final String time;
  final bool unread;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(vertical: 5),
    leading: CircleAvatar(
      backgroundColor: color,
      child: Icon(icon, color: AppColors.inkSoft),
    ),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
    subtitle: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
    trailing: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(time, style: const TextStyle(fontSize: 9, color: AppColors.muted)),
        if (unread)
          const Padding(
            padding: EdgeInsets.only(top: 5),
            child: CircleAvatar(radius: 3, backgroundColor: AppColors.coral),
          ),
      ],
    ),
  );
}

class _FormLabel extends StatelessWidget {
  const _FormLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        color: AppColors.muted,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _ReportStat extends StatelessWidget {
  const _ReportStat({
    required this.value,
    required this.label,
    required this.color,
  });
  final String value;
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 5),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10,
            color: AppColors.inkSoft,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

abstract final class DateFormatPlaceholder {
  static const month = 'JUL 2026';
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
