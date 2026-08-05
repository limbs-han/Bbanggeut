/// 자막 시트에 끼우는 자동 자막 섹션.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import 'caption_line.dart';
import 'caption_controller.dart';
import 'transcript_store.dart';

const _captionCoral = AppColors.coral;
const _captionGreen = AppColors.sageDark;
const _captionBorder = AppColors.line;
const _captionSurface = AppColors.surface;

/// 미리보기가 쓸 한 줄. 미리보기 위젯에 넘길 값을 만든다.
String? autoCaptionAt(CaptionController controller, int positionMs) =>
    controller.textAt(positionMs);

class CaptionAutoSection extends StatefulWidget {
  const CaptionAutoSection({
    super.key,
    required this.controller,
    this.estimateSeconds,
    this.onChanged,
    this.onCancel,
    this.onDone,
  });

  final CaptionController controller;

  /// 전사가 도는 중일 때 보여줄 예상 시간. 모르면 null.
  final int? estimateSeconds;

  /// 사용자가 자막을 고쳤을 때. 화면이 "저장 안 된 변경"으로 표시한다.
  final VoidCallback? onChanged;

  /// 진행 화면을 닫는다. 전사는 기존처럼 백그라운드에서 계속된다.
  final VoidCallback? onCancel;

  /// 검토한 자막을 편집 타임라인에 적용하고 시트를 닫는다.
  final VoidCallback? onDone;

  @override
  State<CaptionAutoSection> createState() => _CaptionAutoSectionState();
}

class _CaptionAutoSectionState extends State<CaptionAutoSection> {
  final _field = TextEditingController();
  Timer? _progressTimer;
  DateTime? _progressStartedAt;
  int _estimatedPercent = 1;

  /// 남은 시간(초). 예상 시간에서 지난 만큼을 뺀 값이라 퍼센트와 같은 근거다.
  int _remainingSeconds = 0;

