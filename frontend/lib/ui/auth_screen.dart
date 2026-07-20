import 'package:flutter/material.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'widgets.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final formKey = GlobalKey<FormState>();
  final name = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  bool signUp = false;
  bool obscure = true;

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    FocusScope.of(context).unfocus();
    if (!(formKey.currentState?.validate() ?? false)) {
      return;
    }
    final ok = signUp
        ? await widget.controller.signUp(name.text, email.text, password.text)
        : await widget.controller.login(email.text, password.text);
    if (!ok && mounted) {
      showAppSnack(
        context,
        widget.controller.errorMessage ?? '다시 시도해 주세요.',
        error: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Form(
              key: formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: _BrandMark(),
                  ),
                  const SizedBox(height: 46),
                  Text(
                    signUp ? '새로운 추억을\n함께 시작해요' : '오늘의 순간을\n다시 만나보세요',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    signUp
                        ? '계정을 만들고 우리 집 카메라를 연결해 보세요.'
                        : '소중한 순간이 안전하게 기다리고 있어요.',
                    style: Theme.of(
                      context,
                    ).textTheme.bodyLarge?.copyWith(color: AppColors.muted),
                  ),
                  const SizedBox(height: 38),
                  if (signUp) ...[
                    TextFormField(
                      controller: name,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: '이름',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                      ),
                      validator: (value) => (value?.trim().isEmpty ?? true)
                          ? '이름을 입력해 주세요.'
                          : null,
                    ),
                    const SizedBox(height: 14),
                  ],
                  TextFormField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '이메일',
                      prefixIcon: Icon(Icons.mail_outline_rounded),
                    ),
                    validator: (value) =>
                        !RegExp(
                          r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                        ).hasMatch(value?.trim() ?? '')
                        ? '올바른 이메일을 입력해 주세요.'
                        : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: password,
                    obscureText: obscure,
                    onFieldSubmitted: (_) => submit(),
                    decoration: InputDecoration(
                      labelText: '비밀번호',
                      helperText: signUp ? '10자 이상 입력해 주세요.' : null,
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => obscure = !obscure),
                        icon: Icon(
                          obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    validator: (value) =>
                        (value?.length ?? 0) < (signUp ? 10 : 1)
                        ? (signUp ? '비밀번호는 10자 이상이어야 해요.' : '비밀번호를 입력해 주세요.')
                        : null,
                  ),
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed: widget.controller.busy ? null : submit,
                    child: widget.controller.busy
                        ? const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Text(signUp ? '계정 만들기' : '로그인'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: widget.controller.busy
                        ? null
                        : () => setState(() => signUp = !signUp),
                    child: Text(signUp ? '이미 계정이 있어요' : '처음이신가요? 회원가입'),
                  ),
                  const SizedBox(height: 24),
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.verified_user_outlined,
                        size: 16,
                        color: AppColors.primary,
                      ),
                      SizedBox(width: 7),
                      Text(
                        'TLS로 안전하게 암호화된 연결',
                        style: TextStyle(fontSize: 12, color: AppColors.muted),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();
  @override
  Widget build(BuildContext context) => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.all(Radius.circular(10)),
        ),
        child: Padding(
          padding: EdgeInsets.all(9),
          child: Icon(
            Icons.auto_awesome_rounded,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
      SizedBox(width: 10),
      Text(
        'WILLIAM JAMES',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.4,
          color: AppColors.primaryDark,
        ),
      ),
    ],
  );
}
