import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'widgets.dart';

class FamilyScreen extends StatefulWidget {
  const FamilyScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends State<FamilyScreen> {
  final inviteEmail = TextEditingController();
  String? appliedMembershipRequestToken;
  Uri? membershipRequestLink;

  AppController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_applyMembershipRequest);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _applyMembershipRequest(),
    );
  }

  void _applyMembershipRequest() {
    final token = controller.pendingMembershipRequestToken;
    final preview = controller.pendingMembershipRequestPreview;
    if (!mounted ||
        token == null ||
        preview == null ||
        token == appliedMembershipRequestToken) {
      return;
    }
    appliedMembershipRequestToken = token;
    inviteEmail.value = TextEditingValue(
      text: preview.email,
      selection: TextSelection.collapsed(offset: preview.email.length),
    );
    setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_applyMembershipRequest);
    inviteEmail.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vault = controller.selectedVault!;
    final device = controller.selectedDevice;
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
                          child: PopupMenuButton<String>(
                            key: const Key('family-vault-selector'),
                            initialValue: vault.id,
                            tooltip: '관리할 Vault 변경',
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
                                    child: Text(item.name),
                                  ),
                                )
                                .toList(growable: false),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    vault.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleLarge,
                                  ),
                                ),
                                if (controller.vaults.length > 1)
                                  const Icon(Icons.swap_horiz_rounded),
                              ],
                            ),
                          ),
                        ),
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
                                Text(
                                  device == null
                                      ? 'MEMORY VAULT'
                                      : 'HOME CAMERA',
                                  style: const TextStyle(
                                    fontSize: 9,
                                    color: AppColors.inkSoft,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1,
                                  ),
                                ),
                                Text(
                                  device?.name ?? vault.name,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                Text(
                                  device == null
                                      ? '● 기기 연결 없음 · 과거 영상과 구성원은 유지됩니다'
                                      : '● ${controller.deviceStatus?.isOnline == true ? '온라인' : '오프라인'} · ${device.model}',
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
                    if (vault.isOwner &&
                        controller.sentInvitations.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      const Text(
                        '보낸 초대',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          color: AppColors.inkSoft,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...controller.sentInvitations.map(
                        (invitation) => _SentInvitationCard(
                          controller: controller,
                          invitation: invitation,
                        ),
                      ),
                    ],
                    if (vault.isOwner) ...[
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
                            if (controller.pendingMembershipRequestPreview !=
                                null) ...[
                              Container(
                                width: double.infinity,
                                margin: const EdgeInsets.only(bottom: 10),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  '${controller.pendingMembershipRequestPreview!.displayName}님이 멤버 초대를 요청했어요. 이메일을 확인하고 초대를 보내 주세요.',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.inkSoft,
                                  ),
                                ),
                              ),
                            ],
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: inviteEmail,
                                    keyboardType: TextInputType.emailAddress,
                                    textInputAction: TextInputAction.send,
                                    autofillHints: const [AutofillHints.email],
                                    decoration: const InputDecoration(
                                      labelText: '이메일',
                                      hintText: 'family@example.com',
                                    ),
                                    onSubmitted: (_) => _sendInvitation(),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton(
                                  onPressed: controller.busy
                                      ? null
                                      : _sendInvitation,
                                  style: FilledButton.styleFrom(
                                    minimumSize: const Size(72, 56),
                                  ),
                                  child: const Text('초대'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '입력한 이메일 계정의 받은 초대함으로 초대를 보내요.',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppColors.inkSoft,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (!vault.isOwner) ...[
                      const SizedBox(height: 18),
                      SoftCard(
                        color: AppColors.greenCard,
                        borderColor: AppColors.greenCard,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '초대링크',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(height: 7),
                            const Text(
                              'OWNER에게 보낼 초대 요청 링크를 만들 수 있어요.',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.inkSoft,
                              ),
                            ),
                            if (membershipRequestLink != null) ...[
                              const SizedBox(height: 12),
                              SelectableText(
                                '$membershipRequestLink',
                                key: const Key('membership-request-link'),
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: FilledButton.icon(
                                    onPressed: controller.busy
                                        ? null
                                        : membershipRequestLink == null
                                        ? _createMemberLink
                                        : _copyMemberLink,
                                    icon: Icon(
                                      membershipRequestLink == null
                                          ? Icons.link_rounded
                                          : Icons.copy_rounded,
                                    ),
                                    label: Text(
                                      membershipRequestLink == null
                                          ? '링크 생성'
                                          : '복사',
                                    ),
                                  ),
                                ),
                                if (membershipRequestLink != null) ...[
                                  const SizedBox(width: 8),
                                  IconButton.filledTonal(
                                    tooltip: '공유',
                                    onPressed: _shareMemberLink,
                                    icon: const Icon(Icons.share_rounded),
                                  ),
                                ],
                              ],
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

  Future<void> _sendInvitation() async {
    if (controller.busy) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final email = inviteEmail.text.trim();
    if (email.isEmpty) {
      showAppSnack(context, '초대할 가족의 이메일을 입력해 주세요.', error: true);
      return;
    }
    if (!_looksLikeEmail(email)) {
      showAppSnack(context, '올바른 이메일 주소를 입력해 주세요.', error: true);
      return;
    }
    final ok = await controller.createInvitation(email, 'MEMBER');
    if (!mounted) return;
    if (ok) {
      inviteEmail.clear();
      showAppSnack(context, '$email 계정으로 초대를 보냈어요.');
    } else {
      showAppSnack(
        context,
        controller.errorMessage ?? '초대를 보내지 못했어요.',
        error: true,
      );
    }
  }

  Future<void> _createMemberLink() async {
    if (controller.busy) return;
    final link = await controller.createMembershipRequestLink();
    if (!mounted) return;
    if (link == null) {
      showAppSnack(
        context,
        controller.errorMessage ?? '초대 요청 링크를 만들지 못했어요.',
        error: true,
      );
      return;
    }
    setState(() => membershipRequestLink = link);
    await Clipboard.setData(ClipboardData(text: '$link'));
    if (mounted) showAppSnack(context, '초대 요청 링크를 복사했어요.');
  }

  Future<void> _copyMemberLink() async {
    final link = membershipRequestLink;
    if (link == null) return;
    await Clipboard.setData(ClipboardData(text: '$link'));
    if (mounted) showAppSnack(context, '초대 요청 링크를 복사했어요.');
  }

  Future<void> _shareMemberLink() async {
    final link = membershipRequestLink;
    if (link == null) return;
    await SharePlus.instance.share(ShareParams(text: '가족 초대 요청 링크입니다.\n$link'));
  }

  bool _looksLikeEmail(String value) {
    final at = value.indexOf('@');
    return at > 0 && at < value.length - 3 && value.substring(at).contains('.');
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
    final isOwner = normalizeRole(member.role) == 'OWNER';
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusPill(
            label: isOwner ? 'OWNER' : 'MEMBER',
            color: AppColors.sageSoft,
          ),
          if (isOwner) ...[
            const SizedBox(width: 5),
            const Text(
              '👑',
              key: Key('family-owner-crown'),
              style: TextStyle(fontSize: 18, height: 1),
            ),
          ],
          if (!isOwner && controller.selectedVault?.isOwner == true)
            PopupMenuButton<String>(
              onSelected: (action) =>
                  action == 'transfer' ? _transfer(context) : _revoke(context),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'transfer', child: Text('소유권 넘기기')),
                PopupMenuItem(value: 'revoke', child: Text('구성원 내보내기')),
              ],
            ),
        ],
      ),
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
        final ok = await controller.transferOwnership(member);
        if (!ok) {
          throw controller.errorMessage ?? '소유권을 이전하지 못했어요.';
        }
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
        title: const Text('구성원을 내보낼까요?'),
        content: Text('${member.user.displayName}님은 즉시 영상과 라이브를 볼 수 없게 됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('내보내기'),
          ),
        ],
      ),
    );
    if (confirmed == true) controller.revokeMemberAccess(member);
  }
}

