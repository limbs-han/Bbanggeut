/// 영상 위 글자를 꾸미는 줄. 키보드 바로 위에 뜬다.
///
/// **왜 입력칸이 없나**: 예전에는 화면 한가운데에 커다란 입력 상자를 띄우고
/// 거기에 글을 썼다. 상자가 영상을 가려서, 정작 그 글이 영상 위에서 어떻게
/// 보이는지는 상자를 닫아 봐야 알 수 있었다. 이제 글은 **영상 위 제자리에서**
/// 직접 쓴다(`local_edit_screen.dart`의 편집 중 레이어). 이 줄은 색·크기·
/// 정렬·배경·굵기만 맡는다.
///
/// 고를 수 있는 것은 전부 내보내기(EditorLayerOverlay.kt)가 그대로 재현할 수
/// 있는 것들뿐이다 — 미리보기에서 본 모습이 저장된 영상에서도 같아야 한다.
library;

import 'package:flutter/material.dart';

import 'editor_project.dart';
import 'editor_tokens.dart';

/// 글자 한 벌의 꾸밈. 그대로 [EditorTextLayer]에 넣는다.
class EditorTextDraft {
  const EditorTextDraft({
    this.color = const Color(0xFFFFFFFF),
    this.backgroundColor = const Color(0x00000000),
    this.fontSize = 64,
    this.bold = true,
    this.italic = false,
    this.align = EditorTextAlign.center,
  });

  final Color color;
  final Color backgroundColor;
  final double fontSize;
  final bool bold;
  final bool italic;
  final EditorTextAlign align;

  bool get hasBackground => backgroundColor.a > 0;

  EditorTextDraft copyWith({
    Color? color,
    Color? backgroundColor,
    double? fontSize,
    bool? bold,
    bool? italic,
    EditorTextAlign? align,
  }) => EditorTextDraft(
    color: color ?? this.color,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    fontSize: (fontSize ?? this.fontSize).clamp(24.0, 144.0),
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    align: align ?? this.align,
  );

  static EditorTextDraft fromLayer(EditorTextLayer layer) => EditorTextDraft(
    color: layer.color,
    backgroundColor: layer.backgroundColor,
    fontSize: layer.fontSize,
    bold: layer.bold,
    italic: layer.italic,
    align: layer.align,
  );

  TextAlign get textAlign => switch (align) {
    EditorTextAlign.left => TextAlign.left,
    EditorTextAlign.center => TextAlign.center,
    EditorTextAlign.right => TextAlign.right,
  };
}

/// 상자 색. 밝은 글자에는 어두운 상자를, 어두운 글자에는 밝은 상자를 깐다.
Color editorTextBoxColorFor(Color textColor) =>
    textColor.computeLuminance() > 0.5
    ? const Color(0xE61B1B1B)
    : const Color(0xF2FFFFFF);

class _TextStylePreset {
  const _TextStylePreset({
    required this.id,
    required this.bold,
    required this.italic,
    this.boxed = false,
  });

  final String id;
  final bool bold;
  final bool italic;

  /// 글자 뒤에 색 상자를 깐다. 상자 색은 지금 고른 글자색을 따라간다.
  final bool boxed;

  static const all = <_TextStylePreset>[
    _TextStylePreset(id: 'regular', bold: false, italic: false),
    _TextStylePreset(id: 'bold', bold: true, italic: false),
    _TextStylePreset(id: 'boxed', bold: true, italic: false, boxed: true),
    _TextStylePreset(id: 'italic', bold: false, italic: true),
    _TextStylePreset(id: 'bolditalic', bold: true, italic: true),
    _TextStylePreset(id: 'boxedlight', bold: false, italic: false, boxed: true),
  ];

  static String match(EditorTextDraft draft) {
    if (draft.hasBackground) return draft.bold ? 'boxed' : 'boxedlight';
    if (draft.bold && draft.italic) return 'bolditalic';
    if (draft.italic) return 'italic';
    if (draft.bold) return 'bold';
    return 'regular';
  }
}

