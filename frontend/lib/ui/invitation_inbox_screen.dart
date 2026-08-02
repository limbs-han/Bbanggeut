import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'widgets.dart';

class InvitationInboxScreen extends StatelessWidget {
  const InvitationInboxScreen({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      body: AppBackdrop(
        child: SafeArea(
          child: Column(
            children: [
              SizedBox(
                height: 58,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: '뒤로',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.chevron_left_rounded, size: 34),
                    ),
                    Expanded(
                      child: Text(
                        '받은 요청함',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: '새로고침',
                      onPressed: controller.busy
                          ? null
                          : () => _refresh(context),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: controller.refreshMyInvitations,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
                    children: [
                      const SoftCard(
                        color: AppColors.sageSoft,
                        borderColor: AppColors.sageSoft,
                        child: Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: AppColors.surface,
                              child: Icon(
                                Icons.mark_email_unread_outlined,
                                color: AppColors.sageDark,
                              ),
                            ),
                            SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                '초대를 수락하면 해당 카메라가 내 기기 목록에 바로 추가돼요.',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: AppColors.inkSoft,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      if (controller.receivedInvitations.isEmpty)
                        const EmptyState(
                          icon: Icons.mail_outline_rounded,
                          title: '받은 요청이 없어요',
                          message: 'Owner가 내 이메일로 초대하면 여기에 표시돼요.',
                        )
                      else
                        ...controller.receivedInvitations.map(
                          (invitation) => _InvitationCard(
                            controller: controller,
                            invitation: invitation,
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
    ),
  );

  Future<void> _refresh(BuildContext context) async {
    try {
      await controller.refreshMyInvitations();
    } catch (failure) {
      if (context.mounted) {
        showAppSnack(context, '$failure', error: true);
      }
    }
  }
}

class _InvitationCard extends StatelessWidget {
  const _InvitationCard({required this.controller, required this.invitation});

  final AppController controller;
  final Invitation invitation;

  @override
  Widget build(BuildContext context) {
    final inviter = invitation.inviter;
    final inviterName = inviter?.displayName.isNotEmpty == true
        ? inviter!.displayName
        : (inviter?.email.isNotEmpty == true ? inviter!.email : '가족');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SoftCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const CircleAvatar(
                  backgroundColor: AppColors.greenCard,
                  child: Icon(
                    Icons.videocam_outlined,
                    color: AppColors.sageDark,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        invitation.deviceName,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        '$inviterName님이 초대했어요',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.muted,
                        ),
                      ),
                      Text(
                        invitation.role == 'EDITOR' ? '편집자로 참여' : '뷰어로 참여',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.sageDark,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                if (invitation.expiresAt != null)
                  Text(
                    '${memoryDate(invitation.expiresAt)} 만료',
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.muted,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: controller.busy ? null : () => _decline(context),
                    child: const Text('거절'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: controller.busy ? null : () => _accept(context),
                    child: const Text('수락'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _accept(BuildContext context) async {
    final ok = await controller.acceptInvitation(invitation);
    if (!context.mounted) return;
    showAppSnack(
      context,
      ok
          ? '${invitation.deviceName} 기기가 목록에 추가됐어요.'
          : (controller.errorMessage ?? '초대를 수락하지 못했어요.'),
      error: !ok,
    );
    if (ok && Navigator.canPop(context)) {
      Navigator.pop(context);
    }
  }

  Future<void> _decline(BuildContext context) async {
    final ok = await controller.declineInvitation(invitation);
    if (!context.mounted) return;
    showAppSnack(
      context,
      ok ? '초대를 거절했어요.' : (controller.errorMessage ?? '초대를 거절하지 못했어요.'),
      error: !ok,
    );
  }
}
