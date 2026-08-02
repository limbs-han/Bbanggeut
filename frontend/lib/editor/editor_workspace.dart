import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'editor_ar_effects.dart';
import 'edit_recommendation_client.dart';
import 'editor_project.dart';
import 'editor_project_controller.dart';
import 'editor_tokens.dart';
import 'editor_trim_bar.dart';

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
    required this.onClipReorder,
    required this.onTrimChanged,
    required this.onTrimCommitted,
    required this.onPlayRange,
    required this.onBlocked,
    required this.onRatioSelected,
    required this.onCanvasChanged,
    required this.onCanvasReset,
    required this.onCanvasFitSelected,
    required this.presetRecommendations,
    required this.recommendationLoading,
    required this.onRecommendationSelected,
    required this.onText,
    required this.onTextEdit,
    required this.onVolumeChanged,
    required this.onMutedChanged,
    required this.onStickerSelected,
    required this.onLookSelected,
    required this.onAiCaption,
    required this.onZoomAdd,
    required this.onZoomChanged,
    required this.onZoomRemove,
    required this.onZoomSelected,
    required this.onToolSelected,
    this.onUndo,
    this.onRedo,
    this.onVolumeCommitted,
    this.textEditing = false,
    this.rangePreviewing = false,
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
  final void Function(int oldIndex, int newIndex) onClipReorder;

  /// 구간 손잡이를 끄는 동안 계속 불린다(되돌리기 이력에 쌓지 않는다).
  final void Function(int startMs, int endMs, bool startHandle) onTrimChanged;

  /// 손잡이에서 손을 뗐다. 이때 한 번만 이력에 쌓는다.
  final VoidCallback onTrimCommitted;

  /// 정해 둔 구간만 돌려 본다(구간 끝에서 선다).
  final VoidCallback onPlayRange;

  /// 지금 구간만 돌려 보는 중인가. 전체 재생과는 다른 상태다 — 위쪽 재생 단추로
  /// 튼 것을 구간 재생으로 표시하면, 정지를 눌렀을 때 엉뚱하게 구간 재생이
  /// 시작된다.
  final bool rangePreviewing;

  /// 지금은 할 수 없는 단추를 눌렀다. 왜 안 되는지 한 줄로 알려 준다.
  final ValueChanged<String> onBlocked;

  final ValueChanged<EditorCanvasRatio> onRatioSelected;
  final ValueChanged<EditorCanvas> onCanvasChanged;
  final VoidCallback onCanvasReset;
  final ValueChanged<EditorCanvasFit> onCanvasFitSelected;
  final Map<String, EditRecommendation> presetRecommendations;
  final bool recommendationLoading;
  final ValueChanged<String> onRecommendationSelected;
  final VoidCallback onText;
  final ValueChanged<String> onTextEdit;
  final ValueChanged<double> onVolumeChanged;

  /// 볼륨 손잡이에서 손을 뗐다. null이면 이력을 따로 확정하지 않는다.
  final VoidCallback? onVolumeCommitted;

  final ValueChanged<bool> onMutedChanged;
  final ValueChanged<String> onStickerSelected;

  /// 영상 전체 색감. 앱 안에서 바로 입히고 저장할 때 함께 구워진다.
  final ValueChanged<EditorLook> onLookSelected;

  /// 영상 위에서 글을 쓰는 중인가.
  ///
  /// 이때는 타임라인·도구 칸·하단 네비를 전부 접는다. 키보드와 꾸밈 줄이
  /// 이미 화면 절반을 가져가는데 아래 도구까지 남겨 두면 미리보기가 손톱만
  /// 해져서, 정작 "지금 쓰는 글이 영상 위에서 어떻게 보이는지"를 볼 수 없다.
  final bool textEditing;

  /// 되돌리기·다시 실행. null이면 컨트롤러를 바로 부른다 — 화면 쪽에서
  /// 재생 위치까지 맞추고 싶을 때만 넘기면 된다.
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;

  /// 자동 자막 화면을 여는 버튼. 자막 로직은 전부 features/stt 쪽에 있고
  /// 편집기는 버튼만 들고 있다.
  final VoidCallback onAiCaption;
  final VoidCallback onZoomAdd;
  final ValueChanged<EditorZoomSegment> onZoomChanged;
  final ValueChanged<EditorZoomSegment> onZoomRemove;
  final ValueChanged<EditorZoomSegment> onZoomSelected;

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
      // 글을 쓰는 동안에는 아래쪽을 전부 접는다. 키보드가 올라와 있으면 화면
      // 스스로도 접는다 — 둘 중 하나만 봐서는 놓치는 경우가 있어 함께 본다.
      final compact = keyboardVisible || textEditing;
      return ColoredBox(
        color: EditorColorTokens.background,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final layout = EditorLayoutTokens.fromSize(
                Size(constraints.maxWidth, constraints.maxHeight),
                keyboardVisible: keyboardVisible,
              );
              // 검은 여백을 잘라 보여 줄 수 있으면 그만큼 컷 타임라인이
              // 프레임 띠를 키운다 — 비율에 따라 배분이 달라진다.
              final trimBarBonus = compact || !cutMode
                  ? 0.0
                  : _cutTrimBarBonus(
                      layout,
                      project,
                      availableHeight: constraints.maxHeight,
                      baseTimelineHeight: _timelineHeightFor(
                        layout,
                        project,
                        cutMode,
                      ),
                    );
              final timelineHeight = compact
                  ? 0.0
                  : _timelineHeightFor(layout, project, cutMode) + trimBarBonus;
              final panelHeight = compact
                  ? 0.0
                  : _toolPanelHeightFor(
                      layout,
                      project,
                      availableHeight: constraints.maxHeight,
                      timelineHeight: timelineHeight,
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
                        onUndo: onUndo ?? controller.undo,
                        onRedo: onRedo ?? controller.redo,
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
                      if (!compact && cutMode)
                        EditorTimelineSection(
                          trimBarHeight: layout.trimBarHeight + trimBarBonus,
                          actionButtonHeight: layout.actionButtonHeight,
                          project: project,
                          thumbnails: thumbnails,
                          expanded: cutMode,
                          canDelete: controller.canDeleteSelectedClip,
                          canSplit: controller.canSplitAtPlayhead,
                          onSeek: onSeek,
                          onClipSelected: (clipId) {
                            controller.selectClip(clipId);
                            onSeek(project.timelineStartFor(clipId));
                          },
                          onSplit: onSplit,
                          onDelete: onDelete,
                          onDuplicate: onDuplicate,
                          onClipReorder: onClipReorder,
                          onTrimChanged: onTrimChanged,
                          onTrimCommitted: onTrimCommitted,
                          onPlayRange: onPlayRange,
                          rangePlaying: rangePreviewing,
                          onBlocked: onBlocked,
                          presetRecommendations: presetRecommendations,
                          recommendationLoading: recommendationLoading,
                          onRecommendationSelected: onRecommendationSelected,
                        ),
                      if (!compact)
                        SelectedToolPanel(
                          key: ValueKey(
                            'editor-selected-tool-${project.selectedTool.name}',
                          ),
                          project: project,
                          height: panelHeight,
                          onRatioSelected: onRatioSelected,
                          onCanvasChanged: onCanvasChanged,
                          onCanvasReset: onCanvasReset,
                          onCanvasFitSelected: onCanvasFitSelected,
                          onText: onText,
                          onTextEdit: onTextEdit,
                          onVolumeChanged: onVolumeChanged,
                          onMutedChanged: onMutedChanged,
                          onVolumeCommitted: onVolumeCommitted,
                          onStickerSelected: onStickerSelected,
                          onLookSelected: onLookSelected,
                          previewFrame: thumbnails.isEmpty
                              ? null
                              : thumbnails[thumbnails.length ~/ 2],
                          onAiCaption: onAiCaption,
                          aiCaptionSummary: aiCaptionSummary,
                          onZoomAdd: onZoomAdd,
                          onZoomChanged: onZoomChanged,
                          onZoomRemove: onZoomRemove,
                          onZoomSelected: onZoomSelected,
                        ),
                      if (!compact)
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

/// 편집기 위로 키보드가 올라올 때의 배치. 키보드 자리는 **여기서만** 뺀다.
///
/// **왜 Scaffold에 맡기지 않는가**: `resizeToAvoidBottomInset`을 켜 두면
/// Scaffold가 본문 높이에서 키보드만큼을 빼고, 그 대가로 본문 안쪽
/// `viewInsets.bottom`을 0으로 지운다. 그래서 두 군데가 동시에 어긋났다.
///
/// * 본문 **안**에서 읽는 편집기는 "키보드가 없다"고 믿고 타임라인·도구 칸·
///   하단 네비를 그대로 펼쳤다. 이미 줄어든 칸에 다 밀어 넣으니 미리보기가
///   손톱만 해졌다.
/// * 본문 **밖**(화면 State의 context)에서 읽으면 키보드 높이가 그대로 나온다.
///   이미 줄어든 칸에서 그만큼 또 띄우니 꾸밈 줄이 화면 위로 날아갔다.
///
/// 이제 Scaffold는 끄고 이 위젯 하나가 자리를 뺀다. [bottomBar]는 겹쳐 띄우지
/// 않고 아래에 이어 붙인다 — 겹치면 영상 아랫부분을 가린다.
class EditorKeyboardShell extends StatelessWidget {
  const EditorKeyboardShell({super.key, required this.child, this.bottomBar});

  final Widget child;

  /// 키보드 바로 위에 붙는 줄. null이면 편집기가 화면을 다 쓴다.
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    final bar = bottomBar;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        children: [
          Expanded(
            // 아래 줄이 제스처바 여백을 맡는 동안에는 편집기가 또 두지 않는다.
            // 그러지 않으면 둘 사이에 크림색 띠가 하나 생긴다.
            child: MediaQuery.removePadding(
              context: context,
              removeBottom: bar != null,
              child: child,
            ),
          ),
          ?bar,
        ],
      ),
    );
  }
}

