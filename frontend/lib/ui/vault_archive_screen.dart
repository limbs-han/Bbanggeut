import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'all_memories_screen.dart';
import 'device_registration_screen.dart';
import 'family_screen.dart';

class VaultArchiveScreen extends StatelessWidget {
  const VaultArchiveScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _openRegistration(BuildContext context) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            DeviceRegistrationScreen(controller: controller, canGoBack: true),
      ),
    );
  }

  Future<void> _openFamily(BuildContext context) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Vault 구성원')),
          body: FamilyScreen(controller: controller),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vault = controller.selectedVault!;
    return Scaffold(
      appBar: AppBar(
        title: controller.vaults.length > 1
            ? PopupMenuButton<String>(
                key: const Key('vault-archive-selector'),
                initialValue: vault.id,
                tooltip: 'Vault 변경',
                onSelected: (vaultId) {
                  final next = controller.vaults.firstWhere(
                    (item) => item.id == vaultId,
                  );
                  controller.selectVault(next);
                },
                itemBuilder: (_) => controller.vaults
                    .map(
                      (item) => PopupMenuItem(
                        value: item.id,
                        child: Row(
                          children: [
                            Icon(
                              item.id == vault.id
                                  ? Icons.check_rounded
                                  : Icons.inventory_2_outlined,
                            ),
                            const SizedBox(width: 8),
                            Expanded(child: Text(item.name)),
                          ],
                        ),
                      ),
                    )
                    .toList(growable: false),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: Text(vault.name)),
                    const Icon(Icons.arrow_drop_down_rounded),
                  ],
                ),
              )
            : Text(vault.name),
        actions: [
          IconButton(
            key: const Key('vault-family-management'),
            tooltip: 'Vault 구성원 관리',
            onPressed: controller.busy ? null : () => _openFamily(context),
            icon: const Icon(Icons.family_restroom_rounded),
          ),
          IconButton(
            key: const Key('vault-archive-refresh'),
            tooltip: '새로고침',
            onPressed: controller.busy ? null : controller.refreshVaultData,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            key: const Key('vault-archive-logout'),
            tooltip: '로그아웃',
            onPressed: controller.busy ? null : controller.logout,
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            key: const Key('device-free-vault-banner'),
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.yellowSoft,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.line),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.video_camera_back_outlined,
                  color: AppColors.sageDark,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '현재 연결된 기기가 없어요',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                      SizedBox(height: 3),
                      Text(
                        '과거 추억은 계속 볼 수 있어요. 새 기기를 연결하면 촬영과 라이브가 다시 시작돼요.',
                        style: TextStyle(
                          color: AppColors.inkSoft,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (controller.canRegisterDevice) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 104,
                    child: FilledButton(
                      key: const Key('connect-device-to-vault'),
                      onPressed: controller.busy
                          ? null
                          : () => _openRegistration(context),
                      child: const Text('기기 연결'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Expanded(child: AllMemoriesScreen(controller: controller)),
        ],
      ),
    );
  }
}
