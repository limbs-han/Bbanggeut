import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'editor_ar_effects.dart';
import 'editor_project.dart';
import 'editor_project_controller.dart';
import 'editor_tokens.dart';

class EditorWorkspace extends StatelessWidget {
  const EditorWorkspace({
    super.key,
    required this.controller,
    required this.preview,
    required this.thumbnails,
    required this.playing,
    required this.currentTime,
    required this.totalTime,
    required this.saving,
    required this.onBack,
    required this.onSave,
    required this.onPlay,
    required this.onSeek,
    required this.onSplit,
    required this.onDelete,
    required this.onDuplicate,
    required this.onTrimStartChanged,
    required this.onTrimEndChanged,
    required this.onRatioSelected,
    required this.onText,
    required this.onVolumeChanged,
    required this.onMutedChanged,
    required this.onStickerSelected,
    required this.onArEffectSelected,
    required this.onArEffectCleared,
    required this.onAiCaption,
    required this.onToolSelected,
    this.aiCaptionSummary,
    this.exportProgress,
    this.exportStatus,
    this.onExportCancel,
  });

  final EditorProjectController controller;
  final Widget preview;
  final List<String> thumbnails;
  final bool playing;
  final String currentTime;
  final String totalTime;
  final bool saving;
  final VoidCallback onBack;
  final VoidCallback onSave;
  final VoidCallback onPlay;
  final ValueChanged<int> onSeek;
  final VoidCallback onSplit;
  final VoidCallback onDelete;
  final VoidCallback onDuplicate;
  final ValueChanged<int> onTrimStartChanged;
  final ValueChanged<int> onTrimEndChanged;
  final ValueChanged<EditorCanvasRatio> onRatioSelected;
  final VoidCallback onText;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<bool> onMutedChanged;
  final ValueChanged<String> onStickerSelected;
  final ValueChanged<EditorArEffect> onArEffectSelected;
  final VoidCallback onArEffectCleared;

  /// 자동 자막 화면을 여는 버튼. 자막 로직은 전부 features/stt 쪽에 있고
  /// 편집기는 버튼만 들고 있다.
  final VoidCallback onAiCaption;

  /// AI 자막 패널에 보여줄 한 줄 상태. 자막 컨트롤러가 만든 문구를 그대로 받는다.
  final String? aiCaptionSummary;

  final ValueChanged<EditorTool> onToolSelected;

  /// 저장 중 진행률(0~1). null이면 진행 표시를 그리지 않는다.
  final double? exportProgress;
  final String? exportStatus;