/// 타임라인 칸이 실제로 차지할 높이.
///
/// [EditorTimelineSection]은 스스로 크기를 정하지만, 미리보기에 몇 dp가 남는지
/// **미리** 알아야 도구 칸을 얼마나 양보시킬지 정할 수 있다. 그래서 같은 셈을
/// 여기서 한 번 더 한다 — 자식이 쓰는 값과 어긋나지 않게 조각을 그대로 더한다.
double _timelineHeightFor(
  EditorLayoutTokens layout,
  EditorProject project,
  bool cutMode,
) {
  if (!cutMode) return 0;
  var height =
      EditorTimelineSection.cutHeaderHeight +
      layout.trimBarHeight +
      layout.actionButtonHeight;
  if (project.clips.length > 1) height += EditorTimelineSection.chooserHeight;
  return height;
}

/// 컷 탭 프레임 띠에 더 줄 수 있는 높이.
///
/// 캔버스의 검은 여백을 잘라 보여 줄 수 있으면([EditorPreviewGeometry])
/// 미리보기는 영상 창과 문맥 띠만큼만 있으면 된다. 남는 세로는 빈 여백으로
/// 두지 않고 프레임 띠를 키워 컷 정밀도를 높인다. 띠가 원래 높이의 갑절을
/// 넘지 않게 막는다 — 그 위로는 프레임이 커져도 얻는 것이 없다.
double _cutTrimBarBonus(
  EditorLayoutTokens layout,
  EditorProject project, {
  required double availableHeight,
  required double baseTimelineHeight,
}) {
  final geometry = EditorPreviewGeometry.of(project);
  if (!geometry.letterboxClippable) return 0;
  final innerWidth =
      layout.availableWidth -
      2 * (EditorSpacingTokens.previewHorizontal + EditorSpacingTokens.sm);
  if (innerWidth <= 0) return 0;
  // 미리보기 칸의 바깥·안쪽 세로 여백.
  const chrome = 4 * EditorSpacingTokens.sm;
  final minimumPreview = math.max(
    innerWidth /
            geometry.canvasAspectRatio *
            geometry.minimumVisibleHeightFraction +
        chrome,
    layout.minimumPreviewHeight,
  );
  final previewSlot =
      availableHeight -
      layout.topBarHeight -
      baseTimelineHeight -
      layout.bottomNavigationHeight;
  final spare = previewSlot - minimumPreview;
  if (spare <= 0) return 0;
  return math.min(spare, layout.trimBarHeight);
}

