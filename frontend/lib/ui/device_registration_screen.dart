import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import 'family_screen.dart';
import 'invitation_inbox_screen.dart';
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
  final codePrefix = TextEditingController();
  final codeSuffix = TextEditingController();
  final codePrefixFocus = FocusNode();
  final codeSuffixFocus = FocusNode();
  int mode = 0;
  Uri? membershipRequestLink;
  String? registrationError;

  @override
  void dispose() {
    codePrefix.dispose();
    codeSuffix.dispose();
    codePrefixFocus.dispose();
    codeSuffixFocus.dispose();
    super.dispose();
  }

  String get _normalizedCode =>
      '${codePrefix.text}${codeSuffix.text}'.trim().toUpperCase();

  Future<void> _register() async {
    if (widget.controller.busy) return;
    FocusScope.of(context).unfocus();
    final code = _normalizedCode;
    if (code.isEmpty) {
      setState(() => registrationError = '시리얼 번호를 입력해 주세요.');
      return;
    }
    if (!RegExp(r'^[A-Z0-9]{8}$').hasMatch(code)) {
      setState(() => registrationError = '영문 대문자와 숫자로 된 8자리 번호를 확인해 주세요.');
      return;
    }
    setState(() => registrationError = null);
    final formatted = '${code.substring(0, 4)}-${code.substring(4)}';
    final ok = await widget.controller.claimDevice(formatted);
    if (!mounted) return;
    if (!ok) {
      final apiMessage = widget.controller.errorMessage;
      setState(
        () => registrationError =
            apiMessage?.contains('서버') == true ||
                apiMessage?.contains('네트워크') == true ||
                apiMessage?.contains('연결') == true
            ? apiMessage
            : '유효하지 않거나 이미 사용된 시리얼 번호예요.',
      );
      return;
    }
    showAppSnack(context, '기기가 연결됐어요. 가족을 초대해 보세요.');
    if (widget.canGoBack) {
      widget.controller.consumeOpenFamilyAfterDeviceClaim();
      await Navigator.pushReplacement<void, void>(
        context,
        MaterialPageRoute(
          builder: (_) => FamilyScreen(controller: widget.controller),
        ),
      );
    }
  }

  Future<void> _createMemberLink() async {
    if (widget.controller.busy) return;
    final link = await widget.controller.createMembershipRequestLink();
    if (!mounted) return;
    if (link == null) {
      showAppSnack(
        context,
        widget.controller.errorMessage ?? '요청 링크를 만들지 못했어요.',
        error: true,
      );
      return;
    }
    setState(() => membershipRequestLink = link);
    await Clipboard.setData(ClipboardData(text: '$link'));
    if (mounted) showAppSnack(context, '멤버 요청 링크를 복사했어요.');
  }

  Future<void> _copyMemberLink() async {
    final link = membershipRequestLink;
    if (link == null) return;
    await Clipboard.setData(ClipboardData(text: '$link'));
    if (mounted) showAppSnack(context, '링크를 다시 복사했어요.');
  }

  Future<void> _exit() async {
    if (widget.controller.busy) return;
    if (widget.canGoBack && Navigator.canPop(context)) {
      Navigator.pop(context);
      return;
    }
    try {
      await widget.controller.logout();
    } catch (_) {
      // AppController가 로컬 인증 상태를 항상 초기화한다.
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: true,
    appBar: AppBar(
      leading: IconButton(
        key: const Key('device-registration-back'),
        tooltip: widget.canGoBack ? '뒤로 가기' : '로그아웃',
        onPressed: _exit,
        icon: const Icon(Icons.chevron_left_rounded),
      ),
      title: const Text('기기 등록'),
      actions: [
        TextButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const SerialNumberHelpScreen()),
          ),
          child: const Text('도움말'),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: AppBackdrop(
      child: SafeArea(
        top: false,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
          children: [
            const Icon(
              Icons.camera_indoor_rounded,
              size: 54,
              color: AppColors.sageDark,
            ),
            const SizedBox(height: 8),
            Text(
              '어떤 방식으로 연결할까요?',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 6),
            const Text(
              '기기를 처음 연결하는 Owner와 초대를 요청하는 Member 흐름을 구분했어요.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            const SizedBox(height: 20),
            SegmentedButton<int>(
              key: const Key('device-registration-mode'),
              segments: const [
                ButtonSegment(
                  value: 0,
                  icon: Icon(Icons.home_work_outlined),
                  label: Text('Owner'),
                ),
                ButtonSegment(
                  value: 1,
                  icon: Icon(Icons.person_add_alt_1_outlined),
                  label: Text('Member'),
                ),
              ],
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: widget.controller.busy
                  ? null
                  : (values) {
                      FocusScope.of(context).unfocus();
                      setState(() => mode = values.first);
                    },
            ),
            const SizedBox(height: 16),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: mode == 0 ? _ownerPanel() : _memberPanel(),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: widget.controller.busy
                  ? null
                  : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => InvitationInboxScreen(
                          controller: widget.controller,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.mark_email_unread_outlined),
              label: Text(
                widget.controller.receivedInvitations.isEmpty
                    ? '받은 가족 초대 확인하기'
                    : '받은 가족 초대 ${widget.controller.receivedInvitations.length}개',
              ),
            ),
            if (!widget.canGoBack) ...[
              const SizedBox(height: 6),
              TextButton(
                key: const Key('device-registration-logout'),
                onPressed: widget.controller.busy ? null : _exit,
                style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                child: const Text('로그아웃'),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _ownerPanel() => SoftCard(
    key: const ValueKey('owner-registration-panel'),
    color: AppColors.surface,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '제품 아래쪽 시리얼 번호',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 5),
        const Text(
          '카메라 바닥의 스티커에서 8자리 번호를 확인해 주세요.',
          style: TextStyle(fontSize: 12, color: AppColors.inkSoft),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const Key('registration-code-prefix'),
                controller: codePrefix,
                focusNode: codePrefixFocus,
                textCapitalization: TextCapitalization.characters,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.next,
                autocorrect: false,
                enableSuggestions: false,
                inputFormatters: const [RegistrationCodePartFormatter()],
                maxLength: 4,
                textAlign: TextAlign.center,
                onChanged: (value) {
                  if (registrationError != null) {
                    setState(() => registrationError = null);
                  }
                  if (value.length == 4) codeSuffixFocus.requestFocus();
                },
                decoration: const InputDecoration(
                  hintText: 'ABCD',
                  counterText: '',
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 9),
              child: Text(
                '-',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
              ),
            ),
            Expanded(
              child: TextField(
                key: const Key('registration-code-suffix'),
                controller: codeSuffix,
                focusNode: codeSuffixFocus,
                textCapitalization: TextCapitalization.characters,
                keyboardType: TextInputType.visiblePassword,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                enableSuggestions: false,
                inputFormatters: const [RegistrationCodePartFormatter()],
                maxLength: 4,
                textAlign: TextAlign.center,
                onChanged: (_) {
                  if (registrationError != null) {
                    setState(() => registrationError = null);
                  }
                },
                onSubmitted: (_) => _register(),
                decoration: const InputDecoration(
                  hintText: '1234',
                  counterText: '',
                ),
              ),
            ),
          ],
        ),
        if (registrationError != null) ...[
          const SizedBox(height: 8),
          Text(
            registrationError!,
            key: const Key('registration-error'),
            style: const TextStyle(
              color: AppColors.danger,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: widget.controller.busy ? null : _register,
          child: widget.controller.busy
              ? const SizedBox.square(
                  dimension: 21,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                )
              : const Text('기기 연결하기'),
        ),
      ],
    ),
  );

  Widget _memberPanel() => SoftCard(
    key: const ValueKey('member-registration-panel'),
    color: AppColors.greenCard,
    borderColor: AppColors.greenCard,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Owner에게 초대 요청하기',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 7),
        Text(
          '${widget.controller.user?.email ?? '현재 로그인 계정'} 정보가 포함된 안전한 요청 링크를 만들어요.',
          style: const TextStyle(fontSize: 12, color: AppColors.inkSoft),
        ),
        const SizedBox(height: 14),
        if (membershipRequestLink != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.line),
            ),
            child: SelectableText(
              '$membershipRequestLink',
              key: const Key('membership-request-link'),
              maxLines: 3,
              style: const TextStyle(fontSize: 11),
            ),
          ),
          const SizedBox(height: 10),
        ],
        FilledButton.icon(
          onPressed: widget.controller.busy
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
            membershipRequestLink == null ? '요청 링크 생성 및 복사' : '링크 다시 복사',
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Owner가 링크를 열면 앱의 가족 초대 화면으로 이동하고 내 이메일이 자동 입력됩니다.',
          style: TextStyle(fontSize: 11, color: AppColors.inkSoft),
        ),
      ],
    ),
  );
}