const _paletteColors = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFF1B1B1B),
  Color(0xFFFF725B),
  Color(0xFFFFC83D),
  Color(0xFFA7B96B),
  Color(0xFF4FA3E3),
  Color(0xFFB07CE8),
  Color(0xFFFF8FB1),
];

enum _StylePanel { style, size, color }

class EditorTextStyleBar extends StatefulWidget {
  const EditorTextStyleBar({
    super.key,
    required this.draft,
    required this.onChanged,
    required this.onDone,
  });

  final EditorTextDraft draft;
  final ValueChanged<EditorTextDraft> onChanged;
  final VoidCallback onDone;

  @override
  State<EditorTextStyleBar> createState() => _EditorTextStyleBarState();
}

class _EditorTextStyleBarState extends State<EditorTextStyleBar> {
  _StylePanel _panel = _StylePanel.style;

  void _apply(EditorTextDraft next) => widget.onChanged(next);

  void _applyPreset(_TextStylePreset preset) => _apply(
    widget.draft.copyWith(
      bold: preset.bold,
      italic: preset.italic,
      backgroundColor: preset.boxed
          ? editorTextBoxColorFor(widget.draft.color)
          : const Color(0x00000000),
    ),
  );

  void _pickColor(Color color) => _apply(
    widget.draft.copyWith(
      color: color,
      backgroundColor: widget.draft.hasBackground
          ? editorTextBoxColorFor(color)
          : const Color(0x00000000),
    ),
  );

  void _cycleAlign() => _apply(
    widget.draft.copyWith(
      align: switch (widget.draft.align) {
        EditorTextAlign.center => EditorTextAlign.left,
        EditorTextAlign.left => EditorTextAlign.right,
        EditorTextAlign.right => EditorTextAlign.center,
      },
    ),
  );

  void _toggleBackground() => _apply(
    widget.draft.copyWith(
      backgroundColor: widget.draft.hasBackground
          ? const Color(0x00000000)
          : editorTextBoxColorFor(widget.draft.color),
    ),
  );

  void _togglePanel(_StylePanel panel) =>
      setState(() => _panel = _panel == panel ? _StylePanel.style : panel);

