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
    return AppBackdrop(
      child: CustomScrollView(
        key: const PageStorageKey('family-scroll'),
        slivers: [
          SliverSafeArea(
            bottom: false,
            sliver: SliverToBoxAdapter(
              child: PagePadding(
                top: 18,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Spacer(),
                        Expanded(
                          flex: 4,
                          child: Text(
                            '우리 가족',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        if (device.isOwner)
                          TextButton(
                            onPressed: () => _invite(context),
                            child: const Text('초대하기'),
                          )
                        else
                          const SizedBox(width: 70),
                      ],
                    ),
                    const SizedBox(height: 15),
                    SoftCard(
                      color: AppColors.sage,
                      borderColor: AppColors.sage,
                      padding: const EdgeInsets.all(13),
                      child: Row(
                        children: [
                          Container(
                            width: 62,
                            height: 62,
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: const Icon(
                              Icons.videocam_rounded,
                              size: 34,
                              color: AppColors.sageDark,
                            ),
                          ),
                          const SizedBox(width: 13),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'HOME CAMERA',
                                  style: TextStyle(
                                    fontSize: 9,
                                    color: AppColors.inkSoft,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1,
                                  ),
                                ),
                                Text(
                                  device.name,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                Text(
                                  '● ${controller.deviceStatus?.isOnline == true ? '온라인' : '오프라인'} · ${device.model}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.inkSoft,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const StatusPill(
                            label: '우리',
                            color: AppColors.surface,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      '가족 구성원 ${controller.members.length}명',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                        color: AppColors.inkSoft,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SoftCard(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      child: Column(
                        children: controller.members.indexed.map((entry) {
                          final member = entry.$2;
                          return Column(
                            children: [
                              _MemberTile(
                                controller: controller,
                                member: member,
                              ),
                              if (entry.$1 != controller.members.length - 1)
                                const Divider(height: 1),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                    if (controller.joinRequests.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      const Text(
                        '가입 요청',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          color: AppColors.inkSoft,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...controller.joinRequests.map(
                        (request) => _JoinRequestCard(
                          controller: controller,
                          request: request,
                        ),
                      ),
                    ],
                    if (device.isOwner) ...[
                      const SizedBox(height: 18),
                      SoftCard(
                        color: AppColors.greenCard,
                        borderColor: AppColors.greenCard,
                        child: Column(
                          children: [
                            const Row(
                              children: [
                                _OverlappingDots(),
                                SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    '함께할 가족을 초대해요',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            FilledButton.icon(
                              onPressed: () => _invite(context),
                              icon: const Icon(Icons.link_rounded),
                              label: const Text('초대 링크 복사'),
                            ),
                            const SizedBox(height: 8),
                            TextButton.icon(
                              onPressed: () async {
                                try {
                                  await controller.api.revokeInvite(device.id);
                                  if (context.mounted) {
                                    showAppSnack(context, '기존 초대 링크를 회수했어요.');
                                  }
                                } catch (failure) {
                                  if (context.mounted) {
                                    showAppSnack(
                                      context,
                                      '$failure',
                                      error: true,
                                    );
                                  }
                                }
                              },
                              icon: const Icon(
                                Icons.link_off_rounded,
                                size: 17,
                              ),
                              label: const Text('기존 링크 회수'),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    const Center(
                      child: Text(
                        '● 가족과 기기를 연결하면 모든 추억을 함께 볼 수 있어요.',
                        style: TextStyle(fontSize: 11, color: AppColors.muted),
                      ),
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
                  '${expires == null ? '정해진 시간 동안' : memoryDate(expires)}까지 유효하며, 가입 요청은 소유자가 다시 승인해야 합니다.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: () => SharePlus.instance.share(
                    ShareParams(
                      text:
                          'Memory Home 가족 초대\nwilliamjames://join?token=$token',
                    ),
                  ),
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

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.controller, required this.member});
  final AppController controller;
  final DeviceMember member;
  @override
  Widget build(BuildContext context) {
    final colors = [
      AppColors.yellowSoft,
      AppColors.greenCard,
      AppColors.pink,
      AppColors.sageSoft,
    ];
    final color =
        colors[member.user.displayName.hashCode.abs() % colors.length];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 4),
      leading: CircleAvatar(
        backgroundColor: color,
        child: Text(
          member.user.displayName.characters.firstOrNull ?? '?',
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            color: AppColors.inkSoft,
          ),
        ),
      ),
      title: Text(
        member.user.displayName,
        style: const TextStyle(fontWeight: FontWeight.w900),
      ),
      subtitle: Text(
        member.user.email,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: member.role == 'OWNER'
          ? const StatusPill(label: '소유자', color: AppColors.sageSoft)
          : controller.selectedDevice!.isOwner
          ? PopupMenuButton<String>(
              onSelected: (action) =>
                  action == 'transfer' ? _transfer(context) : _revoke(context),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'transfer', child: Text('소유권 넘기기')),
                PopupMenuItem(value: 'revoke', child: Text('접근 권한 회수')),
              ],
            )
          : const StatusPill(label: '멤버', color: AppColors.sageSoft),
    );
  }

  Future<void> _transfer(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('소유권을 넘길까요?'),
        content: Text(
          '${member.user.displayName}님이 새 OWNER가 되고 나는 MEMBER가 됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('소유권 이전'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        await controller.api.transferOwnership(
          controller.selectedDevice!.id,
          member.id,
        );
        await controller.refreshAll();
        if (context.mounted) showAppSnack(context, '소유권을 이전했어요.');
      } catch (failure) {
        if (context.mounted) showAppSnack(context, '$failure', error: true);
      }
    }
  }

  Future<void> _revoke(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('접근 권한을 회수할까요?'),
        content: Text('${member.user.displayName}님은 즉시 영상과 라이브를 볼 수 없게 됩니다.'),
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

class _JoinRequestCard extends StatelessWidget {
  const _JoinRequestCard({required this.controller, required this.request});
  final AppController controller;
  final JoinRequestInfo request;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: SoftCard(
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.pink,
            child: Text(
              request.requester.displayName.characters.firstOrNull ?? '?',
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.requester.displayName,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                Text(
                  request.requester.email,
                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => controller.reject(request),
            child: const Text('거절'),
          ),
          FilledButton(
            onPressed: () => controller.approve(request),
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: const Text('승인'),
          ),
        ],
      ),
    ),
  );
}

class _OverlappingDots extends StatelessWidget {
  const _OverlappingDots();
  @override
  Widget build(BuildContext context) => const SizedBox(
    width: 62,
    height: 34,
    child: Stack(
      children: [
        Positioned(
          left: 0,
          child: CircleAvatar(
            radius: 17,
            backgroundColor: AppColors.yellowSoft,
          ),
        ),
        Positioned(
          left: 20,
          child: CircleAvatar(radius: 17, backgroundColor: AppColors.greenCard),
        ),
        Positioned(
          left: 40,
          child: CircleAvatar(radius: 17, backgroundColor: AppColors.pink),
        ),
      ],
    ),
  );
}
