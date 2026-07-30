import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'widgets.dart';

class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({
    super.key,
    required this.controller,
    this.initialEmail = '',
  });

  final AppController controller;
  final String initialEmail;

  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  late final TextEditingController email;
  String? fieldError;
  bool sent = false;

  @override
  void initState() {
    super.initState();
    email = TextEditingController(text: widget.initialEmail);
  }

  @override
  void dispose() {
    email.dispose();
    super.dispose();
  }

  bool _looksLikeEmail(String value) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value);
  }

  Future<void> _submit() async {
    if (widget.controller.busy) return;
    final value = email.text.trim();
    if (!_looksLikeEmail(value)) {
      setState(() => fieldError = '올바른 이메일 주소를 입력해 주세요.');
      return;
    }
    setState(() => fieldError = null);
    final ok = await widget.controller.requestPasswordReset(value);
    if (!mounted) return;
    if (ok) {
      setState(() => sent = true);
    } else {
      setState(
        () => fieldError = widget.controller.errorMessage ?? '요청을 처리하지 못했어요.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('비밀번호 찾기')),
    body: AppBackdrop(
      child: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
          children: [
            const Icon(
              Icons.mark_email_read_outlined,
              size: 54,
              color: AppColors.sageDark,
            ),
            const SizedBox(height: 18),
            Text(
              sent ? '이메일을 확인해 주세요' : '재설정 링크를 보내드릴게요',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 10),
            Text(
              sent
                  ? '가입 여부와 관계없이 같은 안내를 표시합니다. 계정이 있다면 비밀번호 재설정 링크가 전송됩니다.'
                  : '가입할 때 사용한 이메일을 입력해 주세요.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            if (!sent) ...[
              TextField(
                key: const Key('password-reset-email'),
                controller: email,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.send,
                autofillHints: const [AutofillHints.email],
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: '이메일',
                  hintText: 'member@example.com',
                  errorText: fieldError,
                  prefixIcon: const Icon(Icons.mail_outline_rounded),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: widget.controller.busy ? null : _submit,
                child: widget.controller.busy
                    ? const SizedBox.square(
                        dimension: 21,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : const Text('재설정 링크 보내기'),
              ),
            ] else
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('로그인으로 돌아가기'),
              ),
          ],
        ),
      ),
    ),
  );
}
