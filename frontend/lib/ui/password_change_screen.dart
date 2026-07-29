import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'widgets.dart';

class PasswordChangeScreen extends StatefulWidget {
  const PasswordChangeScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<PasswordChangeScreen> createState() => _PasswordChangeScreenState();
}

class _PasswordChangeScreenState extends State<PasswordChangeScreen> {
  final currentPassword = TextEditingController();
  final newPassword = TextEditingController();
  final confirmation = TextEditingController();
  bool obscureCurrent = true;
  bool obscureNew = true;
  bool obscureConfirmation = true;
  String? errorText;

  @override
  void dispose() {
    currentPassword.dispose();
    newPassword.dispose();
    confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.controller.busy) return;
    if (currentPassword.text.isEmpty ||
        newPassword.text.isEmpty ||
        confirmation.text.isEmpty) {
      setState(() => errorText = '모든 비밀번호 입력란을 채워 주세요.');
      return;
    }
    if (newPassword.text.length < 10 || newPassword.text.length > 72) {
      setState(() => errorText = '새 비밀번호는 10자 이상 72자 이하로 입력해 주세요.');
      return;
    }
    if (newPassword.text != confirmation.text) {
      setState(() => errorText = '새 비밀번호와 확인 값이 일치하지 않습니다.');
      return;
    }
    if (newPassword.text == currentPassword.text) {
      setState(() => errorText = '현재 비밀번호와 다른 새 비밀번호를 입력해 주세요.');
      return;
    }
    setState(() => errorText = null);
    final ok = await widget.controller.changePassword(
      currentPassword.text,
      newPassword.text,
    );
    if (!mounted) return;
    if (ok) {
      showAppSnack(context, '비밀번호를 변경했어요.');
      Navigator.pop(context, true);
    } else {
      setState(
        () => errorText = widget.controller.errorMessage ?? '비밀번호를 변경하지 못했어요.',
      );
    }
  }

  InputDecoration _decoration(String label, bool obscure, VoidCallback toggle) {
    return InputDecoration(
      labelText: label,
      prefixIcon: const Icon(Icons.lock_outline_rounded),
      suffixIcon: IconButton(
        onPressed: toggle,
        icon: Icon(
          obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('비밀번호 변경')),
    body: AppBackdrop(
      child: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        children: [
          TextField(
            key: const Key('current-password'),
            controller: currentPassword,
            obscureText: obscureCurrent,
            textInputAction: TextInputAction.next,
            decoration: _decoration(
              '현재 비밀번호',
              obscureCurrent,
              () => setState(() => obscureCurrent = !obscureCurrent),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('new-password'),
            controller: newPassword,
            obscureText: obscureNew,
            textInputAction: TextInputAction.next,
            decoration: _decoration(
              '새 비밀번호',
              obscureNew,
              () => setState(() => obscureNew = !obscureNew),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            key: const Key('password-confirmation'),
            controller: confirmation,
            obscureText: obscureConfirmation,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: _decoration(
              '새 비밀번호 확인',
              obscureConfirmation,
              () => setState(() => obscureConfirmation = !obscureConfirmation),
            ),
          ),
          if (errorText != null) ...[
            const SizedBox(height: 10),
            Text(
              errorText!,
              key: const Key('password-change-error'),
              style: const TextStyle(
                color: AppColors.danger,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: widget.controller.busy ? null : _submit,
            child: widget.controller.busy
                ? const SizedBox.square(
                    dimension: 21,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : const Text('비밀번호 변경하기'),
          ),
        ],
      ),
    ),
  );
}