/// 도구 칸 높이. 미리보기가 [EditorLayoutTokens.minimumPreviewHeight] 밑으로
/// 내려가려 하면 도구 칸이 **먼저** 양보한다.
///
/// **왜 필요한가**: 기준으로 삼은 갤럭시 S24+(411×891dp)에서는 어느 탭을 열어도
/// 미리보기가 넉넉하다. 하지만 세로가 짧은 기기에서 AR 탭(한 뼘 더 쓴다)을 열면
/// 남는 자리가 미리보기의 몫을 파고들어, 영상이 띠처럼 눌린다. 편집기에서 가장
/// 중요한 건 "지금 영상이 어떻게 보이는가"이므로 그 자리를 먼저 지킨다.
double _toolPanelHeightFor(
  EditorLayoutTokens layout,
  EditorProject project, {
  required double availableHeight,
  required double timelineHeight,
}) {
  if (project.selectedTool == EditorTool.cut) return 0;
  // AR 탭은 필터 줄과 마스크 줄을 함께 담아야 해서 한 뼘 더 쓴다.
  final wanted = switch (project.selectedTool) {
    EditorTool.zoom => layout.toolPanelHeight * 1.95,
    EditorTool.ratio => layout.toolPanelHeight * 1.15,
    EditorTool.ar => layout.toolPanelHeight * 1.6,
    _ => layout.toolPanelHeight,
  };
  final leftover =
      availableHeight -
      layout.topBarHeight -
      timelineHeight -
      wanted -
      layout.bottomNavigationHeight;
  if (leftover >= layout.minimumPreviewHeight) return wanted;
  // 다 양보해도 모자랄 수 있다. 그래도 도구 자체는 쓸 수 있어야 하므로
  // 한 줄 높이는 남긴다.
  return math.max(
    EditorLayoutTokens.minimumToolPanelHeight,
    wanted - (layout.minimumPreviewHeight - leftover),
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

/// 캔버스를 폭에 맞춰 그리고, 세로로 넘치는 검은 여백은 잘라 보여 준다.
///
/// [child]는 캔버스 비율의 상자를 가정한 내용(영상 창 + 레이어)이다. 잘라도
/// 되는 조건과 남기는 최소 범위는 [EditorPreviewGeometry]가 정한다. 잘린
/// 위아래 가장자리에는 옅은 그러데이션을 얹어 "캔버스가 더 있다"를 알린다.
class EditorCanvasViewport extends StatelessWidget {
  const EditorCanvasViewport({
    super.key,
    required this.geometry,
    required this.child,
  });

  final EditorPreviewGeometry geometry;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final availWidth = math.max(1.0, constraints.maxWidth);
      final availHeight = math.max(1.0, constraints.maxHeight);
      final aspect = geometry.canvasAspectRatio;
      var contentWidth = availWidth;
      var contentHeight = contentWidth / aspect;
      if (contentHeight > availHeight) {
        if (!geometry.letterboxClippable) {
          // 전체 캔버스를 보여 줘야 한다 — 예전처럼 높이에 맞춘다.
          contentHeight = availHeight;
          contentWidth = contentHeight * aspect;
        } else {
          final minHeight =
              contentHeight * geometry.minimumVisibleHeightFraction;
          if (minHeight > availHeight) {
            // 영상 창과 문맥 띠조차 안 들어가면 그만큼만 폭을 줄인다.
            final scale = availHeight / minHeight;
            contentWidth *= scale;
            contentHeight *= scale;
          }
        }
      }
      final viewportHeight = math.min(contentHeight, availHeight);
      final clipped = contentHeight - viewportHeight > 0.5;
      return Center(
        child: SizedBox(
          key: const Key('editor-canvas-viewport'),
          width: contentWidth,
          height: viewportHeight,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(EditorRadiusTokens.video),
            child: Stack(
              fit: StackFit.expand,
              children: [
                OverflowBox(
                  alignment: Alignment.center,
                  minWidth: contentWidth,
                  maxWidth: contentWidth,
                  minHeight: contentHeight,
                  maxHeight: contentHeight,
                  child: SizedBox(
                    width: contentWidth,
                    height: contentHeight,
                    child: child,
                  ),
                ),
                if (clipped) ...const [
                  _CanvasClipHint(top: true),
                  _CanvasClipHint(top: false),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// 잘린 캔버스 가장자리 표시. 만질 수 없는 안내이므로 입력은 통과시킨다.
class _CanvasClipHint extends StatelessWidget {
  const _CanvasClipHint({required this.top});

  final bool top;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    top: top ? 0 : null,
    bottom: top ? null : 0,
    height: 12,
    child: IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: top ? Alignment.topCenter : Alignment.bottomCenter,
            end: top ? Alignment.bottomCenter : Alignment.topCenter,
            colors: const [Color(0x59FFFFFF), Color(0x00FFFFFF)],
          ),
        ),
      ),
    ),
  );
}

/// 컷 편집 타임라인.
///
/// **왜 원본 전체를 그리는가**: 예전 띠는 "잘라낸 뒤의 길이"를 폭 전체에
/// 펼쳤다. 손잡이를 끌면 클립이 짧아지고, 짧아진 만큼 눈금이 다시 늘어나
/// 손잡이가 손가락에서 달아났다 — 구간이 아예 안 잡혔던 이유다. 이제
/// [TrimRangeBar]가 원본 전체를 담고 노란 창만 움직인다. 창을 다시 벌리면
/// 잘랐던 앞뒤가 그대로 되살아난다.
///
/// **왜 높이를 스스로 정하는가**: 칸에 정해진 높이를 주면 띠와 버튼이 쓰고
/// 남은 자리가 빈칸으로 남는다. 여기서는 띠 한 줄과 버튼 줄을 더한 만큼만
/// 차지하고, 남는 세로는 전부 미리보기가 가져간다. 띠 안쪽도 프레임이 위아래
/// 끝까지 채운다.
///
/// 정해진 구간은 클립에 남으므로 다른 탭으로 넘어가도 유지되고, 접힌 띠에도
/// 같은 창이 그려져 "지금 어디를 편집 중인지"가 계속 보인다.
class EditorTimelineSection extends StatelessWidget {
  const EditorTimelineSection({
    super.key,
    required this.trimBarHeight,
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
    required this.onClipReorder,
    required this.onTrimChanged,
    required this.onTrimCommitted,
    required this.onPlayRange,
    required this.rangePlaying,
    required this.onBlocked,
    required this.presetRecommendations,
    required this.recommendationLoading,
    required this.onRecommendationSelected,
  });

  /// 클립 고르는 줄(여백 포함)의 높이. 클립이 둘 이상일 때만 붙는다.
  static const chooserHeight = 44.0;
  static const cutHeaderHeight = 46.0;
  static const overviewHeight = 46.0;

  /// 지금 나눌 수 없는 이유. null이면 나눌 수 있다.
  static const splitBlockedReason = '나눌 자리를 먼저 정해요. 띠를 눌러 흰 선을 구간 안쪽으로 옮겨 보세요.';

  /// 지금 지울 수 없는 이유.
  static const deleteBlockedReason = '지울 것이 없어요. 구간을 좁히거나 클립을 나눈 뒤에 지울 수 있어요.';

  final double trimBarHeight;
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
  final void Function(int oldIndex, int newIndex) onClipReorder;
  final void Function(int startMs, int endMs, bool startHandle) onTrimChanged;
  final VoidCallback onTrimCommitted;

  /// 정해 둔 구간만 돌려 본다.
  final VoidCallback onPlayRange;
  final bool rangePlaying;

  /// 흐린 단추를 눌렀다. 왜 안 되는지 한 줄로 알려 준다.
  final ValueChanged<String> onBlocked;
  final Map<String, EditRecommendation> presetRecommendations;
  final bool recommendationLoading;
  final ValueChanged<String> onRecommendationSelected;

  @override
  Widget build(BuildContext context) {
    final selected = project.selectedClip;
    final multipleClips = project.clips.length > 1;
    return ColoredBox(
      color: EditorColorTokens.background,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (expanded)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: SizedBox(
                height: cutHeaderHeight,
                child: _CutPrecisionToolbar(
                  project: project,
                  recommendations: presetRecommendations,
                  loading: recommendationLoading,
                  onPresetSelected: onRecommendationSelected,
                  onSeek: onSeek,
                ),
              ),
            ),
          if (expanded && multipleClips)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
              child: SizedBox(
                height: chooserHeight - 6,
                child: ClipChooser(
                  project: project,
                  onClipSelected: onClipSelected,
                  onReorder: onClipReorder,
                ),
              ),
            ),
          if (expanded)
            Padding(
              // 시스템 뒤로가기 제스처 영역과 손잡이 터치 영역을 분리한다.
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: SizedBox(
                height: trimBarHeight,
                child: selected == null
                    ? const ColoredBox(color: EditorColorTokens.border)
                    : TrimRangeBar(
                        sourceDurationMs: project.sourceDurationMs,
                        startMs: selected.sourceStartMs,
                        endMs: selected.sourceEndMs,
                        playheadSourceMs: _playheadSourceMs(selected),
                        thumbnails: thumbnails,
                        recommendationMarker: project.recommendationMarker,
                        zoomSegments: project.zoomSegments,
                        minimumDurationMs:
                            EditorProjectController.minimumClipDurationMs,
                        onTrimChanged: onTrimChanged,
                        onTrimCommitted: onTrimCommitted,
                        // 끝을 1ms 남긴다. 딱 끝까지 밀면 그 시각은 다음 클립의
                        // 시작이라 고른 클립이 바뀐다 — 재생 봉을 오른쪽 끝으로
                        // 옮겼을 뿐인데 편집 대상이 넘어가면 당황스럽다.
                        onScrub: (sourceMs) => onSeek(
                          project.timelineStartFor(selected.id) +
                              (sourceMs - selected.sourceStartMs).clamp(
                                0,
                                math.max(0, selected.durationMs - 1),
                              ),
                        ),
                      ),
              ),
            ),
          if (expanded)
            SizedBox(
              height: actionButtonHeight,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _TimelineAction(
                    key: const Key('editor-play-range'),
                    label: rangePlaying ? '정지' : '구간 재생',
                    icon: rangePlaying
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline_rounded,
                    onPressed: selected == null ? null : onPlayRange,
                  ),
                  _TimelineAction(
                    key: const Key('editor-split-clip'),
                    label: '분할',
                    icon: Icons.content_cut_rounded,
                    onPressed: canSplit ? onSplit : null,
                    // 흐린 단추도 눌리게 둔다. 아무 반응이 없으면 "고장"으로
                    // 읽히지만, 왜 안 되는지 알려 주면 다음에 뭘 할지 알 수 있다.
                    blockedReason: splitBlockedReason,
                    onBlocked: onBlocked,
                  ),
                  _TimelineAction(
                    key: const Key('editor-duplicate-clip'),
                    label: '복제',
                    icon: Icons.copy_rounded,
                    onPressed: selected == null ? null : onDuplicate,
                  ),
                  _TimelineAction(
                    key: const Key('editor-delete-clip'),
                    label: '삭제',
                    icon: Icons.delete_outline_rounded,
                    onPressed: canDelete ? onDelete : null,
                    blockedReason: deleteBlockedReason,
                    onBlocked: onBlocked,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 재생 위치를 고른 클립의 원본 시각으로 옮긴다. 띠는 원본 눈금을 쓴다.
  int _playheadSourceMs(EditorClip clip) {
    final offset = project.playheadMs - project.timelineStartFor(clip.id);
    return clip.sourceStartMs + offset.clamp(0, clip.durationMs);
  }
}

class _CutPrecisionToolbar extends StatelessWidget {
  const _CutPrecisionToolbar({
    required this.project,
    required this.recommendations,
    required this.loading,
    required this.onPresetSelected,
    required this.onSeek,
  });

  static const frameRate = 30;

  final EditorProject project;
  final Map<String, EditRecommendation> recommendations;
  final bool loading;
  final ValueChanged<String> onPresetSelected;
  final ValueChanged<int> onSeek;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      color: Color(0xFF2A2420),
      borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      child: Row(
        children: [
          for (final entry in const [
            ('short', '짧게'),
            ('medium', '중간'),
            ('long', '길게'),
          ]) ...[
            _TimelinePresetChip(
              key: Key('editor-preset-${entry.$1}'),
              label: entry.$2,
              selected: project.recommendationMarker?.preset == entry.$1,
              enabled: !loading && recommendations.containsKey(entry.$1),
              onTap: () => onPresetSelected(entry.$1),
            ),
            const SizedBox(width: 3),
          ],
          const Spacer(),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _frameTimecode(project.playheadMs),
                key: const Key('editor-frame-timecode'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                '30 fps · F${_frameOf(project.playheadMs)}',
                style: const TextStyle(
                  color: Color(0xFFBFB5AE),
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(width: 5),
          _FrameStepButton(
            key: const Key('editor-frame-back'),
            icon: Icons.chevron_left_rounded,
            tooltip: '1프레임 뒤로',
            onTap: () => _stepFrames(-1),
          ),
          _FrameStepButton(
            key: const Key('editor-frame-forward'),
            icon: Icons.chevron_right_rounded,
            tooltip: '1프레임 앞으로',
            onTap: () => _stepFrames(1),
          ),
        ],
      ),
    ),
  );

  int _frameOf(int milliseconds) => (milliseconds * frameRate / 1000).round();

  String _frameTimecode(int milliseconds) {
    final totalFrames = _frameOf(milliseconds);
    final frames = totalFrames % frameRate;
    final totalSeconds = totalFrames ~/ frameRate;
    final seconds = totalSeconds % 60;
    final minutes = (totalSeconds ~/ 60) % 60;
    final hours = totalSeconds ~/ 3600;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(hours)}:${two(minutes)}:${two(seconds)}:${two(frames)}';
  }

  void _stepFrames(int delta) {
    final nextFrame = math.max(0, _frameOf(project.playheadMs) + delta);
    onSeek((nextFrame * 1000 / frameRate).round().clamp(0, project.durationMs));
  }
}

class _TimelinePresetChip extends StatelessWidget {
  const _TimelinePresetChip({
    super.key,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? EditorColorTokens.coral : const Color(0xFF49403B),
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        width: 38,
        height: 21,
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: enabled ? Colors.white : const Color(0xFF77706B),
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    ),
  );
}

class _FrameStepButton extends StatelessWidget {
  const _FrameStepButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: const Color(0xFF49403B),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 27,
          height: 27,
          child: Icon(icon, color: Colors.white, size: 19),
        ),
      ),
    ),
  );
}

