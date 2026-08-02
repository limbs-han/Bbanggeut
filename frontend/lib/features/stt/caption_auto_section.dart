/// 자막 시트에 끼우는 자동 자막 섹션.
///
/// **왜 섹션인가**: 편집 화면의 자막 하단 시트(`_showCaptionEditor`)에는 직접
/// 타이핑하는 입력칸과 색 선택이 이미 있다. 그 아래에 이 섹션 하나만 끼우면
/// "직접 쓰는 자막"과 "알아서 만들어지는 자막"이 한 화면에서 이어진다.
/// 수정 다이얼로그를 섹션이 직접 들고 있어서 화면 쪽에는 위젯 호출만 남는다.
library;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import 'caption_controller.dart';
import 'transcript_api.dart' show transcriptServerReady;

/// 미리보기가 쓸 한 줄. 미리보기 위젯에 넘길 값을 만든다.
String? autoCaptionAt(CaptionController controller, int positionMs) =>
    controller.textAt(positionMs);

class CaptionAutoSection extends StatefulWidget {
  const CaptionAutoSection({
    super.key,
    required this.controller,
    this.estimateSeconds,
    this.onChanged,
  });

  final CaptionController controller;

  /// 전사가 도는 중일 때 보여줄 예상 시간. 모르면 null.
  final int? estimateSeconds;

  /// 사용자가 자막을 고쳤을 때. 화면이 "저장 안 된 변경"으로 표시한다.
  final VoidCallback? onChanged;

  @override
  State<CaptionAutoSection> createState() => _CaptionAutoSectionState();
}

class _CaptionAutoSectionState extends State<CaptionAutoSection> {
  /// 입력칸 컨트롤러는 이 위젯이 소유한다 — 다이얼로그마다 만들어 닫힌 직후
  /// dispose하면 리빌드가 죽은 컨트롤러를 만져 화면이 빈다.
  final _field = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _field.dispose();
    super.dispose();
  }

  Future<void> _edit(int index) async {
    _field.text = widget.controller.lines[index].text;
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${index + 1}번째 자막'),
        content: TextField(
          key: const ValueKey('auto-caption-field'),
          controller: _field,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '들린 그대로 적어 주세요'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, _field.text.trim()),
            child: const Text('넣기'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    widget.controller.edit(index, text);
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.controller.lines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        Row(
          children: [
            const Icon(Icons.auto_awesome_rounded, size: 16),
            const SizedBox(width: 6),
            Text(
              '들린 대사로 자동 자막',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ],
        ),
        if (!transcriptServerReady) ...[
          const SizedBox(height: 6),
          const _SampleNotice(),
        ],
        const SizedBox(height: 6),
        Text(
          widget.controller.message(estimateSeconds: widget.estimateSeconds),
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
        if (widget.controller.canRetry)
          TextButton.icon(
            key: const ValueKey('auto-caption-retry'),
            onPressed: widget.controller.retry,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('다시 시도'),
          ),
        if (lines.isNotEmpty) ...[
          const SizedBox(height: 8),
          // 시트가 화면을 다 먹지 않게 높이를 묶는다.
          SizedBox(
            height: 148,
            child: ListView.builder(
              itemCount: lines.length,
              itemBuilder: (_, index) => InkWell(
                key: ValueKey('auto-caption-row-$index'),
                onTap: () => _edit(index),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 52,
                        child: Text(
                          _clock(lines[index].startMs),
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Expanded(child: Text(lines[index].text)),
                      const Icon(Icons.edit_rounded, size: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _clock(int milliseconds) {
    final value = Duration(milliseconds: milliseconds);
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

/// 서버 통로가 없을 때 자막 목록 위에 붙는 알림. 만화 화면의 `_SampleNotice`와
/// 같은 이유이고 같은 말투다.
///
/// 가짜 통로는 고정된 대사 세 줄을 돌려준다. 알리지 않으면 사용자가 그것을 자기
/// 가족의 말로 오해하고, 미리보기 위에 얹혀 보이는 데다 그대로 저장하면
/// **갤러리에 남는 MP4에 구워진다.** `COMIC_SERVER=true`로 켜면 사라진다.
class _SampleNotice extends StatelessWidget {
  const _SampleNotice();

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('caption-sample-notice'),
    width: double.infinity,
    color: AppColors.yellowSoft,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    child: const Text(
      '아직 서버 통로가 없어서 예시 대사를 보여주고 있어요. '
      '실제로 들린 말이 아니고, 저장하면 영상에도 이 대사가 들어가요.',
      style: TextStyle(fontSize: 12),
    ),
  );
}