class SerialNumberHelpScreen extends StatelessWidget {
  const SerialNumberHelpScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('시리얼 번호 도움말')),
    body: AppBackdrop(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 32),
        children: [
          const Text(
            '제품 아래쪽을 확인해 주세요',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          const Text(
            '전원을 안전하게 분리한 뒤 카메라를 들어 올리면 바닥 스티커에서 번호를 찾을 수 있어요.',
            style: TextStyle(color: AppColors.inkSoft),
          ),
          const SizedBox(height: 18),
          SoftCard(
            color: AppColors.surfaceWarm,
            child: Column(
              children: [
                const Icon(
                  Icons.camera_indoor_rounded,
                  size: 72,
                  color: AppColors.sageDark,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.line),
                  ),
                  child: const Text(
                    'SERIAL  ABCD-1234',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const ListTile(
            leading: CircleAvatar(child: Text('1')),
            title: Text('앞 네 자리와 뒤 네 자리를 차례로 입력해요.'),
          ),
          const ListTile(
            leading: CircleAvatar(child: Text('2')),
            title: Text('영문은 대문자로 자동 변환되며 대시는 입력하지 않아도 돼요.'),
          ),
          const ListTile(
            leading: CircleAvatar(child: Text('3')),
            title: Text('번호가 지워졌다면 고객 지원 또는 제품 구매처에 문의해 주세요.'),
          ),
        ],
      ),
    ),
  );
}

