import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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
  final scanner = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
    autoZoom: true,
  );
  int tab = 0;
  bool handlingScan = false;

  @override
  void dispose() {
    code.dispose();
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
    final normalized = _normalizedCode(scannedValue ?? code.text) ?? '';
    if (normalized.length != 8) {
      showAppSnack(context, '기기 화면에 표시된 8자리 코드를 입력해 주세요.', error: true);
      return;
    }
    final formatted =
        '${normalized.substring(0, 4)}-${normalized.substring(4)}';
    code.text = formatted;
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
    setState(() => tab = value);
    if (value == 0) {
      await scanner.start();
    } else {
      await scanner.stop();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    resizeToAvoidBottomInset: false,
    body: AppBackdrop(
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: 58,
              child: Row(
                children: [
                  const SizedBox(width: 16),
                  if (widget.canGoBack)
                    RoundIconButton(
                      icon: Icons.chevron_left_rounded,
                      size: 44,
                      onPressed: () => Navigator.pop(context),
                    )
                  else
                    const SizedBox(width: 44),
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
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                                  const SizedBox(height: 7),
                                  const StatusPill(
                                    label: 'QR 코드를 자동으로 인식해요',
                                    color: AppColors.greenCard,
                                  ),
                                ],
                              ),
                            )
                          : SoftCard(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Text(
                                    '8자리 등록 코드',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  TextField(
                                    controller: code,
                                    autofocus: true,
                                    textCapitalization:
                                        TextCapitalization.characters,
                                    keyboardType: TextInputType.visiblePassword,
                                    inputFormatters: const [
                                      RegistrationCodeFormatter(),
                                    ],
                                    maxLength: 9,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      fontSize: 25,
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 3,
                                    ),
                                    decoration: const InputDecoration(
                                      hintText: 'XXXX-XXXX',
                                      counterText: '',
                                    ),
                                  ),
                                ],
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
                    SizedBox(
                      height: 40,
                      child: TextButton(
                        onPressed: _joinWithInvite,
                        child: const Text('제품 코드로 가족 연결하기'),
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
                  ],
                ),
              ),
            ),
          ],
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
          decoration: const InputDecoration(labelText: '초대 링크 또는 토큰'),
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
    if (token == null || token.isEmpty) return;
    final parsed = Uri.tryParse(token);
    final inviteToken = parsed?.queryParameters['token'] ?? token;
    try {
      await widget.controller.api.createJoinRequest(inviteToken);
      if (mounted) showAppSnack(context, '가입 요청을 보냈어요. 소유자의 승인을 기다려 주세요.');
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
    }
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
