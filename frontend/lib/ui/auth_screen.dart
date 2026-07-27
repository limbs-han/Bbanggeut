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

class _AuthScreenState extends State<AuthScreen> with WidgetsBindingObserver {
  final name = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  final scrollController = ScrollController();
  final nameFocus = FocusNode();
  final emailFocus = FocusNode();
  final passwordFocus = FocusNode();
  final nameFieldKey = GlobalKey();
  final emailFieldKey = GlobalKey();
  final passwordFieldKey = GlobalKey();
  bool signUp = false;
  bool obscure = true;
  bool remember = true;
  bool keyboardVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    nameFocus.addListener(_scheduleFocusedField);
    emailFocus.addListener(_scheduleFocusedField);
    passwordFocus.addListener(_scheduleFocusedField);
  }

  @override
  void didChangeMetrics() {
    if (mounted) {
      final nextKeyboardVisible = View.of(context).viewInsets.bottom > 0;
      if (nextKeyboardVisible != keyboardVisible) {
        setState(() => keyboardVisible = nextKeyboardVisible);
      }
    }
    _scheduleFocusedField();
  }

  void _scheduleFocusedField() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scrollController.hasClients) return;
      if (!keyboardVisible) {
        scrollController.jumpTo(0);
        return;
      }
      final fieldContext = switch ((
        nameFocus.hasFocus,
        emailFocus.hasFocus,
        passwordFocus.hasFocus,
      )) {
        (true, _, _) => nameFieldKey.currentContext,
        (_, true, _) => emailFieldKey.currentContext,
        (_, _, true) => passwordFieldKey.currentContext,
        _ => null,
      };
      if (fieldContext == null) return;
      Scrollable.ensureVisible(
        fieldContext,
        alignment: 0.45,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    name.dispose();
    email.dispose();
    password.dispose();
    scrollController.dispose();
    nameFocus.dispose();
    emailFocus.dispose();
    passwordFocus.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    FocusScope.of(context).unfocus();
    final ok = signUp
        ? await widget.controller.signUp(
            name.text,
            email.text,
            password.text,
            persistSession: remember,
          )
        : await widget.controller.login(
            email.text,
            password.text,
            persistSession: remember,
          );
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
    resizeToAvoidBottomInset: true,
    body: AppBackdrop(
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            controller: scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: keyboardVisible
                ? const ClampingScrollPhysics()
                : const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
            child: Center(
              child: _AuthViewport(
                keyboardVisible: keyboardVisible,
                width: constraints.maxWidth > 568
                    ? 520
                    : constraints.maxWidth - 48,
                height: constraints.maxHeight - 40,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (signUp)
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Expanded(child: _BrandMark()),
                          Image.asset(
                            'assets/images/bbanggeut_mascot.png',
                            width: 96,
                            height: 104,
                            fit: BoxFit.contain,
                            semanticLabel: '빵긋 캐릭터',
                          ),
                        ],
                      )
                    else ...[
                      const _BrandMark(horizontalOffset: -16),
                      const SizedBox(height: 12),
                      Text(
                        '웃음이 머무는 우리 집',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: AppColors.muted, fontSize: 15),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: RichText(
                                maxLines: 2,
                                softWrap: false,
                                text: TextSpan(
                                  style: Theme.of(context)
                                      .textTheme
                                      .displaySmall
                                      ?.copyWith(fontSize: 34),
                                  children: const [
                                    TextSpan(text: '지나간 웃음도,\n'),
                                    TextSpan(
                                      text: '추억',
                                      style: TextStyle(color: AppColors.coral),
                                    ),
                                    TextSpan(text: '이 됩니다. '),
                                    WidgetSpan(
                                      alignment: PlaceholderAlignment.middle,
                                      child: Icon(
                                        Icons.favorite_rounded,
                                        size: 17,
                                        color: AppColors.coral,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          Image.asset(
                            'assets/images/bbanggeut_mascot.png',
                            width: 122,
                            height: 142,
                            fit: BoxFit.contain,
                            semanticLabel: '빵긋 캐릭터',
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),
                    if (signUp) ...[
                      _FieldLabel('이름'),
                      TextField(
                        key: nameFieldKey,
                        controller: name,
                        focusNode: nameFocus,
                        textInputAction: TextInputAction.next,
                        scrollPadding: const EdgeInsets.only(bottom: 160),
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.person_outline_rounded),
                          hintText: '가족에게 보일 이름',
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    _FieldLabel('이메일'),
                    TextField(
                      key: emailFieldKey,
                      controller: email,
                      focusNode: emailFocus,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      scrollPadding: const EdgeInsets.only(bottom: 160),
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.mail_outline_rounded),
                        hintText: 'owner@example.com',
                      ),
                    ),
                    const SizedBox(height: 10),
                    _FieldLabel('비밀번호'),
                    TextField(
                      key: passwordFieldKey,
                      controller: password,
                      focusNode: passwordFocus,
                      obscureText: obscure,
                      textInputAction: TextInputAction.done,
                      scrollPadding: const EdgeInsets.only(bottom: 160),
                      onSubmitted: (_) => submit(),
                      autofillHints: const [AutofillHints.password],
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        hintText: signUp ? '10자 이상 입력해 주세요' : '비밀번호를 입력하세요',
                        hintStyle: signUp
                            ? null
                            : const TextStyle(
                                color: AppColors.muted,
                                fontSize: 13,
                              ),
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
                    const SizedBox(height: 6),
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
                    FilledButton(
                      onPressed: widget.controller.busy ? null : submit,
                      child: widget.controller.busy
                          ? const SizedBox.square(
                              dimension: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.4,
                              ),
                            )
                          : Text(signUp ? '회원가입 완료' : '로그인'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: widget.controller.busy
                          ? null
                          : () => setState(() => signUp = !signUp),
                      child: Text(signUp ? '로그인으로 돌아가기' : '회원가입'),
                    ),
                    const SizedBox(height: 14),
                    const _SocialDivider(),
                    const SizedBox(height: 10),
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
                    const SizedBox(height: 8),
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
    ),
  );
}

class _AuthViewport extends StatelessWidget {
  const _AuthViewport({
    required this.keyboardVisible,
    required this.width,
    required this.height,
    required this.child,
  });

  final bool keyboardVisible;
  final double width;
  final double height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (keyboardVisible) {
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: child,
      );
    }
    return SizedBox(
      width: width,
      height: height,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topCenter,
        child: SizedBox(width: width, child: child),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark({this.horizontalOffset = 0});

  final double horizontalOffset;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: Transform.translate(
      offset: Offset(horizontalOffset, 0),
      child: SizedBox(
        width: 160,
        height: 60,
        child: Image.asset(
          'assets/images/bbanggeut_logo.png',
          fit: BoxFit.cover,
          alignment: Alignment.center,
          semanticLabel: '빵긋 로고',
        ),
      ),
    ),
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
