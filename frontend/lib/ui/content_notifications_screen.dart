import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'content_state.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

class ContentNotificationsScreen extends StatefulWidget {
  const ContentNotificationsScreen({
    super.key,
    required this.controller,
    this.onOpenInvitations,
    this.onOpenDevices,
    this.contentState,
  });

  final AppController controller;
  final VoidCallback? onOpenInvitations;
  final VoidCallback? onOpenDevices;
  final ContentState? contentState;

  @override
  State<ContentNotificationsScreen> createState() =>
      _ContentNotificationsScreenState();
}

class _ContentNotificationsScreenState
    extends State<ContentNotificationsScreen> {
  final Set<String> _readIds = {};

  ContentState get _state => widget.contentState ?? ContentState.instance;

  List<ContentNotification> get _items {
    final now = DateTime.now();
    final birthdays = _state.schedules.expand((schedule) sync* {
      if (!schedule.yearly || !schedule.title.contains('생일')) return;
      final occurrence = nextYearlyOccurrence(schedule.date, from: now);
      final days = calendarDayDifference(occurrence, from: now);
      if (days < 0 || days > 3) return;
      yield ContentNotification(
        id: 'birthday-${schedule.id}-${occurrence.year}',
        type: ContentNotificationType.birthday,
        title: '생일 알림',
        message: '${schedule.title} ${dDayLabel(occurrence, from: now)}',
        createdAt: now,
      );
    });
    final laughter = widget.controller.videos
        .where((video) => video.triggerType == 'LAUGHTER')
        .map(
          (video) => ContentNotification(
            id: 'laughter-${video.id}',
            type: ContentNotificationType.laughter,
            title: '웃음이 감지되었어요',
            message: '${video.title} 영상이 저장되었습니다.',
            createdAt: video.capturedStartAt ?? video.createdAt ?? now,
            videoId: video.id,
          ),
        );
    final invitations = widget.controller.receivedInvitations
        .where((invitation) => invitation.isPending)
        .map(
          (invitation) => ContentNotification(
            id: 'invitation-${invitation.id}',
            type: ContentNotificationType.invitation,
            title: '가족 초대가 도착했어요',
            message:
                '${invitation.inviter?.displayName ?? invitation.inviteeEmail}님의 초대를 확인해 주세요.',
            createdAt: invitation.createdAt ?? now,
          ),
        );
    // TODO(content-api): 기기 연결 끊김/오프라인 알림을 API 응답으로 추가합니다.
    return [...birthdays, ...laughter, ...invitations]
      ..sort((left, right) => right.createdAt.compareTo(left.createdAt));
  }

  Future<void> _open(ContentNotification item) async {
    setState(() => _readIds.add(item.id));
    switch (item.type) {
      case ContentNotificationType.laughter:
        final matches = widget.controller.videos.where(
          (candidate) => candidate.id == item.videoId,
        );
        if (matches.isEmpty) {
          showAppSnack(context, '영상이 삭제되었거나 존재하지 않습니다.', error: true);
          return;
        }
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => VideoDetailScreen(
              controller: widget.controller,
              video: matches.first,
            ),
          ),
        );
      case ContentNotificationType.invitation:
        if (widget.onOpenInvitations == null) {
          showAppSnack(context, '초대 확인 화면 연결이 필요합니다.', error: true);
        } else {
          widget.onOpenInvitations!();
        }
      case ContentNotificationType.device:
        if (widget.onOpenDevices == null) {
          showAppSnack(context, '기기 관리 화면 연결이 필요합니다.', error: true);
        } else {
          widget.onOpenDevices!();
        }
      case ContentNotificationType.birthday:
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      body: AppBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 72,
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
                        '알림',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                    ),
                    TextButton(
                      onPressed: items.isEmpty
                          ? null
                          : () => setState(
                              () =>
                                  _readIds.addAll(items.map((item) => item.id)),
                            ),
                      child: const Text('모두 읽음'),
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
              ),
              Expanded(
                child: items.isEmpty
                    ? const EmptyState(
                        icon: Icons.notifications_none_rounded,
                        title: '새 알림이 없어요',
                        message: '웃음과 가족 소식이 생기면 알려드릴게요.',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (_, index) {
                          final item = items[index];
                          final visual = _visualFor(item.type);
                          return SoftCard(
                            padding: EdgeInsets.zero,
                            child: ListTile(
                              onTap: () => _open(item),
                              leading: CircleAvatar(
                                backgroundColor: visual.background,
                                child: Icon(
                                  visual.icon,
                                  color: visual.foreground,
                                ),
                              ),
                              title: Text(
                                item.title,
                                style: TextStyle(
                                  fontWeight: _readIds.contains(item.id)
                                      ? FontWeight.w600
                                      : FontWeight.w900,
                                ),
                              ),
                              subtitle: Text(
                                '${item.message}\n'
                                '${DateFormat('M월 d일 HH:mm').format(item.createdAt)}',
                              ),
                              isThreeLine: true,
                              trailing: _readIds.contains(item.id)
                                  ? null
                                  : const Icon(
                                      Icons.circle,
                                      size: 9,
                                      color: AppColors.sageDark,
                                    ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

({IconData icon, Color background, Color foreground}) _visualFor(
  ContentNotificationType type,
) => switch (type) {
  ContentNotificationType.birthday => (
    icon: Icons.cake_rounded,
    background: AppColors.yellowSoft,
    foreground: const Color(0xFFC18425),
  ),
  ContentNotificationType.laughter => (
    icon: Icons.sentiment_very_satisfied_rounded,
    background: AppColors.sageSoft,
    foreground: AppColors.sageDark,
  ),
  ContentNotificationType.invitation => (
    icon: Icons.group_add_outlined,
    background: AppColors.greenCard,
    foreground: AppColors.sageDark,
  ),
  ContentNotificationType.device => (
    icon: Icons.devices_other_rounded,
    background: const Color(0xFFE8EEF7),
    foreground: const Color(0xFF55718F),
  ),
};
