import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'device_registration_screen.dart';
import 'invitation_inbox_screen.dart';
import 'password_change_screen.dart';
import 'profile_avatar.dart';
import 'profile_edit_screen.dart';
import 'widgets.dart';

class NoDeviceFamilyScreen extends StatelessWidget {
  const NoDeviceFamilyScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => AppBackdrop(
    child: ListView(
      key: const PageStorageKey('no-device-family-scroll'),
      padding: const EdgeInsets.fromLTRB(20, 48, 20, 32),
      children: [
        Text('가족', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 18),
        const SoftCard(
          child: EmptyState(
            icon: Icons.family_restroom_rounded,
            title: '아직 참여한 가족이 없어요',
            message: '받은 초대를 확인하거나 OWNER에게 초대를 요청해 주세요.',
          ),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: controller.busy
              ? null
              : () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        InvitationInboxScreen(controller: controller),
                  ),
                ),
          icon: const Icon(Icons.mail_outline_rounded),
          label: Text('받은 초대함 ${controller.receivedInvitations.length}개'),
        ),
      ],
    ),
  );
}

class NoDeviceSettingsScreen extends StatelessWidget {
  const NoDeviceSettingsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => AppBackdrop(
    child: SafeArea(
      bottom: false,
      child: ListView(
        key: const PageStorageKey('no-device-settings-scroll'),
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 36),
        children: [
          SizedBox(
            height: 190,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                const Positioned(
                  left: 4,
                  top: 54,
                  child: Text(
                    '설정',
                    style: TextStyle(
                      fontSize: 38,
                      height: 1,
                      fontWeight: FontWeight.w900,
                      letterSpacing: -2,
                      color: AppColors.ink,
                    ),
                  ),
                ),
                Positioned(
                  right: 4,
                  bottom: 0,
                  width: 166,
                  height: 166,
                  child: Image.asset(
                    'assets/images/bbanggeut_mascot.png',
                    fit: BoxFit.contain,
                  ),
                ),
                const Positioned(
                  right: 157,
                  top: 54,
                  child: Icon(
                    Icons.favorite_rounded,
                    size: 21,
                    color: AppColors.coralSoft,
                  ),
                ),
                const Positioned(
                  left: 116,
                  top: 40,
                  child: Icon(
                    Icons.auto_awesome_rounded,
                    size: 22,
                    color: AppColors.yellowSoft,
                  ),
                ),
              ],
            ),
          ),
          SoftCard(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ProfileEditScreen(controller: controller),
                ),
              ),
              child: Row(
                children: [
                  const ProfileAvatarView(radius: 37),
                  const SizedBox(width: 18),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          controller.user?.displayName ?? '사용자',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: AppColors.ink,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          controller.user?.email ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            color: AppColors.inkSoft,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.muted,
                    size: 28,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          SoftCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _NoDeviceSettingRow(
                  key: const Key('no-device-connect'),
                  icon: Icons.add_to_photos_outlined,
                  iconColor: AppColors.sageDark,
                  iconBackground: AppColors.sageSoft,
                  title: '새 기기 연결',
                  subtitle: '새로운 기기를 연결해 보세요',
                  onTap: () => _openDeviceRegistration(context),
                ),
                const Divider(height: 1, indent: 94),
                _NoDeviceSettingRow(
                  icon: Icons.lock_outline_rounded,
                  iconColor: const Color(0xFFA66B3F),
                  iconBackground: AppColors.surfaceWarm,
                  title: '비밀번호 변경',
                  subtitle: '계정 비밀번호를 변경할 수 있어요',
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          PasswordChangeScreen(controller: controller),
                    ),
                  ),
                ),
                const Divider(height: 1, indent: 94),
                _NoDeviceSettingRow(
                  icon: Icons.logout_rounded,
                  iconColor: AppColors.danger,
                  iconBackground: AppColors.pinkSoft,
                  title: '로그아웃',
                  subtitle: '계정에서 로그아웃합니다',
                  danger: true,
                  onTap: controller.busy ? null : controller.logout,
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    ),
  );

  Future<void> _openDeviceRegistration(BuildContext context) async {
    if (controller.videos.isNotEmpty) {
      final choice = await showMemoryConnectionChoice(context);
      if (!context.mounted || choice == null) return;
      if (choice == MemoryConnectionChoice.restart) {
        showAppSnack(context, '새로 시작 선택을 저장했어요. 실제 추억 삭제는 서버 API 연결 후 처리됩니다.');
      }
    }
    if (!context.mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DeviceRegistrationScreen(controller: controller),
      ),
    );
  }
}

class _NoDeviceSettingRow extends StatelessWidget {
  const _NoDeviceSettingRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: iconBackground,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 28),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: danger ? AppColors.danger : AppColors.ink,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: danger ? AppColors.danger : AppColors.inkSoft,
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.chevron_right_rounded,
            color: AppColors.muted,
            size: 27,
          ),
        ],
      ),
    ),
  );
}
