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
  final name = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  bool signUp = false;
  bool obscure = true;
  bool remember = true;

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    password.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    FocusScope.of(context).unfocus();
    final ok = signUp
        ? await widget.controller.signUp(name.text, email.text, password.text)
        : await widget.controller.login(email.text, password.text);
    if (!ok && mounted) {
      showAppSnack(
        context,
        widget.controller.errorMessage ?? '입력한 정보를 다시 확인해 주세요.',
        error: true,
      );
    }
  }

  void unavailable(String feature) =>
      showAppSnack(context, '$feature 로그인은 현재 백엔드에 구현되어 있지 않아요.', error: true);

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AppBackdrop(
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 52,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _BrandMark(),
                  const SizedBox(height: 32),
                  Text(
                    '웃음이 머무는 우리 집',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppColors.muted,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 8),
                  RichText(
                    text: TextSpan(
                      style: Theme.of(context).textTheme.displaySmall,
                      children: const [
                        TextSpan(text: '지나간 웃음도,\n다시 만나면\n'),
                        TextSpan(
                          text: '추억',
                          style: TextStyle(color: Color(0xFFD98522)),
                        ),
                        TextSpan(text: '이 됩니다.'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Text(
                          'AI가 담은 우리 가족의 웃음,\n영상과 메모로 함께 간직해요.',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 4, right: 8),
                        child: Icon(
                          Icons.favorite_rounded,
                          size: 17,
                          color: AppColors.coral,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  if (signUp) ...[
                    _FieldLabel('이름'),
                    TextField(
                      controller: name,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.person_outline_rounded),
                        hintText: '가족에게 보일 이름',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  _FieldLabel('이메일'),
                  TextField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.mail_outline_rounded),
                      hintText: 'owner@example.com',
                    ),
                  ),
                  const SizedBox(height: 12),
                  _FieldLabel('비밀번호'),
                  TextField(
                    controller: password,
                    obscureText: obscure,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => submit(),
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      hintText: signUp ? '10자 이상 입력해 주세요' : '••••••••',
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => obscure = !obscure),
                        icon: Icon(
                          obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Checkbox(
                        value: remember,
                        onChanged: (value) =>
                            setState(() => remember = value ?? true),
                        activeColor: AppColors.inkSoft,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                      const Text(
                        '로그인 상태 유지',
                        style: TextStyle(color: AppColors.inkSoft),
                      ),
                      const Spacer(),
                      if (!signUp)
                        TextButton(
                          onPressed: () => showAppSnack(
                            context,
                            '비밀번호 찾기 API가 아직 백엔드에 없어요.',
                            error: true,
                          ),
                          child: const Text('비밀번호 찾기'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  FilledButton(
                    onPressed: widget.controller.busy ? null : submit,
                    child: widget.controller.busy
                        ? const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          )
                        : Text(signUp ? '회원가입 완료' : '로그인'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: widget.controller.busy
                        ? null
                        : () => setState(() => signUp = !signUp),
                    child: Text(signUp ? '로그인으로 돌아가기' : '회원가입'),
                  ),
                  const SizedBox(height: 22),
                  const _SocialDivider(),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _SocialButton(
                        label: 'Apple',
                        mark: '●',
                        onTap: () => unavailable('Apple'),
                      ),
                      _SocialButton(
                        label: 'Google',
                        mark: 'G',
                        color: const Color(0xFF4285F4),
                        onTap: () => unavailable('Google'),
                      ),
                      _SocialButton(
                        label: '카카오',
                        mark: 'TALK',
                        color: const Color(0xFFF9DC00),
                        onTap: () => unavailable('카카오'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '로그인하면 서비스 이용약관 및 개인정보 처리방침에 동의하게 됩니다.',
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(fontSize: 11),
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
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: AppColors.greenCard,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Icon(
          Icons.eco_outlined,
          color: AppColors.sageDark,
          size: 32,
        ),
      ),
      const SizedBox(width: 12),
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'M E M O R Y',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
          Text(
            'H O M E',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.2,
              color: AppColors.muted,
            ),
          ),
        ],
      ),
      const Spacer(),
      const Text('✦', style: TextStyle(fontSize: 30, color: AppColors.yellow)),
      const SizedBox(width: 2),
      const CircleAvatar(radius: 2.5, backgroundColor: AppColors.coral),
    ],
  );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 1, bottom: 7),
    child: Text(
      label,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w800,
        color: AppColors.inkSoft,
      ),
    ),
  );
}

class _SocialDivider extends StatelessWidget {
  const _SocialDivider();
  @override
  Widget build(BuildContext context) => const Row(
    children: [
      Expanded(child: Divider()),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: 14),
        child: Text(
          '또는 간편 로그인',
          style: TextStyle(color: AppColors.muted, fontSize: 13),
        ),
      ),
      Expanded(child: Divider()),
    ],
  );
}

class _SocialButton extends StatelessWidget {
  const _SocialButton({
    required this.label,
    required this.mark,
    required this.onTap,
    this.color = Colors.black,
  });
  final String label;
  final String mark;
  final Color color;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(99),
    onTap: onTap,
    child: Column(
      children: [
        Container(
          width: 56,
          height: 56,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: AppColors.surface,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Color(0x17000000),
                blurRadius: 14,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Text(
            mark,
            style: TextStyle(
              fontSize: mark.length > 1 ? 9 : 24,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ),
        const SizedBox(height: 7),
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: AppColors.inkSoft,
            fontSize: 12,
          ),
        ),
      ],
    ),
  );
}