/// 분할한 클립이 둘 이상일 때 나오는 고르개.
///
/// 구간 막대는 언제나 **고른 클립 하나**를 다룬다. 그래서 어느 클립을 만지고
/// 있는지 고를 방법이 있어야 한다 — 예전 띠가 겸하던 일이다.
class ClipChooser extends StatelessWidget {
  const ClipChooser({
    super.key,
    required this.project,
    required this.onClipSelected,
    required this.onReorder,
  });

  final EditorProject project;
  final ValueChanged<String> onClipSelected;
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = project.clips.indexWhere(
      (clip) => clip.id == project.selectedClipId,
    );
    return Row(
      children: [
        Container(
          key: const Key('editor-active-clip'),
          width: 66,
          height: double.infinity,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: EditorColorTokens.coral,
            borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
          ),
          child: Text(
            '클립 ${selectedIndex + 1}/${project.clips.length}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            onReorderItem: onReorder,
            itemCount: project.clips.length,
            itemBuilder: (context, index) {
              final clip = project.clips[index];
              return Padding(
                key: Key('editor-clip-${clip.id}'),
                padding: const EdgeInsets.only(right: 6),
                child: _ClipChip(
                  number: index + 1,
                  sourceRange:
                      '${_formatMs(clip.sourceStartMs)}–${_formatMs(clip.sourceEndMs)}',
                  selected: clip.id == project.selectedClipId,
                  canMoveLeft: index > 0,
                  canMoveRight: index < project.clips.length - 1,
                  onMoveLeft: () => onReorder(index, index - 1),
                  onMoveRight: () => onReorder(index, index + 1),
                  dragHandle: ReorderableDragStartListener(
                    key: Key('editor-clip-drag-${clip.id}'),
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        Icons.drag_indicator_rounded,
                        size: 18,
                        color: EditorColorTokens.muted,
                      ),
                    ),
                  ),
                  onTap: () => onClipSelected(clip.id),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ClipChip extends StatelessWidget {
  const _ClipChip({
    required this.number,
    required this.sourceRange,
    required this.selected,
    required this.onTap,
    required this.canMoveLeft,
    required this.canMoveRight,
    required this.onMoveLeft,
    required this.onMoveRight,
    required this.dragHandle,
  });

  final int number;
  final String sourceRange;
  final bool selected;
  final VoidCallback onTap;
  final bool canMoveLeft;
  final bool canMoveRight;
  final VoidCallback onMoveLeft;
  final VoidCallback onMoveRight;
  final Widget dragHandle;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
    child: Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: selected ? EditorColorTokens.coral : const Color(0xFF26211E),
        borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
        border: Border.all(
          color: selected ? Colors.white : EditorColorTokens.border,
          width: selected ? 2 : 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected)
            _TinyMoveButton(
              icon: Icons.chevron_left_rounded,
              enabled: canMoveLeft,
              onTap: onMoveLeft,
            ),
          SizedBox(
            width: 72,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '클립 $number',
                  style: TextStyle(
                    color: selected ? Colors.white : EditorColorTokens.muted,
                    fontSize: 9,
                    height: 1,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  sourceRange,
                  style: TextStyle(
                    color: selected ? Colors.white70 : EditorColorTokens.muted,
                    fontSize: 7,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
          dragHandle,
          if (selected)
            _TinyMoveButton(
              icon: Icons.chevron_right_rounded,
              enabled: canMoveRight,
              onTap: onMoveRight,
            ),
        ],
      ),
    ),
  );
}

class _TinyMoveButton extends StatelessWidget {
  const _TinyMoveButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: enabled ? onTap : null,
    child: Icon(
      icon,
      size: 17,
      color: enabled ? EditorColorTokens.coral : EditorColorTokens.border,
    ),
  );
}

class SelectedToolPanel extends StatelessWidget {
  const SelectedToolPanel({
    super.key,
    required this.project,
    required this.height,
    required this.onRatioSelected,
    required this.onCanvasChanged,
    required this.onCanvasReset,
    required this.onCanvasFitSelected,
    required this.onText,
    required this.onTextEdit,
    required this.onVolumeChanged,
    required this.onMutedChanged,
    required this.onStickerSelected,
    required this.onLookSelected,
    required this.onAiCaption,
    required this.onZoomAdd,
    required this.onZoomChanged,
    required this.onZoomRemove,
    required this.onZoomSelected,
    this.previewFrame,
    this.onVolumeCommitted,
    this.aiCaptionSummary,
  });

  final EditorProject project;
  final double height;
  final ValueChanged<EditorCanvasRatio> onRatioSelected;
  final ValueChanged<EditorCanvas> onCanvasChanged;
  final VoidCallback onCanvasReset;
  final ValueChanged<EditorCanvasFit> onCanvasFitSelected;
  final VoidCallback onText;
  final ValueChanged<String> onTextEdit;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback? onVolumeCommitted;
  final ValueChanged<bool> onMutedChanged;
  final ValueChanged<String> onStickerSelected;
  final ValueChanged<EditorLook> onLookSelected;
  final String? previewFrame;
  final VoidCallback onAiCaption;
  final VoidCallback onZoomAdd;
  final ValueChanged<EditorZoomSegment> onZoomChanged;
  final ValueChanged<EditorZoomSegment> onZoomRemove;
  final ValueChanged<EditorZoomSegment> onZoomSelected;
  final String? aiCaptionSummary;

  @override
  Widget build(BuildContext context) {
    if (project.selectedTool == EditorTool.cut) {
      return const SizedBox.shrink();
    }
    return Container(
      // 높이는 화면이 정해 준다. 탭마다 필요한 만큼 주되(AR은 한 뼘 더),
      // 미리보기가 눌릴 상황이면 여기부터 줄어든다 — 그 셈은 화면 쪽에 있다.
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
      child: KeyedSubtree(
        // 캔버스와 줌은 모두 스크롤 가능한 패널이다. 키가 없으면 Flutter가
        // 이전 탭의 스크롤 위치를 다음 탭에 재사용해 내용이 화면 밖에서 시작한다.
        key: ValueKey('editor-tool-panel-${project.selectedTool.name}'),
        child: switch (project.selectedTool) {
          EditorTool.ratio => _RatioPanel(
            canvas: project.canvas,
            onSelected: onRatioSelected,
            onFitSelected: onCanvasFitSelected,
          ),
          EditorTool.text => _TextPanel(
            project: project,
            onText: onText,
            onTextEdit: onTextEdit,
          ),
          EditorTool.zoom => _SimpleZoomPanel(
            project: project,
            canvas: project.canvas,
            onCanvasChanged: onCanvasChanged,
            onCanvasReset: onCanvasReset,
            onAdd: onZoomAdd,
            onChanged: onZoomChanged,
            onRemove: onZoomRemove,
            onSelected: onZoomSelected,
          ),
          EditorTool.audio => _AudioPanel(
            audio: project.audio,
            onVolumeChanged: onVolumeChanged,
            onVolumeCommitted: onVolumeCommitted,
            onMutedChanged: onMutedChanged,
          ),
          EditorTool.sticker => _StickerPanel(onSelected: onStickerSelected),
          EditorTool.aiCaption => _AiCaptionPanel(
            summary: aiCaptionSummary,
            onOpen: onAiCaption,
          ),
          EditorTool.ar => _ArPanel(
            look: project.look,
            previewFrame: previewFrame,
            onLookSelected: onLookSelected,
          ),
          EditorTool.cut => const SizedBox.shrink(),
        },
      ),
    );
  }
}

class _RatioPanel extends StatelessWidget {
  const _RatioPanel({
    required this.canvas,
    required this.onSelected,
    required this.onFitSelected,
  });

  final EditorCanvas canvas;
  final ValueChanged<EditorCanvasRatio> onSelected;
  final ValueChanged<EditorCanvasFit> onFitSelected;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Expanded(child: _PanelTitle('캔버스 · 비율과 영상 영역')),
          const _LiveAppliedBadge(),
        ],
      ),
      const Text(
        '출력 비율과 가로 영상의 표시 영역만 정합니다. 이동·확대·회전은 구간 줌에서 조절합니다.',
        style: TextStyle(color: EditorColorTokens.muted, fontSize: 9),
      ),
      const SizedBox(height: 5),
      SizedBox(
        height: 36,
        child: Row(
          children: [
            for (final entry in const [
              (EditorCanvasRatio.original, '원본', Icons.crop_original),
              (EditorCanvasRatio.vertical, '9:16', Icons.crop_portrait),
              (EditorCanvasRatio.landscape, '16:9', Icons.crop_landscape),
            ]) ...[
              Expanded(
                child: _PanelChoice(
                  label: entry.$2,
                  icon: entry.$3,
                  selected: canvas.ratio == entry.$1,
                  onTap: () => onSelected(entry.$1),
                ),
              ),
              if (entry.$1 != EditorCanvasRatio.landscape)
                const SizedBox(width: 5),
            ],
          ],
        ),
      ),
      if (canvas.ratio == EditorCanvasRatio.vertical) ...[
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: _PanelChoice(
                label: '채우기',
                icon: Icons.fullscreen_rounded,
                selected: canvas.fit == EditorCanvasFit.cover,
                onTap: () => onFitSelected(EditorCanvasFit.cover),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _PanelChoice(
                label: '가로 영상 전체 보기',
                icon: Icons.fit_screen_rounded,
                selected: canvas.fit == EditorCanvasFit.contain,
                onTap: () => onFitSelected(EditorCanvasFit.contain),
              ),
            ),
          ],
        ),
      ],
    ],
  );
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkResponse(
    onTap: onTap,
    radius: 18,
    child: SizedBox(
      width: 25,
      height: 40,
      child: Icon(icon, size: 15, color: EditorColorTokens.coral),
    ),
  );
}

