import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import 'editor_project.dart';
import 'editor_text_style_bar.dart';

enum EditorTextScreenPosition { top, center, bottom }

extension EditorTextScreenPositionValue on EditorTextScreenPosition {
  NormalizedPoint get point => switch (this) {
    EditorTextScreenPosition.top => NormalizedPoint(0.5, 0.22),
    EditorTextScreenPosition.center => NormalizedPoint.center,
    EditorTextScreenPosition.bottom => NormalizedPoint(0.5, 0.78),
  };

  String get label => switch (this) {
    EditorTextScreenPosition.top => '상단',
    EditorTextScreenPosition.center => '가운데',
    EditorTextScreenPosition.bottom => '하단',
  };
}

class EditorDirectTextResult {
  const EditorDirectTextResult({
    required this.text,
    required this.position,
    required this.startMs,
    required this.endMs,
    required this.style,
  });

  final String text;
  final EditorTextScreenPosition position;
  final int startMs;
  final int endMs;
  final EditorTextDraft style;
}

Future<EditorDirectTextResult?> showEditorDirectTextSheet(
  BuildContext context, {
  required int startMs,
  required int maxEndMs,
  required Color initialColor,
}) => showModalBottomSheet<EditorDirectTextResult>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  builder: (_) => EditorDirectTextSheet(
    startMs: startMs,
    maxEndMs: maxEndMs,
    initialColor: initialColor,
  ),
);

class EditorDirectTextSheet extends StatefulWidget {
  const EditorDirectTextSheet({
    super.key,
    required this.startMs,
    required this.maxEndMs,
    required this.initialColor,
  });

  final int startMs;
  final int maxEndMs;
  final Color initialColor;

  @override
  State<EditorDirectTextSheet> createState() => _EditorDirectTextSheetState();
}

class _EditorDirectTextSheetState extends State<EditorDirectTextSheet> {
  static const _colors = <Color>[
    Color(0xFFFFFFFF),
    Color(0xFFFFF2B5),
    AppColors.coral,
    AppColors.sageDark,
    Color(0xFF24211F),
  ];
  static const _fontSizes = <double>[48, 64, 80];
  static const _durations = <int>[3, 5, 8];

  final _textController = TextEditingController();
  late EditorTextDraft _style;
  EditorTextScreenPosition _position = EditorTextScreenPosition.bottom;
  int _durationSeconds = 3;

  int get _safeStartMs {
    final latestStart = (widget.maxEndMs - 500).clamp(0, widget.maxEndMs);
    return widget.startMs.clamp(0, latestStart);
  }

  int get _endMs => (_safeStartMs + _durationSeconds * 1000).clamp(
    _safeStartMs + 500,
    widget.maxEndMs,
  );