  @override
  Widget build(BuildContext context) => Material(
    color: EditorColorTokens.surface,
    elevation: 12,
    shadowColor: EditorColorTokens.shadow,
    shape: const RoundedRectangleBorder(
      side: BorderSide(color: EditorColorTokens.border),
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: 50, child: _controlRow()),
          const Divider(height: 1, color: EditorColorTokens.border),
          SizedBox(height: 58, child: _panelContent()),
        ],
      ),
    ),
  );

  Widget _controlRow() => Row(
    children: [
      const SizedBox(width: 6),
      _BarButton(
        keyValue: const Key('editor-text-align'),
        icon: switch (widget.draft.align) {
          EditorTextAlign.left => Icons.format_align_left_rounded,
          EditorTextAlign.center => Icons.format_align_center_rounded,
          EditorTextAlign.right => Icons.format_align_right_rounded,
        },
        active: false,
        onTap: _cycleAlign,
      ),
      _BarButton(
        keyValue: const Key('editor-text-size'),
        label: 'Aa',
        active: _panel == _StylePanel.size,
        onTap: () => _togglePanel(_StylePanel.size),
      ),
      _SwatchButton(
        keyValue: const Key('editor-text-color'),
        color: widget.draft.color,
        active: _panel == _StylePanel.color,
        onTap: () => _togglePanel(_StylePanel.color),
      ),
      _BarButton(
        keyValue: const Key('editor-text-background'),
        icon: Icons.format_color_text_rounded,
        active: widget.draft.hasBackground,
        onTap: _toggleBackground,
      ),
      const Spacer(),
      FilledButton(
        key: const Key('editor-text-done'),
        onPressed: widget.onDone,
        style: FilledButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: EditorColorTokens.coral,
          minimumSize: const Size(66, 36),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text(
          '완료',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
      ),
      const SizedBox(width: 6),
    ],
  );

  Widget _panelContent() => switch (_panel) {
    _StylePanel.size => _sizePanel(),
    _StylePanel.color => _colorPanel(),
    _StylePanel.style => _stylePanel(),
  };

  Widget _sizePanel() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 18),
    child: Row(
      children: [
        const Text(
          '작게',
          style: TextStyle(color: EditorColorTokens.muted, fontSize: 12),
        ),
        Expanded(
          child: Slider(
            key: const Key('editor-text-size-slider'),
            min: 24,
            max: 144,
            value: widget.draft.fontSize.clamp(24, 144),
            activeColor: EditorColorTokens.coral,
            inactiveColor: EditorColorTokens.border,
            onChanged: (value) =>
                _apply(widget.draft.copyWith(fontSize: value)),
          ),
        ),
        const Text(
          '크게',
          style: TextStyle(color: EditorColorTokens.muted, fontSize: 12),
        ),
      ],
    ),
  );

  Widget _colorPanel() => ListView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    children: [
      for (final color in _paletteColors)
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Center(
            child: GestureDetector(
              key: Key('editor-text-color-${color.toARGB32()}'),
              onTap: () => _pickColor(color),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color == widget.draft.color
                        ? EditorColorTokens.coral
                        : EditorColorTokens.border,
                    width: color == widget.draft.color ? 3 : 1.5,
                  ),
                ),
              ),
            ),
          ),
        ),
    ],
  );

  Widget _stylePanel() {
    final current = _TextStylePreset.match(widget.draft);
    return ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      children: [
        for (final preset in _TextStylePreset.all)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Center(
              child: GestureDetector(
                key: Key('editor-text-style-${preset.id}'),
                onTap: () => _applyPreset(preset),
                child: Container(
                  width: 46,
                  height: 46,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: preset.id == current
                        ? EditorColorTokens.selected
                        : Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: preset.id == current
                          ? EditorColorTokens.coral
                          : EditorColorTokens.border,
                    ),
                  ),
                  child: Text(
                    'Aa',
                    style: TextStyle(
                      color: preset.id == current
                          ? EditorColorTokens.coral
                          : EditorColorTokens.ink,
                      fontSize: 18,
                      fontWeight: preset.bold
                          ? FontWeight.w900
                          : FontWeight.w400,
                      fontStyle: preset.italic
                          ? FontStyle.italic
                          : FontStyle.normal,
                      backgroundColor: preset.boxed
                          ? (preset.id == current
                                ? const Color(0x22000000)
                                : const Color(0x22000000))
                          : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.keyValue,
    required this.active,
    required this.onTap,
    this.icon,
    this.label,
  });

  final Key keyValue;
  final IconData? icon;
  final String? label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: keyValue,
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      width: 46,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: active ? EditorColorTokens.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: active ? Border.all(color: EditorColorTokens.coral) : null,
      ),
      child: icon != null
          ? Icon(
              icon,
              color: active ? EditorColorTokens.coral : EditorColorTokens.ink,
              size: 23,
            )
          : Text(
              label ?? '',
              style: TextStyle(
                color: active ? EditorColorTokens.coral : EditorColorTokens.ink,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
    ),
  );
}

class _SwatchButton extends StatelessWidget {
  const _SwatchButton({
    required this.keyValue,
    required this.color,
    required this.active,
    required this.onTap,
  });

  final Key keyValue;
  final Color color;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    key: keyValue,
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: SizedBox(
      width: 46,
      height: 40,
      child: Center(
        child: Container(
          width: active ? 28 : 24,
          height: active ? 28 : 24,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
              color: active ? EditorColorTokens.coral : EditorColorTokens.muted,
              width: active ? 3 : 2,
            ),
          ),
        ),
      ),
    ),
  );
}