class _SimpleZoomPanel extends StatelessWidget {
  const _SimpleZoomPanel({
    required this.project,
    required this.canvas,
    required this.onCanvasChanged,
    required this.onCanvasReset,
    required this.onAdd,
    required this.onChanged,
    required this.onRemove,
    required this.onSelected,
  });

  final EditorProject project;
  final EditorCanvas canvas;
  final ValueChanged<EditorCanvas> onCanvasChanged;
  final VoidCallback onCanvasReset;
  final VoidCallback onAdd;
  final ValueChanged<EditorZoomSegment> onChanged;
  final ValueChanged<EditorZoomSegment> onRemove;
  final ValueChanged<EditorZoomSegment> onSelected;

  @override
  Widget build(BuildContext context) {
    final zooms = project.zoomSegments.take(20).toList(growable: false);
    var index = zooms.indexWhere((zoom) => zoom.id == project.selectedZoomId);
    if (index < 0 && zooms.isNotEmpty) index = 0;
    final active = index < 0 ? null : zooms[index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: _PanelTitle('이동 · 회전 · 구간 줌')),
            if (active != null) ...[
              IconButton(
                tooltip: '이전 줌',
                onPressed: index > 0
                    ? () => onSelected(zooms[index - 1])
                    : null,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_left_rounded, size: 18),
              ),
              Text(
                '${index + 1}/${zooms.length}',
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                ),
              ),
              IconButton(
                tooltip: '다음 줌',
                onPressed: index + 1 < zooms.length
                    ? () => onSelected(zooms[index + 1])
                    : null,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.chevron_right_rounded, size: 18),
              ),
            ],
            IconButton(
              tooltip: '이동·확대·회전 초기화',
              onPressed: onCanvasReset,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.refresh_rounded, size: 16),
            ),
            FilledButton(
              key: const Key('editor-add-zoom'),
              onPressed: onAdd,
              style: FilledButton.styleFrom(
                minimumSize: const Size(64, 32),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                textStyle: const TextStyle(fontSize: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('줌 추가'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: _CompactStepper(
                label: '확대',
                value: '${canvas.scale.toStringAsFixed(2)}×',
                onDecrease: () => onCanvasChanged(
                  canvas.copyWith(
                    scale: math.max(canvas.minimumScale, canvas.scale - 0.05),
                  ),
                ),
                onIncrease: () => onCanvasChanged(
                  canvas.copyWith(scale: math.min(4, canvas.scale + 0.05)),
                ),
              ),
            ),
            Expanded(
              child: _CompactStepper(
                label: '좌우',
                value: canvas.offsetX.toStringAsFixed(2),
                onDecrease: () => onCanvasChanged(
                  canvas.copyWith(offsetX: math.max(-1, canvas.offsetX - 0.05)),
                ),
                onIncrease: () => onCanvasChanged(
                  canvas.copyWith(offsetX: math.min(1, canvas.offsetX + 0.05)),
                ),
              ),
            ),
            Expanded(
              child: _CompactStepper(
                label: '상하',
                value: canvas.offsetY.toStringAsFixed(2),
                onDecrease: () => onCanvasChanged(
                  canvas.copyWith(offsetY: math.max(-1, canvas.offsetY - 0.05)),
                ),
                onIncrease: () => onCanvasChanged(
                  canvas.copyWith(offsetY: math.min(1, canvas.offsetY + 0.05)),
                ),
              ),
            ),
            Expanded(
              child: _CompactStepper(
                label: '회전',
                value: '${canvas.rotationDegrees.round()}°',
                onDecrease: () => onCanvasChanged(
                  canvas.copyWith(
                    rotationDegrees: math.max(-180, canvas.rotationDegrees - 1),
                  ),
                ),
                onIncrease: () => onCanvasChanged(
                  canvas.copyWith(
                    rotationDegrees: math.min(180, canvas.rotationDegrees + 1),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        if (active == null)
          const Expanded(child: Center(child: Text('재생 위치에서 줌을 추가하세요.')))
        else
          Row(
            key: const Key('editor-zoom-frame-controls'),
            children: [
              Expanded(
                child: _CompactStepper(
                  label: '시작 1f',
                  value: _frameTime(active.sourceStartMs),
                  onDecrease: () => onChanged(
                    active.copyWith(
                      sourceStartMs: _stepFrame(
                        active.sourceStartMs,
                        -1,
                        project.sourceDurationMs,
                      ),
                    ),
                  ),
                  onIncrease: () => onChanged(
                    active.copyWith(
                      sourceStartMs: math.min(
                        _stepFrame(
                          active.sourceStartMs,
                          1,
                          project.sourceDurationMs,
                        ),
                        _stepFrame(
                          active.sourceEndMs,
                          -1,
                          project.sourceDurationMs,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _CompactStepper(
                  label: '끝 1f',
                  value: _frameTime(active.sourceEndMs),
                  onDecrease: () => onChanged(
                    active.copyWith(
                      sourceEndMs: math.max(
                        _stepFrame(
                          active.sourceEndMs,
                          -1,
                          project.sourceDurationMs,
                        ),
                        _stepFrame(
                          active.sourceStartMs,
                          1,
                          project.sourceDurationMs,
                        ),
                      ),
                    ),
                  ),
                  onIncrease: () => onChanged(
                    active.copyWith(
                      sourceEndMs: _stepFrame(
                        active.sourceEndMs,
                        1,
                        project.sourceDurationMs,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: _CompactStepper(
                  label: '구간 확대',
                  value: '${active.scale.toStringAsFixed(2)}×',
                  onDecrease: () => onChanged(
                    active.copyWith(scale: math.max(1.05, active.scale - 0.05)),
                  ),
                  onIncrease: () => onChanged(
                    active.copyWith(scale: math.min(2.8, active.scale + 0.05)),
                  ),
                ),
              ),
              IconButton(
                tooltip: '줌 삭제',
                onPressed: () => onRemove(active),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
              ),
            ],
          ),
      ],
    );
  }

  static int _stepFrame(int milliseconds, int delta, int maximum) {
    final frame =
        (milliseconds * _CutPrecisionToolbar.frameRate / 1000).round() + delta;
    return (frame * 1000 / _CutPrecisionToolbar.frameRate).round().clamp(
      0,
      maximum,
    );
  }

  static String _frameTime(int milliseconds) {
    final frame = (milliseconds * _CutPrecisionToolbar.frameRate / 1000)
        .round();
    final seconds = frame ~/ _CutPrecisionToolbar.frameRate;
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}:${(frame % _CutPrecisionToolbar.frameRate).toString().padLeft(2, '0')}';
  }
}

class _CompactStepper extends StatelessWidget {
  const _CompactStepper({
    required this.label,
    required this.value,
    required this.onDecrease,
    required this.onIncrease,
  });

  final String label;
  final String value;
  final VoidCallback onDecrease;
  final VoidCallback onIncrease;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: Row(
      children: [
        _StepButton(icon: Icons.remove_rounded, onTap: onDecrease),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(label, maxLines: 1, style: const TextStyle(fontSize: 8)),
              Text(
                value,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        _StepButton(icon: Icons.add_rounded, onTap: onIncrease),
      ],
    ),
  );
}

class _TextPanel extends StatelessWidget {
  const _TextPanel({
    required this.project,
    required this.onText,
    required this.onTextEdit,
  });

  final EditorProject project;
  final VoidCallback onText;
  final ValueChanged<String> onTextEdit;

  /// 추가 버튼은 고정 높이 SizedBox로 감싸지 않는다.
  ///
  /// **왜**: 도구 패널 제목 줄에서 `SizedBox(height: N)` 안에 FilledButton을
  /// 넣으면 실기기(S24+)에서 이 탭의 프레임 레이아웃이 예외도 없이 끝나지
  /// 않은 채 남아, 패널·하단 네비가 그려지지 않고 화면이 멈춘 것처럼 보였다.
  /// 예전 _ZoomPanel의 "빈 패널·입력 정지"도 같은 조합이 원인이었다. 버튼
  /// 크기는 스타일의 minimumSize로 정한다.
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Expanded(child: _PanelTitle('텍스트 레이어')),
          Text(
            '${project.textLayers.length}개',
            style: const TextStyle(
              color: EditorColorTokens.muted,
              fontSize: 10,
            ),
          ),
          const SizedBox(width: 6),
          FilledButton(
            key: const Key('editor-open-text-sheet'),
            onPressed: onText,
            style: FilledButton.styleFrom(
              minimumSize: const Size(64, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              textStyle: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('+ 추가'),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Expanded(
        child: project.textLayers.isEmpty
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF7F1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: EditorColorTokens.border),
                ),
                child: const Center(
                  child: Text(
                    '+ 추가를 눌러 영상 위에서 바로 입력하세요',
                    style: TextStyle(
                      color: EditorColorTokens.muted,
                      fontSize: 10,
                    ),
                  ),
                ),
              )
            : ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: project.textLayers.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (context, index) {
                  final layer = project.textLayers[index];
                  return InkWell(
                    key: Key('editor-edit-text-${layer.id}'),
                    onTap: () => onTextEdit(layer.id),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 150,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: project.selectedLayerId == layer.id
                            ? EditorColorTokens.selected
                            : const Color(0xFFFFF7F1),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: project.selectedLayerId == layer.id
                              ? EditorColorTokens.coral
                              : EditorColorTokens.border,
                        ),
                      ),
                      child: Row(
                        children: [
                          Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: EditorColorTokens.coral,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              layer.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                          const Icon(Icons.edit_rounded, size: 14),
                        ],
                      ),
                    ),
                  );
                },
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
    this.onVolumeCommitted,
  });

  final EditorAudio audio;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback? onVolumeCommitted;
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
          // 손잡이를 끄는 동안 이력을 쌓으면 되돌리기 한 번이 1% 뒤로만
          // 간다. 손을 뗄 때 한 칸으로 확정한다.
          onChangeEnd: audio.muted || onVolumeCommitted == null
              ? null
              : (_) => onVolumeCommitted!(),
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

  static const _base = ['😊', '😂', '❤️', '⭐', '👏', '🌸', '🍰', '🐱', '👍'];

  /// 기본 스티커와 꾸미기 이모지를 한 곳에 모은다.
  static List<String> get _stickers => [
    ..._base,
    for (final value in EditorArEffect.stickerValues)
      if (!_base.contains(value)) value,
    for (final effect in EditorArEffect.all)
      if (!_base.contains(effect.badge) &&
          !EditorArEffect.stickerValues.contains(effect.badge))
        effect.badge,
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
      // 고정 높이 SizedBox로 버튼을 감싸지 않는다 — _TextPanel 주석 참고.
      FilledButton.icon(
        key: const Key('editor-open-ai-caption'),
        onPressed: onOpen,
        icon: const Icon(Icons.closed_caption_rounded, size: 20),
        label: const Text('AI 자막 만들기 · 고치기'),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(40),
          backgroundColor: EditorColorTokens.sage,
          foregroundColor: EditorColorTokens.ink,
        ),
      ),
    ],
  );
}

/// 인앱 색감 효과 탭.
///
/// **왜 필터가 먼저인가**: 여기서 누른 것은 화면을 벗어나지 않고 그 자리에서
/// 바로 영상에 입혀져야 한다. 색감 필터는 우리 미리보기가 직접 그리고
/// 내보내기(media3)가 같은 값으로 구워 주므로 즉시 적용이 된다. 카드에 깔리는
/// 그림은 남의 스크린샷이 아니라 **지금 편집 중인 영상의 실제 프레임**이다 —
/// 누르기 전에 결과를 그대로 본다.
class _ArPanel extends StatelessWidget {
  const _ArPanel({
    required this.look,
    required this.previewFrame,
    required this.onLookSelected,
  });

  final EditorLook look;

  /// 필터 카드에 깔 프레임. 아직 없으면 색만 있는 칸으로 그린다.
  final String? previewFrame;

  final ValueChanged<EditorLook> onLookSelected;

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.zero,
    children: [
      SizedBox(
        height: 20,
        child: Row(
          children: [
            const Expanded(child: _PanelTitle('효과 · 누르면 바로 적용')),
            if (look != EditorLook.none)
              TextButton(
                key: const Key('editor-clear-look'),
                onPressed: () => onLookSelected(EditorLook.none),
                style: TextButton.styleFrom(
                  foregroundColor: EditorColorTokens.muted,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 20),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('끄기', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
      ),
      const SizedBox(height: 6),
      SizedBox(
        height: 58,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            for (final option in EditorLook.values)
              _LookCard(
                look: option,
                frame: previewFrame,
                selected: option == look,
                onTap: () => onLookSelected(option),
              ),
          ],
        ),
      ),
      const SizedBox(height: 4),
    ],
  );
}

/// 색감 카드. 지금 편집 중인 영상 프레임에 그 색감을 그대로 입혀 보여 준다.
class _LookCard extends StatelessWidget {
  const _LookCard({
    required this.look,
    required this.frame,
    required this.selected,
    required this.onTap,
  });

  final EditorLook look;
  final String? frame;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final path = frame;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        key: Key('editor-look-${look.name}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
        child: SizedBox(
          width: 54,
          child: Column(
            children: [
              Expanded(
                child: Container(
                  width: 50,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      EditorRadiusTokens.control,
                    ),
                    border: Border.all(
                      color: selected
                          ? EditorColorTokens.coral
                          : EditorColorTokens.border,
                      width: selected ? 2.5 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      EditorRadiusTokens.control - 1,
                    ),
                    child: path == null
                        ? const ColoredBox(color: EditorColorTokens.border)
                        : ColorFiltered(
                            colorFilter: look.colorFilter,
                            child: Image.file(
                              File(path),
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              filterQuality: FilterQuality.low,
                              errorBuilder: (_, _, _) => const ColoredBox(
                                color: EditorColorTokens.border,
                              ),
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                look.label,
                maxLines: 1,
                style: TextStyle(
                  color: selected
                      ? EditorColorTokens.coral
                      : EditorColorTokens.ink,
                  fontSize: 10,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
    (EditorTool.cut, '컷', Icons.content_cut_rounded),
    (EditorTool.ratio, '캔버스', Icons.aspect_ratio_rounded),
    (EditorTool.text, '텍스트', Icons.title_rounded),
    (EditorTool.zoom, '구간 줌', Icons.zoom_in_rounded),
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

/// 컷 편집 단추 하나.
///
/// **왜 흐린 단추도 눌리는가**: [onPressed]가 null이면 Flutter는 단추를 아예
/// 죽인다 — 눌러도 아무 일이 없다. 그런데 "지금은 안 되는 단추"와 "고장 난
/// 단추"는 사용자 눈에 똑같이 보인다. 실제로 분할 단추가 그랬다. 그래서 흐린
/// 모습은 그대로 두되 누르면 [onBlocked]로 이유를 알려 준다.
class _TimelineAction extends StatelessWidget {
  const _TimelineAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.blockedReason,
    this.onBlocked,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final String? blockedReason;
  final ValueChanged<String>? onBlocked;

  bool get _blocked => onPressed == null;

  @override
  Widget build(BuildContext context) {
    final reason = blockedReason;
    final explain = onBlocked;
    final action = _blocked && reason != null && explain != null
        ? () => explain(reason)
        : onPressed;
    return TextButton.icon(
      onPressed: action,
      icon: Icon(icon, size: 19),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        // 이유를 알려 주려고 살려 둔 단추도 흐리게 보여야 한다.
        foregroundColor: _blocked
            ? EditorColorTokens.border
            : EditorColorTokens.ink,
        disabledForegroundColor: EditorColorTokens.border,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(64, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
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

class _LiveAppliedBadge extends StatelessWidget {
  const _LiveAppliedBadge();

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(right: 4),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xFFEAF6EE),
      borderRadius: BorderRadius.circular(99),
    ),
    child: const Text(
      '✓ 바로 적용',
      style: TextStyle(
        color: Color(0xFF3D7A53),
        fontSize: 8,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

class _PanelChoice extends StatelessWidget {
  const _PanelChoice({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

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
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon case final icon?) ...[
              Icon(
                icon,
                size: 15,
                color: selected
                    ? EditorColorTokens.coral
                    : EditorColorTokens.muted,
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected
                      ? EditorColorTokens.coral
                      : EditorColorTokens.ink,
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
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
