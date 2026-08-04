import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'device_registration_screen.dart';
import 'family_management_cards.dart';
import 'invitation_inbox_screen.dart';
import 'notification_settings_screen.dart';
import 'password_change_screen.dart';
import 'profile_avatar.dart';
import 'profile_edit_screen.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    // A vault keeps its members, videos and subscription with no device bound,
    // so this screen must render without one.
    final device = controller.selectedDevice;
    final isOwner =
        controller.selectedVault?.isOwner ?? device?.isOwner ?? false;
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
                      height: 132,
                      child: Stack(
                        children: [
                          Positioned(
                            left: 4,
                            top: 0,
                            width: 112,
                            height: 48,
                            child: Image.asset(
                              'assets/images/bbanggeut_logo.png',
                              fit: BoxFit.contain,
                              alignment: Alignment.centerLeft,
                              cacheWidth: decodePixels(context, 112),
                            ),
                          ),
                          const Positioned(
                            left: 4,
                            bottom: 8,
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
                            right: 18,
                            bottom: -2,
                            width: 126,
                            height: 118,
                            child: Image.asset(
                              'assets/images/bbanggeut_mascot.png',
                              fit: BoxFit.contain,
                              cacheWidth: decodePixels(context, 126),
                            ),
                          ),
                          const Positioned(
                            right: 146,
                            top: 38,
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
                          const ProfileAvatarView(radius: 24),
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
                            onPressed: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ProfileEditScreen(controller: controller),
                                ),
                              );
                              if (mounted) setState(() {});
                            },
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
                            subtitle: device?.name ?? '연결된 기기가 없어요',
                            onTap: device != null && device.isOwner
                                ? () => _editDevice(context)
                                : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    const _GroupLabel('가족 초대'),
                    FamilyManagementCards(
                      controller: controller,
                      onOpenInbox: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              InvitationInboxScreen(controller: controller),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const _GroupLabel('알림 설정'),
                    SoftCard(
                      padding: EdgeInsets.zero,
                      child: _SettingRow(
                        icon: Icons.notifications_active_outlined,
                        title: '알림 설정',
                        subtitle: '기념일 · 주간 리포트 · 새로운 추억',
                        trailingText: '설정하기',
                        onTap: () => _notificationSettings(context),
                      ),
                    ),
                    const SizedBox(height: 18),
                    const _GroupLabel('계정 및 보안'),
                    SoftCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          if (isOwner) ...[
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
                          if (controller.canRegisterDevice) ...[
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
                          ],
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
                    if (device != null && isOwner) ...[
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
    final selected = controller.selectedDevice;
    if (selected == null) {
      showAppSnack(context, '연결된 기기가 없어요.', error: true);
      return;
    }
    final result = await showDialog<_DeviceManageResult>(
      context: context,
      builder: (context) => _RenameDeviceDialog(initialName: selected.name),
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
    // The subscription belongs to the vault; the device route is only a
    // fallback for a session that never resolved one.
    final vaultId = controller.selectedVault?.id;
    final deviceId = controller.selectedDevice?.id;
    if (vaultId == null && deviceId == null) {
      showAppSnack(context, '구독 정보를 불러오지 못했어요.', error: true);
      return;
    }
    try {
      var subscription = vaultId != null
          ? await controller.api.getVaultSubscription(vaultId)
          : await controller.api.getSubscription(deviceId!);
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => Dialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(30),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: const BoxDecoration(
                      color: AppColors.sageSoft,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.workspace_premium_rounded,
                      size: 38,
                      color: AppColors.sageDark,
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '웃음 보관 구독',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w900,
                      color: AppColors.ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subscription.active
                        ? '소중한 웃음 영상을 ${subscription.premiumRetentionDays}일 동안 안전하게 보관하고 있어요.'
                        : '구독하면 소중한 웃음 영상을 ${subscription.premiumRetentionDays}일까지 오래 보관할 수 있어요.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.inkSoft,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceWarm,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.favorite_rounded,
                          color: AppColors.coral,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            subscription.active
                                ? '현재 구독이 활성화되어 있어요'
                                : '웃음 영상을 더 오래 간직해요',
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: () async {
                      subscription = subscription.active
                          ? (vaultId != null
                                ? await controller.api.cancelVaultSubscription(
                                    vaultId,
                                  )
                                : await controller.api.cancelSubscription(
                                    deviceId!,
                                  ))
                          : (vaultId != null
                                ? await controller.api
                                      .activateVaultSubscription(vaultId)
                                : await controller.api.activateSubscription(
                                    deviceId!,
                                  ));
                      setDialogState(() {});
                      await controller.refreshAll();
                    },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      backgroundColor: AppColors.coral,
                    ),
                    child: Text(subscription.active ? '구독 해지' : '구독 시작하기'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('닫기'),
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

  Future<void> _notificationSettings(BuildContext context) async {
    final api = widget.controller.api;
    final initialValues = await NotificationSettingsScreen.loadPreferences(
      api: api,
    );
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        child: NotificationSettingsScreen(
          compact: true,
          initialValues: initialValues,
          api: api,
        ),
      ),
    );
  }

  Future<void> _logs(BuildContext context) async {
    final controller = widget.controller;
    final vaultId = controller.selectedVault?.id;
    final deviceId = controller.selectedDevice?.id;
    if (vaultId == null && deviceId == null) {
      showAppSnack(context, '접근 기록을 불러오지 못했어요.', error: true);
      return;
    }
    try {
      final logs = vaultId != null
          ? await controller.api.listVaultAccessLogs(vaultId)
          : await controller.api.listAccessLogs(deviceId!);
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
    final device = widget.controller.selectedDevice;
    if (device == null) {
      showAppSnack(context, '연결된 기기가 없어요.', error: true);
      return;
    }
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
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Dialog(
      key: const Key('device-management-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      backgroundColor: Colors.transparent,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(top: 58, bottom: bottomInset),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.topCenter,
          children: [
            Container(
              constraints: const BoxConstraints(maxWidth: 440),
              padding: const EdgeInsets.fromLTRB(28, 92, 28, 28),
              decoration: BoxDecoration(
                color: AppColors.surfaceWarm,
                borderRadius: BorderRadius.circular(30),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x2E33291F),
                    blurRadius: 28,
                    offset: Offset(0, 14),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    '기기 관리',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.ink,
                      fontSize: 27,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -1.1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '연결된 기기의 이름을 변경할 수 있어요',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.muted,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    '기기 이름',
                    style: TextStyle(
                      color: AppColors.ink,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    key: const Key('device-name-field'),
                    controller: input,
                    autofocus: true,
                    maxLength: 80,
                    decoration: InputDecoration(
                      counterText: '',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 17,
                      ),
                      prefixIcon: Padding(
                        padding: const EdgeInsets.all(9),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: AppColors.surfaceWarm,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(
                            Icons.photo_camera_outlined,
                            color: AppColors.coral,
                            size: 21,
                          ),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: const BorderSide(
                          color: AppColors.coral,
                          width: 1.6,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ValueListenableBuilder<TextEditingValue>(
                      valueListenable: input,
                      builder: (context, value, child) => Text(
                        '${value.text.characters.length}/80',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 9),
                  const Text(
                    '가족들이 알아보기 쉬운 이름으로 설정해 주세요.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                  const SizedBox(height: 28),
                  FilledButton(
                    key: const Key('save-device-name-button'),
                    onPressed: () => Navigator.pop(
                      context,
                      _DeviceManageResult.rename(input.text.trim()),
                    ),
                    style: FilledButton.styleFrom(
                      shadowColor: AppColors.coral.withValues(alpha: 0.4),
                      elevation: 5,
                    ),
                    child: const Text('변경사항 저장'),
                  ),
                  const SizedBox(height: 10),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.muted,
                      minimumSize: const Size.fromHeight(44),
                    ),
                    child: const Text('취소'),
                  ),
                  const Divider(height: 26),
                  TextButton.icon(
                    key: const Key('release-device-button'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.danger,
                      minimumSize: const Size.fromHeight(38),
                    ),
                    onPressed: () => Navigator.pop(
                      context,
                      const _DeviceManageResult.release(),
                    ),
                    icon: const Icon(Icons.link_off_rounded, size: 20),
                    label: const Text('이 기기 연결 해제하기'),
                  ),
                  const Text(
                    '기존 추억은 그대로 유지돼요.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
            Positioned(
              top: -58,
              child: Container(
                width: 116,
                height: 116,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: AppColors.surfaceWarm,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 4),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x2633291F),
                      blurRadius: 16,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: ClipOval(
                  child: Image.asset(
                    'assets/images/bbanggeut_mascot.png',
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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
    this.trailingText,
    this.onTap,
    this.danger = false,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final String? trailingText;
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
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (trailingText != null)
                Text(
                  trailingText!,
                  style: const TextStyle(
                    color: AppColors.sageDark,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              if (trailingText != null) const SizedBox(width: 4),
              const Icon(Icons.chevron_right_rounded, color: AppColors.muted),
            ],
          ),
    onTap: onTap,
  );
}
