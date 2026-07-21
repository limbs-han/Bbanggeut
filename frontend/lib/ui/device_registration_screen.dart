import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'widgets.dart';

class DeviceRegistrationScreen extends StatefulWidget {
  const DeviceRegistrationScreen({
    super.key,
    required this.controller,
    this.canGoBack = true,
  });
  final AppController controller;
  final bool canGoBack;
  @override
  State<DeviceRegistrationScreen> createState() =>
      _DeviceRegistrationScreenState();
}

class _DeviceRegistrationScreenState extends State<DeviceRegistrationScreen> {
  final code = TextEditingController();
  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  Future<void> register() async {
    final normalized = code.text.toUpperCase().replaceAll(
      RegExp(r'[^A-Z0-9]'),
      '',
    );
    if (normalized.length != 8) {
      showAppSnack(context, '기기 화면의 8자리 등록 코드를 입력해 주세요.', error: true);
      return;
    }
    final formatted =
        '${normalized.substring(0, 4)}-${normalized.substring(4)}';
    final ok = await widget.controller.claimDevice(formatted);
    if (!mounted) return;
    if (ok) {
      showAppSnack(context, '기기를 연결했어요. 이제 추억을 만나보세요.');
      if (widget.canGoBack) Navigator.pop(context);
    } else {
      showAppSnack(
        context,
        widget.controller.errorMessage ?? '등록하지 못했어요.',
        error: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      automaticallyImplyLeading: widget.canGoBack,
      title: const Text('새 기기 연결'),
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        child: PagePadding(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [AppColors.primaryDark, AppColors.primary],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(26),
                ),
                child: const Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '카메라 화면의 코드를\n준비해 주세요',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 23,
                              height: 1.25,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            '코드는 2분 동안 한 번만 사용할 수 있어요.',
                            style: TextStyle(
                              color: AppColors.mint,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 16),
                    Icon(
                      Icons.connected_tv_rounded,
                      size: 60,
                      color: Colors.white,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              const _Step(
                number: 1,
                title: '기기의 등록 버튼을 눌러요',
                detail: '기기 화면에 등록 코드가 표시됩니다.',
              ),
              const _Step(
                number: 2,
                title: '8자리 코드를 입력해요',
                detail: '대소문자와 하이픈은 자동으로 정리해요.',
              ),
              const _Step(
                number: 3,
                title: '첫 등록자는 소유자가 돼요',
                detail: '이후 가족을 안전하게 초대할 수 있어요.',
              ),
              const SizedBox(height: 22),
              Text('등록 코드', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 9),
              TextField(
                controller: code,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9-]')),
                  LengthLimitingTextInputFormatter(9),
                ],
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
                decoration: const InputDecoration(
                  hintText: 'ABCD-EFGH',
                  prefixIcon: Icon(Icons.password_rounded),
                ),
                onSubmitted: (_) => register(),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: widget.controller.busy ? null : register,
                child: const Text('기기 연결하기'),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: widget.controller.busy ? null : _joinWithInvite,
                icon: const Icon(Icons.group_add_outlined),
                label: const Text('가족 초대 링크로 참여'),
              ),
              if (!widget.canGoBack) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: widget.controller.logout,
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('다른 계정으로 로그인'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _joinWithInvite() async {
    final input = TextEditingController();
    final token = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('가족 초대 받기'),
        content: TextField(
          controller: input,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: '초대 링크 또는 토큰',
            hintText: '공유받은 내용을 붙여넣으세요',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('요청 보내기'),
          ),
        ],
      ),
    );
    input.dispose();
    if (token == null || token.isEmpty) {
      return;
    }
    final parsed = Uri.tryParse(token);
    final inviteToken = parsed?.queryParameters['token'] ?? token;
    try {
      await widget.controller.api.createJoinRequest(inviteToken);
      if (mounted) {
        showAppSnack(context, '가입 요청을 보냈어요. 소유자의 승인을 기다려 주세요.');
      }
    } catch (failure) {
      if (mounted) {
        showAppSnack(context, '$failure', error: true);
      }
    }
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    required this.detail,
  });
  final int number;
  final String title;
  final String detail;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CircleAvatar(
          radius: 17,
          backgroundColor: AppColors.mint,
          foregroundColor: AppColors.primaryDark,
          child: Text(
            '$number',
            style: const TextStyle(fontWeight: FontWeight.w900),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 3),
              Text(detail, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
        ),
      ],
    ),
  );
}
