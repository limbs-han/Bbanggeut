import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import '../core/notification_visuals.dart';
import 'notification_routing.dart';
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
    // 목적지 결정은 여기 두지 않는다 — 푸시를 눌렀을 때 도는 쪽(app.dart)과
    // 갈라져 있던 동안 같은 알림이 어디서 눌렀느냐에 따라 다른 곳으로 갔다.
    await openNotificationTarget(
      context,
      controller: widget.controller,
      type: item.type,
      resourceId: item.resourceId,
      onOpenInvitations: widget.onOpenInvitations,
      onOpenDevices: widget.onOpenDevices,
    );
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