  /// 렌더링을 중간에 그만둘 때. null이면 취소 버튼을 감춘다.
  final VoidCallback? onExportCancel;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final project = controller.project;
      final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
      final cutMode = project.selectedTool == EditorTool.cut;
      return ColoredBox(
        color: EditorColorTokens.background,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final layout = EditorLayoutTokens.fromSize(
                Size(constraints.maxWidth, constraints.maxHeight),
                keyboardVisible: keyboardVisible,
              );
              return Stack(
                children: [
                  Column(
                    children: [
                      EditorTopBar(
                        height: layout.topBarHeight,
                        canUndo: controller.canUndo,
                        canRedo: controller.canRedo,
                        saving: saving,
                        onBack: onBack,
                        onUndo: controller.undo,
                        onRedo: controller.redo,
                        onSave: onSave,
                      ),
                      Expanded(
                        child: VideoPreviewWorkspace(
                          preview: preview,
                          playing: playing,
                          currentTime: currentTime,
                          totalTime: totalTime,
                          onPlay: onPlay,
                        ),
                      ),
                      if (!keyboardVisible)
                        EditorTimelineSection(
                          height: cutMode
                              ? layout.timelineHeight
                              : layout.collapsedTimelineHeight,
                          thumbnailHeight: layout.thumbnailHeight,
                          actionButtonHeight: layout.actionButtonHeight,
                          project: project,
                          thumbnails: thumbnails,
                          expanded: cutMode,
                          canDelete: controller.canDeleteSelectedClip,
                          canSplit: controller.canSplitAtPlayhead,
                          onSeek: onSeek,
                          onClipSelected: controller.selectClip,
                          onSplit: onSplit,
                          onDelete: onDelete,
                          onDuplicate: onDuplicate,
                          onTrimStartChanged: onTrimStartChanged,
                          onTrimEndChanged: onTrimEndChanged,
                        ),
                      if (!keyboardVisible)
                        AnimatedSize(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: SelectedToolPanel(
                            project: project,
                            height: layout.toolPanelHeight,
                            onRatioSelected: onRatioSelected,
                            onText: onText,
                            onVolumeChanged: onVolumeChanged,
                            onMutedChanged: onMutedChanged,
                            onStickerSelected: onStickerSelected,
                            onArEffectSelected: onArEffectSelected,
                            onArEffectCleared: onArEffectCleared,
                            onAiCaption: onAiCaption,
                            aiCaptionSummary: aiCaptionSummary,
                          ),
                        ),
                      if (!keyboardVisible)
                        EditorBottomNavigation(
                          height: layout.bottomNavigationHeight,
                          selectedTool: project.selectedTool,
                          fontSize: layout.navigationFontSize,
                          iconSize: layout.navigationIconSize,
                          onSelected: onToolSelected,
                        ),
                    ],
                  ),
                  if (saving)
                    Positioned.fill(
                      child: EditorExportBlocker(
                        progress: exportProgress,
                        status: exportStatus,
                        onCancel: onExportCancel,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
    },
  );
}

/// 저장(렌더링) 중에는 편집 조작을 막고 진행률을 보여 준다. 예전에는 아무
/// 표시가 없어서 오래 걸리는 렌더링이 "저장이 안 된다"로 보였다.
class EditorExportBlocker extends StatelessWidget {
  const EditorExportBlocker({
    super.key,
    this.progress,
    this.status,
    this.onCancel,
  });

  final double? progress;
  final String? status;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const Key('editor-export-blocker'),
    color: const Color(0xC6231A14),
    child: Center(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 36),
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
        decoration: BoxDecoration(
          color: EditorColorTokens.surface,
          borderRadius: BorderRadius.circular(EditorRadiusTokens.panel + 4),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 46,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 4,
                color: EditorColorTokens.coral,
                backgroundColor: EditorColorTokens.border,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              progress == null
                  ? '영상을 준비하고 있어요'
                  : '영상 만드는 중 ${(progress! * 100).round()}%',
              style: const TextStyle(
                color: EditorColorTokens.ink,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              status ?? '잠시만 기다려 주세요',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: EditorColorTokens.muted,
                fontSize: 12,
                height: 1.35,
              ),
            ),
            if (onCancel != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextButton(
                  key: const Key('editor-cancel-export'),
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    foregroundColor: EditorColorTokens.muted,
                  ),
                  child: const Text('그만두기'),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class EditorTopBar extends StatelessWidget {
  const EditorTopBar({
    super.key,
    required this.height,
    required this.canUndo,
    required this.canRedo,
    required this.saving,
    required this.onBack,
    required this.onUndo,
    required this.onRedo,
    required this.onSave,
  });

  final double height;
  final bool canUndo;
  final bool canRedo;
  final bool saving;
  final VoidCallback onBack;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    height: height,
    child: ColoredBox(
      color: EditorColorTokens.surface,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Text(
            '영상 편집',
            style: TextStyle(
              color: EditorColorTokens.ink,
              fontSize: EditorTypographyTokens.title,
              fontWeight: FontWeight.w700,
            ),
          ),
          Positioned.fill(
            child: Row(
              children: [
                _EditorIconButton(
                  tooltip: '뒤로가기',
                  icon: Icons.arrow_back_ios_new_rounded,
                  onPressed: onBack,
                ),
                const Spacer(),
                _EditorIconButton(
                  tooltip: '실행 취소',
                  icon: Icons.undo_rounded,
                  onPressed: canUndo && !saving ? onUndo : null,
                ),
                _EditorIconButton(
                  tooltip: '다시 실행',
                  icon: Icons.redo_rounded,
                  onPressed: canRedo && !saving ? onRedo : null,
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SizedBox(
                    width: 64,
                    height: 34,
                    child: FilledButton(
                      key: const Key('editor-save'),
                      onPressed: saving ? null : onSave,
                      style: FilledButton.styleFrom(
                        padding: EdgeInsets.zero,
                        backgroundColor: EditorColorTokens.coral,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: EditorColorTokens.border,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(
                            EditorRadiusTokens.control,
                          ),
                        ),
                      ),
                      child: saving
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              '저장',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class VideoPreviewWorkspace extends StatelessWidget {
  const VideoPreviewWorkspace({
    super.key,
    required this.preview,
    required this.playing,
    required this.currentTime,
    required this.totalTime,
    required this.onPlay,
  });

  final Widget preview;
  final bool playing;
  final String currentTime;
  final String totalTime;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: EditorSpacingTokens.previewHorizontal,
      vertical: EditorSpacingTokens.sm,
    ),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: EditorColorTokens.previewWorkspace,
        borderRadius: BorderRadius.circular(EditorRadiusTokens.panel),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: const EdgeInsets.all(EditorSpacingTokens.sm),
            child: Center(child: preview),
          ),
          Positioned(
            left: 10,
            bottom: 8,
            child: PlaybackOverlay(
              playing: playing,
              currentTime: currentTime,
              totalTime: totalTime,
              onPlay: onPlay,
            ),
          ),
        ],
      ),
    ),
  );
}

class PlaybackOverlay extends StatelessWidget {
  const PlaybackOverlay({
    super.key,
    required this.playing,
    required this.currentTime,
    required this.totalTime,
    required this.onPlay,
  });

  final bool playing;
  final String currentTime;
  final String totalTime;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox.square(
        dimension: 44,
        child: IconButton.filled(
          tooltip: playing ? '일시정지' : '재생',
          onPressed: onPlay,
          style: IconButton.styleFrom(
            backgroundColor: EditorColorTokens.coral,
            foregroundColor: Colors.white,
            iconSize: 22,
          ),
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
      ),
      const SizedBox(width: 6),
      DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xB31E1510),
          borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          child: Text(
            '$currentTime / $totalTime',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ],
  );
}

/// 컷 편집 타임라인.
///
/// **왜 클립 띠인가**: 예전에는 썸네일 위에 투명한 [Slider] 하나를 덮고, 그
/// 위에 원본 전체 길이를 다루는 [RangeSlider]를 따로 뒀다. 클립이 여러 개로
/// 나뉘어도 눈에 보이는 변화가 없고, 슬라이더가 모든 드래그를 먹어서 구간
/// 조절이 안 됐다. 이제 클립마다 제 폭을 가진 칸으로 그리고, 고른 클립의 양
/// 끝에만 손잡이를 붙인다 — 분할·복제·삭제 결과가 띠 모양으로 바로 보인다.
class EditorTimelineSection extends StatelessWidget {
  const EditorTimelineSection({
    super.key,
    required this.height,
    required this.thumbnailHeight,
    required this.actionButtonHeight,
    required this.project,
    required this.thumbnails,
    required this.expanded,
    required this.canDelete,
    required this.canSplit,
    required this.onSeek,
    required this.onClipSelected,
    required this.onSplit,
    required this.onDelete,
    required this.onDuplicate,
    required this.onTrimStartChanged,
    required this.onTrimEndChanged,
  });

  final double height;
  final double thumbnailHeight;
  final double actionButtonHeight;
  final EditorProject project;
  final List<String> thumbnails;
  final bool expanded;
  final bool canDelete;
  final bool canSplit;
  final ValueChanged<int> onSeek;
  final ValueChanged<String> onClipSelected;
  final VoidCallback onSplit;
  final VoidCallback onDelete;
  final VoidCallback onDuplicate;
  final ValueChanged<int> onTrimStartChanged;
  final ValueChanged<int> onTrimEndChanged;

  String get _hint {
    if (project.clips.isEmpty) return '';
    if (project.selectedClip == null) {
      return '편집할 클립을 눌러 골라 주세요.';
    }
    if (!canSplit) {
      return '분할은 재생 위치를 클립 안쪽으로 옮긴 뒤 할 수 있어요.';
    }
    if (!canDelete) {
      return '양 끝 손잡이로 구간을 정하거나 분할한 뒤 삭제할 수 있어요.';
    }
    return '클립을 눌러 고르고, 양 끝 손잡이를 끌어 구간을 정해요.';
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: ColoredBox(
      color: EditorColorTokens.background,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: Column(
          children: [
            SizedBox(
              height: expanded ? 18 : 10,
              child: expanded
                  ? Row(
                      children: [
                        Expanded(
                          child: Text(
                            _selectionLabel(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: EditorColorTokens.muted,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          '전체 ${_formatMs(project.durationMs)}',
                          style: const TextStyle(
                            color: EditorColorTokens.muted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    )
                  : null,
            ),
            Expanded(
              child: ClipTimelineStrip(
                project: project,
                thumbnails: thumbnails,
                expanded: expanded,
                thumbnailHeight: thumbnailHeight,
                onSeek: onSeek,
                onClipSelected: onClipSelected,
                onTrimStartChanged: onTrimStartChanged,
                onTrimEndChanged: onTrimEndChanged,
              ),
            ),
            if (expanded) ...[
              SizedBox(
                height: actionButtonHeight,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _TimelineAction(
                      label: '분할',
                      icon: Icons.content_cut_rounded,
                      onPressed: canSplit ? onSplit : null,
                    ),
                    _TimelineAction(
                      label: '복제',
                      icon: Icons.copy_rounded,
                      onPressed: project.selectedClip == null
                          ? null
                          : onDuplicate,
                    ),
                    _TimelineAction(
                      label: '삭제',
                      icon: Icons.delete_outline_rounded,
                      onPressed: canDelete ? onDelete : null,
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 15,
                child: Text(
                  _hint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: EditorColorTokens.muted,
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  String _selectionLabel() {
    final selected = project.selectedClip;
    if (selected == null) return '클립을 골라 주세요';
    final index = project.clips.indexOf(selected) + 1;
    return '클립 $index/${project.clips.length} · '
        '${_formatMs(selected.sourceStartMs)}~${_formatMs(selected.sourceEndMs)}'
        ' (${_formatMs(selected.durationMs)})';
  }
}

/// 클립을 폭으로 나눠 그리는 타임라인 띠. 고른 클립 양 끝에 트림 손잡이가 붙는다.
class ClipTimelineStrip extends StatefulWidget {
  const ClipTimelineStrip({
    super.key,
    required this.project,
    required this.thumbnails,
    required this.expanded,
    required this.thumbnailHeight,
    required this.onSeek,
    required this.onClipSelected,
    required this.onTrimStartChanged,
    required this.onTrimEndChanged,
  });

  final EditorProject project;
  final List<String> thumbnails;
  final bool expanded;
  final double thumbnailHeight;
  final ValueChanged<int> onSeek;
  final ValueChanged<String> onClipSelected;
  final ValueChanged<int> onTrimStartChanged;
  final ValueChanged<int> onTrimEndChanged;

  @override
  State<ClipTimelineStrip> createState() => _ClipTimelineStripState();
}

class _ClipTimelineStripState extends State<ClipTimelineStrip> {
  /// 손잡이를 잡은 순간의 기준값. 드래그 중 클립 길이가 변해도 손가락과 눈금이
  /// 어긋나지 않게, 잡은 시점의 배율을 끝까지 쓴다.
  int _handleAnchorMs = 0;
  double _handleOffsetPx = 0;
  double _handleMsPerPx = 1;
  bool _draggingHandle = false;

  static const _handleWidth = 15.0;
  static const _handleTouchWidth = 34.0;

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    if (project.clips.isEmpty) {
      return const ColoredBox(color: EditorColorTokens.border);
    }
    final totalMs = math.max(1, project.durationMs);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth <= 0 ? 1.0 : constraints.maxWidth;
        final msPerPx = totalMs / width;
        final segments = <_ClipSegment>[];
        var left = 0.0;
        for (final clip in project.clips) {
          final segmentWidth = clip.durationMs / totalMs * width;
          segments.add(
            _ClipSegment(clip: clip, left: left, width: segmentWidth),
          );
          left += segmentWidth;
        }
        final selected = segments
            .where((segment) => segment.clip.id == project.selectedClipId)
            .firstOrNull;
        final playheadX = (project.playheadMs / totalMs * width).clamp(
          0.0,
          width,
        );

        return Stack(
          key: const Key('editor-timeline-strip'),
          clipBehavior: Clip.none,
          children: [
            for (final segment in segments)
              Positioned(
                left: segment.left,
                width: segment.width,
                top: 0,
                bottom: 0,
                child: _ClipCell(
                  key: Key('editor-clip-${segment.clip.id}'),
                  clip: segment.clip,
                  index: project.clips.indexOf(segment.clip) + 1,
                  totalClips: project.clips.length,
                  selected: segment.clip.id == project.selectedClipId,
                  expanded: widget.expanded,
                  thumbnails: _cellsFor(segment),
                ),
              ),
            // 어디를 눌러도 그 자리로 재생 위치가 가고 그 클립이 골라진다.
            // 손잡이는 이 레이어보다 위에 있어서 드래그를 먼저 잡는다.
            Positioned.fill(
              child: GestureDetector(
                key: const Key('editor-timeline-scrub'),
                behavior: HitTestBehavior.translucent,
                onTapDown: (details) =>
                    _scrubTo(details.localPosition.dx, msPerPx, totalMs),
                onHorizontalDragStart: (details) =>
                    _scrubTo(details.localPosition.dx, msPerPx, totalMs),
                onHorizontalDragUpdate: (details) =>
                    _scrubTo(details.localPosition.dx, msPerPx, totalMs),
              ),
            ),
            IgnorePointer(
              child: Padding(
                padding: EdgeInsets.only(left: math.max(0, playheadX - 1)),
                child: Align(
                  key: const Key('editor-playhead'),
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 2,
                    height: widget.thumbnailHeight,
                    decoration: BoxDecoration(
                      color: EditorColorTokens.coral,
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: const [
                        BoxShadow(color: Color(0x66000000), blurRadius: 3),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 손잡이는 고른 클립 **안쪽**에 붙인다. 경계에 걸치게 두면 절반이
            // 띠 밖으로 나가고, RenderBox는 자기 크기 밖을 hit test에서
            // 걸러내므로 그만큼 눌러도 반응하지 않는다.
            if (widget.expanded && selected != null) ...[
              _handle(
                key: const Key('editor-trim-start-handle'),
                left: selected.left.clamp(
                  0.0,
                  math.max(0, width - _handleTouchWidth),
                ),
                isStart: true,
                anchorMs: selected.clip.sourceStartMs,
                msPerPx: msPerPx,
              ),
              _handle(
                key: const Key('editor-trim-end-handle'),
                left: (selected.left + selected.width - _handleTouchWidth)
                    .clamp(0.0, math.max(0, width - _handleTouchWidth)),
                isStart: false,
                anchorMs: selected.clip.sourceEndMs,
                msPerPx: msPerPx,
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _handle({
    required Key key,
    required double left,
    required bool isStart,
    required int anchorMs,
    required double msPerPx,
  }) => Positioned(
    left: left,
    width: _handleTouchWidth,
    top: 0,
    bottom: 0,
    child: GestureDetector(
      key: key,
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) {
        _draggingHandle = true;
        _handleAnchorMs = anchorMs;
        _handleOffsetPx = 0;
        _handleMsPerPx = msPerPx;
      },
      onHorizontalDragUpdate: (details) {
        if (!_draggingHandle) return;
        _handleOffsetPx += details.delta.dx;
        final nextMs = (_handleAnchorMs + _handleOffsetPx * _handleMsPerPx)
            .round();
        if (isStart) {
          widget.onTrimStartChanged(nextMs);
        } else {
          widget.onTrimEndChanged(nextMs);
        }
      },
      onHorizontalDragEnd: (_) => _draggingHandle = false,
      onHorizontalDragCancel: () => _draggingHandle = false,
      child: Center(
        child: Container(
          width: _handleWidth,
          decoration: BoxDecoration(
            color: EditorColorTokens.coral,
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(isStart ? 7 : 2),
              right: Radius.circular(isStart ? 2 : 7),
            ),
          ),
          child: const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _HandleGrip(),
              SizedBox(height: 3),
              _HandleGrip(),
              SizedBox(height: 3),
              _HandleGrip(),
            ],
          ),
        ),
      ),
    ),
  );

  void _scrubTo(double dx, double msPerPx, int totalMs) {
    final timelineMs = (dx * msPerPx).round().clamp(0, totalMs);
    widget.onSeek(timelineMs);
    final clip = _clipAt(timelineMs);
    if (clip != null) widget.onClipSelected(clip.id);
  }

  EditorClip? _clipAt(int timelineMs) {
    var startMs = 0;
    for (final clip in widget.project.clips) {
      final endMs = startMs + clip.durationMs;
      if (timelineMs >= startMs && timelineMs <= endMs) return clip;
      startMs = endMs;
    }
    return widget.project.clips.lastOrNull;
  }

  /// 클립이 덮는 원본 구간에 해당하는 썸네일들. 분할·트림하면 칸에 보이는
  /// 그림도 같이 달라진다.
  List<String> _cellsFor(_ClipSegment segment) {
    final frames = widget.thumbnails;
    if (frames.isEmpty) return const [];
    final sourceDurationMs = math.max(1, widget.project.sourceDurationMs);
    final count = math.max(1, (segment.width / 54).round());
    final spanMs = segment.clip.durationMs;
    return [
      for (var index = 0; index < count; index++)
        frames[(((segment.clip.sourceStartMs +
                            spanMs * (index + 0.5) / count) /
                        sourceDurationMs) *
                    frames.length)
                .floor()
                .clamp(0, frames.length - 1)],
    ];
  }
}

class _HandleGrip extends StatelessWidget {
  const _HandleGrip();

  @override
  Widget build(BuildContext context) => Container(
    width: 7,
    height: 2,
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(1),
    ),
  );
}

class _ClipSegment {
  const _ClipSegment({
    required this.clip,
    required this.left,
    required this.width,
  });

  final EditorClip clip;
  final double left;
  final double width;
}

class _ClipCell extends StatelessWidget {
  const _ClipCell({
    super.key,
    required this.clip,
    required this.index,
    required this.totalClips,
    required this.selected,
    required this.expanded,
    required this.thumbnails,
  });

  final EditorClip clip;
  final int index;
  final int totalClips;
  final bool selected;
  final bool expanded;
  final List<String> thumbnails;

  @override
  Widget build(BuildContext context) => Padding(
    // 클립 사이가 붙어 보이지 않게 아주 얇은 틈을 둔다.
    padding: const EdgeInsets.symmetric(horizontal: 0.5),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: EditorColorTokens.border,
        borderRadius: BorderRadius.circular(EditorRadiusTokens.video + 1),
        border: Border.all(
          color: selected ? EditorColorTokens.coral : Colors.white54,
          width: selected ? 2.5 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(EditorRadiusTokens.video),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumbnails.isEmpty)
              const Center(
                child: SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: EditorColorTokens.coral,
                  ),
                ),
              )
            else
              Row(
                children: [
                  for (final path in thumbnails)
                    Expanded(child: _Thumbnail(path: path)),
                ],
              ),
            if (expanded && totalClips > 1)
              Positioned(left: 2, top: 2, child: _ClipBadge(label: '$index')),
            if (expanded)
              Positioned(
                right: 2,
                bottom: 2,
                child: _ClipBadge(label: _formatMs(clip.durationMs)),
              ),
          ],
        ),
      ),
    ),
  );
}

class _ClipBadge extends StatelessWidget {
  const _ClipBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: const Color(0xAA1E1510),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) => Image.file(
    File(path),
    fit: BoxFit.cover,
    gaplessPlayback: true,
    errorBuilder: (_, _, _) =>
        const ColoredBox(color: EditorColorTokens.border),
  );
}

class SelectedToolPanel extends StatelessWidget {
  const SelectedToolPanel({
    super.key,
    required this.project,
    required this.height,
    required this.onRatioSelected,
    required this.onText,
    required this.onVolumeChanged,
    required this.onMutedChanged,
    required this.onStickerSelected,
    required this.onArEffectSelected,
    required this.onArEffectCleared,
    required this.onAiCaption,
    this.aiCaptionSummary,
  });

  final EditorProject project;
  final double height;
  final ValueChanged<EditorCanvasRatio> onRatioSelected;
  final VoidCallback onText;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<bool> onMutedChanged;
  final ValueChanged<String> onStickerSelected;
  final ValueChanged<EditorArEffect> onArEffectSelected;
  final VoidCallback onArEffectCleared;
  final VoidCallback onAiCaption;
  final String? aiCaptionSummary;

  @override
  Widget build(BuildContext context) {
    if (project.selectedTool == EditorTool.cut) {
      return const SizedBox.shrink();
    }
    return Container(
      height: height,
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: const BoxDecoration(
        color: EditorColorTokens.surface,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(EditorRadiusTokens.panel),
        ),
        border: Border(top: BorderSide(color: EditorColorTokens.border)),
      ),
      child: switch (project.selectedTool) {
        EditorTool.ratio => _RatioPanel(
          selected: project.canvas.ratio,
          onSelected: onRatioSelected,
        ),
        EditorTool.text => _TextPanel(onText: onText),
        EditorTool.audio => _AudioPanel(
          audio: project.audio,
          onVolumeChanged: onVolumeChanged,
          onMutedChanged: onMutedChanged,
        ),
        EditorTool.sticker => _StickerPanel(onSelected: onStickerSelected),
        EditorTool.aiCaption => _AiCaptionPanel(
          summary: aiCaptionSummary,
          onOpen: onAiCaption,
        ),
        EditorTool.ar => _ArPanel(
          activeEffectId: project.arEffectId,
          onSelected: onArEffectSelected,
          onCleared: onArEffectCleared,
        ),
        EditorTool.cut => const SizedBox.shrink(),
      },
    );
  }
}

class _RatioPanel extends StatelessWidget {
  const _RatioPanel({required this.selected, required this.onSelected});

  final EditorCanvasRatio selected;
  final ValueChanged<EditorCanvasRatio> onSelected;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _PanelTitle('화면 비율'),
      const SizedBox(height: 6),
      Expanded(
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final entry in const [
              (EditorCanvasRatio.original, '원본'),
              (EditorCanvasRatio.vertical, '9:16'),
              (EditorCanvasRatio.landscape, '16:9'),
              (EditorCanvasRatio.square, '1:1'),
              (EditorCanvasRatio.portrait, '4:5'),
            ])
              _PanelChoice(
                label: entry.$2,
                selected: selected == entry.$1,
                onTap: () => onSelected(entry.$1),
              ),
          ],
        ),
      ),
    ],
  );
}

class _TextPanel extends StatelessWidget {
  const _TextPanel({required this.onText});

  final VoidCallback onText;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _PanelTitle('텍스트'),
      const SizedBox(height: 2),
      // 남는 높이를 글로 채운다. 고정 높이로 두면 세로가 짧은 기기에서 넘친다.
      const Expanded(
        child: Text(
          '배경 없는 글자로 얹혀요. 영상 위 글자를 끌어 옮기고, 모서리를 끌어 크기를 바꿔요.',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: EditorColorTokens.muted,
            fontSize: 11,
            height: 1.3,
          ),
        ),
      ),
      SizedBox(
        width: double.infinity,
        height: 40,
        child: OutlinedButton.icon(
          key: const Key('editor-open-text-sheet'),
          onPressed: onText,
          icon: const Icon(Icons.title_rounded, size: 20),
          label: const Text('텍스트 넣기'),
        ),
      ),
    ],
  );
}

class _AudioPanel extends StatelessWidget {
  const _AudioPanel({
    required this.audio,
    required this.onVolumeChanged,
    required this.onMutedChanged,
  });

  final EditorAudio audio;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<bool> onMutedChanged;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        height: 30,
        child: Row(
          children: [
            const Expanded(child: _PanelTitle('원본 오디오')),
            TextButton.icon(
              onPressed: () => onMutedChanged(!audio.muted),
              icon: Icon(
                audio.muted
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                size: 18,
              ),
              label: Text(
                audio.muted ? '음소거 해제' : '음소거',
                style: const TextStyle(fontSize: 12),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      ),
      Expanded(
        child: Slider(
          value: audio.sourceVolume,
          onChanged: audio.muted ? null : onVolumeChanged,
        ),
      ),
      Text(
        '${(audio.effectiveVolume * 100).round()}%',
        style: const TextStyle(color: EditorColorTokens.muted, fontSize: 11),
      ),
    ],
  );
}

class _StickerPanel extends StatelessWidget {
  const _StickerPanel({required this.onSelected});

  final ValueChanged<String> onSelected;

  static const _stickers = [
    '😊',
    '😂',
    '🥳',
    '❤️',
    '⭐',
    '🎉',
    '👏',
    '🌸',
    '🍰',
    '🐶',
    '🐱',
    '👍',
  ];

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _PanelTitle('스티커'),
      const SizedBox(height: 1),
      const Text(
        '누르면 영상 가운데에 놓여요. 끌어 옮기고 모서리로 크기를 바꿔요.',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: EditorColorTokens.muted, fontSize: 11),
      ),
      const SizedBox(height: 4),
      Expanded(
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final sticker in _stickers)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: InkWell(
                  key: Key('editor-sticker-$sticker'),
                  onTap: () => onSelected(sticker),
                  borderRadius: BorderRadius.circular(
                    EditorRadiusTokens.control,
                  ),
                  child: Container(
                    width: 50,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: EditorColorTokens.background,
                      borderRadius: BorderRadius.circular(
                        EditorRadiusTokens.control,
                      ),
                      border: Border.all(color: EditorColorTokens.border),
                    ),
                    child: Text(sticker, style: const TextStyle(fontSize: 25)),
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

/// AI 자막 탭. 자막을 만드는 코드는 features/stt 쪽 그대로 쓰고, 여기서는
/// 그 화면을 여는 버튼과 상태 한 줄만 그린다.
class _AiCaptionPanel extends StatelessWidget {
  const _AiCaptionPanel({required this.onOpen, this.summary});

  final VoidCallback onOpen;
  final String? summary;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _PanelTitle('AI 자막'),
      const SizedBox(height: 2),
      Expanded(
        child: Text(
          summary ?? '들린 대사로 자막을 만들어 영상에 얹어요.',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: EditorColorTokens.muted,
            fontSize: 11,
            height: 1.3,
          ),
        ),
      ),
      SizedBox(
        width: double.infinity,
        height: 40,
        child: FilledButton.icon(
          key: const Key('editor-open-ai-caption'),
          onPressed: onOpen,
          icon: const Icon(Icons.closed_caption_rounded, size: 20),
          label: const Text('AI 자막 만들기 · 고치기'),
          style: FilledButton.styleFrom(
            backgroundColor: EditorColorTokens.sage,
            foregroundColor: EditorColorTokens.ink,
          ),
        ),
      ),
    ],
  );
}

/// AR 탭. 앱 밖으로 나가지 않고 우리 미리보기에 바로 효과를 얹는다.
class _ArPanel extends StatelessWidget {
  const _ArPanel({
    required this.activeEffectId,
    required this.onSelected,
    required this.onCleared,
  });

  final String? activeEffectId;
  final ValueChanged<EditorArEffect> onSelected;
  final VoidCallback onCleared;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // 높이를 고정한다. "효과 끄기"가 나타날 때 머리 줄이 커지면 아래
      // 카드 칸이 그만큼 줄어들어 넘친다.
      SizedBox(
        height: 24,
        child: Row(
          children: [
            const Expanded(child: _PanelTitle('AR 효과')),
            if (activeEffectId != null)
              TextButton.icon(
                key: const Key('editor-clear-ar-effect'),
                onPressed: onCleared,
                icon: const Icon(Icons.close_rounded, size: 15),
                label: const Text('효과 끄기', style: TextStyle(fontSize: 11)),
                style: TextButton.styleFrom(
                  foregroundColor: EditorColorTokens.muted,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 24),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 4),
      Expanded(
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final effect in EditorArEffect.all)
              _ArEffectCard(
                effect: effect,
                selected: effect.id == activeEffectId,
                onTap: () => onSelected(effect),
              ),
          ],
        ),
      ),
    ],
  );
}

class _ArEffectCard extends StatelessWidget {
  const _ArEffectCard({
    required this.effect,
    required this.selected,
    required this.onTap,
  });

  final EditorArEffect effect;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: InkWell(
      key: Key('editor-ar-effect-${effect.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
      child: Container(
        width: 62,
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? EditorColorTokens.selected
              : EditorColorTokens.background,
          borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
          border: Border.all(
            color: selected
                ? EditorColorTokens.coral
                : EditorColorTokens.border,
            width: selected ? 2 : 1,
          ),
        ),
        // 패널 높이는 기기마다 다르다. 좁아지면 카드 내용이 통째로 줄어든다.
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(effect.badge, style: const TextStyle(fontSize: 22)),
              const SizedBox(height: 2),
              Text(
                effect.label,
                maxLines: 1,
                style: TextStyle(
                  color: selected
                      ? EditorColorTokens.coral
                      : EditorColorTokens.ink,
                  fontSize: 10,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class EditorBottomNavigation extends StatelessWidget {
  const EditorBottomNavigation({
    super.key,
    required this.height,
    required this.selectedTool,
    required this.onSelected,
    this.fontSize = EditorTypographyTokens.navigation,
    this.iconSize = 20,
  });

  final double height;
  final EditorTool selectedTool;
  final ValueChanged<EditorTool> onSelected;
  final double fontSize;
  final double iconSize;

  static const _items = <(EditorTool, String, IconData)>[
    (EditorTool.cut, '컷 편집', Icons.content_cut_rounded),
    (EditorTool.ratio, '비율', Icons.aspect_ratio_rounded),
    (EditorTool.text, '텍스트', Icons.title_rounded),
    (EditorTool.audio, '오디오', Icons.music_note_rounded),
    (EditorTool.sticker, '스티커', Icons.emoji_emotions_outlined),
    (EditorTool.aiCaption, 'AI자막', Icons.closed_caption_rounded),
    (EditorTool.ar, 'AR', Icons.face_retouching_natural),
  ];

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: 2),
    decoration: const BoxDecoration(
      color: EditorColorTokens.surface,
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(EditorRadiusTokens.navigation),
      ),
      border: Border(top: BorderSide(color: EditorColorTokens.border)),
      boxShadow: [
        BoxShadow(
          color: EditorColorTokens.shadow,
          blurRadius: 12,
          offset: Offset(0, -3),
        ),
      ],
    ),
    child: Row(
      children: [
        for (final item in _items)
          _NavigationItem(
            tool: item.$1,
            label: item.$2,
            icon: item.$3,
            selected: selectedTool == item.$1,
            fontSize: fontSize,
            iconSize: iconSize,
            onSelected: onSelected,
          ),
      ],
    ),
  );
}

class _NavigationItem extends StatelessWidget {
  const _NavigationItem({
    required this.tool,
    required this.label,
    required this.icon,
    required this.selected,
    required this.fontSize,
    required this.iconSize,
    required this.onSelected,
  });

  final EditorTool tool;
  final String label;
  final IconData icon;
  final bool selected;
  final double fontSize;
  final double iconSize;
  final ValueChanged<EditorTool> onSelected;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      key: Key('editor-nav-${tool.name}'),
      onTap: () => onSelected(tool),
      borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 1),
        decoration: BoxDecoration(
          color: selected ? EditorColorTokens.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: iconSize,
              color: selected
                  ? EditorColorTokens.coral
                  : EditorColorTokens.muted,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
              style: TextStyle(
                color: selected
                    ? EditorColorTokens.coral
                    : EditorColorTokens.muted,
                fontSize: fontSize,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EditorIconButton extends StatelessWidget {
  const _EditorIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: EditorSpacingTokens.minimumTouch,
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 21,
      color: EditorColorTokens.ink,
      disabledColor: EditorColorTokens.border,
      icon: Icon(icon),
    ),
  );
}

class _TimelineAction extends StatelessWidget {
  const _TimelineAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: onPressed,
    icon: Icon(icon, size: 19),
    label: Text(label, style: const TextStyle(fontSize: 12)),
    style: TextButton.styleFrom(
      foregroundColor: EditorColorTokens.ink,
      disabledForegroundColor: EditorColorTokens.border,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      minimumSize: const Size(72, 36),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
  );
}

class _PanelTitle extends StatelessWidget {
  const _PanelTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(
      color: EditorColorTokens.ink,
      fontSize: EditorTypographyTokens.panelTitle,
      fontWeight: FontWeight.w600,
    ),
  );
}

class _PanelChoice extends StatelessWidget {
  const _PanelChoice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
      child: Container(
        constraints: const BoxConstraints(minWidth: 56),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? EditorColorTokens.selected : Colors.transparent,
          borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
          border: Border.all(
            color: selected
                ? EditorColorTokens.coral
                : EditorColorTokens.border,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? EditorColorTokens.coral : EditorColorTokens.ink,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    ),
  );
}

String _formatMs(int value) {
  final duration = Duration(milliseconds: value);
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
