import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import '../core/notification_visuals.dart';
import '../features/comic/comic_screen.dart';
import 'content_calendar_screen.dart';
import 'edited_video_screen.dart';
import 'invitation_inbox_screen.dart';
import 'laugh_report_content_screen.dart';
import 'video_detail_screen.dart';
import 'widgets.dart';

class ContentNotificationsScreen extends StatefulWidget {
  const ContentNotificationsScreen({
    super.key,
    required this.controller,
    this.onOpenInvitations,
    this.onOpenDevices,
  });

  final AppController controller;
  final VoidCallback? onOpenInvitations;
  final VoidCallback? onOpenDevices;

  @override
  State<ContentNotificationsScreen> createState() =>
      _ContentNotificationsScreenState();
}

class _ContentNotificationsScreenState
    extends State<ContentNotificationsScreen> {
  List<AppNotification> items = const [];
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    try {
      final loaded = await widget.controller.api.listNotifications();
      if (mounted) setState(() => items = loaded);
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _markAllRead() async {
    try {
      await widget.controller.api.markAllNotificationsRead();
      final readAt = DateTime.now();
      if (mounted) {
        setState(
          () => items = items
              .map((item) => item.copyWith(readAt: readAt))
              .toList(growable: false),
        );
      }
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
    }
  }

  /// 알림이 가리키는 영상. 이미 받아 둔 목록에 있으면 그것을 쓰고, 없으면
  /// 한 건만 받아 온다 — 목록에 없는 영상(다른 기기·오래된 것)도 열려야 한다.
  Future<VideoMemory> _videoFor(String videoId) async {
    final matches = widget.controller.videos.where(
      (candidate) => candidate.id == videoId,
    );
    return matches.isNotEmpty
        ? matches.first
        : await widget.controller.api.getVideo(videoId);
  }

  Future<void> _open(AppNotification item) async {
    if (!item.isRead) {
      try {
        await widget.controller.api.markNotificationRead(item.id);
        final index = items.indexWhere((candidate) => candidate.id == item.id);
        if (mounted && index >= 0) {
          final next = [...items];
          next[index] = item.copyWith(readAt: DateTime.now());
          setState(() => items = next);
        }
      } catch (_) {
        // 대상 화면은 읽음 API가 일시 실패해도 열 수 있어야 한다.
      }
    }

    if (!mounted) return;
    if (item.type == 'EDIT_COMMENT_ADDED' && item.resourceId != null) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => EditedVideoScreen(
            api: widget.controller.api,
            videoId: item.resourceId!,
            title: '',
            myUserId: widget.controller.user?.id,
            isOwner: widget.controller.isOwner,
          ),
        ),
      );
      return;
    }
    // 만화 완성은 만화 화면으로 곧장 간다. 그림 생성이 백그라운드로 바뀌면서
    // "화면을 나간 뒤에 끝나는 것"이 정상 경로가 됐으므로, 알림에서 한 번에
    // 결과까지 가야 한다 — 영상 상세를 거치게 하면 만화 버튼을 다시 찾아
    // 눌러야 한다.
    //
    // 대사 준비 알림도 같은 곳으로 보낸다. 만화 화면이 저장된 구성을 읽어
    // 대사 편집으로 이어 주므로, 사용자가 고칠 자리가 곧 여기다.
    if ((item.type == 'COMIC_READY' || item.type == 'COMIC_SCRIPT_READY') &&
        item.resourceId != null) {
      try {
        final video = await _videoFor(item.resourceId!);
        if (!mounted) return;
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) =>
                ComicScreen(api: widget.controller.api, video: video),
          ),
        );
      } catch (failure) {
        if (mounted) showAppSnack(context, '$failure', error: true);
      }
      return;
    }
    // 분석 완료는 웃음 영상 도착과 같은 목적지다 — 영상 상세에서 편집하기를
    // 누르면 이미 분석돼 있어 AI 컷이 바로 열린다.
    if ((item.type == 'LAUGHTER_VIDEO_READY' ||
            item.type == 'EDIT_ANALYSIS_READY') &&
        item.resourceId != null) {
      try {
        final video = await _videoFor(item.resourceId!);
        if (!mounted) return;
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) =>
                VideoDetailScreen(controller: widget.controller, video: video),
          ),
        );
      } catch (failure) {
        if (mounted) showAppSnack(context, '$failure', error: true);
      }
      return;
    }

    // 주기 리포트 알림은 각자의 화면으로 — 기념일은 캘린더, 주간 리포트는
    // 웃음 리포트다.
    if (item.type == 'ANNIVERSARY' || item.type == 'WEEKLY_REPORT') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => item.type == 'ANNIVERSARY'
              ? ContentCalendarScreen(controller: widget.controller)
              : LaughReportContentScreen(controller: widget.controller),
        ),
      );
      return;
    }

    if (item.type == 'INVITATION_RECEIVED') {
      await widget.controller.refreshMyInvitations();
      if (!mounted) return;
      if (widget.onOpenInvitations != null) {
        widget.onOpenInvitations!();
      } else {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) =>
                InvitationInboxScreen(controller: widget.controller),
          ),
        );
      }
      return;
    }
    widget.onOpenDevices?.call();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
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
                      '알림 센터',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  TextButton(
                    onPressed: items.any((item) => !item.isRead)
                        ? _markAllRead
                        : null,
                    child: const Text('모두 읽음'),
                  ),
                  const SizedBox(width: 12),
                ],
              ),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.pink,
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Row(
                children: [
                  Text('🌱', style: TextStyle(fontSize: 20)),
                  SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      '가족에게 꼭 필요한 순간만 부드럽고 편안하게 전해드려요.',
                      style: TextStyle(
                        color: AppColors.inkSoft,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _body()),
          ],
        ),
      ),
    ),
  );

  Widget _body() {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (error != null) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 70),
            EmptyState(
              icon: Icons.cloud_off_rounded,
              title: '알림을 불러오지 못했어요',
              message: error!,
            ),
          ],
        ),
      );
    }
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 70),
            EmptyState(
              icon: Icons.notifications_none_rounded,
              title: '새 알림이 없어요',
              message: '가족과 추억 소식이 생기면 알려드릴게요.',
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(height: 9),
        itemBuilder: (_, index) {
          final item = items[index];
          final visual = notificationVisualFor(item.type);
          return SoftCard(
            color: item.isRead ? AppColors.surface : const Color(0xFFFFFBF6),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => _open(item),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 45,
                    height: 45,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: visual.background,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      visual.emoji,
                      style: const TextStyle(fontSize: 23),
                    ),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 갈래를 먼저 알려 주는 라벨. 제목이 비슷한 알림
                        // ('...이 도착했어요'가 여럿이다)을 훑어 읽을 때
                        // 이모지 하나만으로는 갈라지지 않았다.
                        Text(
                          visual.category,
                          style: TextStyle(
                            color: visual.accent,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          item.title,
                          style: TextStyle(
                            fontWeight: item.isRead
                                ? FontWeight.w700
                                : FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          item.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.inkSoft,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        DateFormat('M/d HH:mm').format(item.createdAt),
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 10,
                        ),
                      ),
                      if (!item.isRead) ...[
                        const SizedBox(height: 9),
                        const Icon(
                          Icons.circle,
                          size: 8,
                          color: AppColors.coral,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

