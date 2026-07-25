import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
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
  final scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
    autoZoom: true,
  );
  int tab = 0;
  bool handlingScan = false;

  @override
  void dispose() {
    codePrefix.dispose();
    codeSuffix.dispose();
    codePrefixFocus.dispose();
    codeSuffixFocus.dispose();
    scanner.dispose();
    super.dispose();
  }

  String? _normalizedCode(String raw) {
    final match = RegExp(
      r'([A-Z0-9]{4})-?([A-Z0-9]{4})',
    ).firstMatch(raw.toUpperCase());
    if (match == null) return null;
    return '${match.group(1)}${match.group(2)}';
  }

  Future<void> _register([String? scannedValue]) async {
    final typedCode = '${codePrefix.text}-${codeSuffix.text}';
    final normalized = _normalizedCode(scannedValue ?? typedCode) ?? '';
    if (normalized.length != 8) {
      showAppSnack(context, '기기 화면에 표시된 8자리 코드를 입력해 주세요.', error: true);
      return;
    }
    final formatted =
        '${normalized.substring(0, 4)}-${normalized.substring(4)}';
    codePrefix.text = formatted.substring(0, 4);
    codeSuffix.text = formatted.substring(5);
    final ok = await widget.controller.claimDevice(formatted);
    if (!mounted) return;
    if (ok) {
      showAppSnack(context, '새 카메라가 연결됐어요.');
      if (widget.canGoBack) Navigator.pop(context);
    } else {
      showAppSnack(
        context,
        widget.controller.errorMessage ?? '등록하지 못했어요.',
        error: true,
      );
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (handlingScan || widget.controller.busy) return;
    final raw = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .whereType<String>()
        .firstWhere(
          (value) => _normalizedCode(value) != null,
          orElse: () => '',
        );
    if (raw.isEmpty) return;
    handlingScan = true;
    await scanner.stop();
    await _register(raw);
    if (mounted && widget.controller.selectedDevice == null) {
      handlingScan = false;
      await scanner.start();
    }
  }

  Future<void> _selectTab(int value) async {
    if (value == 0) {
      FocusScope.of(context).unfocus();
      setState(() => tab = value);
      await scanner.start();
    } else {
      await scanner.stop();
      if (!mounted) return;
      setState(() => tab = value);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) codePrefixFocus.requestFocus();
      });
    }
  }

  Future<void> _exitToLogin() async {
    if (widget.controller.busy) return;
    if (widget.canGoBack && Navigator.canPop(context)) {
      Navigator.pop(context);
      return;
    }
    try {
      await scanner.stop();
    } catch (_) {
      // 스캐너 상태와 무관하게 로그아웃은 계속 진행한다.
    }
    try {
      await widget.controller.logout();
    } catch (_) {
      // AppController가 로컬 인증 상태를 항상 초기화하므로 화면 전환은 보장된다.
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: true,
    body: AppBackdrop(
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 58,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  IconButton(
                    key: const Key('device-registration-back'),
                    tooltip: '로그인 화면으로 돌아가기',
                    onPressed: _exitToLogin,
                    icon: const Icon(
                      Icons.chevron_left_rounded,
                      size: 34,
                      color: AppColors.ink,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '기기 등록',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        showAppSnack(context, '카메라 화면에서 등록 모드를 먼저 켜 주세요.'),
                    child: const Text('도움말'),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Column(
                  children: [
                    AnimatedSize(
                      duration: const Duration(milliseconds: 120),
                      alignment: Alignment.topCenter,
                      child: MediaQuery.viewInsetsOf(context).bottom > 0
                          ? const SizedBox.shrink()
                          : Column(
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 52,
                                      height: 52,
                                      decoration: BoxDecoration(
                                        color: AppColors.surface,
                                        borderRadius: BorderRadius.circular(17),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: Color(0x12000000),
                                            blurRadius: 14,
                                          ),
                                        ],
                                      ),
                                      child: const Icon(
                                        Icons.videocam_rounded,
                                        color: AppColors.sageDark,
                                        size: 28,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    const Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '새 카메라 연결',
                                            style: TextStyle(
                                              fontSize: 19,
                                              fontWeight: FontWeight.w900,
                                            ),
                                          ),
                                          SizedBox(height: 2),
                                          Text(
                                            'QR 코드 또는 8자리 등록 코드로 연결해요.',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: AppColors.muted,
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                              ],
                            ),
                    ),
                    SizedBox(
                      height: 48,
                      child: SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(
                            value: 0,
                            icon: Icon(Icons.qr_code_scanner_rounded),
                            label: Text('QR 코드 스캔'),
                          ),
                          ButtonSegment(value: 1, label: Text('직접 코드 입력')),
                        ],
                        selected: {tab},
                        showSelectedIcon: false,
                        onSelectionChanged: (value) => _selectTab(value.first),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: tab == 0
                          ? SoftCard(
                              padding: const EdgeInsets.all(10),
                              child: Column(
                                children: [
                                  const Text(
                                    '기기 화면의 QR 코드를 비춰 주세요',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 7),
                                  Expanded(
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(16),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          MobileScanner(
                                            controller: scanner,
                                            onDetect: _onDetect,
                                            fit: BoxFit.cover,
                                            errorBuilder: (context, error) =>
                                                Container(
                                                  color: AppColors.cream,
                                                  alignment: Alignment.center,
                                                  padding: const EdgeInsets.all(
                                                    18,
                                                  ),
                                                  child: Column(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      const Icon(
                                                        Icons
                                                            .no_photography_outlined,
                                                        color: AppColors.muted,
                                                        size: 36,
                                                      ),
                                                      const SizedBox(height: 8),
                                                      Text(
                                                        error
                                                                .errorDetails
                                                                ?.message ??
                                                            '카메라 권한을 허용해 주세요.',
                                                        textAlign:
                                                            TextAlign.center,
                                                        style: const TextStyle(
                                                          color:
                                                              AppColors.muted,
                                                          fontSize: 12,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                          ),
                                          const IgnorePointer(
                                            child: CustomPaint(
                                              painter: _ScanFramePainter(),
                                            ),
                                          ),
                                          Positioned(
                                            right: 8,
                                            bottom: 8,
                                            child: _ScannerButton(
                                              icon: Icons.cameraswitch_outlined,
                                              onPressed: scanner.switchCamera,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : SingleChildScrollView(
                              keyboardDismissBehavior:
                                  ScrollViewKeyboardDismissBehavior.onDrag,
                              child: SoftCard(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    const Text(
                                      '8자리 등록 코드',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    AnimatedBuilder(
                                      animation: Listenable.merge([
                                        codePrefixFocus,
                                        codeSuffixFocus,
                                      ]),
                                      builder: (context, _) => AnimatedContainer(
                                        duration: const Duration(
                                          milliseconds: 120,
                                        ),
                                        decoration: BoxDecoration(
                                          color: AppColors.surface,
                                          borderRadius: BorderRadius.circular(
                                            18,
                                          ),
                                          border: Border.all(
                                            color:
                                                codePrefixFocus.hasFocus ||
                                                    codeSuffixFocus.hasFocus
                                                ? AppColors.sageDark
                                                : AppColors.line,
                                            width:
                                                codePrefixFocus.hasFocus ||
                                                    codeSuffixFocus.hasFocus
                                                ? 1.7
                                                : 1.2,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: TextField(
                                                key: const Key(
                                                  'registration-code-prefix',
                                                ),
                                                controller: codePrefix,
                                                focusNode: codePrefixFocus,
                                                textCapitalization:
                                                    TextCapitalization
                                                        .characters,
                                                keyboardType: TextInputType
                                                    .visiblePassword,
                                                textInputAction:
                                                    TextInputAction.next,
                                                scrollPadding:
                                                    const EdgeInsets.only(
                                                      bottom: 100,
                                                    ),
                                                autocorrect: false,
                                                enableSuggestions: false,
                                                inputFormatters: const [
                                                  RegistrationCodePartFormatter(),
                                                ],
                                                maxLength: 4,
                                                textAlign: TextAlign.center,
                                                onChanged: (value) {
                                                  if (value.length == 4) {
                                                    codeSuffixFocus
                                                        .requestFocus();
                                                    codeSuffix.selection =
                                                        TextSelection.collapsed(
                                                          offset: codeSuffix
                                                              .text
                                                              .length,
                                                        );
                                                  }
                                                },
                                                onSubmitted: (_) =>
                                                    codeSuffixFocus
                                                        .requestFocus(),
                                                style: const TextStyle(
                                                  fontSize: 25,
                                                  fontWeight: FontWeight.w900,
                                                  letterSpacing: 3,
                                                ),
                                                decoration:
                                                    const InputDecoration(
                                                      hintText: 'XXXX',
                                                      counterText: '',
                                                      filled: false,
                                                      border: InputBorder.none,
                                                      enabledBorder:
                                                          InputBorder.none,
                                                      focusedBorder:
                                                          InputBorder.none,
                                                      contentPadding:
                                                          EdgeInsets.symmetric(
                                                            horizontal: 14,
                                                            vertical: 18,
                                                          ),
                                                    ),
                                              ),
                                            ),
                                            const Padding(
                                              padding: EdgeInsets.symmetric(
                                                horizontal: 10,
                                              ),
                                              child: Text(
                                                '-',
                                                style: TextStyle(
                                                  fontSize: 30,
                                                  fontWeight: FontWeight.w900,
                                                  color: AppColors.ink,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              child: TextField(
                                                key: const Key(
                                                  'registration-code-suffix',
                                                ),
                                                controller: codeSuffix,
                                                focusNode: codeSuffixFocus,
                                                textCapitalization:
                                                    TextCapitalization
                                                        .characters,
                                                keyboardType: TextInputType
                                                    .visiblePassword,
                                                textInputAction:
                                                    TextInputAction.done,
                                                scrollPadding:
                                                    const EdgeInsets.only(
                                                      bottom: 100,
                                                    ),
                                                autocorrect: false,
                                                enableSuggestions: false,
                                                inputFormatters: const [
                                                  RegistrationCodePartFormatter(),
                                                ],
                                                maxLength: 4,
                                                textAlign: TextAlign.center,
                                                onSubmitted: (_) => _register(),
                                                style: const TextStyle(
                                                  fontSize: 25,
                                                  fontWeight: FontWeight.w900,
                                                  letterSpacing: 3,
                                                ),
                                                decoration:
                                                    const InputDecoration(
                                                      hintText: 'XXXX',
                                                      counterText: '',
                                                      filled: false,
                                                      border: InputBorder.none,
                                                      enabledBorder:
                                                          InputBorder.none,
                                                      focusedBorder:
                                                          InputBorder.none,
                                                      contentPadding:
                                                          EdgeInsets.symmetric(
                                                            horizontal: 14,
                                                            vertical: 18,
                                                          ),
                                                    ),
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
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: widget.controller.busy
                          ? null
                          : tab == 0
                          ? () => _selectTab(1)
                          : _register,
                      child: Text(tab == 0 ? '직접 코드 입력하기' : '기기 연결하기'),
                    ),
                    if (MediaQuery.viewInsetsOf(context).bottom == 0) ...[
                      SizedBox(
                        height: 40,
                        child: TextButton(
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => InvitationInboxScreen(
                                controller: widget.controller,
                              ),
                            ),
                          ),
                          child: Text(
                            widget.controller.receivedInvitations.isEmpty
                                ? '받은 가족 초대 확인하기'
                                : '받은 가족 초대 ${widget.controller.receivedInvitations.length}개',
                          ),
                        ),
                      ),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 14,
                            color: AppColors.muted,
                          ),
                          SizedBox(width: 6),
                          Text(
                            '연결 정보는 암호화되어 안전하게 처리됩니다.',
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.muted,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(
                        height: 34,
                        child: TextButton(
                          key: const Key('device-registration-logout'),
                          style: TextButton.styleFrom(
                            foregroundColor: AppColors.danger,
                            padding: EdgeInsets.zero,
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          onPressed: widget.controller.busy
                              ? null
                              : _exitToLogin,
                          child: const Text(
                            '로그아웃',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
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

class _ScannerButton extends StatelessWidget {
  const _ScannerButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: const Color(0xA82D312B),
    shape: const CircleBorder(),
    child: IconButton(
      onPressed: onPressed,
      color: Colors.white,
      icon: Icon(icon),
    ),
  );
}

class _ScanFramePainter extends CustomPainter {
  const _ScanFramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.sageDark
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const length = 22.0;
    const inset = 18.0;
    canvas.drawLine(
      const Offset(inset, inset + length),
      const Offset(inset, inset),
      paint,
    );
    canvas.drawLine(
      const Offset(inset, inset),
      Offset(inset + length, inset),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - inset - length, inset),
      Offset(size.width - inset, inset),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - inset, inset),
      Offset(size.width - inset, inset + length),
      paint,
    );
    canvas.drawLine(
      Offset(inset, size.height - inset - length),
      Offset(inset, size.height - inset),
      paint,
    );
    canvas.drawLine(
      Offset(inset, size.height - inset),
      Offset(inset + length, size.height - inset),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - inset - length, size.height - inset),
      Offset(size.width - inset, size.height - inset),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - inset, size.height - inset),
      Offset(size.width - inset, size.height - inset - length),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
