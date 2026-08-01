import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'editor_ar_effects.dart';
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
    required this.onTrimChanged,
    required this.onTrimCommitted,
    required this.onPlayRange,
    required this.onBlocked,
    required this.onRatioSelected,
    required this.onText,
    required this.onVolumeChanged,
    required this.onMutedChanged,
    required this.onStickerSelected,
    required this.onLookSelected,
    required this.onAiCaption,
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
  final VoidCallback onText;
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
              final timelineHeight = compact
                  ? 0.0
                  : _timelineHeightFor(layout, project, cutMode);
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
                      if (!compact)
                        EditorTimelineSection(
                          trimBarHeight: layout.trimBarHeight,
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
                          onTrimChanged: onTrimChanged,
                          onTrimCommitted: onTrimCommitted,
                          onPlayRange: onPlayRange,
                          rangePlaying: rangePreviewing,
                          onBlocked: onBlocked,
                        ),
                      if (!compact)
                        AnimatedSize(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: SelectedToolPanel(
                            project: project,
                            height: panelHeight,
                            onRatioSelected: onRatioSelected,
                            onText: onText,
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
                          ),
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
  var height = layout.trimBarHeight;
  if (cutMode) {
    height += layout.actionButtonHeight;
    if (project.clips.length > 1) height += EditorTimelineSection.chooserHeight;
  }
  return height;
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
  final wanted = project.selectedTool == EditorTool.ar
      ? layout.toolPanelHeight * 1.6
      : layout.toolPanelHeight;
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
    required this.onTrimChanged,
    required this.onTrimCommitted,
    required this.onPlayRange,
    required this.rangePlaying,
    required this.onBlocked,
  });

  /// 클립 고르는 줄(여백 포함)의 높이. 클립이 둘 이상일 때만 붙는다.
  static const chooserHeight = 24.0;

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
  final void Function(int startMs, int endMs, bool startHandle) onTrimChanged;
  final VoidCallback onTrimCommitted;

  /// 정해 둔 구간만 돌려 본다.
  final VoidCallback onPlayRange;
  final bool rangePlaying;

  /// 흐린 단추를 눌렀다. 왜 안 되는지 한 줄로 알려 준다.
  final ValueChanged<String> onBlocked;

  @override
  Widget build(BuildContext context) {
    final selected = project.selectedClip;
    final multipleClips = project.clips.length > 1;
    return ColoredBox(
      color: EditorColorTokens.background,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: trimBarHeight,
            child: selected == null
                ? const ColoredBox(color: EditorColorTokens.border)
                : TrimRangeBar(
                    sourceDurationMs: project.sourceDurationMs,
                    startMs: selected.sourceStartMs,
                    endMs: selected.sourceEndMs,
                    playheadSourceMs: _playheadSourceMs(selected),
                    thumbnails: thumbnails,
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
          if (expanded && multipleClips)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: SizedBox(
                height: chooserHeight - 4,
                child: ClipChooser(
                  project: project,
                  onClipSelected: onClipSelected,
                ),
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

/// 분할한 클립이 둘 이상일 때 나오는 고르개.
///
/// 구간 막대는 언제나 **고른 클립 하나**를 다룬다. 그래서 어느 클립을 만지고
/// 있는지 고를 방법이 있어야 한다 — 예전 띠가 겸하던 일이다.
class ClipChooser extends StatelessWidget {
  const ClipChooser({
    super.key,
    required this.project,
    required this.onClipSelected,
  });

  final EditorProject project;
  final ValueChanged<String> onClipSelected;

  @override
  Widget build(BuildContext context) => ListView(
    scrollDirection: Axis.horizontal,
    children: [
      for (var index = 0; index < project.clips.length; index++)
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: _ClipChip(
            key: Key('editor-clip-${project.clips[index].id}'),
            label:
                '${index + 1} · ${_formatMs(project.clips[index].durationMs)}',
            selected: project.clips[index].id == project.selectedClipId,
            onTap: () => onClipSelected(project.clips[index].id),
          ),
        ),
    ],
  );
}

class _ClipChip extends StatelessWidget {
  const _ClipChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
    child: Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 9),
      decoration: BoxDecoration(
        color: selected ? EditorColorTokens.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
        border: Border.all(
          color: selected ? EditorColorTokens.coral : EditorColorTokens.border,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? EditorColorTokens.coral : EditorColorTokens.muted,
          fontSize: 10,
          fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
    ),
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
    required this.onLookSelected,
    required this.onAiCaption,
    this.previewFrame,
    this.onVolumeCommitted,
    this.aiCaptionSummary,
  });

  final EditorProject project;
  final double height;
  final ValueChanged<EditorCanvasRatio> onRatioSelected;
  final VoidCallback onText;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback? onVolumeCommitted;
  final ValueChanged<bool> onMutedChanged;
  final ValueChanged<String> onStickerSelected;
  final ValueChanged<EditorLook> onLookSelected;
  final String? previewFrame;
  final VoidCallback onAiCaption;
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
      child: switch (project.selectedTool) {
        EditorTool.ratio => _RatioPanel(
          selected: project.canvas.ratio,
          onSelected: onRatioSelected,
        ),
        EditorTool.text => _TextPanel(onText: onText),
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
          '영상 위에 바로 써요. 다 쓰면 끌어 옮기고 모서리로 크기를 바꿔요.\n올려 둔 글자를 두 번 누르면 다시 고쳐요.',
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
    (EditorTool.cut, '컷 편집', Icons.content_cut_rounded),
    (EditorTool.ratio, '비율', Icons.aspect_ratio_rounded),
    (EditorTool.text, '텍스트', Icons.title_rounded),
    (EditorTool.audio, '오디오', Icons.music_note_rounded),
    (EditorTool.sticker, '스티커', Icons.emoji_emotions_outlined),
    (EditorTool.aiCaption, 'AI자막', Icons.closed_caption_rounded),
    (EditorTool.ar, '효과', Icons.auto_awesome_rounded),
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
