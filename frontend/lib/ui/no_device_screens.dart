import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'device_registration_screen.dart';
import 'invitation_inbox_screen.dart';
import 'laugh_report_content_screen.dart';
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
    child: ListView(
      key: const PageStorageKey('no-device-settings-scroll'),
      padding: const EdgeInsets.fromLTRB(20, 48, 20, 32),
      children: [
        Text('설정', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 18),
        SoftCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: Text(controller.user?.displayName ?? '사용자'),
                subtitle: Text(controller.user?.email ?? ''),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProfileEditScreen(controller: controller),
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.bar_chart_rounded),
                title: const Text('웃음 리포트'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        LaughReportContentScreen(controller: controller),
                  ),
                ),
              ),
              if (controller.canRegisterDevice) ...[
                const Divider(height: 1),
                ListTile(
                  key: const Key('no-device-connect'),
                  leading: const Icon(Icons.add_to_photos_outlined),
                  title: const Text('새 기기 연결'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _openDeviceRegistration(context),
                ),
              ],
              const Divider(height: 1),
              ListTile(
                leading: const Icon(
                  Icons.logout_rounded,
                  color: AppColors.danger,
                ),
                title: const Text('로그아웃'),
                onTap: controller.busy ? null : controller.logout,
              ),
            ],
          ),
        ),
      ],
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
