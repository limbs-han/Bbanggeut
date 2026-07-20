import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'device_registration_screen.dart';
import 'widgets.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final device = controller.selectedDevice!;
    final status = controller.deviceStatus;
    return CustomScrollView(
      slivers: [
        const SliverAppBar(floating: true, title: Text('설정과 보안')),
        SliverToBoxAdapter(
          child: PagePadding(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        const CircleAvatar(
                          radius: 26,
                          backgroundColor: AppColors.mint,
                          child: Icon(
                            Icons.videocam_rounded,
                            color: AppColors.primaryDark,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                device.name,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 3),
                              Text(
                                '${device.model} · ${device.myRole}',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                        StatusPill(
                          label: device.isOnline ? '온라인' : '오프라인',
                          positive: device.isOnline,
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const SectionHeader('기기 상태'),
                const SizedBox(height: 8),
                _SettingTile(
                  icon: Icons.fiber_manual_record_rounded,
                  title: '녹화 상태',
                  subtitle: status?.recording == true
                      ? '현재 순환 녹화 중'
                      : '현재 녹화하지 않음',
                  trailing: status?.recording == true ? 'ON' : 'OFF',
                ),
                _SettingTile(
                  icon: Icons.history_rounded,
                  title: '자동 보관',
                  subtitle: '기본 보관 기간',
                  trailing: '${device.retentionDays}일',
                  onTap: device.isOwner ? () => _editRetention(context) : null,
                ),
                _SettingTile(
                  icon: Icons.cloud_upload_outlined,
                  title: '업로드 대기',
                  subtitle: '기기의 전송 대기 영상',
                  trailing: '${status?.uploadQueueDepth ?? 0}개',
                ),
                const SizedBox(height: 24),
                const SectionHeader('관리'),
                const SizedBox(height: 8),
                _SettingTile(
                  icon: Icons.edit_outlined,
                  title: '기기 이름',
                  subtitle: device.name,
                  onTap: device.isOwner ? () => _editName(context) : null,
                ),
                _SettingTile(
                  icon: Icons.workspace_premium_outlined,
                  title: '보관 구독',
                  subtitle: '장기 보관 상태와 변경',
                  onTap: device.isOwner ? () => _subscription(context) : null,
                ),
                _SettingTile(
                  icon: Icons.receipt_long_outlined,
                  title: '접근 기록',
                  subtitle: '최근 조회·다운로드 확인',
                  onTap: () => _logs(context),
                ),
                _SettingTile(
                  icon: Icons.add_to_photos_outlined,
                  title: '새 기기 연결',
                  subtitle: '8자리 등록 코드 사용',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          DeviceRegistrationScreen(controller: controller),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                const SectionHeader('계정'),
                const SizedBox(height: 8),
                _SettingTile(
                  icon: Icons.logout_rounded,
                  title: '로그아웃',
                  subtitle: controller.user?.email ?? '현재 계정',
                  onTap: () => controller.logout(),
                ),
                _SettingTile(
                  icon: Icons.person_off_outlined,
                  title: '회원 탈퇴',
                  subtitle: '소유 중인 기기가 있으면 먼저 양도해야 해요',
                  danger: true,
                  onTap: () => _withdraw(context),
                ),
                const SizedBox(height: 18),
                const Text(
                  '재생·다운로드 주소는 서버에서 짧게 발급되며 앱에 영구 저장하지 않습니다. 기기 접근 권한은 화면 표시와 별개로 서버가 매 요청마다 확인합니다.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: AppColors.muted,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _editName(BuildContext context) async {
    final input = TextEditingController(text: controller.selectedDevice!.name);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('기기 이름 바꾸기'),
        content: TextField(controller: input, autofocus: true, maxLength: 60),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    input.dispose();
    if (value?.isNotEmpty == true) {
      try {
        await controller.api.updateDevice(
          controller.selectedDevice!.id,
          name: value,
        );
        await controller.refreshAll();
      } catch (failure) {
        if (context.mounted) showAppSnack(context, '$failure', error: true);
      }
    }
  }

  Future<void> _editRetention(BuildContext context) async {
    final value = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                '기본 보관 기간',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text('구독 상태에 따라 서버가 허용 범위를 검증합니다.'),
            ),
            for (final days in [7, 14, 30, 60, 90])
              ListTile(
                title: Text('$days일'),
                trailing: days == controller.selectedDevice!.retentionDays
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(context, days),
              ),
          ],
        ),
      ),
    );
    if (value != null) {
      try {
        await controller.api.updateDevice(
          controller.selectedDevice!.id,
          retentionDays: value,
        );
        await controller.refreshAll();
      } catch (failure) {
        if (context.mounted) showAppSnack(context, '$failure', error: true);
      }
    }
  }

  Future<void> _subscription(BuildContext context) async {
    try {
      var subscription = await controller.api.getSubscription(
        controller.selectedDevice!.id,
      );
      if (!context.mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => StatefulBuilder(
          builder: (context, setState) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '추억 장기 보관',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subscription.active
                        ? '현재 ${subscription.premiumRetentionDays}일 장기 보관이 활성화되어 있어요.'
                        : '활성화하면 보관 기간을 ${subscription.premiumRetentionDays}일까지 늘릴 수 있어요.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () async {
                      subscription = subscription.active
                          ? await controller.api.cancelSubscription(
                              controller.selectedDevice!.id,
                            )
                          : await controller.api.activateSubscription(
                              controller.selectedDevice!.id,
                            );
                      setState(() {});
                      await controller.refreshAll();
                    },
                    child: Text(subscription.active ? '구독 해지' : 'MVP 구독 활성화'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } catch (failure) {
      if (context.mounted) showAppSnack(context, '$failure', error: true);
    }
  }

  Future<void> _logs(BuildContext context) async {
    try {
      final logs = await controller.api.listAccessLogs(
        controller.selectedDevice!.id,
      );
      if (!context.mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (context) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: .7,
          builder: (context, scroll) => ListView(
            controller: scroll,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            children: [
              const SectionHeader('최근 접근 기록'),
              if (logs.isEmpty)
                const EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: '아직 기록이 없어요',
                  message: '영상 조회나 다운로드 기록이 생기면 표시됩니다.',
                ),
              ...logs.map(
                (log) => ListTile(
                  leading: CircleAvatar(
                    backgroundColor: log.outcome == 'SUCCESS'
                        ? AppColors.mint
                        : const Color(0xFFF6E9E4),
                    child: Icon(
                      log.outcome == 'SUCCESS'
                          ? Icons.check_rounded
                          : Icons.priority_high_rounded,
                      color: log.outcome == 'SUCCESS'
                          ? AppColors.primaryDark
                          : AppColors.danger,
                    ),
                  ),
                  title: Text(log.action),
                  subtitle: Text(
                    log.createdAt == null
                        ? log.outcome
                        : '${DateFormat('M월 d일 HH:mm').format(log.createdAt!)} · ${log.outcome}',
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } catch (failure) {
      if (context.mounted) showAppSnack(context, '$failure', error: true);
    }
  }

  Future<void> _withdraw(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('정말 탈퇴할까요?'),
        content: const Text('모든 로그인 세션이 종료됩니다. 소유 중인 기기가 있다면 서버가 탈퇴를 차단합니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            child: const Text('탈퇴'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await controller.withdraw();
      } catch (failure) {
        if (context.mounted) showAppSnack(context, '$failure', error: true);
      }
    }
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final String? trailing;
  final VoidCallback? onTap;
  final bool danger;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Card(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        leading: CircleAvatar(
          backgroundColor: danger ? const Color(0xFFF6E9E4) : AppColors.mint,
          child: Icon(
            icon,
            color: danger ? AppColors.danger : AppColors.primaryDark,
          ),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: danger ? AppColors.danger : AppColors.ink,
          ),
        ),
        subtitle: Text(subtitle),
        trailing: trailing != null
            ? Text(
                trailing!,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                ),
              )
            : onTap != null
            ? const Icon(Icons.chevron_right_rounded)
            : null,
        onTap: onTap,
      ),
    ),
  );
}
