import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'widgets.dart';

class FamilyManagementCards extends StatefulWidget {
  const FamilyManagementCards({
    super.key,
    required this.controller,
    this.onOpenInbox,
  });

  final AppController controller;
  final VoidCallback? onOpenInbox;

  @override
  State<FamilyManagementCards> createState() => _FamilyManagementCardsState();
}

class _FamilyManagementCardsState extends State<FamilyManagementCards> {
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

  @override
  void didUpdateWidget(covariant FamilyManagementCards oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == controller) return;
    oldWidget.controller.removeListener(_applyMembershipRequest);
    controller.addListener(_applyMembershipRequest);
    _applyMembershipRequest();
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
    final vault = controller.selectedVault;
    if (vault == null) return const SizedBox.shrink();

    final pendingInvitationCount = controller.receivedInvitations
        .where((item) => item.isPending)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (vault.isOwner) ...[
          _buildOwnerInvitationCard(),
          const SizedBox(height: 14),
        ],
        Row(
          children: [
            Expanded(
              child: Text(
                '가족 구성원 ${controller.members.length}명',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  color: AppColors.inkSoft,
                ),
              ),
            ),
            if (widget.onOpenInbox != null)
              TextButton.icon(
                onPressed: widget.onOpenInbox,
                icon: const Icon(Icons.mark_email_unread_outlined, size: 18),
                label: Text(
                  pendingInvitationCount == 0
                      ? '받은 초대함'
                      : '받은 초대 $pendingInvitationCount',
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (controller.members.isEmpty)
          const SoftCard(
            child: Text(
              '아직 등록된 가족 구성원이 없어요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted),
            ),
          )
        else
          LayoutBuilder(
            builder: (context, constraints) {
              final visibleCount = controller.members.length.clamp(1, 3);
              final cardWidth =
                  (constraints.maxWidth - ((visibleCount - 1) * 8)) /
                  visibleCount;
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: controller.members.indexed.map((entry) {
                    return Padding(
                      padding: EdgeInsets.only(
                        right: entry.$1 == controller.members.length - 1
                            ? 0
                            : 8,
                      ),
                      child: _MemberTile(
                        controller: controller,
                        member: entry.$2,
                        width: cardWidth,
                      ),
                    );
                  }).toList(),
                ),
              );
            },
          ),
        if (vault.isOwner && controller.sentInvitations.isNotEmpty) ...[
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
        if (!vault.isOwner) ...[
          const SizedBox(height: 18),
          _buildMemberLinkCard(),
        ],
        const SizedBox(height: 10),
        const Center(
          child: Text(
            '● 가족과 기기를 연결하면 모든 추억을 함께 볼 수 있어요.',
            style: TextStyle(fontSize: 11, color: AppColors.muted),
          ),
        ),
      ],
    );
  }

  Widget _buildOwnerInvitationCard() {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        SoftCard(
          color: AppColors.greenCard,
          borderColor: AppColors.greenCard,
          padding: const EdgeInsets.fromLTRB(118, 24, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '함께할 가족을 초대해요',
                style: TextStyle(
                  color: AppColors.sageDark,
                  fontSize: 17,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 12),
              if (controller.pendingMembershipRequestPreview != null) ...[
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.surface.withValues(alpha: .82),
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
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('settings-family-invite-email'),
                      controller: inviteEmail,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.send,
                      autofillHints: const [AutofillHints.email],
                      decoration: InputDecoration(
                        hintText: '이메일 입력',
                        filled: true,
                        fillColor: AppColors.surface.withValues(alpha: .94),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 15,
                        ),
                      ),
                      onSubmitted: (_) => _sendInvitation(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: controller.busy ? null : _sendInvitation,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(88, 54),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                    child: const Text(
                      '초대하기',
                      style: TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                '입력한 이메일 계정으로 초대장을 보내요.',
                style: TextStyle(fontSize: 11, color: AppColors.inkSoft),
              ),
            ],
          ),
        ),
        const Positioned(left: 14, top: 25, child: _InviteEnvelopeDecoration()),
      ],
    );
  }

  Widget _buildMemberLinkCard() {
    return SoftCard(
      color: AppColors.greenCard,
      borderColor: AppColors.greenCard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '초대 요청 링크',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 7),
          const Text(
            'OWNER에게 보낼 가족 초대 요청 링크를 만들 수 있어요.',
            style: TextStyle(fontSize: 12, color: AppColors.inkSoft),
          ),
          if (membershipRequestLink != null) ...[
            const SizedBox(height: 12),
            SelectableText(
              '$membershipRequestLink',
              key: const Key('settings-membership-request-link'),
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
                  label: Text(membershipRequestLink == null ? '링크 생성' : '복사'),
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
  const _MemberTile({
    required this.controller,
    required this.member,
    required this.width,
  });

  final AppController controller;
  final DeviceMember member;
  final double width;

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
    return SizedBox(
      width: width,
      child: SoftCard(
        padding: const EdgeInsets.fromLTRB(10, 12, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isOwner) ...[
              const Center(
                child: Text(
                  '👑',
                  key: Key('settings-owner-crown'),
                  style: TextStyle(fontSize: 25, height: 1),
                ),
              ),
              const SizedBox(height: 5),
            ],
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: color,
                  child: Text(
                    member.user.displayName.characters.firstOrNull ?? '?',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: AppColors.inkSoft,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    member.user.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                if (!isOwner && controller.selectedVault?.isOwner == true)
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: PopupMenuButton<String>(
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      onSelected: (action) => action == 'transfer'
                          ? _transfer(context)
                          : _revoke(context),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'transfer',
                          child: Text('소유권 넘기기'),
                        ),
                        PopupMenuItem(value: 'revoke', child: Text('구성원 내보내기')),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            StatusPill(
              label: isOwner ? 'OWNER' : 'MEMBER',
              color: AppColors.sageSoft,
            ),
            const SizedBox(height: 8),
            Text(
              member.user.email,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: AppColors.inkSoft),
            ),
          ],
        ),
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
    if (confirmed != true) return;
    final ok = await controller.transferOwnership(member);
    if (!context.mounted) return;
    showAppSnack(
      context,
      ok ? '소유권을 이전했어요.' : (controller.errorMessage ?? '소유권을 이전하지 못했어요.'),
      error: !ok,
    );
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
    if (confirmed == true) {
      final ok = await controller.revokeMemberAccess(member);
      if (!context.mounted) return;
      showAppSnack(
        context,
        ok ? '구성원을 내보냈어요.' : (controller.errorMessage ?? '구성원을 내보내지 못했어요.'),
        error: !ok,
      );
    }
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
          const CircleAvatar(
            backgroundColor: AppColors.greenCard,
            child: Icon(Icons.mail_outline_rounded),
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

class _InviteEnvelopeDecoration extends StatelessWidget {
  const _InviteEnvelopeDecoration();

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/images/family_invite_envelope.png',
    width: 102,
    fit: BoxFit.contain,
    filterQuality: FilterQuality.high,
  );
}
