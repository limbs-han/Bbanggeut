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
    required this.saving,
    required this.onBack,
    required this.onSaveDraft,
    required this.onSave,
    required this.onPlay,
    required this.onSeek,
    required this.onClipAdd,
    required this.onDelete,
    required this.onClipReorder,
    required this.onTrimChanged,
    required this.onTrimCommitted,
    required this.onPlayRange,
    required this.onBlocked,
    required this.onRatioSelected,
    required this.onEditCommitted,
    required this.presetRecommendations,
    required this.recommendationLoading,
    required this.onRecommendationSelected,
    required this.onText,
    required this.onTextEdit,
    required this.onTextRemove,
    required this.onVolumeChanged,
    required this.onMutedChanged,
    required this.onStickerSelected,
    required this.onFaceStickerSelected,
    required this.onLookSelected,
    required this.onAiCaption,
    required this.onZoomAdd,
    required this.onZoomRemove,
    required this.onZoomSelected,
    required this.onToolSelected,
    this.onUndo,
    this.onRedo,
    this.onVolumeCommitted,
    this.textEditing = false,
    this.rangePreviewing = false,
    this.exportProgress,
    this.exportStatus,
    this.onExportCancel,
  });

  final EditorProjectController controller;
  final Widget preview;
  final List<String> thumbnails;
  final bool playing;
  final bool saving;
  final VoidCallback onBack;

  /// 편집본(초안)만 서버에 저장한다.
  final VoidCallback onSaveDraft;

  /// 내보내기 — 렌더링해서 서버·갤러리에 올린다.
  final VoidCallback onSave;
  final VoidCallback onPlay;
  final ValueChanged<int> onSeek;

  /// 재생 위치에 3초짜리 클립을 하나 더 얹는다.
  final VoidCallback onClipAdd;
  final VoidCallback onDelete;
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

  /// 슬라이더·구간 손잡이 같은 연속 조작에서 손을 뗐다. 화면 쪽이 이력을
  /// 확정하고(endGesture) "저장 안 된 변경"을 표시할 때 쓴다.
  final VoidCallback onEditCommitted;
  final Map<String, EditRecommendation> presetRecommendations;
  final bool recommendationLoading;
  final ValueChanged<String> onRecommendationSelected;
  final VoidCallback onText;
  final ValueChanged<String> onTextEdit;

  /// 고른 자막의 시작(true)·끝(false)을 지금 재생 위치로 맞춘다.
  final ValueChanged<String> onTextRemove;
  final ValueChanged<double> onVolumeChanged;

  /// 볼륨 손잡이에서 손을 뗐다. null이면 이력을 따로 확정하지 않는다.
  final VoidCallback? onVolumeCommitted;

  final ValueChanged<bool> onMutedChanged;
  final ValueChanged<String> onStickerSelected;

  /// 얼굴을 따라다니는 AR 스티커(스티커 탭의 둘째 줄). null이면 벗긴다.
  final ValueChanged<String?> onFaceStickerSelected;

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
  final ValueChanged<EditorZoomSegment> onZoomRemove;
  final ValueChanged<EditorZoomSegment> onZoomSelected;

  /// AI 자막 패널에 보여줄 한 줄 상태. 자막 컨트롤러가 만든 문구를 그대로 받는다.

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
      // 줌·자막 탭은 컷과 같은 프레임 타임라인으로 "어느 구간인지"를 정한다.
      final rangeTarget = _rangeTimelineTarget(project);
      return ColoredBox(
        color: EditorColorTokens.background,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final layout = EditorLayoutTokens.fromSize(
                Size(constraints.maxWidth, constraints.maxHeight),
                keyboardVisible: keyboardVisible,
              );
              final rangeToolOpen =
                  project.selectedTool == EditorTool.zoom ||
                  project.selectedTool == EditorTool.text;
              final multipleClips = project.clips.length > 1;
              final timelineHeight = compact
                  ? 0.0
                  : cutMode
                  ? _timelineHeightFor(layout, project, cutMode)
                  : !rangeToolOpen
                  ? 0.0
                  : (rangeTarget == null ? 0.0 : layout.trimBarHeight) +
                        (multipleClips
                            ? EditorTimelineSection.chooserHeight
                            : 0.0);
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
                        onSaveDraft: onSaveDraft,
                        onSave: onSave,
                      ),
                      Expanded(child: VideoPreviewWorkspace(preview: preview)),
                      if (!compact)
                        EditorTransportBar(
                          playing: playing,
                          playheadMs: project.playheadMs,
                          onPlay: onPlay,
                          onSeek: onSeek,
                        ),
                      // 줌·자막 탭도 컷과 같은 구조를 쓴다 — 클립 고르개와
                      // 프레임 타임라인. "어느 클립의 어느 구간인지"가 컷과
                      // 같은 눈으로 보인다.
                      if (!compact && rangeToolOpen && multipleClips)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
                          child: SizedBox(
                            height: EditorTimelineSection.chooserHeight - 6,
                            child: ClipChooser(
                              project: project,
                              thumbnails: thumbnails,
                              onClipSelected: (clipId) {
                                controller.selectClip(clipId);
                                onSeek(project.timelineStartFor(clipId));
                              },
                              onReorder: onClipReorder,
                            ),
                          ),
                        ),
                      if (!compact && rangeToolOpen && rangeTarget != null)
                        Padding(
                          // 시스템 뒤로가기 제스처와 손잡이 터치를 분리한다.
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          child: SizedBox(
                            height: layout.trimBarHeight,
                            child: _RangeTimeline(
                              project: project,
                              controller: controller,
                              target: rangeTarget,
                              thumbnails: thumbnails,
                              onSeek: onSeek,
                              onEditCommitted: onEditCommitted,
                            ),
                          ),
                        ),
                      if (!compact && cutMode)
                        EditorTimelineSection(
                          trimBarHeight: layout.trimBarHeight,
                          actionButtonHeight: layout.actionButtonHeight,
                          project: project,
                          thumbnails: thumbnails,
                          expanded: cutMode,
                          canDelete: controller.canDeleteSelectedClip,
                          onSeek: onSeek,
                          onClipSelected: (clipId) {
                            controller.selectClip(clipId);
                            onSeek(project.timelineStartFor(clipId));
                          },
                          onClipAdd: onClipAdd,
                          onDelete: onDelete,
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
                        AnimatedSize(
                          duration: const Duration(milliseconds: 180),
                          curve: Curves.easeOutCubic,
                          child: SelectedToolPanel(
                            key: ValueKey(
                              'editor-selected-tool-${project.selectedTool.name}',
                            ),
                            project: project,
                            controller: controller,
                            height: panelHeight,
                            onRatioSelected: onRatioSelected,
                            onEditCommitted: onEditCommitted,
                            onText: onText,
                            onTextEdit: onTextEdit,
                            onTextRemove: onTextRemove,
                            onVolumeChanged: onVolumeChanged,
                            onMutedChanged: onMutedChanged,
                            onVolumeCommitted: onVolumeCommitted,
                            onStickerSelected: onStickerSelected,
                            onLookSelected: onLookSelected,
                            thumbnails: thumbnails,
                            previewFrame: thumbnails.isEmpty
                                ? null
                                : thumbnails[thumbnails.length ~/ 2],
                            onAiCaption: onAiCaption,
                            onFaceStickerSelected: onFaceStickerSelected,
                            onZoomAdd: onZoomAdd,
                            onZoomRemove: onZoomRemove,
                            onZoomSelected: onZoomSelected,
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
  if (!cutMode) return 0;
  var height =
      EditorTimelineSection.cutHeaderHeight +
      layout.trimBarHeight +
      layout.actionButtonHeight;
  if (project.clips.length > 1) height += EditorTimelineSection.chooserHeight;
  return height;
}

/// 줌·자막 탭이 다루는 클립. 클립을 고르면 그 클립에 귀속된 것만 보인다.
EditorClip? _scopeClip(EditorProject project) =>
    project.selectedClip ??
    (project.clips.isEmpty ? null : project.clips.first);

/// 고른 클립에 귀속된 줌들. 옛 데이터(묶이지 않은 줌)는 어디서나 보인다.
List<EditorZoomSegment> _zoomsOfClip(EditorProject project, EditorClip clip) =>
    [
      for (final zoom in project.zoomSegments)
        if (zoom.worksIn(clip)) zoom,
    ];

/// 고른 클립에 귀속된 자막들.
List<EditorTextLayer> _textLayersOfClip(
  EditorProject project,
  EditorClip clip,
) => [
  for (final layer in project.textLayers)
    if (layer.clipId == null || layer.clipId == clip.id) layer,
];

/// 줌·자막 탭에서 프레임 타임라인이 다룰 대상. 없으면 타임라인을 접는다.
_RangeTimelineTarget? _rangeTimelineTarget(EditorProject project) {
  final clip = _scopeClip(project);
  if (clip == null) return null;
  switch (project.selectedTool) {
    case EditorTool.zoom:
      final zoom = _activeZoom(project, clip);
      if (zoom == null) return null;
      return _RangeTimelineTarget.zoom(zoom);
    case EditorTool.text:
      final layers = _textLayersOfClip(project, clip);
      if (layers.isEmpty) return null;
      // 고른 자막이 이 클립 것이면 그것, 아니면 클립의 첫 자막.
      final layer = layers
          .where((item) => item.id == project.selectedLayerId)
          .firstOrNull;
      return _RangeTimelineTarget.text(layer ?? layers.first);
    default:
      return null;
  }
}

/// 지금 만지고 있는 줌 — **고른 클립에 귀속된 것 중에서만** 고른다.
/// 다른 클립의 줌은 그 클립을 골라야 보인다.
EditorZoomSegment? _activeZoom(EditorProject project, EditorClip clip) {
  final zooms = _zoomsOfClip(project, clip);
  for (final zoom in zooms) {
    if (zoom.id == project.selectedZoomId) return zoom;
  }
  return zooms.isEmpty ? null : zooms.first;
}

class _RangeTimelineTarget {
  const _RangeTimelineTarget.zoom(EditorZoomSegment this.zoomSegment)
    : textLayer = null;
  const _RangeTimelineTarget.text(EditorTextLayer this.textLayer)
    : zoomSegment = null;

  final EditorZoomSegment? zoomSegment;
  final EditorTextLayer? textLayer;
}

/// 미리보기 바로 아래 재생 줄. 재생 단추와 프레임 타임코드는 여기 한 곳에만
/// 있다 — 영상 위에 띄우면 영상을 가리고, 탭마다 흩어 두면 두 번 그린다.
class EditorTransportBar extends StatelessWidget {
  const EditorTransportBar({
    super.key,
    required this.playing,
    required this.playheadMs,
    required this.onPlay,
    required this.onSeek,
  });

  static const height = 38.0;
  static const frameRate = 30;

  final bool playing;
  final int playheadMs;
  final VoidCallback onPlay;
  final ValueChanged<int> onSeek;

  int get _frame => (playheadMs * frameRate / 1000).round();

  /// 분:초:프레임. 한 시간 넘는 영상은 나오지 않으므로 시는 표기하지 않는다.
  String get _timecode {
    final frames = _frame % frameRate;
    final totalSeconds = _frame ~/ frameRate;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(totalSeconds ~/ 60)}:${two(totalSeconds % 60)}'
        ':${two(frames)}';
  }

  void _stepFrames(int delta) {
    final nextFrame = math.max(0, _frame + delta);
    onSeek((nextFrame * 1000 / frameRate).round());
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: EditorSpacingTokens.previewHorizontal,
      ),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 32,
            child: IconButton.filled(
              key: const Key('editor-transport-play'),
              tooltip: playing ? '일시정지' : '재생',
              onPressed: onPlay,
              style: IconButton.styleFrom(
                padding: EdgeInsets.zero,
                backgroundColor: EditorColorTokens.coral,
                foregroundColor: Colors.white,
                iconSize: 20,
              ),
              icon: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _timecode,
            key: const Key('editor-frame-timecode'),
            style: const TextStyle(
              color: EditorColorTokens.ink,
              fontSize: 13,
              fontFeatures: [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$frameRate fps',
            style: const TextStyle(
              color: EditorColorTokens.muted,
              fontSize: 9,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          _FrameStepButton(
            key: const Key('editor-frame-back'),
            icon: Icons.chevron_left_rounded,
            tooltip: '1프레임 뒤로',
            onTap: () => _stepFrames(-1),
          ),
          const SizedBox(width: 4),
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
}

/// 줌·자막 탭의 프레임 타임라인. **고른 클립 하나의 범위만** 띠에 펼친다 —
/// 구간 선택이 클립별로 분리되고, 짧은 클립도 띠 전체를 써서 정밀하게
/// 잡을 수 있다. 같은 클립 안의 다른 구간들은 파란 마커로 함께 보여
/// "여러 구간"이 어디 있는지 한눈에 들어온다. 활성 구간만 노란 창이다.
class _RangeTimeline extends StatelessWidget {
  const _RangeTimeline({
    required this.project,
    required this.controller,
    required this.target,
    required this.thumbnails,
    required this.onSeek,
    required this.onEditCommitted,
  });

  final EditorProject project;
  final EditorProjectController controller;
  final _RangeTimelineTarget target;
  final List<String> thumbnails;
  final ValueChanged<int> onSeek;
  final VoidCallback onEditCommitted;

  /// 원본 [fromMs, toMs) 구간을 대표하는 프레임들. 클립이 짧아도 띠가
  /// 프레임으로 차도록 최소 6장은 뽑는다.
  List<String> _sliceThumbnails(int fromMs, int toMs) {
    if (thumbnails.isEmpty) return const [];
    final sourceTotal = math.max(1, project.sourceDurationMs);
    final count = math.max(
      6,
      (thumbnails.length * (toMs - fromMs) / sourceTotal).ceil(),
    );
    return [
      for (var i = 0; i < count; i++)
        thumbnails[((fromMs + (toMs - fromMs) * i / math.max(1, count - 1)) /
                sourceTotal *
                thumbnails.length)
            .floor()
            .clamp(0, thumbnails.length - 1)],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final zoom = target.zoomSegment;
    if (zoom != null) return _zoomBar(zoom);
    return _textBar(target.textLayer!);
  }

  Widget _zoomBar(EditorZoomSegment zoom) {
    // 띠의 범위 = 이 줌이 **묶인** 클립. 줌은 클립에 귀속된다 — 같은 원본
    // 구간을 쓰는 다른 클립과는 무관하다. 좌표는 클립 시작만큼 밀어서
    // 상대 눈금으로 다룬다.
    var scope = project.selectedClip ?? project.clips.first;
    if (zoom.clipId != null) {
      for (final clip in project.clips) {
        if (clip.id == zoom.clipId) {
          scope = clip;
          break;
        }
      }
    }
    final clipStart = scope.sourceStartMs;
    final span = math.max(1, scope.durationMs);
    // 같은 클립의 이웃 줌과 클립 경계가 이 창의 한계다. 줌은 서로 겹칠 수 없다.
    var lowerBound = clipStart;
    var upperBound = scope.sourceEndMs;
    for (final other in project.zoomSegments) {
      if (other.id == zoom.id || !other.worksIn(scope)) continue;
      if (other.sourceEndMs <= zoom.sourceStartMs) {
        lowerBound = math.max(lowerBound, other.sourceEndMs);
      }
      if (other.sourceStartMs >= zoom.sourceEndMs) {
        upperBound = math.min(upperBound, other.sourceStartMs);
      }
    }
    return TrimRangeBar(
      key: const Key('editor-zoom-range-bar'),
      sourceDurationMs: span,
      startMs: (zoom.sourceStartMs - clipStart).clamp(0, span),
      endMs: (zoom.sourceEndMs - clipStart).clamp(0, span),
      playheadSourceMs:
          ((project.sourcePositionForTimeline(project.playheadMs) ?? 0) -
                  clipStart)
              .clamp(0, span),
      thumbnails: _sliceThumbnails(clipStart, scope.sourceEndMs),
      // 이 클립에 묶인 줌 전부를 마커로 보여 준다. 순서가 장면 카드와
      // 같아서 마커 색과 카드 순번 색이 일치한다.
      zoomSegments: [
        for (final other in _zoomsOfClip(project, scope))
          other.copyWith(
            sourceStartMs: (other.sourceStartMs - clipStart).clamp(0, span),
            sourceEndMs: (other.sourceEndMs - clipStart).clamp(0, span),
          ),
      ],
      minimumDurationMs: 200,
      lowerBoundMs: (lowerBound - clipStart).clamp(0, span),
      upperBoundMs: (upperBound - clipStart).clamp(0, span),
      windowSlidable: true,
      onTrimChanged: (startMs, endMs, _) => controller.updateZoomGesture(
        zoom.copyWith(
          sourceStartMs: startMs + clipStart,
          sourceEndMs: endMs + clipStart,
        ),
        notify: false,
      ),
      onTrimCommitted: onEditCommitted,
      onScrub: (relativeMs) =>
          onSeek(project.timelinePositionForSource(relativeMs + clipStart)),
    );
  }

  Widget _textBar(EditorTextLayer layer) {
    // 자막은 타임라인 눈금이되 **묶인 클립**의 구간만 펼친다.
    var scope = project.selectedClip ?? project.clips.first;
    if (layer.clipId != null) {
      for (final clip in project.clips) {
        if (clip.id == layer.clipId) {
          scope = clip;
          break;
        }
      }
    }
    final clipTimelineStart = project.timelineStartFor(scope.id);
    final span = math.max(1, scope.durationMs);
    return TrimRangeBar(
      key: const Key('editor-text-range-bar'),
      sourceDurationMs: span,
      startMs: (layer.startMs - clipTimelineStart).clamp(0, span),
      endMs: (layer.endMs - clipTimelineStart).clamp(0, span),
      playheadSourceMs: (project.playheadMs - clipTimelineStart).clamp(0, span),
      thumbnails: _sliceThumbnails(scope.sourceStartMs, scope.sourceEndMs),
      // 이 클립의 자막 전부를 마커로 — 동시 자막·여러 구간이 보이고,
      // 순서가 칩 목록과 같아 마커 색과 칩 순번 색이 일치한다.
      zoomSegments: [
        for (final other in _textLayersOfClip(project, scope))
          EditorZoomSegment(
            id: 'subtitle-${other.id}',
            sourceStartMs: (other.startMs - clipTimelineStart).clamp(0, span),
            sourceEndMs: (other.endMs - clipTimelineStart).clamp(0, span),
            scale: 1,
            focus: NormalizedPoint.center,
          ),
      ],
      minimumDurationMs: 200,
      windowSlidable: true,
      onTrimChanged: (startMs, endMs, _) =>
          controller.updateTextLayerRangeGesture(
            layer.id,
            startMs + clipTimelineStart,
            endMs + clipTimelineStart,
            notify: false,
          ),
      onTrimCommitted: onEditCommitted,
      onScrub: (relativeMs) => onSeek(relativeMs + clipTimelineStart),
    );
  }
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
  final wanted = switch (project.selectedTool) {
    // 장면 카드 한 줄과 배율 슬라이더 한 줄.
    EditorTool.zoom => layout.toolPanelHeight * 1.45,
    // 비율 선택 한 줄과 확대 슬라이더 한 줄.
    EditorTool.ratio => layout.toolPanelHeight * 1.5,
    // 자막 목록 아래에 구간 조절 줄이 한 줄 더 붙는다.
    EditorTool.text => layout.toolPanelHeight * 1.3,
    // 일반 스티커 줄과 얼굴 추적(AR) 줄, 두 줄을 담는다.
    EditorTool.sticker => layout.toolPanelHeight * 1.7,
    _ => layout.toolPanelHeight,
  };
  final leftover =
      availableHeight -
      layout.topBarHeight -
      EditorTransportBar.height -
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
    required this.onSaveDraft,
    required this.onSave,
  });

  final double height;
  final bool canUndo;
  final bool canRedo;
  final bool saving;
  final VoidCallback onBack;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  /// 편집본(초안)만 서버에 저장한다. 렌더링하지 않는다.
  final VoidCallback onSaveDraft;

  /// 내보내기 — 렌더링해서 서버·갤러리에 올린다.
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
                // 편집본 저장(렌더링 없음)과 내보내기(렌더링)를 나눈다.
                // 하나의 "저장"에 뭉치면 초안만 남기고 싶을 때도 몇 분짜리
                // 렌더링을 기다려야 한다.
                //
                // **고정 높이 SizedBox로 감싸지 않는다** — 이 앱에서 버튼을
                // 고정 높이 SizedBox에 넣으면 실기기(S24+)에서 프레임
                // 레이아웃이 예외 없이 멈춰 이후 위젯이 그려지지 않는다
                // (_TextPanel 주석과 같은 병). 크기는 스타일로 정한다.
                OutlinedButton(
                  key: const Key('editor-save-draft'),
                  onPressed: saving ? null : onSaveDraft,
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(48, 34),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    foregroundColor: EditorColorTokens.ink,
                    side: const BorderSide(color: EditorColorTokens.border),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        EditorRadiusTokens.control,
                      ),
                    ),
                  ),
                  child: const Text(
                    '저장',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilledButton(
                    key: const Key('editor-save'),
                    onPressed: saving ? null : onSave,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(60, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      backgroundColor: EditorColorTokens.coral,
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: EditorColorTokens.border,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                            '내보내기',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
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

/// 미리보기 칸. 영상만 그린다 — 재생 단추와 타임코드는 아래
/// [EditorTransportBar]가 맡아 영상을 가리지 않는다.
class VideoPreviewWorkspace extends StatelessWidget {
  const VideoPreviewWorkspace({super.key, required this.preview});

  final Widget preview;

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
      child: Padding(
        padding: const EdgeInsets.all(EditorSpacingTokens.sm),
        child: Center(child: preview),
      ),
    ),
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
    required this.onSeek,
    required this.onClipSelected,
    required this.onClipAdd,
    required this.onDelete,
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
  /// 칩 안에 실제 프레임을 깔기 때문에 글자 한 줄보다 한 뼘 높다.
  static const chooserHeight = 58.0;
  static const cutHeaderHeight = 46.0;
  static const overviewHeight = 46.0;

  /// 지금 지울 수 없는 이유.
  static const deleteBlockedReason = '지울 것이 없어요. 구간을 좁히거나 클립을 추가한 뒤에 지울 수 있어요.';

  final double trimBarHeight;
  final double actionButtonHeight;
  final EditorProject project;
  final List<String> thumbnails;
  final bool expanded;
  final bool canDelete;
  final ValueChanged<int> onSeek;
  final ValueChanged<String> onClipSelected;
  final VoidCallback onClipAdd;
  final VoidCallback onDelete;
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
                  thumbnails: thumbnails,
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
                        zoomSegments: project.zoomSegments,
                        minimumDurationMs:
                            EditorProjectController.minimumClipDurationMs,
                        // 창 안쪽을 끌면 클립 구간이 길이를 유지한 채
                        // 원본 위를 통째로 움직인다 — 추가한 클립을 원하는
                        // 장면으로 옮기는 가장 빠른 손이다.
                        windowSlidable: true,
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
                    key: const Key('editor-add-clip'),
                    label: '클립 추가',
                    icon: Icons.add_box_outlined,
                    onPressed: onClipAdd,
                  ),
                  _TimelineAction(
                    key: const Key('editor-delete-clip'),
                    label: '클립 삭제',
                    icon: Icons.delete_outline_rounded,
                    onPressed: canDelete ? onDelete : null,
                    // 흐린 단추도 눌리게 둔다. 아무 반응이 없으면 "고장"으로
                    // 읽히지만, 왜 안 되는지 알려 주면 다음에 뭘 할지 알 수 있다.
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

/// 컷 탭 머리 줄. 왼쪽은 AI 길이 프리셋, 오른쪽은 지금 고른 구간의
/// 시작~끝을 **프레임 단위**로 보여 준다 — 어디부터 어디까지 자르는지가
/// 드래그 중이 아니어도 늘 보인다.
class _CutPrecisionToolbar extends StatelessWidget {
  const _CutPrecisionToolbar({
    required this.project,
    required this.recommendations,
    required this.loading,
    required this.onPresetSelected,
    required this.onSeek,
  });

  final EditorProject project;
  final Map<String, EditRecommendation> recommendations;
  final bool loading;
  final ValueChanged<String> onPresetSelected;
  final ValueChanged<int> onSeek;

  @override
  Widget build(BuildContext context) {
    final selected = project.selectedClip;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xFF2A2420),
        borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        child: Row(
          children: [
            const Text(
              'AI 컷',
              style: TextStyle(
                color: Color(0xFFBFB5AE),
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 5),
            for (final entry in const [
              ('short', '짧게'),
              ('medium', '중간'),
              ('long', '길게'),
            ]) ...[
              _TimelinePresetChip(
                key: Key('editor-preset-${entry.$1}'),
                label: entry.$2,
                selected: project.recommendationMarker?.preset == entry.$1,
                // 서버 응답이 아직 없어도 눌리게 둔다 — 누르면 그때 받아
                // 오거나 화면 쪽이 기본 규칙으로 잘라 준다.
                enabled: !loading,
                onTap: () => onPresetSelected(entry.$1),
              ),
              const SizedBox(width: 3),
            ],
            if (selected != null)
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // 좁은 화면에서는 글자를 줄여서라도 잘리지 않게 한다.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        '${frameClock(selected.sourceStartMs)}'
                        ' ~ ${frameClock(selected.sourceEndMs)}',
                        key: const Key('editor-selected-range'),
                        maxLines: 1,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontFeatures: [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    const Text(
                      '고른 구간 · 분:초:프레임',
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      softWrap: false,
                      style: TextStyle(
                        color: Color(0xFFBFB5AE),
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              )
            else
              const Spacer(),
          ],
        ),
      ),
    );
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
    required this.thumbnails,
    required this.onClipSelected,
    required this.onReorder,
  });

  final EditorProject project;

  /// 원본 전체에 고르게 뽑은 프레임들. 각 클립 칩이 제 구간의 프레임을
  /// 골라 배경에 깐다 — 숫자만 있는 칩으로는 어느 장면인지 알 수 없다.
  final List<String> thumbnails;
  final ValueChanged<String> onClipSelected;
  final void Function(int oldIndex, int newIndex) onReorder;

  /// 클립 구간을 대표하는 프레임 경로들(시작·가운데·끝).
  List<String> _framesFor(EditorClip clip) {
    if (thumbnails.isEmpty) return const [];
    final total = math.max(1, project.sourceDurationMs);
    String frameAt(int sourceMs) =>
        thumbnails[(sourceMs / total * thumbnails.length).floor().clamp(
          0,
          thumbnails.length - 1,
        )];
    return [
      frameAt(clip.sourceStartMs),
      frameAt((clip.sourceStartMs + clip.sourceEndMs) ~/ 2),
      frameAt(math.max(clip.sourceStartMs, clip.sourceEndMs - 1)),
    ];
  }

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
                  // 분:초:프레임 — 어느 프레임에서 시작하고 끝나는지까지 보인다.
                  sourceRange:
                      '${frameClock(clip.sourceStartMs)}–${frameClock(clip.sourceEndMs)}',
                  frames: _framesFor(clip),
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
                        color: Colors.white,
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

/// 클립 하나. 배경에 그 구간의 실제 프레임을 깔고 번호·구간을 얹는다.
class _ClipChip extends StatelessWidget {
  const _ClipChip({
    required this.number,
    required this.sourceRange,
    required this.frames,
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
  final List<String> frames;
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
      width: selected ? 130 : 104,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
        border: Border.all(
          color: selected ? EditorColorTokens.coral : EditorColorTokens.border,
          width: selected ? 2 : 1,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(EditorRadiusTokens.control - 1),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (frames.isEmpty)
              const ColoredBox(color: Color(0xFF26211E))
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final path in frames)
                    Expanded(
                      child: Image.file(
                        File(path),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.low,
                        errorBuilder: (_, _, _) =>
                            const ColoredBox(color: Color(0xFF26211E)),
                      ),
                    ),
                ],
              ),
            // 프레임 위 글자가 읽히도록 아래쪽만 살짝 어둡게 깐다.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x26000000), Color(0xB3000000)],
                ),
              ),
            ),
            Positioned(
              left: 5,
              right: 5,
              bottom: 3,
              child: Row(
                children: [
                  Text(
                    '$number',
                    style: TextStyle(
                      color: selected ? EditorColorTokens.coral : Colors.white,
                      fontSize: 11,
                      height: 1,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      sourceRange,
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      softWrap: false,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        height: 1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: Color(0x8C000000),
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(8),
                  ),
                ),
                child: dragHandle,
              ),
            ),
            if (selected) ...[
              Positioned(
                left: 0,
                top: 0,
                bottom: 14,
                child: Center(
                  child: _TinyMoveButton(
                    icon: Icons.chevron_left_rounded,
                    enabled: canMoveLeft,
                    onTap: onMoveLeft,
                  ),
                ),
              ),
              Positioned(
                right: 0,
                top: 22,
                bottom: 14,
                child: Center(
                  child: _TinyMoveButton(
                    icon: Icons.chevron_right_rounded,
                    enabled: canMoveRight,
                    onTap: onMoveRight,
                  ),
                ),
              ),
            ],
          ],
        ),
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
    required this.controller,
    required this.height,
    required this.onRatioSelected,
    required this.onEditCommitted,
    required this.onText,
    required this.onTextEdit,
    required this.onTextRemove,
    required this.onVolumeChanged,
    required this.onMutedChanged,
    required this.onStickerSelected,
    required this.onFaceStickerSelected,
    required this.onLookSelected,
    required this.onAiCaption,
    required this.onZoomAdd,
    required this.onZoomRemove,
    required this.onZoomSelected,
    this.thumbnails = const [],
    this.previewFrame,
    this.onVolumeCommitted,
  });

  final EditorProject project;
  final EditorProjectController controller;
  final double height;

  /// 원본 전체에 고르게 뽑은 프레임들. 줌 탭이 장면 카드를 그릴 때 쓴다.
  final List<String> thumbnails;
  final ValueChanged<EditorCanvasRatio> onRatioSelected;
  final VoidCallback onEditCommitted;
  final VoidCallback onText;
  final ValueChanged<String> onTextEdit;
  final ValueChanged<String> onTextRemove;
  final ValueChanged<double> onVolumeChanged;
  final VoidCallback? onVolumeCommitted;
  final ValueChanged<bool> onMutedChanged;
  final ValueChanged<String> onStickerSelected;
  final ValueChanged<String?> onFaceStickerSelected;
  final ValueChanged<EditorLook> onLookSelected;
  final String? previewFrame;
  final VoidCallback onAiCaption;
  final VoidCallback onZoomAdd;
  final ValueChanged<EditorZoomSegment> onZoomRemove;
  final ValueChanged<EditorZoomSegment> onZoomSelected;

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
            controller: controller,
            onSelected: onRatioSelected,
            onEditCommitted: onEditCommitted,
          ),
          EditorTool.text => _TextPanel(
            project: project,
            onText: onText,
            onTextEdit: onTextEdit,
            onTextRemove: onTextRemove,
            onAiCaption: onAiCaption,
          ),
          EditorTool.zoom => _SimpleZoomPanel(
            project: project,
            controller: controller,
            thumbnails: thumbnails,
            onAdd: onZoomAdd,
            onRemove: onZoomRemove,
            onSelected: onZoomSelected,
            onEditCommitted: onEditCommitted,
          ),
          EditorTool.audio => _AudioPanel(
            audio: project.audio,
            onVolumeChanged: onVolumeChanged,
            onVolumeCommitted: onVolumeCommitted,
            onMutedChanged: onMutedChanged,
          ),
          EditorTool.sticker => _StickerPanel(
            project: project,
            onSelected: onStickerSelected,
            onFaceStickerSelected: onFaceStickerSelected,
          ),
          EditorTool.effect => _LookPanel(
            look: project.look,
            previewFrame: previewFrame,
            onLookSelected: onLookSelected,
          ),
          // AI 자막은 자막 탭의 버튼으로, AR은 스티커 탭의 줄로 들어갔다.
          // 하단 네비에는 없지만 enum은 남아 있어 빈 칸으로 답한다.
          EditorTool.aiCaption || EditorTool.ar => const SizedBox.shrink(),
          EditorTool.cut => const SizedBox.shrink(),
        },
      ),
    );
  }
}