  bool get _isLoading => widget.controller.status is TranscriptRunning;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _syncProgressTimer();
  }

  void _onControllerChanged() {
    _syncProgressTimer();
    if (mounted) setState(() {});
  }

  void _syncProgressTimer() {
    if (!_isLoading) {
      _progressTimer?.cancel();
      _progressTimer = null;
      return;
    }
    if (_progressTimer != null) return;
    _progressStartedAt = DateTime.now();
    _estimatedPercent = 1;
    _remainingSeconds = widget.estimateSeconds ?? 0;
    _progressTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted || !_isLoading) {
        _progressTimer?.cancel();
        _progressTimer = null;
        return;
      }
      final expectedSeconds = math.max(10, widget.estimateSeconds ?? 60);
      final elapsedMs = DateTime.now()
          .difference(_progressStartedAt!)
          .inMilliseconds;
      final next = (1 + elapsedMs / (expectedSeconds * 1000) * 94)
          .floor()
          .clamp(1, 95);
      // 예상보다 오래 끌면 음수가 된다. 0에서 멈춰 두고 화면이 문구를 바꾼다.
      final remainingMs = math.max(0, expectedSeconds * 1000 - elapsedMs);
      final nextRemaining = (remainingMs / 1000).ceil();
      if (next == _estimatedPercent && nextRemaining == _remainingSeconds) {
        return;
      }
      setState(() {
        _estimatedPercent = next;
        _remainingSeconds = nextRemaining;
      });
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _progressTimer?.cancel();
    _field.dispose();
    super.dispose();
  }

  Future<void> _edit(int index) async {
    _field.text = widget.controller.lines[index].text;
    final line = widget.controller.lines[index];
    final text = await showDialog<String>(
      context: context,
      barrierColor: const Color(0x99000000),
      builder: (dialogContext) =>
          _CaptionEditDialog(index: index, line: line, controller: _field),
    );
    if (text == null || text.isEmpty) return;
    widget.controller.edit(index, text);
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int?>(
    valueListenable: mlkitDownloadPercent,
    builder: (_, downloadPercent, _) {
      final lines = widget.controller.lines;
      if (lines.isNotEmpty) return _readyContent(lines);
      if (_isLoading || downloadPercent != null) {
        return _loadingContent(downloadPercent);
      }
      return _emptyContent();
    },
  );

  Widget _loadingContent(int? downloadPercent) {
    final preparing = downloadPercent != null;
    final visiblePercent = (downloadPercent ?? _estimatedPercent).clamp(1, 99);
    final statusText = widget.controller.message(
      estimateSeconds: widget.estimateSeconds,
    );
    // 예상 시간을 아는 동안에는 줄어드는 숫자를 보여 준다. 고정된 "약 108초
    // 걸려요"는 아무리 기다려도 그대로라 멈춘 것처럼 읽힌다.
    final countdown = widget.estimateSeconds == null || _progressTimer == null
        ? null
        : (_remainingSeconds > 0 ? '약 $_remainingSeconds초 남았어요' : '거의 다 됐어요');
    return Column(
      key: const ValueKey('auto-caption-loading'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 20),
        const Text(
          '자동 자막을 만들고 있어요',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.ink,
            fontSize: 25,
            height: 1.2,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          preparing ? '자막 기능을 준비하는 중' : '영상 소리를 분석하는 중',
          style: const TextStyle(
            color: AppColors.inkSoft,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 18),
        const AnimatedCaptionWaveform(),
        const SizedBox(height: 20),
        Text(
          '자동 자막 생성 중 · $visiblePercent%',
          style: const TextStyle(
            color: AppColors.ink,
            fontSize: 17,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          countdown ?? statusText,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.muted, fontSize: 13),
        ),
        const SizedBox(height: 20),
        const Divider(color: _captionBorder, height: 1),
        const SizedBox(height: 16),
        _CaptionProgressSteps(preparing: preparing),
        const SizedBox(height: 18),
        const Text(
          '완료되면 자막 검토 화면으로 이동해요.',
          style: TextStyle(
            color: AppColors.inkSoft,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (widget.onCancel != null) ...[
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton(
              key: const ValueKey('auto-caption-cancel'),
              onPressed: widget.onCancel,
              style: OutlinedButton.styleFrom(
                foregroundColor: _captionCoral,
                side: const BorderSide(color: _captionCoral, width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: const Text(
                '자동 자막 취소',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _emptyContent() => Column(
    key: const ValueKey('auto-caption-empty'),
    children: [
      const SizedBox(height: 20),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
        decoration: BoxDecoration(
          color: AppColors.surfaceWarm,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _captionBorder),
        ),
        child: Column(
          children: [
            const Icon(
              Icons.graphic_eq_rounded,
              color: _captionGreen,
              size: 38,
            ),
            const SizedBox(height: 12),
            Text(
              widget.controller.message(
                estimateSeconds: widget.estimateSeconds,
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.inkSoft,
                fontSize: 14,
                height: 1.45,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
      if (widget.onCancel != null) ...[
        const SizedBox(height: 16),
        TextButton(
          key: const ValueKey('auto-caption-close'),
          onPressed: widget.onCancel,
          child: const Text('닫기'),
        ),
      ],
    ],
  );

  Widget _readyContent(List<CaptionLine> lines) => Column(
    key: const ValueKey('auto-caption-ready'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: const BoxDecoration(
              color: AppColors.sageSoft,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.graphic_eq_rounded,
              color: _captionGreen,
              size: 22,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '자동 자막이 준비됐어요',
                  style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  widget.controller.message(
                    estimateSeconds: widget.estimateSeconds,
                  ),
                  style: const TextStyle(color: AppColors.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      SizedBox(
        height: 210,
        child: ListView.separated(
          itemCount: lines.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (_, index) => Material(
            color: _captionSurface,
            shape: RoundedRectangleBorder(
              side: const BorderSide(color: _captionBorder),
              borderRadius: BorderRadius.circular(14),
            ),
            child: InkWell(
              key: ValueKey('auto-caption-row-$index'),
              onTap: () => _edit(index),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.sageSoft,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _clock(lines[index].startMs),
                        style: const TextStyle(
                          color: _captionGreen,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        lines[index].text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.ink,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.edit_outlined,
                      color: AppColors.muted,
                      size: 18,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      if (widget.onDone != null || widget.onCancel != null) ...[
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton(
            key: const ValueKey('auto-caption-done'),
            onPressed: widget.onDone ?? widget.onCancel,
            style: FilledButton.styleFrom(
              backgroundColor: _captionCoral,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: const Text(
              '자막 검토 완료',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
    ],
  );

  String _clock(int milliseconds) {
    final value = Duration(milliseconds: milliseconds);
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _CaptionEditDialog extends StatefulWidget {
  const _CaptionEditDialog({
    required this.index,
    required this.line,
    required this.controller,
  });

  final int index;
  final CaptionLine line;
  final TextEditingController controller;

  @override
  State<_CaptionEditDialog> createState() => _CaptionEditDialogState();
}

class _CaptionEditDialogState extends State<_CaptionEditDialog> {
  String _clock(int milliseconds) {
    final value = Duration(milliseconds: milliseconds);
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  void _submit() {
    final text = widget.controller.text.trim();
    if (text.isEmpty) return;
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableHeight = math.max(
      280.0,
      media.size.height - media.viewInsets.bottom - 24,
    );
    return Dialog(
      key: const ValueKey('auto-caption-edit-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      elevation: 0,
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 370, maxHeight: availableHeight),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _captionSurface,
            borderRadius: BorderRadius.circular(28),
            boxShadow: const [
              BoxShadow(
                color: Color(0x260D0905),
                blurRadius: 30,
                offset: Offset(0, 14),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: const BoxDecoration(
                        color: AppColors.sageSoft,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.graphic_eq_rounded,
                        color: _captionGreen,
                        size: 23,
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        key: const ValueKey('auto-caption-edit-close'),
                        tooltip: '닫기',
                        onPressed: () => Navigator.pop(context),
                        icon: const Icon(Icons.close_rounded, size: 24),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                Text(
                  '${widget.index + 1}번째 자막 수정',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.ink,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -0.7,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  '문장을 확인하고 필요한 부분을 고쳐 주세요.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.inkSoft,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 9),
                Row(
                  children: [
                    const Text(
                      '자막 내용',
                      style: TextStyle(
                        color: AppColors.ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.sageSoft,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        _clock(widget.line.startMs),
                        style: const TextStyle(
                          color: _captionGreen,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                TextField(
                  key: const ValueKey('auto-caption-field'),
                  controller: widget.controller,
                  autofocus: true,
                  maxLength: 40,
                  minLines: 1,
                  maxLines: 2,
                  textInputAction: TextInputAction.done,
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    hintText: '들린 그대로 적어 주세요',
                    counterStyle: TextStyle(
                      color: AppColors.muted,
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceWarm,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _captionBorder),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        color: AppColors.muted,
                        size: 17,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '수정한 내용은 바로 미리보기에 반영돼요.',
                          style: TextStyle(
                            color: AppColors.inkSoft,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 9),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          foregroundColor: _captionCoral,
                          side: const BorderSide(
                            color: _captionCoral,
                            width: 1.4,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text('취소'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: FilledButton(
                        key: const ValueKey('auto-caption-edit-submit'),
                        onPressed: widget.controller.text.trim().isEmpty
                            ? null
                            : _submit,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          backgroundColor: _captionCoral,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: const Text(
                          '수정 완료',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 자동 자막 로딩 화면에서 재사용하는 음성 파형과 네 개의 반짝임.
///
/// 하나의 컨트롤러만 사용하고 [CustomPainter]의 repaint에 직접 연결한다.
/// 따라서 매 틱마다 로딩 바텀시트를 다시 빌드하지 않고 이 영역만 다시 그린다.
///
/// 막대 높이 위에 **왼쪽에서 오른쪽으로 훑는 빛**을 한 겹 얹는다. 높이만
/// 흔들면 조금 떨어져서 볼 때 정지한 그림과 구분이 안 된다.
class AnimatedCaptionWaveform extends StatefulWidget {
  const AnimatedCaptionWaveform({super.key, this.animate = true});

  final bool animate;

  @override
  State<AnimatedCaptionWaveform> createState() =>
      _AnimatedCaptionWaveformState();

  /// 테스트에서도 제품과 같은 높이 공식을 확인할 수 있게 한 막대 하나의 높이.
  @visibleForTesting
  static double debugBarHeight(int index, double waveProgress) =>
      _captionBarHeight(index, waveProgress);
}

class _AnimatedCaptionWaveformState extends State<AnimatedCaptionWaveform>
    with SingleTickerProviderStateMixin {
  static const _waveDuration = Duration(milliseconds: 720);

  late final AnimationController _controller;
  late final _CaptionWavePaintResources _paintResources;

  /// 기기에서 애니메이션을 줄여 달라고 했는가. 움직임을 **끄지는 않고**
  /// 폭만 줄인다 — 아래 [didChangeDependencies] 참조.
  bool _calm = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _waveDuration);
    _paintResources = _CaptionWavePaintResources();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // **애니메이션 감소 설정이어도 멈추지 않는다.** 예전에는 여기서 파형을
    // 정지시켰는데, 개발자 옵션으로 애니메이터 배율을 꺼 둔 기기에서 로딩
    // 화면이 통째로 굳어 "앱이 멎었다"로 읽혔다. 진행 표시는 기다리라는
    // 말을 하는 그림이라 이 설정에서 빠진다 — Flutter의 진행 표시기도
    // 같은 이유로 따르지 않는다. 대신 흔들림 폭을 줄여 잔잔하게 돈다.
    _calm = MediaQuery.disableAnimationsOf(context);
    _syncAnimation();
  }

  @override
  void didUpdateWidget(AnimatedCaptionWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animate != widget.animate) _syncAnimation();
  }

  /// 화면 밖으로 밀린 동안 헛돌지 않게 하는 일은 [SingleTickerProviderStateMixin]이
  /// [TickerMode]를 보고 알아서 한다 — 여기서는 껐다 켜는 것만 본다.
  void _syncAnimation() {
    if (widget.animate) {
      if (!_controller.isAnimating) _controller.repeat();
      return;
    }
    _controller
      ..stop()
      ..value = 0;
  }

  @override
  void dispose() {
    _controller
      ..stop()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: SizedBox(
      key: const ValueKey('auto-caption-wave'),
      height: 106,
      width: double.infinity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Stack(
            children: [
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, _) => CustomPaint(
                    key: const ValueKey('auto-caption-wave-paint'),
                    painter: _CaptionWaveformPainter(
                      elapsedMs: widget.animate
                          ? (_controller.lastElapsedDuration?.inMicroseconds
                                        .toDouble() ??
                                    0) /
                                1000
                          : 0,
                      frozen: !widget.animate,
                      calm: _calm,
                      resources: _paintResources,
                    ),
                    willChange: widget.animate,
                  ),
                ),
              ),
              for (final sparkle in _captionSparkles)
                Positioned(
                  key: ValueKey('auto-caption-sparkle-${sparkle.id}'),
                  left: width * sparkle.x - sparkle.size / 2,
                  top: 106 * sparkle.y - sparkle.size / 2,
                  child: SizedBox.square(dimension: sparkle.size),
                ),
            ],
          );
        },
      ),
    ),
  );
}

const _captionBarCount = 24;
const _captionBarWidth = 4.0;
const _captionBarGap = 5.5;
const _captionWavePeriodMs = 720.0;
const _twoPi = math.pi * 2;

/// 훑고 지나가는 빛의 한 바퀴와 그 폭(dp). 파형 주기(720ms)의 배수가 아닌
/// 값이라 둘이 겹쳐 같은 모양이 반복되는 것처럼 보이지 않는다.
const _captionSweepPeriodMs = 1150.0;
const _captionSweepWidth = 84.0;

double _captionBarHeight(int index, double waveProgress) {
  final distance =
      ((index - (_captionBarCount - 1) / 2).abs() /
              ((_captionBarCount - 1) / 2))
          .clamp(0.0, 1.0);
  final envelope = 1 - math.pow(distance, 1.45) * 0.42;
  final primary = math.sin(_twoPi * waveProgress + index * 0.72);
  final secondary = math.sin(_twoPi * waveProgress * 2 + index * 1.31);
  final tertiary = math.sin(_twoPi * waveProgress * 3 - index * 0.43);
  final mixed = ((primary * 0.56 + secondary * 0.29 + tertiary * 0.15) + 1) / 2;
  final normalized = mixed.clamp(0.0, 1.0).toDouble();
  final eased = 0.5 - math.cos(math.pi * normalized) / 2;
  return (8 + envelope * (12 + 28 * (0.2 + eased * 0.8))).clamp(8.0, 48.0);
}

class _CaptionWaveformPainter extends CustomPainter {
  _CaptionWaveformPainter({
    required this.elapsedMs,
    required this.frozen,
    required this.calm,
    required this.resources,
  });

  final double elapsedMs;

  /// 아예 세워 둘 것인가. 호출부가 `animate: false`를 준 때만이다.
  final bool frozen;

  /// 흔들림 폭을 줄일 것인가. 기기의 애니메이션 감소 설정이다 — 움직임을
  /// 없애지는 않는다.
  final bool calm;

  final _CaptionWavePaintResources resources;

  @override
  void paint(Canvas canvas, Size size) {
    final frameElapsedMs = frozen ? 0.0 : elapsedMs;
    final waveProgress =
        (frameElapsedMs % _captionWavePeriodMs) / _captionWavePeriodMs;
    const waveformWidth =
        _captionBarCount * _captionBarWidth +
        (_captionBarCount - 1) * _captionBarGap;
    final startX = (size.width - waveformWidth) / 2 + _captionBarWidth / 2;
    final centerY = size.height / 2;
    // 빛은 파형 왼쪽 밖에서 들어와 오른쪽 밖으로 빠진다.
    final sweepX =
        startX -
        _captionSweepWidth +
        (frameElapsedMs % _captionSweepPeriodMs) /
            _captionSweepPeriodMs *
            (waveformWidth + _captionSweepWidth * 2);

    for (var index = 0; index < _captionBarCount; index++) {
      final height = frozen
          ? _captionBarHeight(index, 0.16)
          : _captionBarHeight(index, waveProgress);
      final x = startX + index * (_captionBarWidth + _captionBarGap);
      final glow = _glowAt(x, sweepX);
      resources.barPaint.color = glow == 0
          ? _captionGreen
          : Color.lerp(_captionGreen, AppColors.sage, glow)!;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(x, centerY),
            // 빛이 지나가는 자리는 살짝 더 솟는다.
            width: _captionBarWidth,
            height: _calmed(height) + glow * 5,
          ),
          const Radius.circular(99),
        ),
        resources.barPaint,
      );
    }

    for (final sparkle in _captionSparkles) {
      _paintSparkle(canvas, size, sparkle, frameElapsedMs);
    }
  }

  /// 흔들림 폭을 가운데 높이 쪽으로 당긴다. 파형인 것은 그대로 보이되
  /// 출렁임이 얌전해진다.
  double _calmed(double height) => calm ? 24 + (height - 24) * 0.5 : height;

  /// [x]에 놓인 막대가 빛을 얼마나 받는가(0~1). 가장자리로 갈수록 제곱으로
  /// 약해져서 띠의 경계가 눈에 띄지 않는다.
  double _glowAt(double x, double sweepX) {
    if (frozen) return 0;
    final distance = (x - sweepX).abs();
    if (distance >= _captionSweepWidth) return 0;
    final falloff = 1 - distance / _captionSweepWidth;
    return falloff * falloff * (calm ? 0.5 : 1);
  }

  void _paintSparkle(
    Canvas canvas,
    Size size,
    _CaptionSparkleSpec sparkle,
    double elapsedMs,
  ) {
    final progress =
        ((elapsedMs + sparkle.delayMs) % sparkle.periodMs) / sparkle.periodMs;
    final triangle = progress < 0.5 ? progress * 2 : (1 - progress) * 2;
    // 제곱으로 눌러 밝은 구간을 짧게 만든다. 고르게 오르내리면 '숨쉬기'로
    // 보이고, 이렇게 해야 '반짝'으로 읽힌다.
    final pulse = math
        .pow(0.5 - math.cos(math.pi * triangle) / 2, 1.8)
        .toDouble();
    // 감소 설정에서도 밝기는 오간다 — 크기와 기울기만 붙잡아 둔다.
    final scale = frozen || calm ? 0.85 : 0.55 + pulse * 0.75;
    final opacity = frozen
        ? 0.55
        : (calm ? 0.35 + pulse * 0.4 : 0.12 + pulse * 0.88);
    final rotation = frozen || calm ? 0.0 : (pulse - 0.5) * 0.35;

    resources.sparklePaint.color = sparkle.color.withValues(alpha: opacity);
    canvas
      ..save()
      ..translate(size.width * sparkle.x, size.height * sparkle.y)
      ..rotate(rotation)
      ..scale(sparkle.size * scale)
      ..drawPath(resources.unitSparkle, resources.sparklePaint)
      ..restore();
  }

  @override
  bool shouldRepaint(_CaptionWaveformPainter oldDelegate) =>
      oldDelegate.elapsedMs != elapsedMs ||
      oldDelegate.frozen != frozen ||
      oldDelegate.calm != calm;
}

class _CaptionWavePaintResources {
  _CaptionWavePaintResources()
    : barPaint = (Paint()
        ..color = _captionGreen
        ..style = PaintingStyle.fill
        ..isAntiAlias = true),
      sparklePaint = (Paint()
        ..style = PaintingStyle.fill
        ..isAntiAlias = true),
      unitSparkle = (Path()
        ..moveTo(0, -0.5)
        ..lineTo(0.12, -0.12)
        ..lineTo(0.5, 0)
        ..lineTo(0.12, 0.12)
        ..lineTo(0, 0.5)
        ..lineTo(-0.12, 0.12)
        ..lineTo(-0.5, 0)
        ..lineTo(-0.12, -0.12)
        ..close());

  final Paint barPaint;
  final Paint sparklePaint;
  final Path unitSparkle;
}

class _CaptionSparkleSpec {
  const _CaptionSparkleSpec({
    required this.id,
    required this.x,
    required this.y,
    required this.size,
    required this.color,
    required this.periodMs,
    required this.delayMs,
  });

  final String id;
  final double x;
  final double y;
  final double size;
  final Color color;
  final double periodMs;
  final double delayMs;
}

/// 반짝이는 자리를 고정으로 둔다. 무작위로 흩뿌리면 뜰 때마다 그림이 달라져
/// 화면이 안정돼 보이지 않는다.
///
/// 자리는 **막대가 닿지 않는 곳**만 고른다. 막대는 가운데 222dp 폭에 최대
/// 53dp 높이로 서므로, 세로로는 y<0.2·y>0.8, 가로로는 x<0.16·x>0.84가
/// 비어 있다. 주기는 서로 나누어떨어지지 않게 흩어 두어야 여럿이 한꺼번에
/// 켜졌다 꺼지지 않는다.
const _captionSparkles = <_CaptionSparkleSpec>[
  _CaptionSparkleSpec(
    id: 'coral-top-left',
    x: 0.12,
    y: 0.18,
    size: 13,
    color: _captionCoral,
    periodMs: 620,
    delayMs: 0,
  ),
  _CaptionSparkleSpec(
    id: 'olive-top-right',
    x: 0.88,
    y: 0.20,
    size: 10,
    color: _captionGreen,
    periodMs: 680,
    delayMs: 150,
  ),
  _CaptionSparkleSpec(
    id: 'olive-bottom-left',
    x: 0.17,
    y: 0.82,
    size: 9,
    color: _captionGreen,
    periodMs: 770,
    delayMs: 330,
  ),
  _CaptionSparkleSpec(
    id: 'coral-bottom-right',
    x: 0.84,
    y: 0.80,
    size: 15,
    color: _captionCoral,
    periodMs: 850,
    delayMs: 470,
  ),
  _CaptionSparkleSpec(
    id: 'coral-mid-left',
    x: 0.05,
    y: 0.52,
    size: 8,
    color: _captionCoral,
    periodMs: 590,
    delayMs: 240,
  ),
  _CaptionSparkleSpec(
    id: 'olive-mid-right',
    x: 0.96,
    y: 0.48,
    size: 7,
    color: _captionGreen,
    periodMs: 710,
    delayMs: 620,
  ),
  _CaptionSparkleSpec(
    id: 'olive-top-center',
    x: 0.52,
    y: 0.07,
    size: 8,
    color: _captionGreen,
    periodMs: 930,
    delayMs: 80,
  ),
  _CaptionSparkleSpec(
    id: 'coral-bottom-center',
    x: 0.44,
    y: 0.92,
    size: 11,
    color: _captionCoral,
    periodMs: 1010,
    delayMs: 560,
  ),
];

class _CaptionProgressSteps extends StatelessWidget {
  const _CaptionProgressSteps({required this.preparing});

  final bool preparing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _CaptionStep(
        icon: preparing ? Icons.downloading_rounded : Icons.check_rounded,
        label: '소리 불러오기',
        color: _captionGreen,
        active: preparing,
        completed: !preparing,
      ),
      const Expanded(
        child: Divider(color: _captionBorder, indent: 8, endIndent: 8),
      ),
      _CaptionStep(
        icon: preparing ? Icons.circle_outlined : Icons.circle,
        label: '대사 인식',
        color: preparing ? const Color(0xFFA79D94) : _captionCoral,
        active: !preparing,
      ),
      const Expanded(
        child: Divider(color: _captionBorder, indent: 8, endIndent: 8),
      ),
      const _CaptionStep(
        icon: Icons.circle_outlined,
        label: '자막 정리',
        color: Color(0xFFA79D94),
        active: false,
      ),
    ],
  );
}

class _CaptionStep extends StatelessWidget {
  const _CaptionStep({
    required this.icon,
    required this.label,
    required this.color,
    required this.active,
    this.completed = false,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool active;
  final bool completed;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: completed ? color : _captionSurface,
          shape: BoxShape.circle,
          border: Border.all(color: color, width: 1.5),
        ),
        child: Icon(icon, color: completed ? Colors.white : color, size: 18),
      ),
      const SizedBox(height: 7),
      Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: active || completed ? FontWeight.w800 : FontWeight.w700,
        ),
      ),
    ],
  );
}