  @override
  void initState() {
    super.initState();
    _style = EditorTextDraft(color: widget.initialColor);
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  String _time(int milliseconds) {
    final seconds = milliseconds ~/ 1000;
    final minutes = seconds ~/ 60;
    return '${minutes.toString().padLeft(2, '0')}:'
        '${(seconds % 60).toString().padLeft(2, '0')}';
  }

  void _submit() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;
    Navigator.of(context).pop(
      EditorDirectTextResult(
        text: text,
        position: _position,
        startMs: _safeStartMs,
        endMs: _endMs,
        style: _style,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(22, 10, 22, 18 + keyboard),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 5,
                decoration: BoxDecoration(
                  color: AppColors.line,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '직접 텍스트 추가',
                        style: TextStyle(
                          color: AppColors.ink,
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.7,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '영상에 원하는 문구를 직접 넣어 보세요',
                        style: TextStyle(
                          color: AppColors.muted,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('editor-direct-text-close'),
                  tooltip: '닫기',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, size: 28),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: AppColors.pinkSoft,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.open_with_rounded,
                    color: AppColors.inkSoft,
                    size: 21,
                  ),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '추가한 뒤 영상 미리보기에서 크기와 위치를 더 조절할 수 있어요',
                      style: TextStyle(
                        color: AppColors.inkSoft,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const _SectionLabel('텍스트 내용'),
            const SizedBox(height: 7),
            TextField(
              key: const Key('editor-direct-text-input'),
              controller: _textController,
              autofocus: false,
              maxLength: 40,
              minLines: 2,
              maxLines: 3,
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                hintText: '자막 문구를 입력해 주세요',
                counterStyle: TextStyle(color: AppColors.muted, fontSize: 11),
              ),
            ),
            const SizedBox(height: 12),
            const _SectionLabel('화면 위치'),
            const SizedBox(height: 7),
            Row(
              children: [
                for (final position in EditorTextScreenPosition.values) ...[
                  if (position != EditorTextScreenPosition.top)
                    const SizedBox(width: 8),
                  Expanded(
                    child: _PositionButton(
                      position: position,
                      selected: _position == position,
                      onTap: () => setState(() => _position = position),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),
            const _SectionLabel('표시 시간'),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(child: _TimeBox(value: _time(_safeStartMs))),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 9),
                  child: Text('–', style: TextStyle(color: AppColors.muted)),
                ),
                Expanded(child: _TimeBox(value: _time(_endMs))),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                for (final seconds in _durations) ...[
                  if (seconds != _durations.first) const SizedBox(width: 7),
                  Expanded(
                    child: ChoiceChip(
                      key: Key('editor-direct-duration-$seconds'),
                      label: Text('$seconds초'),
                      selected: _durationSeconds == seconds,
                      onSelected: (_) =>
                          setState(() => _durationSeconds = seconds),
                      selectedColor: AppColors.sageSoft,
                      side: BorderSide(
                        color: _durationSeconds == seconds
                            ? AppColors.sageDark
                            : AppColors.line,
                      ),
                      showCheckmark: false,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 14),
            const _SectionLabel('빠른 설정'),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(
                  child: PopupMenuButton<double>(
                    tooltip: '글자 크기',
                    initialValue: _style.fontSize,
                    onSelected: (size) => setState(
                      () => _style = _style.copyWith(fontSize: size),
                    ),
                    itemBuilder: (_) => [
                      for (final size in _fontSizes)
                        PopupMenuItem(
                          value: size,
                          child: Text('${size.toInt()} pt'),
                        ),
                    ],
                    child: _QuickSetting(
                      icon: Icons.text_fields_rounded,
                      label: '글꼴',
                      active: _fontSizes.contains(_style.fontSize),
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: _QuickSetting(
                    key: const Key('editor-direct-bold'),
                    icon: Icons.format_bold_rounded,
                    label: '굵기',
                    active: _style.bold,
                    onTap: () => setState(
                      () => _style = _style.copyWith(bold: !_style.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: PopupMenuButton<Color>(
                    tooltip: '글자 색상',
                    initialValue: _style.color,
                    onSelected: (color) =>
                        setState(() => _style = _style.copyWith(color: color)),
                    itemBuilder: (_) => [
                      for (final color in _colors)
                        PopupMenuItem(
                          value: color,
                          child: Row(
                            children: [
                              _ColorDot(color: color),
                              const SizedBox(width: 10),
                              const Text('색상 선택'),
                            ],
                          ),
                        ),
                    ],
                    child: _QuickSetting(
                      icon: Icons.palette_outlined,
                      label: '색상',
                      swatch: _style.color,
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: _QuickSetting(
                    key: const Key('editor-direct-background'),
                    icon: Icons.texture_rounded,
                    label: '배경',
                    active: _style.hasBackground,
                    onTap: () => setState(
                      () => _style = _style.copyWith(
                        backgroundColor: _style.hasBackground
                            ? Colors.transparent
                            : editorTextBoxColorFor(_style.color),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                SizedBox(
                  width: 92,
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('취소'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    key: const Key('editor-direct-text-submit'),
                    onPressed: _textController.text.trim().isEmpty
                        ? null
                        : _submit,
                    child: const Text('텍스트 추가'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(
      color: AppColors.ink,
      fontSize: 13,
      fontWeight: FontWeight.w900,
    ),
  );
}

class _PositionButton extends StatelessWidget {
  const _PositionButton({
    required this.position,
    required this.selected,
    required this.onTap,
  });

  final EditorTextScreenPosition position;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    key: Key('editor-direct-position-${position.name}'),
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(44),
      padding: EdgeInsets.zero,
      foregroundColor: selected ? AppColors.coralDark : AppColors.inkSoft,
      backgroundColor: selected ? AppColors.coralSoft : AppColors.surface,
      side: BorderSide(color: selected ? AppColors.coral : AppColors.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
    ),
    child: Text(position.label),
  );
}

class _TimeBox extends StatelessWidget {
  const _TimeBox({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) => Container(
    height: 42,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      border: Border.all(color: AppColors.line),
      borderRadius: BorderRadius.circular(13),
    ),
    child: Text(
      value,
      style: const TextStyle(
        color: AppColors.inkSoft,
        fontSize: 14,
        fontWeight: FontWeight.w700,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    ),
  );
}

class _QuickSetting extends StatelessWidget {
  const _QuickSetting({
    super.key,
    required this.icon,
    required this.label,
    this.active = false,
    this.onTap,
    this.swatch,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback? onTap;
  final Color? swatch;

  @override
  Widget build(BuildContext context) => Material(
    color: active ? AppColors.coralSoft : AppColors.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(13),
      side: BorderSide(color: active ? AppColors.coral : AppColors.line),
    ),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(13),
      child: SizedBox(
        height: 62,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            swatch == null
                ? Icon(icon, color: AppColors.inkSoft, size: 23)
                : _ColorDot(color: swatch!),
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(
                color: AppColors.inkSoft,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 22,
    height: 22,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: Border.all(color: AppColors.line),
    ),
  );
}