/// 출력 비율을 고르고, 영상 창의 크기·위치를 조절한다.
///
/// 9:16은 가로 영상을 중앙에 두고 위아래를 검은 띠로 남기는 숏폼 구도다.
/// 검은 띠의 크기는 아래 확대 슬라이더(또는 영상 핀치)로, 위치는 영상을
/// 위아래로 끌어서 바꾼다. 여기서 정한 값은 다른 탭과 저장 결과에 그대로
/// 적용된다.
class _RatioPanel extends StatelessWidget {
  const _RatioPanel({
    required this.canvas,
    required this.controller,
    required this.onSelected,
    required this.onEditCommitted,
  });

  final EditorCanvas canvas;
  final EditorProjectController controller;
  final ValueChanged<EditorCanvasRatio> onSelected;
  final VoidCallback onEditCommitted;

  @override
  // 세로가 짧은 기기에서 도구 칸이 양보하면 줄이 잘릴 수 있다 — 스크롤로 본다.
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.zero,
    children: [
      Row(
        children: [
          const Expanded(child: _PanelTitle('비율 · 영상 창')),
          const _LiveAppliedBadge(),
        ],
      ),
      const Text(
        '9:16의 검은 띠는 자막 자리예요. 영상을 위아래로 끌어 위치를, 확대로 띠 크기를 바꿔요.',
        style: TextStyle(color: EditorColorTokens.muted, fontSize: 9),
      ),
      const SizedBox(height: 5),
      SizedBox(
        height: 36,
        child: Row(
          children: [
            // 1:1·4:5는 UI에서 뺐다(요청). enum 값은 예전 초안 호환으로 남는다.
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
      Row(
        children: [
          const Text(
            '확대',
            style: TextStyle(
              color: EditorColorTokens.muted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          Expanded(
            child: Slider(
              key: const Key('editor-canvas-scale-slider'),
              value: canvas.scale.clamp(1.0, 3.5),
              min: 1,
              max: 3.5,
              onChangeStart: (_) => controller.beginGesture(),
              onChanged: (value) => controller.updateCanvasGesture(
                scale: value,
                offsetX: canvas.offsetX,
                offsetY: canvas.offsetY,
                rotationDegrees: canvas.rotationDegrees,
              ),
              onChangeEnd: (_) => onEditCommitted(),
            ),
          ),
          Text(
            '${canvas.scale.toStringAsFixed(2)}×',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
          ),
          IconButton(
            key: const Key('editor-canvas-reset'),
            tooltip: '크기·위치 초기화',
            onPressed: () {
              controller.resetCanvasTransform();
              onEditCommitted();
            },
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh_rounded, size: 16),
          ),
        ],
      ),
    ],
  );
}

/// 줌 도구.
///
/// 배율 하나만 다룬다 — 예전의 캔버스 확대·좌우·상하·회전 스테퍼는 구간
/// 줌과 헷갈리기만 해서 걷어냈다. 배율은 슬라이더로 끌고, 초점은 영상을
/// 직접 끌거나 벌려서 잡는다. 구간(시작~끝)은 위 프레임 타임라인의
/// 손잡이가 맡는다.
class _SimpleZoomPanel extends StatelessWidget {
  const _SimpleZoomPanel({
    required this.project,
    required this.controller,
    required this.thumbnails,
    required this.onAdd,
    required this.onRemove,
    required this.onSelected,
    required this.onEditCommitted,
  });

  final EditorProject project;
  final EditorProjectController controller;
  final List<String> thumbnails;
  final VoidCallback onAdd;
  final ValueChanged<EditorZoomSegment> onRemove;
  final ValueChanged<EditorZoomSegment> onSelected;
  final VoidCallback onEditCommitted;

  /// 이 시각을 대표하는 프레임 경로. 아직 못 뽑았으면 null.
  String? _frameAt(int sourceMs) {
    if (thumbnails.isEmpty) return null;
    final total = math.max(1, project.sourceDurationMs);
    return thumbnails[(sourceMs / total * thumbnails.length).floor().clamp(
      0,
      thumbnails.length - 1,
    )];
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scopeClip(project);
    // 고른 클립에 귀속된 줌만 보인다 — 다른 클립의 줌은 그 클립을 골라야
    // 나온다.
    final zooms = scope == null
        ? const <EditorZoomSegment>[]
        : _zoomsOfClip(project, scope).take(20).toList(growable: false);
    final active = scope == null ? null : _activeZoom(project, scope);
    // 세로가 짧은 기기에서 도구 칸이 양보하면 이 패널이 다 안 들어갈 수
    // 있다. 줄이 잘리는 대신 스크롤로 내려 볼 수 있게 한다.
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        Row(
          children: [
            const Expanded(child: _PanelTitle('줌 · 이 클립의 장면')),
            if (active != null)
              IconButton(
                key: const Key('editor-remove-zoom'),
                tooltip: '이 줌 삭제',
                onPressed: () => onRemove(active),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
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
        if (zooms.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              '이 클립에는 줌이 없어요. 재생 위치에서 "줌 추가"를 누르면 이 클립에 묶인 줌이 생겨요.',
              style: TextStyle(color: EditorColorTokens.muted, fontSize: 10),
            ),
          )
        else
          SizedBox(
            height: 62,
            child: ListView(
              key: const Key('editor-zoom-scenes'),
              scrollDirection: Axis.horizontal,
              children: [
                for (final (sceneIndex, zoom) in zooms.indexed)
                  _ZoomSceneCard(
                    key: Key('editor-zoom-scene-${zoom.id}'),
                    zoom: zoom,
                    number: sceneIndex + 1,
                    color: EditorMarkerTokens.colorAt(sceneIndex),
                    frame: _frameAt(
                      (zoom.sourceStartMs + zoom.sourceEndMs) ~/ 2,
                    ),
                    selected: active?.id == zoom.id,
                    onTap: () => onSelected(zoom),
                  ),
              ],
            ),
          ),
        if (active != null)
          Row(
            children: [
              const Text(
                '배율',
                style: TextStyle(
                  color: EditorColorTokens.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Expanded(
                child: Slider(
                  key: const Key('editor-zoom-scale-slider'),
                  value: active.scale.clamp(1.05, 2.8),
                  min: 1.05,
                  max: 2.8,
                  onChanged: (value) => controller.updateZoomGesture(
                    active.copyWith(scale: value),
                  ),
                  onChangeEnd: (_) => onEditCommitted(),
                ),
              ),
              Text(
                '${active.scale.toStringAsFixed(2)}×',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        const Text(
          '영상을 끌면 확대 초점이, 두 손가락으로 벌리면 배율이 바뀌어요. 구간은 위 타임라인 손잡이로 옮겨요.',
          style: TextStyle(color: EditorColorTokens.muted, fontSize: 9),
        ),
      ],
    );
  }
}

/// 줌 장면 하나를 미리 보여 주는 카드.
///
/// 카드에 깔린 프레임에 그 장면의 배율·초점을 **그대로 적용**해 그린다 —
/// 누르기 전에 "이 장면이 어떻게 확대되는지"를 카드에서 먼저 본다. 누르면
/// 재생 위치가 그 장면으로 가서 미리보기 화면에도 같은 효과가 걸린다.
class _ZoomSceneCard extends StatelessWidget {
  const _ZoomSceneCard({
    super.key,
    required this.zoom,
    required this.number,
    required this.color,
    required this.frame,
    required this.selected,
    required this.onTap,
  });

  final EditorZoomSegment zoom;
  final int number;

  /// 타임라인 마커와 같은 순번 색 — 카드와 마커가 눈으로 이어진다.
  final Color color;
  final String? frame;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final path = frame;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
        child: SizedBox(
          width: 84,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      EditorRadiusTokens.control,
                    ),
                    border: Border.all(
                      color: selected ? color : EditorColorTokens.border,
                      width: selected ? 2.5 : 1,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(
                      EditorRadiusTokens.control - 1,
                    ),
                    child: path == null
                        ? const ColoredBox(color: EditorColorTokens.border)
                        : Transform.scale(
                            scale: zoom.scale,
                            alignment: Alignment(
                              zoom.focus.x * 2 - 1,
                              zoom.focus.y * 2 - 1,
                            ),
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
                '${zoom.automatic ? 'AI ' : ''}$number · '
                '${zoom.scale.toStringAsFixed(1)}× · '
                '${_formatMs(zoom.sourceStartMs)}',
                maxLines: 1,
                overflow: TextOverflow.clip,
                softWrap: false,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: selected ? color : EditorColorTokens.muted,
                  fontSize: 8,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 자막 도구.
///
/// 자막마다 제 표시 구간(시작~끝)이 있고, 구간이 겹치면 같은 시각에 여러
/// 자막이 함께 뜬다. 칩을 누르면 그 자막의 시작으로 이동해 영상 위에서
/// 바로 확인하고, 연필로 내용을 고친다.
class _TextPanel extends StatelessWidget {
  const _TextPanel({
    required this.project,
    required this.onText,
    required this.onTextEdit,
    required this.onTextRemove,
    required this.onAiCaption,
  });

  final EditorProject project;
  final VoidCallback onText;

  /// 들린 대사로 자막을 만드는 시트를 연다. 결과는 이 탭의 자막으로 합쳐진다.
  final VoidCallback onAiCaption;
  final ValueChanged<String> onTextEdit;

  /// 칩을 눌러 그 자막을 고르고 시작 시각으로 이동한다.

  /// 고른 자막의 시작(true)·끝(false)을 지금 재생 위치로 맞춘다.
  final ValueChanged<String> onTextRemove;

  /// 추가 버튼은 고정 높이 SizedBox로 감싸지 않는다.
  ///
  /// **왜**: 도구 패널 제목 줄에서 `SizedBox(height: N)` 안에 FilledButton을
  /// 넣으면 실기기(S24+)에서 이 탭의 프레임 레이아웃이 예외도 없이 끝나지
  /// 않은 채 남아, 패널·하단 네비가 그려지지 않고 화면이 멈춘 것처럼 보였다.
  /// 예전 _ZoomPanel의 "빈 패널·입력 정지"도 같은 조합이 원인이었다. 버튼
  /// 크기는 스타일의 minimumSize로 정한다.
  @override
  Widget build(BuildContext context) {
    final scope = _scopeClip(project);
    // 고른 클립에 귀속된 자막만 보인다.
    final layers = scope == null
        ? const <EditorTextLayer>[]
        : _textLayersOfClip(project, scope);
    final selected = layers
        .where((layer) => layer.id == project.selectedLayerId)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(child: _PanelTitle('자막 · 이 클립의 자막')),
            Text(
              '${layers.length}개',
              style: const TextStyle(
                color: EditorColorTokens.muted,
                fontSize: 10,
              ),
            ),
            const SizedBox(width: 6),
            // AI 자막도 이 탭의 일이다 — 만들어진 자막이 이 목록으로 합쳐진다.
            OutlinedButton(
              key: const Key('editor-open-ai-caption'),
              onPressed: onAiCaption,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(56, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                textStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('AI 자막'),
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
          child: layers.isEmpty
              ? DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFF7F1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: EditorColorTokens.border),
                  ),
                  child: const Center(
                    child: Text(
                      '+ 추가를 누르면 지금 재생 위치부터 3초짜리 자막이 생겨요',
                      style: TextStyle(
                        color: EditorColorTokens.muted,
                        fontSize: 10,
                      ),
                    ),
                  ),
                )
              : ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: layers.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, index) {
                    final layer = layers[index];
                    final isSelected = selected?.id == layer.id;
                    // 타임라인 마커와 같은 순번 색으로 구분한다.
                    final markerColor = EditorMarkerTokens.colorAt(index);
                    return InkWell(
                      key: Key('editor-edit-text-${layer.id}'),
                      // 칩을 누르면 바로 내용 편집으로 들어간다 — 따로 연필을
                      // 찾게 하지 않는다. 구간은 아래 타임라인이 맡는다.
                      onTap: () => onTextEdit(layer.id),
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 150,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? EditorColorTokens.selected
                              : const Color(0xFFFFF7F1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelected
                                ? markerColor
                                : EditorColorTokens.border,
                            width: isSelected ? 2 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Text(
                              '${index + 1}',
                              style: TextStyle(
                                color: markerColor,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    layer.text,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  Text(
                                    '${_formatMs(layer.startMs)}–${_formatMs(layer.endMs)}',
                                    style: const TextStyle(
                                      color: EditorColorTokens.muted,
                                      fontSize: 9,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
        if (selected != null) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  '자막 ${layers.indexOf(selected) + 1} · '
                  '${_formatMs(selected.startMs)}–${_formatMs(selected.endMs)}'
                  ' · 구간은 위 타임라인의 노란 창을 끌어 옮겨요',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: EditorColorTokens.muted,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                key: const Key('editor-text-remove'),
                tooltip: '자막 삭제',
                onPressed: () => onTextRemove(selected.id),
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline_rounded, size: 17),
              ),
            ],
          ),
        ],
      ],
    );
  }
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
  const _StickerPanel({
    required this.project,
    required this.onSelected,
    required this.onFaceStickerSelected,
  });

  final EditorProject project;
  final ValueChanged<String> onSelected;

  /// 얼굴을 따라다니는 AR 스티커를 씌우거나(null이면) 벗긴다.
  final ValueChanged<String?> onFaceStickerSelected;

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
  Widget build(BuildContext context) {
    final faceSticker = project.stickerLayers
        .where((layer) => layer.tracksFace)
        .firstOrNull;
    final faceReady = project.faceTrack.isNotEmpty;
    return Column(
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
                      child: Text(
                        sticker,
                        style: const TextStyle(fontSize: 25),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 20,
          child: Row(
            children: [
              const Expanded(
                child: _PanelTitle('AR · 얼굴을 따라다니는 스티커'),
              ),
              if (faceSticker != null)
                TextButton(
                  key: const Key('editor-clear-face-sticker'),
                  onPressed: () => onFaceStickerSelected(null),
                  style: TextButton.styleFrom(
                    foregroundColor: EditorColorTokens.muted,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 20),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('벗기기', style: TextStyle(fontSize: 11)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: faceReady
              ? ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final sticker in EditorArEffect.stickerValues)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: InkWell(
                          key: Key('editor-face-sticker-$sticker'),
                          onTap: () => onFaceStickerSelected(sticker),
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
                              border: Border.all(
                                color: faceSticker?.value == sticker
                                    ? EditorColorTokens.coral
                                    : EditorColorTokens.border,
                                width: faceSticker?.value == sticker
                                    ? 2.5
                                    : 1,
                              ),
                            ),
                            child: Text(
                              sticker,
                              style: const TextStyle(fontSize: 25),
                            ),
                          ),
                        ),
                      ),
                  ],
                )
              : const Center(
                  child: Text(
                    '이 영상에서는 얼굴 정보를 아직 받지 못했어요.',
                    key: Key('editor-face-sticker-unavailable'),
                    style: TextStyle(
                      color: EditorColorTokens.muted,
                      fontSize: 11,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// 인앱 색감 효과 탭.
///
/// **왜 필터가 먼저인가**: 여기서 누른 것은 화면을 벗어나지 않고 그 자리에서
/// 바로 영상에 입혀져야 한다. 색감 필터는 우리 미리보기가 직접 그리고
/// 내보내기(media3)가 같은 값으로 구워 주므로 즉시 적용이 된다. 카드에 깔리는
/// 그림은 남의 스크린샷이 아니라 **지금 편집 중인 영상의 실제 프레임**이다 —
/// 누르기 전에 결과를 그대로 본다.
///
/// **왜 AR에서 떼어 냈나**: 색감은 얼굴 추적과 아무 상관이 없고, AR 탭 미리보기가
/// Banuba의 `SurfaceView`로 바뀌면서 그 위에는 Flutter의 색 필터가 닿지 않는다
/// (SurfaceView는 Flutter가 합성하지 않고 안드로이드가 직접 얹는 층이다).
/// 고를 수는 있는데 미리보기가 안 되는 자리에 두느니, 원래 어울리는 자리로 옮겼다.
class _LookPanel extends StatelessWidget {
  const _LookPanel({
    required this.look,
    required this.previewFrame,
    required this.onLookSelected,
  });

  final EditorLook look;

  /// 카드에 깔 프레임. 아직 없으면 색만 있는 칸으로 그린다.
  final String? previewFrame;

  final ValueChanged<EditorLook> onLookSelected;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
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
      Expanded(
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

  /// 클립 단위 도구. AI자막은 자막 탭의 버튼으로, AR은 스티커 탭의 줄로
  /// 들어가서 하단 네비에는 없다.
  static const _clipItems = <(EditorTool, String, IconData)>[
    (EditorTool.cut, '컷 편집', Icons.content_cut_rounded),
    (EditorTool.ratio, '비율', Icons.aspect_ratio_rounded),
    (EditorTool.zoom, '줌', Icons.zoom_in_rounded),
    (EditorTool.text, '자막', Icons.subtitles_rounded),
    (EditorTool.sticker, '스티커', Icons.emoji_emotions_outlined),
  ];

  /// 영상 **전체**에 걸리는 도구. 클립 단위가 아니라서 구분선 너머
  /// 오른쪽에 따로 둔다.
  static const _globalItems = <(EditorTool, String, IconData)>[
    (EditorTool.audio, '오디오', Icons.music_note_rounded),
    (EditorTool.effect, '효과', Icons.auto_awesome_rounded),
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
        for (final item in _clipItems)
          _NavigationItem(
            tool: item.$1,
            label: item.$2,
            icon: item.$3,
            selected: selectedTool == item.$1,
            fontSize: fontSize,
            iconSize: iconSize,
            onSelected: onSelected,
          ),
        Container(
          key: const Key('editor-nav-divider'),
          width: 1,
          margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 3),
          color: EditorColorTokens.border,
        ),
        for (final item in _globalItems)
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