class RegistrationCodePartFormatter extends TextInputFormatter {
  const RegistrationCodePartFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final selectionEnd = newValue.selection.end.clamp(0, newValue.text.length);
    final beforeSelection = newValue.text.substring(0, selectionEnd);
    final raw = newValue.text.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    final limited = raw.length > 4 ? raw.substring(0, 4) : raw;
    final cursor = beforeSelection
        .toUpperCase()
        .replaceAll(RegExp('[^A-Z0-9]'), '')
        .length
        .clamp(0, limited.length);
    return TextEditingValue(
      text: limited,
      selection: TextSelection.collapsed(offset: cursor),
    );
  }
}

class RegistrationCodeFormatter extends TextInputFormatter {
  const RegistrationCodeFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final selectionEnd = newValue.selection.end.clamp(0, newValue.text.length);
    final beforeSelection = newValue.text.substring(0, selectionEnd);
    final raw = newValue.text.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
    final limited = raw.length > 8 ? raw.substring(0, 8) : raw;
    final formatted = limited.length > 4
        ? '${limited.substring(0, 4)}-${limited.substring(4)}'
        : limited;
    final rawCursor = beforeSelection
        .toUpperCase()
        .replaceAll(RegExp('[^A-Z0-9]'), '')
        .length
        .clamp(0, limited.length);
    final formattedCursor = (rawCursor + (rawCursor > 4 ? 1 : 0)).clamp(
      0,
      formatted.length,
    );
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formattedCursor),
    );
  }
}
