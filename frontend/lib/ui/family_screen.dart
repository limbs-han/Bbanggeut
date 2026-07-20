import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'widgets.dart';

class FamilyScreen extends StatelessWidget {
  const FamilyScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final device = controller.selectedDevice!;
    return CustomScrollView(
      slivers: [
        SliverAppBar(
          floating: true,
          title: const Text('함께 보는 가족'),
          actions: [
            if (device.isOwner)
              IconButton(
                onPressed: () => _invite(context),
                icon: const Icon(Icons.person_add_alt_1_rounded),
              ),
            const SizedBox(width: 8),
          ],
        ),
        SliverToBoxAdapter(
          child: PagePadding(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${device.name} · ${controller.members.length}명',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 18),
                if (device.isOwner)
                  FilledButton.icon(
                    onPressed: () => _invite(context),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('안전한 초대 링크 만들기'),
                  ),
                if (controller.joinRequests.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  const SectionHeader('가입 요청'),
                  const SizedBox(height: 8),
                  ...controller.joinRequests.map(
                    (request) => _JoinRequestCard(
                      controller: controller,
                      request: request,
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                const SectionHeader('구성원'),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      for (var i = 0; i < controller.members.length; i++) ...[
                        _MemberTile(
                          controller: controller,
                          member: controller.members[i],
                        ),
                        if (i != controller.members.length - 1)
                          const Divider(height: 1, indent: 72),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Card(
                  color: AppColors.mint,
                  child: const Padding(
                    padding: EdgeInsets.all(18),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          color: AppColors.primaryDark,
                        ),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            '초대 링크만으로 바로 가족이 되지 않아요. 소유자가 가입 요청을 확인하고 승인해야 영상과 라이브에 접근할 수 있습니다.',
                            style: TextStyle(
                              height: 1.5,
                              color: AppColors.primaryDark,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _invite(BuildContext context) async {
    try {
      final result = await controller.api.createInvite(
        controller.selectedDevice!.id,
      );
      final token = result['inviteToken'] as String;
      final expires = parseDate(result['expiresAt']);
      if (!context.mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '초대 링크가 준비됐어요',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  '이 링크는 ${expires == null ? '정해진 시간 동안' : memoryDate(expires)}까지 유효하며, 가입 요청은 다시 승인해야 합니다.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () async {
                    await SharePlus.instance.share(
                      ShareParams(
                        text:
                            'William James 가족 초대\nwilliamjames://join?token=$token',
                      ),
                    );
                  },
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('초대 링크 공유'),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (failure) {
      if (context.mounted) showAppSnack(context, '$failure', error: true);
    }
  }
}

class _JoinRequestCard extends StatelessWidget {
  const _JoinRequestCard({required this.controller, required this.request});
  final AppController controller;
  final JoinRequestInfo request;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: AppColors.mint,
                child: Text(
                  request.requester.displayName.characters.firstOrNull ?? '?',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.requester.displayName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      request.requester.email,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => controller.reject(request),
                  child: const Text('거절'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () => controller.approve(request),
                  child: const Text('승인'),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.controller, required this.member});
  final AppController controller;
  final DeviceMember member;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    leading: CircleAvatar(
      backgroundColor: member.role == 'OWNER'
          ? const Color(0xFFF7D3B7)
          : AppColors.mint,
      child: Text(
        member.user.displayName.characters.firstOrNull ?? '?',
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    title: Text(member.user.displayName),
    subtitle: Text(member.user.email),
    trailing: member.role == 'OWNER'
        ? const StatusPill(label: 'OWNER')
        : controller.selectedDevice!.isOwner
        ? TextButton(
            onPressed: () => _confirmRevoke(context),
            child: const Text('권한 회수'),
          )
        : const StatusPill(label: 'MEMBER'),
  );
  Future<void> _confirmRevoke(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('접근 권한을 회수할까요?'),
        content: Text(
          '${member.user.displayName}님은 즉시 이 기기의 영상과 라이브를 볼 수 없게 됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('회수'),
          ),
        ],
      ),
    );
    if (confirmed == true) controller.revoke(member);
  }
}