class _SentInvitationCard extends StatelessWidget {
  const _SentInvitationCard({
    required this.controller,
    required this.invitation,
  });
  final AppController controller;
  final Invitation invitation;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: SoftCard(
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: AppColors.greenCard,
            child: const Icon(Icons.mail_outline_rounded),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  invitation.inviteeEmail,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                Text(
                  '${invitation.role} · ${_invitationStatusLabel(invitation.status)}',
                  style: const TextStyle(fontSize: 11, color: AppColors.muted),
                ),
              ],
            ),
          ),
          if (invitation.isPending)
            TextButton(
              onPressed: controller.busy
                  ? null
                  : () async {
                      final ok = await controller.revokeInvitation(invitation);
                      if (!context.mounted) return;
                      showAppSnack(
                        context,
                        ok
                            ? '초대를 취소했어요.'
                            : (controller.errorMessage ?? '초대를 취소하지 못했어요.'),
                        error: !ok,
                      );
                    },
              child: const Text('초대 취소'),
            ),
        ],
      ),
    ),
  );
}

String _invitationStatusLabel(String status) => switch (status) {
  'PENDING' => '수락 대기',
  'ACCEPTED' => '수락됨',
  'DECLINED' => '거절됨',
  'REVOKED' => '취소됨',
  'EXPIRED' => '만료됨',
  _ => status,
};

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
