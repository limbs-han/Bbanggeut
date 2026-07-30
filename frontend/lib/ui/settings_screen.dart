import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'device_registration_screen.dart';
import 'laugh_report_content_screen.dart';
import 'password_change_screen.dart';
import 'profile_edit_screen.dart';
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
                    SizedBox(
                      height: 100,
                      child: Stack(
                        children: [
                          const Positioned(
                            left: 4,
                            top: 22,
                            child: Text(
                              '설정',
                              style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.w900,
                                color: AppColors.ink,
                              ),
                            ),
                          ),
                          Positioned(
                            right: 40,
                            bottom: -6,
                            width: 116,
                            height: 104,
                            child: Image.asset(
                              'assets/images/bbanggeut_mascot.png',
                              fit: BoxFit.contain,
                            ),
                          ),
                          const Positioned(
                            right: 142,
                            top: 23,
                            child: Icon(
                              Icons.favorite_rounded,
                              color: AppColors.sageSoft,
                              size: 19,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    SoftCard(
                      color: AppColors.surface,
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 24,
                            backgroundColor: AppColors.surfaceWarm,
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
                                    fontSize: 17,
                                  ),
                                ),
                                Text(
                                  controller.user?.email ?? '로그인 계정',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: AppColors.inkSoft,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) =>
                                    ProfileEditScreen(controller: controller),
                              ),
                            ),
                            child: const Text('수정하기'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    const _GroupLabel('기기 설정'),
                    SoftCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          _SettingRow(
                            icon: Icons.videocam_outlined,
                            title: '카메라 설정',
                            subtitle: device.name,
                            onTap: device.isOwner
                                ? () => _editDevice(context)
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
                            icon: Icons.notifications_active_outlined,
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
                            icon: Icons.event_available_outlined,
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
                            icon: Icons.video_camera_back_outlined,
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
                                builder: (_) => LaughReportContentScreen(
                                  controller: controller,
                                ),
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
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => PasswordChangeScreen(
                                  controller: controller,
                                ),
                              ),
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
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.inkSoft,
                          backgroundColor: AppColors.surfaceWarm,
                          minimumSize: const Size.fromHeight(48),
                          side: const BorderSide(color: AppColors.line),
                        ),
                        icon: const Icon(Icons.link_off_rounded),
                        label: const Text('기기 해제'),
                      ),
                    ],
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => _withdraw(context),
                      style: TextButton.styleFrom(
                        foregroundColor: AppColors.danger,
                        backgroundColor: AppColors.pink,
                        minimumSize: const Size.fromHeight(48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
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
      if (!ok && context.mounted) {
        showAppSnack(
          context,
          controller.errorMessage ?? '기기 이름을 바꾸지 못했어요.',
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
          '소유 중인 Vault가 있다면 탈퇴할 수 없습니다. 먼저 다른 구성원에게 소유권을 이전해 주세요.',
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
          '라이브 스트리밍과 영상 감지가 중단됩니다. Vault의 구성원과 과거 영상은 그대로 유지돼요. 이 연결은 되돌릴 수 없으며, 다시 연결하려면 기기를 새로 등록하면서 기존 Vault 또는 새 Vault를 선택해야 합니다.',
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
        fontSize: 13,
        color: AppColors.inkSoft,
        fontWeight: FontWeight.w900,
      ),
    ),
  );
}

class _SettingRow extends StatelessWidget {
  const _SettingRow({
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
    minVerticalPadding: 11,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    leading: CircleAvatar(
      radius: 18,
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
        fontSize: 15,
        fontWeight: FontWeight.w800,
        color: danger ? AppColors.danger : AppColors.ink,
      ),
    ),
    subtitle: subtitle == null
        ? null
        : Text(
            subtitle!,
            style: const TextStyle(fontSize: 11, color: AppColors.inkSoft),
          ),
    trailing: onTap == null
        ? null
        : const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
    onTap: onTap,
  );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  @override
  Widget build(BuildContext context) => ListTile(
    minVerticalPadding: 9,
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    leading: CircleAvatar(
      radius: 20,
      backgroundColor: AppColors.sageSoft,
      child: Icon(icon, size: 21, color: AppColors.sageDark),
    ),
    title: Text(
      title,
      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
    ),
    subtitle: Text(
      subtitle,
      style: const TextStyle(fontSize: 10, color: AppColors.inkSoft),
    ),
    trailing: Switch(
      value: value,
      activeTrackColor: AppColors.sage,
      onChanged: onChanged,
    ),
    onTap: () => onChanged(!value),
  );
}
