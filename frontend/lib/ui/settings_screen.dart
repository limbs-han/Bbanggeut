import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'device_registration_screen.dart';
import 'extra_screens.dart';
import 'invitation_inbox_screen.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _storage = FlutterSecureStorage();
  static const _anniversaryKey = 'wj_pref_anniversary_alerts';
  static const _weeklyKey = 'wj_pref_weekly_report';
  static const _memoryKey = 'wj_pref_new_memory_alerts';
  bool anniversaryAlerts = true;
  bool weeklyReport = true;
  bool newMemoryAlerts = false;

  @override
  void initState() {
    super.initState();
    _loadNotificationPreferences();
  }

  Future<void> _loadNotificationPreferences() async {
    try {
      final values = await Future.wait([
        _storage.read(key: _anniversaryKey),
        _storage.read(key: _weeklyKey),
        _storage.read(key: _memoryKey),
      ]);
      if (!mounted) return;
      setState(() {
        anniversaryAlerts = values[0] != 'false';
        weeklyReport = values[1] != 'false';
        newMemoryAlerts = values[2] == 'true';
      });
    } catch (_) {
      // 플랫폼 저장소를 사용할 수 없으면 현재 세션의 기본값을 유지한다.
    }
  }

  Future<void> _savePreference(String key, bool value) async {
    try {
      await _storage.write(key: key, value: '$value');
    } catch (_) {
      // 화면 상태는 유지하고 다음 실행 시 기본값으로 복구한다.
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final device = controller.selectedDevice!;
    return AppBackdrop(
      child: CustomScrollView(
        key: const PageStorageKey('settings-scroll'),
        slivers: [
          SliverSafeArea(
            bottom: false,
            sliver: SliverToBoxAdapter(
              child: PagePadding(
                top: 18,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '설정',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 18),
                    SoftCard(
                      color: AppColors.sage,
                      borderColor: AppColors.sage,
                      padding: EdgeInsets.zero,
                      child: InkWell(
                        key: const Key('edit-profile-button'),
                        onTap: () => _editProfile(context),
                        child: Padding(
                          padding: const EdgeInsets.all(13),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 25,
                                backgroundColor: AppColors.surface,
                                child: Text(
                                  controller
                                          .user
                                          ?.displayName
                                          .characters
                                          .firstOrNull ??
                                      '나',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: AppColors.sageDark,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      controller.user?.displayName ?? '현재 사용자',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                        fontSize: 16,
                                      ),
                                    ),
                                    Text(
                                      controller.user?.email ?? '로그인 계정',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: AppColors.inkSoft,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const StatusPill(
                                label: '수정',
                                color: AppColors.surface,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const _GroupLabel('가족 초대'),
                    SoftCard(
                      padding: EdgeInsets.zero,
                      child: _SettingRow(
                        icon: Icons.mark_email_unread_outlined,
                        title: '받은 초대함',
                        subtitle: controller.receivedInvitations.isEmpty
                            ? '새로운 초대가 없어요'
                            : '대기 중인 초대 ${controller.receivedInvitations.length}개',
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                InvitationInboxScreen(controller: controller),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const _GroupLabel('기기 설정'),
                    SoftCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          _SettingRow(
                            key: const Key('edit-camera-name-button'),
                            icon: Icons.videocam_outlined,
                            title: '카메라 설정',
                            subtitle: device.name,
                            onTap: device.isOwner
                                ? () => _editDevice(context)
                                : null,
                          ),
                          const Divider(height: 1, indent: 58),
                          _SettingRow(
                            icon: Icons.auto_awesome_motion_outlined,
                            title: '녹화 및 저장 설정',
                            subtitle: '${device.retentionDays}일 자동 보관',
                            onTap: device.isOwner
                                ? () => _editRetention(context)
                                : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    const _GroupLabel('알림 설정'),
                    SoftCard(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Column(
                        children: [
                          _SwitchRow(
                            title: '기념일 알림',
                            subtitle: '등록한 기념일을 알려드려요',
                            value: anniversaryAlerts,
                            onChanged: (value) {
                              setState(() => anniversaryAlerts = value);
                              _savePreference(_anniversaryKey, value);
                            },
                          ),
                          const Divider(height: 1, indent: 18, endIndent: 18),
                          _SwitchRow(
                            title: '주간 리포트 알림',
                            subtitle: '이번 주 웃음 기록을 요약해요',
                            value: weeklyReport,
                            onChanged: (value) {
                              setState(() => weeklyReport = value);
                              _savePreference(_weeklyKey, value);
                            },
                          ),
                          const Divider(height: 1, indent: 18, endIndent: 18),
                          _SwitchRow(
                            title: '새로운 추억 알림',
                            subtitle: '새 영상 저장 시 알려드려요',
                            value: newMemoryAlerts,
                            onChanged: (value) {
                              setState(() => newMemoryAlerts = value);
                              _savePreference(_memoryKey, value);
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    const _GroupLabel('계정 및 보안'),
                    SoftCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          _SettingRow(
                            icon: Icons.bar_chart_rounded,
                            title: '웃음 리포트',
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    LaughReportScreen(controller: controller),
                              ),
                            ),
                          ),
                          const Divider(height: 1, indent: 58),
                          if (device.isOwner) ...[
                            _SettingRow(
                              icon: Icons.receipt_long_outlined,
                              title: '접근 기록',
                              onTap: () => _logs(context),
                            ),
                            const Divider(height: 1, indent: 58),
                            _SettingRow(
                              icon: Icons.workspace_premium_outlined,
                              title: '보관 구독',
                              onTap: () => _subscription(context),
                            ),
                            const Divider(height: 1, indent: 58),
                          ],
                          _SettingRow(
                            icon: Icons.add_to_photos_outlined,
                            title: '새 기기 연결',
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => DeviceRegistrationScreen(
                                  controller: controller,
                                ),
                              ),
                            ),
                          ),
                          const Divider(height: 1, indent: 58),
                          _SettingRow(
                            icon: Icons.lock_outline_rounded,
                            title: '비밀번호 변경',
                            onTap: () => showAppSnack(
                              context,
                              '비밀번호 변경 API가 아직 백엔드에 없어요.',
                              error: true,
                            ),
                          ),
                          const Divider(height: 1, indent: 58),
                          _SettingRow(
                            icon: Icons.logout_rounded,
                            title: '로그아웃',
                            danger: true,
                            onTap: controller.logout,
                          ),
                        ],
                      ),
                    ),
                    if (device.isOwner) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => _releaseDevice(context),
                        icon: const Icon(Icons.link_off_rounded),
                        label: const Text('기기 해제'),
                      ),
                    ],
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => _withdraw(context),
                      icon: const Icon(Icons.person_off_outlined),
                      label: const Text('회원 탈퇴'),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Memory Home 1.0.0',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 10, color: AppColors.muted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _editProfile(BuildContext context) async {
    final controller = widget.controller;
    final input = TextEditingController(text: controller.user?.displayName);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('프로필 수정'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 60,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(labelText: '이름'),
          onSubmitted: (value) {
            final name = value.trim();
            if (name.isNotEmpty) Navigator.pop(context, name);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              final name = input.text.trim();
              if (name.isNotEmpty) Navigator.pop(context, name);
            },
            child: const Text('저장'),
          ),
        ],
      ),
    );
    input.dispose();
    if (!context.mounted || value == null) return;
    final ok = await controller.updateProfile(value);
    if (!context.mounted) return;
    showAppSnack(
      context,
      ok ? '프로필을 수정했어요.' : (controller.errorMessage ?? '프로필을 수정하지 못했어요.'),
      error: !ok,
    );
  }

  Future<void> _editDevice(BuildContext context) async {
    final controller = widget.controller;
    final result = await showDialog<_DeviceManageResult>(
      context: context,
      builder: (context) =>
          _RenameDeviceDialog(initialName: controller.selectedDevice!.name),
    );
    if (!context.mounted || result == null) return;
    if (result.release) {
      await _releaseDevice(context);
      return;
    }
    final value = result.name;
    if (value?.isNotEmpty == true) {
      final ok = await controller.updateSelectedDevice(name: value);
      if (context.mounted) {
        showAppSnack(
          context,
          ok
              ? '카메라 이름을 수정했어요.'
              : (controller.errorMessage ?? '기기 이름을 바꾸지 못했어요.'),
          error: !ok,
        );
      }
    }
  }

  Future<void> _editRetention(BuildContext context) async {
    final controller = widget.controller;
    final days = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                '기본 보관 기간',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            for (final value in [7, 14, 30, 60, 90])
              ListTile(
                title: Text('$value일'),
                trailing: value == controller.selectedDevice!.retentionDays
                    ? const Icon(Icons.check_rounded)
                    : null,
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
    if (days != null) {
      final ok = await controller.updateSelectedDevice(retentionDays: days);
      if (!ok && context.mounted) {
        showAppSnack(
          context,
          controller.errorMessage ?? '보관 기간을 바꾸지 못했어요.',
          error: true,
        );
      }
    }
  }

  Future<void> _subscription(BuildContext context) async {
    final controller = widget.controller;
    try {
      var subscription = await controller.api.getSubscription(
        controller.selectedDevice!.id,
      );
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('보관 구독'),
            content: Text(
              subscription.active
                  ? '현재 ${subscription.premiumRetentionDays}일 장기 보관이 활성화되어 있어요.'
                  : '활성화하면 ${subscription.premiumRetentionDays}일까지 보관할 수 있어요.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('닫기'),
              ),
              FilledButton(
                onPressed: () async {
                  subscription = subscription.active
                      ? await controller.api.cancelSubscription(
                          controller.selectedDevice!.id,
                        )
                      : await controller.api.activateSubscription(
                          controller.selectedDevice!.id,
                        );
                  setDialogState(() {});
                  await controller.refreshAll();
                },
                child: Text(subscription.active ? '구독 해지' : 'MVP 구독 활성화'),
              ),
            ],
          ),
        ),
      );
    } catch (failure) {
      if (context.mounted) showAppSnack(context, '$failure', error: true);
    }
  }

  Future<void> _logs(BuildContext context) async {
    try {
      final logs = await widget.controller.api.listAccessLogs(
        widget.controller.selectedDevice!.id,
      );
      if (!context.mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: .72,
          builder: (_, scrollController) => ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 28),
            children: [
              Text('접근 기록', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (logs.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('접근 기록이 없어요.'),
                ),
              ...logs.map(
                (log) => ListTile(
                  leading: CircleAvatar(
                    backgroundColor: log.outcome == 'SUCCESS'
                        ? AppColors.sageSoft
                        : AppColors.pink,
                    child: Icon(
                      log.outcome == 'SUCCESS'
                          ? Icons.check_rounded
                          : Icons.warning_amber_rounded,
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
        content: const Text(
          '소유 중인 기기가 있다면 서버가 탈퇴를 차단합니다. 먼저 소유권을 이전하거나 기기를 해제해 주세요.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('탈퇴'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await widget.controller.withdraw();
      } catch (failure) {
        if (context.mounted) showAppSnack(context, '$failure', error: true);
      }
    }
  }

  Future<void> _releaseDevice(BuildContext context) async {
    final device = widget.controller.selectedDevice!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('기기 등록을 해제할까요?'),
        content: const Text(
          '멤버십과 영상 접근이 종료되고 저장된 영상은 삭제 작업에 들어갑니다. 되돌릴 수 없습니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('등록 해제'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final ok = await widget.controller.releaseSelectedDevice();
      if (!context.mounted) return;
      if (ok) {
        showAppSnack(context, '${device.name} 기기 연결을 해제했어요.');
      } else {
        showAppSnack(
          context,
          widget.controller.errorMessage ?? '기기 연결을 해제하지 못했어요.',
          error: true,
        );
      }
    }
  }
}

class _DeviceManageResult {
  const _DeviceManageResult.rename(this.name) : release = false;
  const _DeviceManageResult.release() : name = null, release = true;

  final String? name;
  final bool release;
}

class _RenameDeviceDialog extends StatefulWidget {
  const _RenameDeviceDialog({required this.initialName});

  final String initialName;

  @override
  State<_RenameDeviceDialog> createState() => _RenameDeviceDialogState();
}

class _RenameDeviceDialogState extends State<_RenameDeviceDialog> {
  late final TextEditingController input;

  @override
  void initState() {
    super.initState();
    input = TextEditingController(text: widget.initialName);
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('기기 관리'),
    content: TextField(
      controller: input,
      autofocus: true,
      maxLength: 80,
      decoration: const InputDecoration(labelText: '기기 이름'),
    ),
    actions: [
      TextButton.icon(
        style: TextButton.styleFrom(foregroundColor: AppColors.danger),
        onPressed: () =>
            Navigator.pop(context, const _DeviceManageResult.release()),
        icon: const Icon(Icons.link_off_rounded),
        label: const Text('기기 해제'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(
          context,
          _DeviceManageResult.rename(input.text.trim()),
        ),
        child: const Text('저장'),
      ),
    ],
  );
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 3, bottom: 7),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 11,
        color: AppColors.muted,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool danger;
  @override
  Widget build(BuildContext context) => ListTile(
    leading: CircleAvatar(
      radius: 17,
      backgroundColor: danger ? AppColors.pink : AppColors.sageSoft,
      child: Icon(
        icon,
        size: 19,
        color: danger ? AppColors.danger : AppColors.sageDark,
      ),
    ),
    title: Text(
      title,
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w800,
        color: danger ? AppColors.danger : AppColors.ink,
      ),
    ),
    subtitle: subtitle == null
        ? null
        : Text(subtitle!, style: const TextStyle(fontSize: 10)),
    trailing: onTap == null
        ? null
        : const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
    onTap: onTap,
  );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => SwitchListTile(
    title: Text(
      title,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
    ),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: 10)),
    value: value,
    activeTrackColor: AppColors.sage,
    onChanged: onChanged,
  );
}
