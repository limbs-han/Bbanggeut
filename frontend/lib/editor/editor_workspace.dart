import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/app_theme.dart';
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
    this.directCaptionAddMode = false,
    this.onDirectCaptionAddMode,
    this.onEditCaption,
    this.onDeleteCaption,
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
  final bool directCaptionAddMode;
  final VoidCallback? onDirectCaptionAddMode;

  /// 자막 카드·겹침 시트의 연필. 그 자막을 영상 위에서 고치러 들어간다.
  /// null이면 연필을 그리지 않는다.
  final ValueChanged<String>? onEditCaption;

  /// 자막 카드 머리줄·겹침 시트의 휴지통. 그 자막을 지운다.
  final ValueChanged<String>? onDeleteCaption;

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
      // 자막이 하나라도 있으면 자막 탭은 도구 칸을 쓰지 않는다 — 프레임 띠·
      // 눈금·자막 줄이 한 판에 모인 [_CaptionTimelinePanel]이 그 자리를 다
      // 맡는다. 아직 하나도 없을 때만 만드는 두 갈래([_CaptionEmptyPanel])가
      // 도구 칸에 선다.
      final captionMode = project.selectedTool == EditorTool.text;
      final captionLayers = captionMode
          ? _captionLayersOf(project)
          : const <EditorTextLayer>[];
      final captionEmptyState =
          captionMode && captionLayers.isEmpty && !directCaptionAddMode;
      // 고를 자막이 있을 때만 카드 줄이 붙는다. 판 안쪽과 높이 계산이 같은
      // 조건을 봐야 카드 줄만큼 판이 넘치는 일이 없다.
      final captionCards =
          captionMode && captionLayers.isNotEmpty && !directCaptionAddMode;
      // 줌·자막 탭은 컷과 같은 프레임 타임라인으로 "어느 구간인지"를 정한다.
      final rangeTarget = _rangeTimelineTarget(
        project,
        directCaptionAddMode: directCaptionAddMode,
      );
      return ColoredBox(
        color: EditorColorTokens.canvas,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final layout = EditorLayoutTokens.fromSize(
                Size(constraints.maxWidth, constraints.maxHeight),
                keyboardVisible: keyboardVisible,
              );
              final rangeToolOpen =
                  project.selectedTool == EditorTool.zoom ||
                  project.selectedTool == EditorTool.text ||
                  project.selectedTool == EditorTool.sticker;
              final multipleClips = project.clips.length > 1;
              final rangeTimelineHeight = captionMode
                  ? _captionPanelHeightFor(
                      layout,
                      availableHeight: constraints.maxHeight,
                      multipleClips: multipleClips,
                      cards: captionCards,
                      addCard: directCaptionAddMode,
                    )
                  : layout.trimBarHeight;
              final timelineHeight = compact
                  ? 0.0
                  : cutMode
                  ? _timelineHeightFor(layout, project, cutMode)
                  : !rangeToolOpen
                  ? 0.0
                  : (rangeTarget == null ? 0.0 : rangeTimelineHeight) +
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
                      captionEmptyState: captionEmptyState,
                    );
              return Stack(
                children: [
                  Column(
                    children: [
                      EditorTopBar(
                        height: layout.topBarHeight,
                        saving: saving,
                        onBack: onBack,
                        onSaveDraft: onSaveDraft,
                        onSave: onSave,
                      ),
                      Expanded(child: VideoPreviewWorkspace(preview: preview)),
                      if (!compact)
                        EditorTransportBar(
                          playing: playing,
                          playheadMs: project.playheadMs,
                          canUndo: controller.canUndo && !saving,
                          canRedo: controller.canRedo && !saving,
                          onPlay: onPlay,
                          onUndo: onUndo ?? controller.undo,
                          onRedo: onRedo ?? controller.redo,
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
                          //
                          // 자막 판은 이 여백을 거의 쓰지 않는다 — 손잡이가
                          // 띠 **안쪽**(컷 경계선)에 있어서 화면 가장자리와
                          // 다툴 일이 없고, 프레임과 자막 카드는 넓을수록
                          // 읽기 좋다. 줌·스티커 띠의 손잡이는 창 바깥에
                          // 서므로 예전 여백이 그대로 필요하다.
                          padding: EdgeInsets.symmetric(
                            horizontal: captionMode ? 10 : 18,
                          ),
                          child: SizedBox(
                            height: rangeTimelineHeight,
                            child: _RangeTimeline(
                              project: project,
                              controller: controller,
                              target: rangeTarget,
                              thumbnails: thumbnails,
                              onSeek: onSeek,
                              onEditCommitted: onEditCommitted,
                              onClipTrimChanged: onTrimChanged,
                              onClipTrimCommitted: onTrimCommitted,
                              directCaptionAddMode: directCaptionAddMode,
                              onAddCaption: onText,
                              onAddCaptionMode:
                                  onDirectCaptionAddMode ?? onText,
                              onAiCaption: onAiCaption,
                              onEditCaption: onEditCaption,
                              onDeleteCaption: onDeleteCaption,
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
                            captionEmptyState: captionEmptyState,
                            onDirectCaptionAddMode:
                                onDirectCaptionAddMode ?? onText,
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

/// 자막 판이 차지할 높이. 자막 탭은 도구 칸을 쓰지 않으므로 이 값 하나가
/// 미리보기 아래 자리 전부다.
///
/// **왜 줄 칸만 늘었다 줄었다 하는가**: 프레임 띠·눈금·카드 줄은 어느
/// 기기에서나 같은 높이로 있어야 "지금 어디"가 흔들리지 않는다. 기준으로
/// 삼은 갤럭시 S24+(SafeArea 안쪽 411×840dp)에서는 자막 줄이 두 개 보이고,
/// 세로가 짧은 기기에서는 미리보기를 지키느라 한 줄까지 줄어든다.
///
/// [cards]가 참이면 판 아래에 자막 카드 줄이 붙는다. 만드는 안내 카드가
/// 떠 있는 동안([addCard])에는 고를 자막이 아직 없어 카드 줄을 세지 않고,
/// 대신 줄 칸을 그 안내 카드가 통째로 쓴다.
double _captionPanelHeightFor(
  EditorLayoutTokens layout, {
  required double availableHeight,
  required bool multipleClips,
  required bool cards,
  required bool addCard,
}) {
  final outside =
      layout.topBarHeight +
      EditorTransportBar.height +
      layout.bottomNavigationHeight +
      (multipleClips ? EditorTimelineSection.chooserHeight : 0.0);
  final fixed =
      _CaptionTimelineMetrics.chrome +
      (cards ? _CaptionTimelineMetrics.cardsSection : 0.0);
  if (addCard) return fixed + _CaptionTimelineMetrics.addCardHeight;
  final room = availableHeight - outside - layout.minimumPreviewHeight - fixed;
  final rows = room.clamp(
    _CaptionTimelineMetrics.rowsHeight(1),
    _CaptionTimelineMetrics.rowsHeight(_CaptionTimelineMetrics.visibleRows),
  );
  return fixed + rows;
}

/// 지금 자막 판이 다루는 자막들. 재생 줄의 '자막 추가'가 첫 자막인지
/// 아닌지를 가릴 때도 같은 목록을 본다.
List<EditorTextLayer> _captionLayersOf(EditorProject project) {
  final clip = _captionScopeClip(project);
  return clip == null
      ? const <EditorTextLayer>[]
      : _textLayersOfClip(project, clip);
}

/// 자막 판이 펼치는 클립.
///
/// **왜 "고른 클립"이 아닌가**: 자막은 만들어질 때 **재생 위치가 속한 클립**에
/// 붙는다([EditorProjectController.addTextLayer]). 그런데 고른 클립은 그와
/// 다를 수 있다 — 클립을 나눈 뒤 앞 클립을 골라 둔 채 재생 위치만 뒤 클립으로
/// 옮겨 자막을 만들면 그렇다. 판을 고른 클립에 묶어 두면 그렇게 만든 자막이
/// 막대에도 카드에도 나타나지 않는다. **방금 고른 자막이 있는 클립**을 먼저
/// 보면 어느 쪽에서 만들었든 그 자막이 있는 자리가 펼쳐진다.
EditorClip? _captionScopeClip(EditorProject project) {
  final clipId = project.textLayers
      .where((layer) => layer.id == project.selectedLayerId)
      .firstOrNull
      ?.clipId;
  if (clipId != null) {
    for (final clip in project.clips) {
      if (clip.id == clipId) return clip;
    }
  }
  return _scopeClip(project);
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

/// 자동으로 만들어진 자막인가. 전사 결과를 자막으로 합칠 때 id에 붙는
/// `ai-caption-` 접두사가 표시다.
bool _automaticCaption(EditorTextLayer layer) =>
    layer.id.startsWith('ai-caption-');

/// 자막 하나를 알아보는 색. [order]는 자막 카드에 찍히는 번호와 같은 순번이라,
/// 막대·카드·겹침 시트가 늘 같은 색으로 같은 자막을 가리킨다.
///
/// **자막이 어디서 왔는지는 색으로 가르지 않는다.** AI 자막만 올리브로 묶어
/// 두면 자동 자막이 스무 개일 때 올리브 막대 스무 개가 한 덩이로 붙어, 어디서
/// 하나가 끝나고 다음이 시작하는지 알 수 없었다. 순번마다 색이 도는 지금은
/// 이웃한 막대가 늘 다르다.
Color _captionAccent(EditorTextLayer layer, int order) =>
    EditorCaptionTokens.colorAt(order);

/// 고른 클립에 귀속된 스티커들(얼굴 추적 포함).
List<EditorStickerLayer> _stickerLayersOfClip(
  EditorProject project,
  EditorClip clip,
) => [
  for (final layer in project.stickerLayers)
    if (layer.clipId == null || layer.clipId == clip.id) layer,
];

/// 줌·자막 탭에서 프레임 타임라인이 다룰 대상. 없으면 타임라인을 접는다.
_RangeTimelineTarget? _rangeTimelineTarget(
  EditorProject project, {
  bool directCaptionAddMode = false,
}) {
  final clip = _scopeClip(project);
  if (clip == null) return null;
  switch (project.selectedTool) {
    case EditorTool.zoom:
      final zoom = _activeZoom(project, clip);
      if (zoom == null) return null;
      return _RangeTimelineTarget.zoom(zoom);
    case EditorTool.text:
      // 고른 자막은 **모든 클립에서** 찾는다. 그 자막이 붙은 클립이 곧 판이
      // 펼칠 자리다([_captionScopeClip]) — 여기서 고른 클립의 자막만 뒤지면
      // 다른 클립에 방금 만든 자막을 못 찾고 엉뚱한 클립을 펼친다.
      final selected = project.textLayers
          .where((item) => item.id == project.selectedLayerId)
          .firstOrNull;
      if (selected != null) return _RangeTimelineTarget.text(selected);
      final layers = _textLayersOfClip(project, clip);
      // 자막이 하나도 없으면 판을 열지 않는다 — 아직 손댈 것이 없는 눈금과
      // 빈 줄 칸을 먼저 보여 주면 "여기서 뭘 해야 하지"가 한 박자 늦는다.
      // 그 자리는 [_CaptionEmptyPanel]의 '직접/자동' 두 갈래가 대신 쓴다.
      if (layers.isEmpty) {
        return directCaptionAddMode
            ? const _RangeTimelineTarget.text(null)
            : null;
      }
      return _RangeTimelineTarget.text(layers.first);
    case EditorTool.sticker:
      final layers = _stickerLayersOfClip(project, clip);
      if (layers.isEmpty) return null;
      // 고른 스티커가 이 클립 것이면 그것, 아니면 클립의 첫 스티커.
      final layer = layers
          .where((item) => item.id == project.selectedLayerId)
          .firstOrNull;
      return _RangeTimelineTarget.sticker(layer ?? layers.first);
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
    : textLayer = null,
      stickerLayer = null,
      isTextTimeline = false;
  const _RangeTimelineTarget.text(this.textLayer)
    : zoomSegment = null,
      stickerLayer = null,
      isTextTimeline = true;
  const _RangeTimelineTarget.sticker(EditorStickerLayer this.stickerLayer)
    : zoomSegment = null,
      textLayer = null,
      isTextTimeline = false;

  final EditorZoomSegment? zoomSegment;
  final EditorTextLayer? textLayer;
  final EditorStickerLayer? stickerLayer;
  final bool isTextTimeline;
}

/// 미리보기 바로 아래 재생 줄. 재생 단추와 프레임 타임코드는 여기 한 곳에만
/// 있다 — 영상 위에 띄우면 영상을 가리고, 탭마다 흩어 두면 두 번 그린다.
class EditorTransportBar extends StatelessWidget {
  const EditorTransportBar({
    super.key,
    required this.playing,
    required this.playheadMs,
    required this.canUndo,
    required this.canRedo,
    required this.onPlay,
    required this.onUndo,
    required this.onRedo,
  });

  static const height = 38.0;
  static const frameRate = 30;

  final bool playing;
  final int playheadMs;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback onPlay;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  int get _frame => (playheadMs * frameRate / 1000).round();

  /// 분:초:프레임. 한 시간 넘는 영상은 나오지 않으므로 시는 표기하지 않는다.
  String get _timecode {
    final frames = _frame % frameRate;
    final totalSeconds = _frame ~/ frameRate;
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(totalSeconds ~/ 60)}:${two(totalSeconds % 60)}'
        ':${two(frames)}';
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
          // 좁은 기기에서 줄이 넘치지 않도록 시각 표시가 먼저 줄어든다 —
          // 단추는 눌러야 하지만 시각은 읽기만 하면 된다.
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
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
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _HistoryButton(
            key: const Key('editor-undo'),
            icon: Icons.undo_rounded,
            tooltip: '실행 취소',
            onTap: canUndo ? onUndo : null,
          ),
          const SizedBox(width: 4),
          _HistoryButton(
            key: const Key('editor-redo'),
            icon: Icons.redo_rounded,
            tooltip: '다시 실행',
            onTap: canRedo ? onRedo : null,
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
    required this.onClipTrimChanged,
    required this.onClipTrimCommitted,
    required this.directCaptionAddMode,
    required this.onAddCaption,
    required this.onAddCaptionMode,
    required this.onAiCaption,
    this.onEditCaption,
    this.onDeleteCaption,
  });

  final EditorProject project;
  final EditorProjectController controller;
  final _RangeTimelineTarget target;
  final List<String> thumbnails;
  final ValueChanged<int> onSeek;

  /// 아래 넷은 자막 판만 쓴다 — 줌·스티커 띠는 구간만 다룬다.
  final bool directCaptionAddMode;

  /// 지금 위치에 자막을 하나 얹고 입력 시트를 연다.
  final VoidCallback onAddCaption;

  /// "지금 위치에 넣어요" 안내 카드를 먼저 띄운다(자막이 하나도 없을 때).
  final VoidCallback onAddCaptionMode;
  final VoidCallback onAiCaption;
  final ValueChanged<String>? onEditCaption;
  final ValueChanged<String>? onDeleteCaption;

  /// 클립의 컷 구간(원본 시각)을 바꾼다. 컷 편집 탭의 손잡이와 **같은**
  /// 콜백이다 — 되돌리기 이력과 잡은 쪽 프레임 미리보기가 거기에 들어 있다.
  final void Function(int startMs, int endMs, bool startHandle)
  onClipTrimChanged;
  final VoidCallback onClipTrimCommitted;
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
    final sticker = target.stickerLayer;
    if (sticker != null) return _stickerBar(sticker);
    return _textBar(target.textLayer);
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

  Widget _textBar(EditorTextLayer? layer) {
    // 자막은 타임라인 눈금이되 **묶인 클립**의 구간만 펼친다.
    var scope = project.selectedClip ?? project.clips.first;
    if (layer?.clipId != null) {
      for (final clip in project.clips) {
        if (clip.id == layer!.clipId) {
          scope = clip;
          break;
        }
      }
    }
    final clipTimelineStart = project.timelineStartFor(scope.id);
    final span = math.max(1, scope.durationMs);
    return _CaptionTimelinePanel(
      key: const Key('editor-text-range-bar'),
      project: project,
      controller: controller,
      scope: scope,
      clipTimelineStart: clipTimelineStart,
      span: span,
      thumbnails: _sliceThumbnails(scope.sourceStartMs, scope.sourceEndMs),
      directCaptionAddMode: directCaptionAddMode,
      onSeek: onSeek,
      onEditCommitted: onEditCommitted,
      onClipTrimChanged: onClipTrimChanged,
      onClipTrimCommitted: onClipTrimCommitted,
      onAddCaption: onAddCaption,
      onAddCaptionMode: onAddCaptionMode,
      onAiCaption: onAiCaption,
      onEditCaption: onEditCaption,
      onDeleteCaption: onDeleteCaption,
    );
  }

  /// 스티커(얼굴 추적 포함)의 구간 조절 띠. 자막과 같은 규칙 — 묶인 클립의
  /// 범위만 펼치고, 그 클립의 스티커 전부를 마커로 보여 준다.
  Widget _stickerBar(EditorStickerLayer layer) {
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
    // 얼굴 추적 스티커는 그 얼굴이 잡혀 있는 구간이 손잡이의 한계다.
    final coverage = layer.tracksFace ? project.faceCoverageFor(layer) : null;
    return TrimRangeBar(
      key: const Key('editor-sticker-range-bar'),
      sourceDurationMs: span,
      startMs: (layer.startMs - clipTimelineStart).clamp(0, span),
      endMs: (layer.endMs - clipTimelineStart).clamp(0, span),
      playheadSourceMs: (project.playheadMs - clipTimelineStart).clamp(0, span),
      thumbnails: _sliceThumbnails(scope.sourceStartMs, scope.sourceEndMs),
      zoomSegments: [
        for (final other in _stickerLayersOfClip(project, scope))
          EditorZoomSegment(
            id: 'sticker-${other.id}',
            sourceStartMs: (other.startMs - clipTimelineStart).clamp(0, span),
            sourceEndMs: (other.endMs - clipTimelineStart).clamp(0, span),
            scale: 1,
            focus: NormalizedPoint.center,
          ),
      ],
      minimumDurationMs: 200,
      lowerBoundMs: coverage == null
          ? 0
          : (coverage.startMs - clipTimelineStart).clamp(0, span),
      upperBoundMs: coverage == null
          ? span
          : (coverage.endMs - clipTimelineStart).clamp(0, span),
      windowSlidable: true,
      onTrimChanged: (startMs, endMs, _) =>
          controller.updateStickerLayerRangeGesture(
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

/// 자막 판의 조각 높이. 화면 쪽 [_captionPanelHeightFor]와 판 안쪽이 같은
/// 값을 봐야 "머리줄·프레임 띠·눈금은 그대로, 자막 줄 칸만 늘었다 줄었다"가
/// 어긋나지 않는다.
abstract final class _CaptionTimelineMetrics {
  /// 줄과 줄 사이(막대 중심에서 중심까지). 막대 4dp에 틈 6dp다 — 좁게 붙여야
  /// 자막 층이 한 덩이로 읽히고, 넓히면 줄마다 따로 노는 띠처럼 보인다.
  static const barPitch = 10.0;

  /// 고른 막대와 그 길이 손잡이가 쓰는 **손가락 자리**의 높이.
  ///
  /// **왜 줄 간격과 따로 두는가**: 눈에 보이는 줄 간격(10dp)을 그대로 손가락
  /// 자리로 쓰면 4dp 실선을 10dp 안에서 겨눠야 한다 — 열 번에 서너 번은
  /// 빗나갔다. 고른 막대는 이 값만큼 위아래로 넓혀 잡고, 고르지 않은 막대는
  /// 빗나간 손끝을 [_CaptionTimelinePanelState._selectNearest]가 가장 가까운
  /// 막대로 보내 준다. 그림은 촘촘한 채로 손가락만 넉넉해진다.
  static const selectedRowTouch = 22.0;

  /// 줄 칸 위 여백. 첫 줄이 눈금에 달라붙지 않게 띄우고, 고른 막대의 손가락
  /// 자리가 칸 위로 넘치지 않게 받쳐 준다.
  static const rowsPad = 7.0;

  /// 마지막 줄 **아래**에 비워 두는 칸. +N 배지가 여기 선다.
  ///
  /// **왜 줄 위가 아닌가**: 배지를 줄에 얹으면 그 자리의 막대가 숫자를 덮어
  /// 몇 줄이 더 있는지 읽을 수가 없다. 막대는 세 줄에서 끝나고, 숫자는 그
  /// 아래 빈 칸에서 해당 막대의 오른쪽 아래에 붙는다 — 서로 가릴 일이 없다.
  static const badgeRow = 20.0;

  /// 같은 줄에 선 막대끼리의 가로 틈. 이보다 가까우면 아래 줄로 내린다.
  static const barGap = 4.0;
  static const headerHeight = 22.0;
  static const headerGap = 4.0;
  static const stripHeight = 44.0;
  static const rulerHeight = 13.0;
  static const rowsGap = 4.0;

  /// 판을 감싸던 흰 카드를 걷어냈다 — 위아래로 숨 쉴 틈만 남긴다.
  static const outerMargin = 2.0;

  /// 막대를 그리는 줄 수의 한계. **이보다 깊게 겹치는 자리는 +N 배지로
  /// 접는다** — 손바닥만 한 화면에 층을 다섯 개 쌓아 봐야 어느 것이 어느
  /// 것인지 알 수 없고, 그렇다고 줄 칸을 세로로 넘기게 하면 프레임 띠에서
  /// 눈을 떼야 한다. 접힌 자막은 배지를 눌러 시트로 펼친다.
  static const visibleRows = 3;

  /// 직접 추가 안내 카드가 줄 칸을 대신 쓸 때 필요한 높이. 얇은 막대 줄과
  /// 달리 이 카드는 글 두 줄과 단추 한 줄이 들어간다 — 막대 줄 높이를
  /// 그대로 주면 단추가 잘려 누를 수 없다.
  static const addCardHeight = 104.0;

  /// 자막 카드 줄. 타임라인 판 **아래**에 붙어, 막대와 카드가 서로를 가리킨다.
  static const cardsGap = 5.0;

  /// 머리줄에는 만드는 단추 둘이 선다 — 단추 높이(36dp)를 담아야 한다.
  static const cardsHeaderHeight = 38.0;
  static const cardsHeaderGap = 5.0;

  /// 카드 한 장의 높이. 글 두 줄과 시각 한 줄이 눌리지 않고 들어가되, 이보다
  /// 키우면 S24+에서 미리보기가 화면의 절반 아래로 내려간다 — 자막을 고치는
  /// 동안에도 영상이 주인공이어야 한다.
  static const cardHeight = 68.0;
  static const cardGap = 9.0;

  /// 카드 폭은 화면 너비를 따라간다 — **두 장이 온전히 서고 셋째가 반쯤
  /// 잘려 보이는** 폭이라야 "옆으로 더 있다"가 스크롤바 없이 읽힌다.
  /// 넓은 기기에서 카드가 헐렁해지지 않게 위쪽을 막아 둔다.
  static const minimumCardWidth = 140.0;
  static const maximumCardWidth = 190.0;

  static double cardWidthFor(double viewportWidth) =>
      ((viewportWidth - cardGap * 2) / 2.35).clamp(
        minimumCardWidth,
        maximumCardWidth,
      );

  /// 카드 줄 전체(위 틈 + 머리줄 + 틈 + 카드).
  static const cardsSection =
      cardsGap + cardsHeaderHeight + cardsHeaderGap + cardHeight;

  /// 자막 줄 칸을 뺀 나머지 전부.
  static const chrome =
      outerMargin * 2 +
      headerHeight +
      headerGap +
      stripHeight +
      rulerHeight +
      rowsGap;

  /// 줄 칸의 높이. 위 여백 + 줄들 + 배지 칸이다.
  static double rowsHeight(int rows) => rowsPad + rows * barPitch + badgeRow;

  /// 마지막 줄 아래, 배지 칸이 시작되는 높이.
  static double badgeRowTop(int rows) => rowsPad + rows * barPitch;

  /// [lane]번째 줄의 위쪽. 막대는 이 자리에서 [barPitch] 안에 가운데로 선다.
  static double laneTop(int lane) => rowsPad + lane * barPitch;

  /// [lane]번째 막대의 한가운데.
  static double laneCenter(int lane) => laneTop(lane) + barPitch / 2;
}

/// 자막 판. 프레임 띠와 눈금 아래에 **자막 하나에 한 줄씩** 놓는다.
///
/// **왜 줄마다 하나인가**: 예전에는 직접·AI 두 레인에 자막을 겹쳐 그렸다.
/// 같은 시각에 자막이 셋이면 셋이 한 줄에 포개져 어느 것이 어느 것인지
/// 알 수 없었고, 0.3초짜리 AI 조각은 서로 붙어 빗살무늬가 됐다. 이제
/// 겹칠수록 아래로 쌓이고, [_CaptionTimelineMetrics.visibleRows]를 넘는
/// 층은 **+N 배지**로 접힌다 — 배지를 누르면 그 시점의 자막 전부가 시트로
/// 펼쳐진다. 프레임 띠와 눈금은 제자리에 있어야 "지금 어디"가 흔들리지 않는다.
///
/// 판 아래에는 자막 카드 줄이 붙어 막대와 **양방향으로** 이어진다. 막대를
/// 누르면 그 카드가 가운데로 흘러오고, 카드를 누르면 그 막대가 흰 테두리와
/// 그림자로 들린다.
///
/// 배율(1~4×)을 올리면 띠가 가로로 늘어나고 함께 가로로 스크롤한다. 긴
/// 클립에서 짧은 자막을 정확히 잡으려면 이 길이가 필요하다.
///
/// 색은 앱 팔레트 그대로다 — 직접 넣은 자막은 코랄, **AI 자막은 올리브**.
class _CaptionTimelinePanel extends StatefulWidget {
  const _CaptionTimelinePanel({
    super.key,
    required this.project,
    required this.controller,
    required this.scope,
    required this.clipTimelineStart,
    required this.span,
    required this.thumbnails,
    required this.directCaptionAddMode,
    required this.onSeek,
    required this.onEditCommitted,
    required this.onClipTrimChanged,
    required this.onClipTrimCommitted,
    required this.onAddCaption,
    required this.onAddCaptionMode,
    required this.onAiCaption,
    this.onEditCaption,
    this.onDeleteCaption,
  });

  final EditorProject project;
  final EditorProjectController controller;

  /// 이 판이 펼치는 클립. 자막도 눈금도 이 클립의 범위 안에서만 다룬다.
  final EditorClip scope;
  final int clipTimelineStart;
  final int span;
  final List<String> thumbnails;
  final bool directCaptionAddMode;
  final ValueChanged<int> onSeek;
  final VoidCallback onEditCommitted;

  /// 클립의 컷 구간(원본 시각)을 바꾼다. 컷 편집 탭의 손잡이와 같은 콜백이다.
  final void Function(int startMs, int endMs, bool startHandle)
  onClipTrimChanged;
  final VoidCallback onClipTrimCommitted;
  final VoidCallback onAddCaption;
  final VoidCallback onAddCaptionMode;
  final VoidCallback onAiCaption;
  final ValueChanged<String>? onEditCaption;
  final ValueChanged<String>? onDeleteCaption;

  @override
  State<_CaptionTimelinePanel> createState() => _CaptionTimelinePanelState();
}

class _CaptionTimelinePanelState extends State<_CaptionTimelinePanel> {
  /// 가로 배율. 2분짜리 영상의 3초 자막도 16배율이면 155dp라, 막대 폭이 곧
  /// 자막 길이가 된다 — 길이를 눈으로 재고 다듬는 자리다.
  static const _zoomLevels = <int>[1, 2, 4, 8, 16];
  static const _minimumCaptionMs = 200;

  /// 아주 짧은 자막의 막대도 이만큼은 그린다 — 0.2초짜리가 실 한 올이 되면
  /// 누를 수가 없다. 막대에 글자가 없으니 폭은 이것만 넘기면 되고, 그래서
  /// **막대 폭이 곧 자막 길이**로 읽힌다. 정확히 잡고 싶으면 배율을 올린다.
  static const _minimumBarWidth = 18.0;

  /// 길이 손잡이의 손가락 자리. 막대 끝을 가운데로 삼아 반은 안, 반은 밖에
  /// 걸친다.
  static const _handleTouchWidth = 26.0;

  /// 보이는 컷 경계선의 굵기. 손가락 자리는 [_cutTouchWidth]가 따로 낸다.
  static const _cutHandleWidth = 4.0;
  static const _cutTouchWidth = 40.0;

  /// 재생 봉을 잡는 자리의 폭. 컷 손잡이(40dp)와 겹쳐 그 둘을 덮지 않을
  /// 만큼만 넓힌다 — 봉은 늘 컷 손잡이 위에 있어서 더 넓히면 클립 처음·끝에서
  /// 컷을 잡을 수 없다.
  static const _playheadTouchWidth = 36.0;

  final ScrollController _horizontal = ScrollController();

  /// 판 아래 자막 카드 줄. 고른 자막의 카드를 가운데로 끌어온다.
  final ScrollController _cards = ScrollController();

  /// 지금 줄이 쓰고 있는 카드 폭. 화면 너비에서 나오므로 그릴 때 정해지고,
  /// [_revealCard]가 화면 밖 카드의 자리를 셈할 때 다시 쓴다.
  double _cardWidth = _CaptionTimelineMetrics.minimumCardWidth;
  int _zoomIndex = 0;

  /// 자막 구간을 끄는 중. 끄는 대상은 id로 기억한다 — 프로젝트가 매 프레임
  /// 새로 만들어지므로 레이어 객체를 붙들고 있으면 옛 값을 본다.
  String? _dragLayerId;
  bool _draggingStart = false;
  bool _sliding = false;
  double _travelPx = 0;
  double _msPerPx = 1;
  int _anchorStartMs = 0;
  int _anchorEndMs = 0;

  /// 지금 자막 끝이 달라붙어 있는 자리(타임라인 ms). 없으면 null.
  int? _snappedMs;

  bool _scrubbing = false;
  double _scrubMsPerPx = 1;
  int _playheadDragStartMs = 0;
  double _playheadTravelPx = 0;

  /// 컷 손잡이를 끄는 동안의 상태. 끄는 중에는 부모가 다시 그리지 않으므로
  /// (`trimSelectedClip(notify: false)`) 잡은 자리를 이 위젯이 직접 기억한다.
  bool _cutDragging = false;
  bool _cutDraggingStart = false;
  double _cutTravelPx = 0;
  double _cutMsPerPx = 1;
  int _cutAnchorStartMs = 0;
  int _cutAnchorEndMs = 0;
  int _cutStartMs = 0;
  int _cutEndMs = 0;

  int get _zoom => _zoomLevels[_zoomIndex];

  /// 이 클립의 자막을 시작 시각 순으로. 겹치는 자막이 위에서 아래로 계단처럼
  /// 놓여야 "무엇이 무엇 위에 얹혔는지"가 한눈에 들어온다.
  List<EditorTextLayer> get _layers =>
      _textLayersOfClip(widget.project, widget.scope)..sort((a, b) {
        final byStart = a.startMs.compareTo(b.startMs);
        return byStart != 0 ? byStart : a.id.compareTo(b.id);
      });

  /// 지금 끌고 있는 자막. 프로젝트가 매 프레임 새로 만들어지므로 id로 찾는다.
  EditorTextLayer? get _draggingLayer {
    final id = _dragLayerId;
    if (id == null) return null;
    for (final layer in widget.project.textLayers) {
      if (layer.id == id) return layer;
    }
    return null;
  }

  /// 자막 id → 카드에 찍히는 번호(1부터)의 밑값. 색도 이 순번에서 나온다.
  ///
  /// **왜 미리 담아 두는가**: [_layers]는 부를 때마다 목록을 새로 만들고
  /// 정렬한다. 막대마다 제 순번을 물으면 한 프레임에 자막 수만큼 정렬이
  /// 돌아, 손잡이를 끄는 동안 막대가 손끝을 못 따라온다. [build]에서 한 번
  /// 담고 그 프레임 내내 돌려 쓴다.
  Map<String, int> _order = const {};

  /// AI가 만든 자막은 어디서나 올리브 하나, 직접 넣은 자막은 순번마다 다른
  /// 색이다 — 막대와 카드가 같은 색으로 같은 자막을 가리킨다.
  Color _accent(EditorTextLayer layer) =>
      _captionAccent(layer, _order[layer.id] ?? 0);

  /// 막대를 채우는 색. **거의 원색 그대로**다 — 흰 바탕에 눕는 4dp 실선이라
  /// 조금만 옅게 깔아도 색이 바래 셋을 구분하기 어려워진다. 고른 것만 온전한
  /// 원색이고, 나머지도 그 턱밑까지 온다. "지금 잡은 것"은 색보다 두께
  /// (4dp→6dp)가 먼저 말한다.
  Color _fill(EditorTextLayer layer, bool selected) =>
      _accent(layer).withValues(alpha: selected ? 1 : 0.92);

  @override
  void didUpdateWidget(covariant _CaptionTimelinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.playheadMs != widget.project.playheadMs) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealPlayhead());
    }
    // 고른 자막이 바뀌면 그 카드를 가운데로 끌어온다. 막대를 눌렀을 때든
    // 영상 위 글자 상자를 눌렀을 때든 **같은 자리**에서 처리해야, 어디서
    // 골랐느냐에 따라 카드가 따라오다 말다 하지 않는다.
    if (oldWidget.project.selectedLayerId != widget.project.selectedLayerId) {
      final selected = widget.project.selectedLayerId;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _revealCard(selected),
      );
    }
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _cards.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final layers = _layers;
    _order = {
      for (var index = 0; index < layers.length; index++)
        layers[index].id: index,
    };
    // 카드 줄은 고를 자막이 있을 때만 붙는다. 높이를 정하는
    // [_captionPanelHeightFor]도 같은 조건을 본다.
    final cards = layers.isNotEmpty && !widget.directCaptionAddMode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 눈금 판이 남는 자리를 먹는다 — 판 높이가 카드 줄과 어긋나도 넘치는
        // 대신 눈금 판이 먼저 줄어든다.
        //
        // 판을 감싸던 흰 카드(둥근 모서리 + 크림빛 테두리)는 걷어냈다. 화면
        // 절반을 차지하는 조각을 또 한 겹 상자에 넣으면 안쪽 여백만큼 프레임이
        // 좁아지고, 정작 봐야 할 그림 대신 테두리가 눈에 먼저 들어온다.
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: _CaptionTimelineMetrics.outerMargin,
            ),
            child: Column(
              key: const Key('editor-caption-track-timeline'),
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: _CaptionTimelineMetrics.headerHeight,
                  child: _header(),
                ),
                const SizedBox(height: _CaptionTimelineMetrics.headerGap),
                Expanded(child: LayoutBuilder(builder: _track)),
              ],
            ),
          ),
        ),
        if (cards)
          SizedBox(
            height: _CaptionTimelineMetrics.cardsSection,
            child: _cardStrip(layers),
          ),
      ],
    );
  }

  /// 머리줄. 제목 하나와 배율 조작 하나가 **같은 줄**에 선다 — 이 판은 곧
  /// 프레임 띠라, 이름도 컷 편집 탭과 같은 '프레임 타임라인'이다.
  Widget _header() => Row(
    children: [
      const Expanded(
        child: Text(
          '프레임 타임라인',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: EditorColorTokens.ink,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      const Text(
        '핀치로 확대',
        style: TextStyle(
          color: EditorColorTokens.subtle,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
      const SizedBox(width: 6),
      _zoomStepper(),
    ],
  );

  /// 가로 배율. 짧은 자막이 서로 붙어 잡히지 않을 때 늘려 본다.
  ///
  /// 캡슐도 테두리도 없다 — 글자와 아이콘만 놓는다. 머리줄의 주인공은 아래
  /// 프레임이지 이 조작부가 아니다.
  Widget _zoomStepper() => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _zoomStep(
        keyValue: const Key('editor-caption-zoom-out'),
        icon: Icons.remove_rounded,
        onTap: _zoomIndex > 0 ? () => _setZoom(_zoomIndex - 1) : null,
      ),
      SizedBox(
        width: 26,
        child: Text(
          '$_zoom×',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: EditorColorTokens.ink,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ),
      _zoomStep(
        keyValue: const Key('editor-caption-zoom-in'),
        icon: Icons.add_rounded,
        onTap: _zoomIndex < _zoomLevels.length - 1
            ? () => _setZoom(_zoomIndex + 1)
            : null,
      ),
    ],
  );

  Widget _zoomStep({
    required Key keyValue,
    required IconData icon,
    VoidCallback? onTap,
  }) => GestureDetector(
    key: keyValue,
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: SizedBox(
      width: 24,
      height: _CaptionTimelineMetrics.headerHeight,
      child: Icon(
        icon,
        size: 16,
        color: onTap == null
            ? EditorColorTokens.hairline
            : EditorColorTokens.ink,
      ),
    ),
  );

  void _setZoom(int index) {
    setState(() => _zoomIndex = index);
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealPlayhead());
  }

  /// 판 아래 자막 카드 줄. 막대가 "얼마나 길고 어디 얹혔는지"를 말한다면
  /// 카드는 "무슨 말이 적혀 있는지"를 말한다 — 좁은 막대에서 잘린 글을 여기서
  /// 온전히 읽고, 연필로 바로 고치러 들어간다.
  Widget _cardStrip(List<EditorTextLayer> layers) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SizedBox(height: _CaptionTimelineMetrics.cardsGap),
      SizedBox(
        height: _CaptionTimelineMetrics.cardsHeaderHeight,
        child: _cardStripHeader(layers),
      ),
      const SizedBox(height: _CaptionTimelineMetrics.cardsHeaderGap),
      SizedBox(
        height: _CaptionTimelineMetrics.cardHeight,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 카드 폭은 화면 너비에서 나오되, 한번 정해지면 줄 전체가 같은
            // 폭을 쓴다. 가운데로 끌어오는 자리를 글자 길이와 상관없이 셈으로
            // 정할 수 있어야, 아직 그려지지도 않은(화면 밖) 카드도 정확히
            // 가운데로 온다.
            _cardWidth = _CaptionTimelineMetrics.cardWidthFor(
              constraints.maxWidth,
            );
            return ListView.builder(
              key: const Key('editor-caption-cards'),
              controller: _cards,
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.zero,
              itemExtent: _cardWidth + _CaptionTimelineMetrics.cardGap,
              itemCount: layers.length,
              itemBuilder: (context, index) {
                final layer = layers[index];
                return Padding(
                  padding: const EdgeInsets.only(
                    right: _CaptionTimelineMetrics.cardGap,
                  ),
                  child: _CaptionCard(
                    keyValue: Key('editor-caption-card-${layer.id}'),
                    layer: layer,
                    order: index + 1,
                    accent: _captionAccent(layer, index),
                    selected: layer.id == widget.project.selectedLayerId,
                    onTap: () => _select(layer),
                    onEdit: widget.onEditCaption == null
                        ? null
                        : () => widget.onEditCaption!(layer.id),
                  ),
                );
              },
            );
          },
        ),
      ),
    ],
  );

  /// 카드 줄 머리. 만드는 단추 둘은 **여기**에 있다 — 재생 줄에 두면 재생·
  /// 시각·되돌리기와 일곱 가지가 한 줄에 끼어 앉는다. 자막을 만드는 일은
  /// 자막 목록 바로 위가 제자리다.
  Widget _cardStripHeader(List<EditorTextLayer> layers) {
    final selected = widget.project.selectedLayerId;
    final removable =
        widget.onDeleteCaption != null &&
        layers.any((layer) => layer.id == selected);
    return Row(
      children: [
        // 제목은 한 줄이다. 단추 셋이 들어갈 자리를 먼저 내주고 남는 만큼만
        // 쓴다 — 좁은 기기에서는 제목이 줄어들지언정 단추가 밀려나지 않는다.
        Flexible(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Flexible(
                child: Text(
                  '자막 · 이 클립의 자막',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: EditorColorTokens.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${layers.length}개',
                style: const TextStyle(
                  color: EditorColorTokens.subtle,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _SubtitleActionButton(
          keyValue: const Key('editor-open-ai-caption'),
          label: 'AI 자막',
          color: EditorColorTokens.ink,
          borderColor: EditorColorTokens.hairline,
          onPressed: widget.onAiCaption,
        ),
        const SizedBox(width: 8),
        _SubtitleActionButton(
          keyValue: const Key('editor-open-text-sheet'),
          label: '추가',
          icon: Icons.add_rounded,
          color: AppColors.coral,
          filled: true,
          onPressed: widget.onAddCaption,
        ),
        // 휴지통은 고른 자막이 있을 때만 선다 — 무엇이 지워질지 모르는 채로
        // 놓여 있으면 누를 수가 없다.
        if (removable)
          GestureDetector(
            key: const Key('editor-caption-delete-selected'),
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onDeleteCaption!(selected!),
            child: const SizedBox(
              width: 32,
              height: _CaptionTimelineMetrics.cardsHeaderHeight,
              child: Icon(
                Icons.delete_outline_rounded,
                size: 19,
                color: EditorColorTokens.subtle,
              ),
            ),
          ),
      ],
    );
  }

  /// 고른 자막의 카드를 줄 가운데로 흘려보낸다(웹의
  /// `scrollIntoView({inline: 'center'})`와 같은 자리).
  ///
  /// 카드 자리를 **셈으로** 구한다 — 카드를 붙들고 있는 열쇠(GlobalKey)로
  /// 찾으면 화면 밖 카드는 아직 그려지지 않아 못 찾는다. 타임라인 맨 끝
  /// 막대를 눌렀을 때가 바로 그 경우다.
  void _revealCard(String? layerId) {
    if (layerId == null || !mounted || !_cards.hasClients) return;
    final index = _layers.indexWhere((layer) => layer.id == layerId);
    if (index < 0) return;
    final position = _cards.position;
    if (!position.haveDimensions) return;
    final extent = _cardWidth + _CaptionTimelineMetrics.cardGap;
    final target =
        index * extent - (position.viewportDimension - _cardWidth) / 2;
    unawaited(
      position.animateTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  /// 프레임 띠 · 눈금 · 자막 줄을 한 덩이로 그린다. 배율이 1보다 크면 이
  /// 덩이가 화면보다 넓어져 가로로 스크롤한다 — 세 조각이 늘 같은 눈금을
  /// 쓰려면 함께 움직여야 한다.
  Widget _track(BuildContext context, BoxConstraints constraints) {
    final viewportWidth = math.max(1.0, constraints.maxWidth);
    final trackWidth = viewportWidth * _zoom;
    final trackHeight = math.max(0.0, constraints.maxHeight);
    final layers = _layers;
    final playheadX = _xOf(widget.project.playheadMs, trackWidth);
    // 컷 손잡이는 **고른 클립**에만 붙인다 — 자르는 함수가 고른 클립을
    // 대상으로 삼으므로, 다른 클립의 자막을 보고 있을 때 손잡이를 내주면
    // 엉뚱한 클립이 잘린다.
    final trimmable = widget.scope.id == widget.project.selectedClip?.id;
    // 끄는 중에는 필름스트립이 그대로 서 있고 손잡이만 움직인다. 어디서
    // 잘리는지가 프레임 위에 바로 보인다.
    final cutStartX = _cutDragging
        ? ((_cutStartMs - _cutAnchorStartMs) / _cutMsPerPx).clamp(
            0.0,
            trackWidth,
          )
        : 0.0;
    final cutEndX = _cutDragging
        ? ((_cutEndMs - _cutAnchorStartMs) / _cutMsPerPx).clamp(0.0, trackWidth)
        : trackWidth;

    return SizedBox(
      height: trackHeight,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        controller: _horizontal,
        physics: _zoom == 1
            ? const NeverScrollableScrollPhysics()
            : const ClampingScrollPhysics(),
        child: SizedBox(
          width: trackWidth,
          height: trackHeight,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: _CaptionTimelineMetrics.stripHeight,
                    child: GestureDetector(
                      key: const Key('editor-caption-video-track'),
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) => widget.onSeek(
                        widget.clipTimelineStart +
                            (details.localPosition.dx /
                                    trackWidth *
                                    widget.span)
                                .round()
                                .clamp(0, widget.span),
                      ),
                      // 배율을 올린 동안에는 띠를 끌어 **옆으로 넘긴다**.
                      // 재생 위치는 눌러서 옮기거나 분홍 봉을 잡는다 —
                      // 넘기려는 손짓마다 재생 위치가 따라오면 넓혀 놓은
                      // 띠를 볼 수가 없다.
                      onHorizontalDragStart: _zoom == 1
                          ? (_) => _startScrub(trackWidth)
                          : null,
                      onHorizontalDragUpdate: _zoom == 1
                          ? (details) => _updateScrub(details.delta.dx)
                          : null,
                      onHorizontalDragEnd: _zoom == 1
                          ? (_) => _endScrub()
                          : null,
                      onHorizontalDragCancel: _zoom == 1 ? _endScrub : null,
                      child: _filmStrip(),
                    ),
                  ),
                  // 눈금 줄은 통째로 재생 봉을 끄는 자리다.
                  //
                  // **왜 여기인가**: 배율을 올리면 프레임 띠의 가로 끌기는
                  // 띠를 옆으로 넘기는 데 쓰인다. 그래서 확대해 놓으면 봉을
                  // 옮길 길이 "봉 자체를 정확히 집는 것" 하나뿐이었다 —
                  // 봉이 자유롭게 움직이지 않던 정체다. 눈금 줄은 어느
                  // 배율에서나 끌면 봉이 따라오고, 누르면 그 자리로 간다.
                  SizedBox(
                    height:
                        _CaptionTimelineMetrics.rulerHeight +
                        _CaptionTimelineMetrics.rowsGap,
                    child: GestureDetector(
                      key: const Key('editor-caption-ruler-scrub'),
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) => widget.onSeek(
                        widget.clipTimelineStart +
                            (details.localPosition.dx /
                                    trackWidth *
                                    widget.span)
                                .round()
                                .clamp(0, widget.span),
                      ),
                      onHorizontalDragStart: (_) => _startScrub(trackWidth),
                      onHorizontalDragUpdate: (details) =>
                          _updateScrub(details.delta.dx),
                      onHorizontalDragEnd: (_) => _endScrub(),
                      onHorizontalDragCancel: _endScrub,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: SizedBox(
                          height: _CaptionTimelineMetrics.rulerHeight,
                          child: _ruler(trackWidth),
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: _rows(layers, trackWidth)),
                ],
              ),
              // 컷 손잡이는 재생 봉보다 아래에 그리고, 손가락 판은 위에
              // 얹는다. 봉이 클립 끝에 붙어 있어도 자를 수 있어야 한다.
              if (trimmable) ...[
                if (_cutDragging) ...[
                  _cutVeil(left: 0, width: cutStartX),
                  _cutVeil(left: cutEndX, width: trackWidth - cutEndX),
                ],
                _cutHandleFace(edgeX: cutStartX, isStart: true),
                _cutHandleFace(edgeX: cutEndX, isStart: false),
              ],
              _playheadLine(playheadX),
              _playheadKnob(playheadX, trackWidth),
              if (trimmable) ...[
                _cutHandleTouch(
                  keyValue: const Key('editor-caption-clip-start-handle'),
                  edgeX: cutStartX,
                  isStart: true,
                  trackWidth: trackWidth,
                ),
                _cutHandleTouch(
                  keyValue: const Key('editor-caption-clip-end-handle'),
                  edgeX: cutEndX,
                  isStart: false,
                  trackWidth: trackWidth,
                ),
              ],
              // 봉을 잡는 자리는 **가장 위**다. 컷 손잡이보다 아래에 두면
              // 봉이 클립 처음(00:00)에 붙어 있을 때 잡을 수가 없다 — 처음
              // 열었을 때가 바로 그 상태다. 대신 컷 손잡이는 40dp 중 25dp가
              // 남아 여전히 잡힌다.
              _playheadTouch(
                keyValue: const Key('editor-caption-playhead-handle'),
                x: playheadX,
                trackWidth: trackWidth,
                top: 0,
                height:
                    _CaptionTimelineMetrics.stripHeight +
                    _CaptionTimelineMetrics.rulerHeight +
                    _CaptionTimelineMetrics.rowsGap,
              ),
              if (_cutDragging)
                _dragBadge(
                  '컷 ${frameClock(_cutStartMs)}–${frameClock(_cutEndMs)}',
                )
              else if (_draggingLayer case final layer?)
                _dragBadge(
                  '${frameClock(layer.startMs)}–${frameClock(layer.endMs)}',
                  snapped: _snappedMs != null,
                ),
            ],
          ),
        ),
      ),
    );
  }

  double _xOf(int timelineMs, double trackWidth) =>
      ((timelineMs - widget.clipTimelineStart) / widget.span * trackWidth)
          .clamp(0.0, trackWidth);

  Widget _filmStrip() {
    if (widget.thumbnails.isEmpty) {
      return const DecoratedBox(
        decoration: BoxDecoration(
          color: EditorColorTokens.border,
          borderRadius: BorderRadius.all(Radius.circular(3)),
        ),
      );
    }
    return ClipRRect(
      // 모서리는 "각지지 않았다"가 느껴질 만큼만 깎는다. 크게 굴리면 프레임
      // 네 귀퉁이가 잘려 나가 첫 장면·끝 장면을 가늠하기 어려워진다.
      borderRadius: BorderRadius.circular(3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final path in widget.thumbnails)
            Expanded(
              child: Image.file(
                File(path),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: FilterQuality.low,
                errorBuilder: (_, _, _) =>
                    const ColoredBox(color: EditorColorTokens.border),
              ),
            ),
        ],
      ),
    );
  }

  /// 시각 눈금. 글자끼리 붙지 않을 만큼 성긴 간격을 고른다.
  Widget _ruler(double trackWidth) {
    final step = _rulerStepMs(trackWidth);
    return Stack(
      children: [
        for (var ms = 0; ms <= widget.span; ms += step)
          Positioned(
            left: (ms / widget.span * trackWidth - 22).clamp(
              0.0,
              math.max(0.0, trackWidth - 44),
            ),
            top: 2,
            width: 44,
            child: Text(
              _formatMs(widget.clipTimelineStart + ms),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: EditorColorTokens.subtle,
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
      ],
    );
  }

  int _rulerStepMs(double trackWidth) {
    const candidates = [
      500,
      1000,
      2000,
      5000,
      10000,
      15000,
      30000,
      60000,
      120000,
      300000,
    ];
    for (final step in candidates) {
      if (step / widget.span * trackWidth >= 56) return step;
    }
    return math.max(1000, widget.span);
  }

  /// 자막 줄 칸. 자막이 없으면 만드는 두 갈래를, 추가 모드면 안내 카드를
  /// 대신 세운다 — 이 자리가 자막 탭의 본문 전부다.
  Widget _rows(List<EditorTextLayer> layers, double trackWidth) {
    if (widget.directCaptionAddMode) {
      return SingleChildScrollView(
        child: _DirectCaptionAddCard(
          playheadMs: widget.project.playheadMs,
          onAdd: widget.onAddCaption,
        ),
      );
    }
    if (layers.isEmpty) {
      return SingleChildScrollView(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _SubtitleEntryCard(
                keyValue: const Key('editor-caption-empty-direct'),
                icon: Icons.keyboard_alt_outlined,
                iconColor: AppColors.coral,
                title: '직접 자막',
                description: '원하는 문장을 입력해요',
                onTap: widget.onAddCaptionMode,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SubtitleEntryCard(
                keyValue: const Key('editor-caption-empty-ai'),
                icon: Icons.graphic_eq_rounded,
                iconColor: AppColors.sageDark,
                title: '자동 자막',
                description: '영상 속 대사를 만들어요',
                badge: 'AI',
                onTap: widget.onAiCaption,
              ),
            ),
          ],
        ),
      );
    }
    // 겹침이 [visibleRows]를 넘으면 넘치는 층은 그리지 않고, 덩이마다
    // +N 배지 하나로 접는다.
    final all = _lanes(layers, trackWidth);
    final lanes = all.take(_CaptionTimelineMetrics.visibleRows).toList();
    final clusters = _overflowClusters(all, trackWidth);
    final placements = <_CaptionPlacement>[];
    for (var lane = 0; lane < lanes.length; lane++) {
      for (final layer in lanes[lane]) {
        final span = _barSpan(layer, trackWidth);
        placements.add(
          _CaptionPlacement(
            layer: layer,
            lane: lane,
            left: span.left,
            width: span.width,
          ),
        );
      }
    }
    final selectedId = widget.project.selectedLayerId;
    final chosen = placements
        .where((placement) => placement.layer.id == selectedId)
        .firstOrNull;
    // 줄을 ListView로 쌓지 않고 한 판에 그린다. 줄마다 상자를 두면 막대의
    // 손가락 자리가 그 상자(10dp) 밖으로 나갈 수 없어, 고른 막대를 넉넉히
    // 넓혀 잡을 수가 없었다.
    return LayoutBuilder(
      builder: (context, constraints) => Stack(
        key: const Key('editor-caption-rows'),
        children: [
          // 빗나간 손끝을 가장 가까운 막대로 보낸다. 막대들 **아래**에 깔려
          // 있으므로 막대를 제대로 짚었을 때는 여기까지 내려오지 않는다.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) =>
                  _selectNearest(details.localPosition, placements),
              child: const SizedBox.expand(),
            ),
          ),
          for (final cluster in clusters)
            _overflowBadge(
              cluster: cluster,
              trackWidth: trackWidth,
              rowsHeight: constraints.maxHeight,
              lanes: lanes.length,
            ),
          for (final placement in placements)
            if (placement.layer.id != selectedId)
              _captionRow(placement, trackWidth, selected: false),
          // 고른 막대와 그 길이 손잡이는 가장 위에, 가장 넓은 손가락 자리로.
          if (chosen != null) ...[
            _captionRow(chosen, trackWidth, selected: true),
            ..._rangeHandles(chosen, trackWidth),
          ],
        ],
      ),
    );
  }

  /// 빗나간 손끝을 가장 가까운 막대로 보낸다.
  ///
  /// **왜 필요한가**: 막대는 4dp고 줄 간격은 10dp다. 사진처럼 촘촘한 그림을
  /// 지키면서 그 실선을 정확히 겨누라고 하면 열 번에 서너 번은 헛손질이 된다.
  /// 눈에 보이는 것은 그대로 두고, 닿는 자리만 넓힌다.
  void _selectNearest(Offset point, List<_CaptionPlacement> placements) {
    const reach = 20.0;
    EditorTextLayer? best;
    var bestDistance = double.infinity;
    for (final placement in placements) {
      final dy = (point.dy - _CaptionTimelineMetrics.laneCenter(placement.lane))
          .abs();
      final dx = point.dx < placement.left
          ? placement.left - point.dx
          : point.dx > placement.left + placement.width
          ? point.dx - (placement.left + placement.width)
          : 0.0;
      if (dx > reach || dy > reach) continue;
      // 가로로 빗나간 것은 더 크게 친다 — 옆으로 벗어났다면 그 자막을 겨눈
      // 것이 아니라 이웃을 겨눴을 때가 많다.
      final distance = dx * 1.6 + dy;
      if (distance >= bestDistance) continue;
      bestDistance = distance;
      best = placement.layer;
    }
    if (best != null) _select(best);
  }

  /// 줄 칸에 담기지 않은 자막들을 겹치는 것끼리 한 덩이로 묶는다. 덩이마다
  /// +N 배지 하나가 서고, 그 배지를 누르면 [_openOverlapSheet]가 그 시점의
  /// 자막 전부를 펼친다.
  ///
  /// **N은 접힌 줄 수다.** 세 줄까지는 막대가 그대로 보이니 셀 필요가 없고,
  /// 네 번째 줄부터가 "여기 더 있다"의 대상이다 — 한 줄 접히면 +1, 두 줄이면
  /// +2. 같은 줄에 나란히 선 자막 둘이 한 덩이에 들어와도 그건 한 줄이다.
  List<_CaptionOverflowCluster> _overflowClusters(
    List<List<EditorTextLayer>> lanes,
    double trackWidth,
  ) {
    // 접힌 자막을 **어느 줄에 있었는지**와 함께 들고 간다. 배지가 세는 것은
    // 자막 수가 아니라 줄 수라서, 같은 줄에 나란히 선 자막 둘은 한 줄로
    // 친다([_CaptionOverflowCluster.count]).
    final hidden =
        <({EditorTextLayer layer, int lane})>[
          for (final (index, lane) in lanes.indexed)
            if (index >= _CaptionTimelineMetrics.visibleRows)
              for (final layer in lane) (layer: layer, lane: index),
        ]..sort((a, b) {
          final byStart = a.layer.startMs.compareTo(b.layer.startMs);
          return byStart != 0 ? byStart : a.layer.id.compareTo(b.layer.id);
        });
    final clusters = <_CaptionOverflowCluster>[];
    // 덩이마다 "여기 걸친 줄 번호"를 모은다. 같은 줄이 두 번 들어와도 하나다.
    final lanesInCluster = <Set<int>>[];
    for (final entry in hidden) {
      final span = _barSpan(entry.layer, trackWidth);
      final right = span.left + span.width;
      final last = clusters.isEmpty ? null : clusters.last;
      if (last != null && span.left <= last.right) {
        lanesInCluster.last.add(entry.lane);
        clusters[clusters.length - 1] = _CaptionOverflowCluster(
          right: math.max(last.right, right),
          // 덩이가 다 함께 떠 있는 순간 — 가장 늦게 시작한 자막의 시작이다.
          atMs: math.max(last.atMs, entry.layer.startMs),
          count: lanesInCluster.last.length,
        );
        continue;
      }
      lanesInCluster.add({entry.lane});
      clusters.add(
        _CaptionOverflowCluster(
          right: right,
          atMs: entry.layer.startMs,
          count: 1,
        ),
      );
    }
    return clusters;
  }

  /// 자막을 줄에 나눠 담는다.
  ///
  /// **왜 한 자막에 한 줄이 아닌가**: 자막 스무 개가 서로 안 겹쳐도 줄이
  /// 스무 개가 되어, 아래로 한참 넘겨야 다음 자막이 나왔다. 이제 앞 자막이
  /// 끝난 자리부터는 같은 줄을 이어 쓴다 — **겹치는 자막만** 아래 줄로
  /// 밀린다. 겹친 자막이 셋이면 줄도 셋, 안 겹치면 줄 하나로 끝난다.
  ///
  /// 겹침은 시각이 아니라 **그려지는 자리**로 따진다. 짧은 자막은 최소 폭만큼
  /// 자리를 차지하므로, 시각만 보면 안 겹치는데 그림은 포개지는 일이 생긴다.
  ///
  /// **직접 넣은 자막이 먼저 자리를 잡는다.** 예전에는 시작 시각 순으로만
  /// 담았다. AI 자막 스무 줄이 이미 세 층을 채워 놓은 자리에 '+ 추가'로 자막을
  /// 하나 얹으면, 그 자막은 넷째 층으로 밀려 [visibleRows] 밖으로 나갔다 —
  /// 카드 줄에는 새 카드가 서는데 위 타임라인에는 코랄 막대가 나타나지 않던
  /// 정체가 이것이다. 직접 자막은 몇 개 되지 않으므로 먼저 담아도 층이 늘지
  /// 않고, 사용자가 방금 만든 것은 언제나 눈에 보인다.
  List<List<EditorTextLayer>> _lanes(
    List<EditorTextLayer> layers,
    double trackWidth,
  ) {
    const gap = _CaptionTimelineMetrics.barGap;
    final lanes = <List<EditorTextLayer>>[];
    // 줄마다 **이미 찬 자리 전부**를 들고 있는다. 예전처럼 오른쪽 끝 하나만
    // 기억하면 나중에 담는 무리(AI 자막)가 앞쪽 빈자리를 못 쓰고 줄만 늘린다.
    final taken = <List<({double left, double right})>>[];
    for (final layer in [
      for (final layer in layers)
        if (!_automaticCaption(layer)) layer,
      for (final layer in layers)
        if (_automaticCaption(layer)) layer,
    ]) {
      final span = _barSpan(layer, trackWidth);
      final left = span.left;
      final right = span.left + span.width;
      var placed = false;
      for (var lane = 0; lane < lanes.length; lane++) {
        final collides = taken[lane].any(
          (other) => left < other.right + gap && other.left < right + gap,
        );
        if (collides) continue;
        lanes[lane].add(layer);
        taken[lane].add((left: left, right: right));
        placed = true;
        break;
      }
      if (placed) continue;
      lanes.add([layer]);
      taken.add([(left: left, right: right)]);
    }
    return lanes;
  }

  /// 막대가 그려지는 자리. 폭은 자막이 떠 있는 길이지만, 양끝 손잡이를 잡을
  /// 수 있는 [_minimumBarWidth] 아래로는 줄지 않는다.
  ({double left, double width}) _barSpan(
    EditorTextLayer layer,
    double trackWidth,
  ) {
    final startX = _xOf(layer.startMs, trackWidth);
    final width = math.min(
      trackWidth,
      math.max(_minimumBarWidth, _xOf(layer.endMs, trackWidth) - startX),
    );
    return (
      left: math.max(0.0, math.min(startX, trackWidth - width)),
      width: width,
    );
  }

  /// 접힌 겹침을 알리는 +N 배지. **마지막 줄 아래 빈 칸**의, 접힌 덩이가
  /// 끝나는 자리에 선다 — 곧 해당 막대의 오른쪽 아래다.
  ///
  /// **왜 줄 밖인가**: 예전에는 줄 칸 위에 얹었다. 한가운데에 두면 둘째 줄
  /// 막대를, 셋째 줄에 맞추면 셋째 줄 막대를 덮어 **숫자가 가려졌다** —
  /// 자막이 촘촘한 구간일수록 심했고, 정작 "몇 줄이 더 있나"를 읽을 수 없는
  /// 배지가 됐다. 막대는 세 줄에서 끝나고 숫자는 그 아래 칸에서 사니, 이제
  /// 둘이 서로를 가리지 않는다.
  Widget _overflowBadge({
    required _CaptionOverflowCluster cluster,
    required double trackWidth,
    required double rowsHeight,
    required int lanes,
  }) {
    const width = EditorSpacingTokens.minimumTouch;
    final top = _CaptionTimelineMetrics.badgeRowTop(lanes);
    final height = math.min(
      _CaptionTimelineMetrics.badgeRow,
      math.max(0.0, rowsHeight - top),
    );
    return Positioned(
      // 접힌 덩이가 끝나는 자리에 걸친다. 띠 끝에서는 안쪽으로 물러선다.
      left: (cluster.right - width / 2).clamp(
        0.0,
        math.max(0.0, trackWidth - width),
      ),
      top: top.clamp(0.0, math.max(0.0, rowsHeight - height)),
      width: width,
      height: height,
      child: GestureDetector(
        key: Key('editor-caption-overflow-${cluster.atMs}'),
        behavior: HitTestBehavior.opaque,
        onTap: () => unawaited(_openOverlapSheet(cluster.atMs)),
        // 알갱이는 테두리 없는 옅은 회색이다 — 자막 막대가 아니라 "더 있다"는
        // 표시라서, 색을 가지면 자막 하나로 잘못 읽힌다.
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: EditorColorTokens.badge,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                '+${cluster.count}',
                style: const TextStyle(
                  color: EditorColorTokens.subtle,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 겹친 자막을 한자리에 펼치는 시트. 배지를 누른 순간의 시각으로 재생 봉을
  /// 옮긴 다음 연다 — 시트가 말하는 "현재 시점"과 영상이 어긋나지 않는다.
  ///
  /// 시트는 자막 판 위로 올라오지 않는다. 미리보기를 덮으면 고른 자막이 영상
  /// 위에서 어디 있는지를 볼 수 없어, 정작 고칠 자막을 못 고른다.
  Future<void> _openOverlapSheet(int atMs) async {
    widget.onSeek(atMs);
    final screenHeight = MediaQuery.sizeOf(context).height;
    final box = context.findRenderObject() as RenderBox?;
    final panelTop = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero).dy
        : screenHeight / 2;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      constraints: BoxConstraints(
        maxHeight: (screenHeight - panelTop).clamp(200.0, screenHeight),
      ),
      builder: (_) => _CaptionOverlapSheet(
        controller: widget.controller,
        scope: widget.scope,
        atMs: atMs,
        // 시트에서 고를 때는 재생 봉을 옮기지 않는다 — 시트가 말하는
        // "현재 시점"이 발밑에서 달아나면 무엇을 고르고 있는지 알 수 없다.
        // 고르기만 해도 막대는 들리고 아래 카드는 가운데로 온다.
        onSelect: (layer) => widget.controller.selectLayer(layer.id),
        onEdit: widget.onEditCaption,
        onDelete: widget.onDeleteCaption,
      ),
    );
  }

  /// 자막 한 줄. **막대의 폭이 곧 자막이 떠 있는 길이다** — 손잡이를 끌면
  /// 그만큼 막대가 줄고 는다.
  ///
  /// 막대에는 글자가 없다. 무슨 말이 적혀 있는지는 아래 자막 카드가 말하고,
  /// 막대는 **길이와 색**만 말한다 — 글자를 담으려고 짧은 자막까지 부풀리면
  /// 길이가 다른 자막들이 죄다 같은 폭으로 보였다.
  ///
  /// 손잡이는 **고른 줄에만** 붙는다. 줄마다 둘이 늘 서 있으면 겹친 자막이
  /// 여럿일 때 화면이 눈금인지 단추밭인지 알 수 없다.
  Widget _captionRow(
    _CaptionPlacement placement,
    double trackWidth, {
    required bool selected,
  }) => Positioned(
    left: placement.left,
    width: placement.width,
    top: _touchTop(placement.lane, selected: selected),
    height: selected
        ? _CaptionTimelineMetrics.selectedRowTouch
        : _CaptionTimelineMetrics.barPitch,
    child: _captionBar(placement.layer, selected, trackWidth),
  );

  /// 막대의 손가락 자리가 시작되는 높이. 고른 막대는 제 줄의 한가운데를
  /// 붙든 채 위아래로 넓어진다 — 그림(4dp 실선)은 그대로 제자리다.
  double _touchTop(int lane, {required bool selected}) => selected
      ? _CaptionTimelineMetrics.laneCenter(lane) -
            _CaptionTimelineMetrics.selectedRowTouch / 2
      : _CaptionTimelineMetrics.laneTop(lane);

  List<Widget> _rangeHandles(_CaptionPlacement placement, double trackWidth) =>
      [
        _rangeHandle(
          placement: placement,
          isStart: true,
          edgeX: placement.left,
          trackWidth: trackWidth,
        ),
        _rangeHandle(
          placement: placement,
          isStart: false,
          edgeX: placement.left + placement.width,
          trackWidth: trackWidth,
        ),
      ];

  Widget _captionBar(EditorTextLayer layer, bool selected, double trackWidth) =>
      GestureDetector(
        key: Key('editor-caption-segment-${layer.id}'),
        // 막대는 얇지만 손가락 자리는 줄 높이 전부다 — 8dp 실선을 정확히
        // 겨누게 하면 아무도 못 누른다.
        behavior: HitTestBehavior.opaque,
        onTap: () => _select(layer),
        // 고른 막대는 통째로 끌어 옮긴다. 고르지 않은 막대의 가로 끌기는
        // 스크롤에 넘긴다 — 배율을 올린 뒤 옆으로 넘기는 손짓이 막대에 걸리면
        // 띠가 꼼짝하지 않는다.
        onHorizontalDragStart: selected
            ? (_) => _startSlide(layer, trackWidth)
            : null,
        onHorizontalDragUpdate: selected
            ? (details) => _updateSlide(details.delta.dx)
            : null,
        onHorizontalDragEnd: selected ? (_) => _endDrag() : null,
        onHorizontalDragCancel: selected ? _endDrag : null,
        child: Center(
          child: SizedBox(
            // **가로로 꽉** 채운다. 폭을 주지 않으면 자식 없는
            // DecoratedBox가 허용된 가장 작은 크기(폭 0)를 골라, 막대가
            // 아예 그려지지 않는다 — 손잡이만 남아 점처럼 보였다.
            width: double.infinity,
            // 고른 막대만 2dp 두꺼워진다. 테두리도 그림자도 두르지 않는다 —
            // 4dp 막대에 두르면 색이 남지 않고, 스무 개가 늘어선 줄 칸이
            // 그림자밭이 된다.
            height: selected
                ? EditorCaptionTokens.selectedBarHeight
                : EditorCaptionTokens.barHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                // 직접 넣은 자막은 코랄, AI 자막은 올리브. 아래 자막 카드의
                // 번호·테두리와 1:1로 같은 색이다.
                color: _fill(layer, selected),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
      );

  /// 자막 양끝의 길이 손잡이. 보이는 마개는 10dp 폭이지만 손가락이 닿는
  /// 자리는 26dp다. 누르기만 하면 그 자막을 고른다.
  Widget _rangeHandle({
    required _CaptionPlacement placement,
    required bool isStart,
    required double edgeX,
    required double trackWidth,
  }) {
    final layer = placement.layer;
    return Positioned(
      // 띠 끝에서도 자리를 안쪽으로 옮기지 않는다. 옮기면 손잡이가 연필·
      // 휴지통 위로 올라앉아 그 둘을 누를 수 없게 된다 — 끝에서는 반만
      // 보이더라도 자리는 늘 막대 끝에 붙어 있어야 한다.
      left: edgeX - _handleTouchWidth / 2,
      top: _touchTop(placement.lane, selected: true),
      height: _CaptionTimelineMetrics.selectedRowTouch,
      width: _handleTouchWidth,
      child: GestureDetector(
        key: Key(
          'editor-caption-${isStart ? 'start' : 'end'}-handle-${layer.id}',
        ),
        behavior: HitTestBehavior.opaque,
        onTap: () => _select(layer),
        onHorizontalDragStart: (_) => _startHandle(layer, isStart, trackWidth),
        onHorizontalDragUpdate: (details) => _updateHandle(details.delta.dx),
        onHorizontalDragEnd: (_) => _endDrag(),
        onHorizontalDragCancel: _endDrag,
        // 고른 막대의 두께를 꽉 채우는 끝마개. 손가락 자리는 막대 끝에 걸쳐
        // 두되, **보이는 마개는 막대 안쪽**에 붙인다 — 막대가 제 양끝을 붙잡고
        // 있는 모양이 된다.
        //
        // 색은 **흰색**이다. 마개가 얹히는 바닥은 언제나 제 색으로 꽉 찬
        // 막대라, 흰색이면 코랄·주황·올리브 어느 색 위에서든 같은 세기로
        // 도드라진다. 막대 밖으로 반쯤 걸치는 순간을 위해 옅은 그림자만
        // 하나 받쳐 둔다.
        child: Align(
          alignment: isStart ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 6,
            height: 10,
            decoration: BoxDecoration(
              // 자석에 붙은 손잡이는 노랗게 바뀐다 — 붙었다는 걸 손끝뿐 아니라
              // 눈으로도 알 수 있어야 한다.
              color: _snappedTo(layer, isStart)
                  ? TrimBarTokens.handleSnapped
                  : Colors.white,
              borderRadius: BorderRadius.circular(3),
              boxShadow: const [
                BoxShadow(color: Color(0x40000000), blurRadius: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 재생 봉. 이 판에서 세로선은 **이것 하나뿐**이다 — 자석에 붙은 자리를
  /// 알리는 선을 따로 그렸더니 재생 봉이 둘로 보였다. 자막이 봉에 딱 붙으면
  /// 봉이 굵어지는 것으로 대신 알린다.
  Widget _playheadLine(double x) {
    final snappedHere = _snappedMs == widget.project.playheadMs;
    return Positioned(
      left: x - (snappedHere ? 1.5 : 1),
      top: 4,
      bottom: 0,
      width: snappedHere ? 3 : 2,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.coral,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  /// 봉 머리의 동그란 손잡이. 선만으로는 "끌 수 있는 것"으로 읽히지 않는다.
  Widget _playheadKnob(double x, double trackWidth) => Positioned(
    left: (x - 4.5).clamp(0.0, math.max(0.0, trackWidth - 9)),
    top: 0,
    width: 9,
    height: 9,
    child: const IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.coral,
          shape: BoxShape.circle,
        ),
      ),
    ),
  );

  /// 재생 봉을 잡는 자리. 프레임 띠와 눈금 줄을 덮는다.
  ///
  /// **왜 자막 줄까지는 안 덮는가**: 봉이 지나가는 자리의 자막을 끌 수 없게
  /// 된다.
  ///
  /// 보이는 봉은 2dp 실선에 9dp 손잡이지만 잡히는 자리는 [_playheadTouchWidth]
  /// 다 — 실선을 정확히 겨누라고 하면 "봉이 안 잡힌다"가 된다. 그렇다고 44dp를
  /// 다 주면 봉이 클립 처음에 서 있을 때 그 아래 컷 손잡이를 덮어 버린다.
  Widget _playheadTouch({
    required Key keyValue,
    required double x,
    required double trackWidth,
    required double top,
    required double height,
  }) => Positioned(
    left: x - _playheadTouchWidth / 2,
    top: top,
    width: _playheadTouchWidth,
    height: height,
    child: GestureDetector(
      key: keyValue,
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => _startScrub(trackWidth),
      onHorizontalDragUpdate: (details) => _updateScrub(details.delta.dx),
      onHorizontalDragEnd: (_) => _endScrub(),
      onHorizontalDragCancel: _endScrub,
      child: const SizedBox.expand(),
    ),
  );

  /// 끄는 동안 눈금 위에 뜨는 시각 알림. 자석에 붙으면 노랗게 바뀐다.
  Widget _dragBadge(String label, {bool snapped = false}) => Positioned(
    left: 0,
    right: 0,
    top: 2,
    child: IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xE633291F),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: snapped ? TrimBarTokens.handleSnapped : Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    ),
  );

  /// 컷 밖으로 빠지는 자리를 덮는 막. 끄는 동안만 뜬다 — "여기는 빠져요"가
  /// 프레임 위에 그대로 보인다.
  Widget _cutVeil({required double left, required double width}) => Positioned(
    left: left,
    top: 0,
    width: math.max(0, width),
    height: _CaptionTimelineMetrics.stripHeight,
    child: const IgnorePointer(child: ColoredBox(color: TrimBarTokens.outside)),
  );

  /// 보이는 컷 손잡이.
  ///
  /// **왜 얇은 코랄인가**: 예전에는 컷 편집 탭과 같은 노란 블록(14dp)이었다.
  /// 프레임 띠가 얇아지자 그 블록이 띠 양끝의 그림을 통째로 덮어, 클립이
  /// 어디서 시작하고 끝나는지를 보려고 열어 둔 띠에서 정작 첫 장면과 끝
  /// 장면이 보이지 않았다. 이제 구간의 경계만 코랄 실선으로 긋는다 —
  /// 손가락 자리는 [_cutHandleTouch]가 그대로 40dp를 낸다.
  Widget _cutHandleFace({required double edgeX, required bool isStart}) =>
      Positioned(
        left: isStart ? edgeX : edgeX - _cutHandleWidth,
        top: 0,
        width: _cutHandleWidth,
        height: _CaptionTimelineMetrics.stripHeight,
        child: const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: AppColors.coral,
              borderRadius: BorderRadius.all(Radius.circular(2)),
            ),
          ),
        ),
      );

  /// 손잡이 위에 얹는 투명한 손가락 판. 보이는 손잡이는 14dp지만 실제로
  /// 눌리는 자리는 40dp다.
  Widget _cutHandleTouch({
    required Key keyValue,
    required double edgeX,
    required bool isStart,
    required double trackWidth,
  }) => Positioned(
    left:
        ((isStart ? edgeX + _cutHandleWidth / 2 : edgeX - _cutHandleWidth / 2) -
                _cutTouchWidth / 2)
            .clamp(0.0, math.max(0.0, trackWidth - _cutTouchWidth)),
    top: 0,
    width: _cutTouchWidth,
    height: _CaptionTimelineMetrics.stripHeight,
    child: GestureDetector(
      key: keyValue,
      // 반투명이라 **누르는 것**은 아래 프레임 띠로 넘어간다 — 클립 끝
      // 가까이를 눌러도 재생 위치는 그리로 간다. 끄는 것만 여기서 받는다.
      behavior: HitTestBehavior.translucent,
      onHorizontalDragStart: (_) => _startCut(isStart, trackWidth),
      onHorizontalDragUpdate: (details) => _updateCut(details.delta.dx),
      onHorizontalDragEnd: (_) => _endCut(),
      onHorizontalDragCancel: _endCut,
      child: const SizedBox.expand(),
    ),
  );

  void _select(EditorTextLayer layer) {
    widget.controller.selectLayer(layer.id);
    widget.onSeek(layer.startMs);
  }

  void _startHandle(EditorTextLayer layer, bool isStart, double trackWidth) {
    setState(() {
      _dragLayerId = layer.id;
      _draggingStart = isStart;
      _sliding = false;
      _travelPx = 0;
      _msPerPx = widget.span / math.max(1.0, trackWidth);
      _anchorStartMs = layer.startMs;
      _anchorEndMs = layer.endMs;
      _snappedMs = null;
    });
  }

  void _updateHandle(double deltaPx) {
    final id = _dragLayerId;
    if (id == null || _sliding) return;
    _travelPx += deltaPx;
    final clipStart = widget.clipTimelineStart;
    final clipEnd = clipStart + widget.span;
    var start = _anchorStartMs;
    var end = _anchorEndMs;
    if (_draggingStart) {
      start = _snapped(
        _anchorStartMs + (_travelPx * _msPerPx).round(),
        id,
      ).clamp(clipStart, end - _minimumCaptionMs);
    } else {
      end = _snapped(
        _anchorEndMs + (_travelPx * _msPerPx).round(),
        id,
      ).clamp(start + _minimumCaptionMs, clipEnd);
    }
    widget.controller.updateTextLayerRangeGesture(id, start, end);
  }

  void _startSlide(EditorTextLayer layer, double trackWidth) {
    setState(() {
      _dragLayerId = layer.id;
      _draggingStart = false;
      _sliding = true;
      _travelPx = 0;
      _msPerPx = widget.span / math.max(1.0, trackWidth);
      _anchorStartMs = layer.startMs;
      _anchorEndMs = layer.endMs;
      _snappedMs = null;
    });
  }

  void _updateSlide(double deltaPx) {
    final id = _dragLayerId;
    if (id == null || !_sliding) return;
    _travelPx += deltaPx;
    final clipStart = widget.clipTimelineStart;
    final clipEnd = clipStart + widget.span;
    final duration = _anchorEndMs - _anchorStartMs;
    final raw = _anchorStartMs + (_travelPx * _msPerPx).round();
    // 통째로 옮길 때는 앞끝·뒤끝 중 더 가까운 쪽이 달라붙는다.
    final head = _snapTarget(raw, id);
    final tail = _snapTarget(raw + duration, id);
    final headDistance = head == null ? null : (head - raw).abs();
    final tailDistance = tail == null ? null : (tail - raw - duration).abs();
    int? landed;
    var start = _frameAligned(raw);
    if (headDistance != null &&
        (tailDistance == null || headDistance <= tailDistance)) {
      start = head!;
      landed = head;
    } else if (tailDistance != null) {
      start = tail! - duration;
      landed = tail;
    }
    // 클립 밖으로 밀려났으면 붙은 게 아니다.
    final bounded = start.clamp(clipStart, clipEnd - duration);
    _markSnap(bounded == start ? landed : null);
    widget.controller.updateTextLayerRangeGesture(
      id,
      bounded,
      bounded + duration,
    );
  }

  /// 가까운 자리에 자막 끝을 달라붙게 한다.
  ///
  /// **왜 필요한가**: 겹치는 자막을 "여기부터 저기까지 똑같이"로 맞추는 일이
  /// 잦은데, 1px이 수십~수백 ms다. 손가락으로는 늘 몇 프레임씩 어긋난다.
  ///
  /// 달라붙는 자리는 넷이다 — 클립의 **처음**·**끝**, 지금 **재생 위치**,
  /// 그리고 **다른 자막의 시작·끝**. 컷 편집 띠의 자석([TrimRangeBar])과 같은
  /// 거리(12px)를 쓰고, 붙는 순간 짧게 떨리며 손잡이가 밝아진다.
  ///
  /// 붙을 자리가 없으면 30fps 프레임 경계로 맞춘다.
  int _snapped(int rawMs, String movingLayerId) {
    final target = _snapTarget(rawMs, movingLayerId);
    _markSnap(target);
    return target ?? _frameAligned(rawMs);
  }

  int? _snapTarget(
    int rawMs,
    String movingLayerId, {
    bool includePlayhead = true,
  }) {
    final tolerance = math.max(
      1,
      (TrimBarTokens.snapDistance * _msPerPx).round(),
    );
    int? landed;
    var bestDistance = tolerance + 1;
    for (final target in <int>[
      widget.clipTimelineStart,
      widget.clipTimelineStart + widget.span,
      // 재생 봉을 끌 때는 봉 자신을 자석으로 삼지 않는다 — 제자리에 붙어
      // 한 발짝도 못 움직인다.
      if (includePlayhead) widget.project.playheadMs,
      for (final layer in _layers)
        if (layer.id != movingLayerId) ...[layer.startMs, layer.endMs],
    ]) {
      final distance = (target - rawMs).abs();
      if (distance <= tolerance && distance < bestDistance) {
        landed = target;
        bestDistance = distance;
      }
    }
    return landed;
  }

  /// 이 손잡이가 지금 자석에 붙어 있는가. 끌고 있는 자막의, 붙은 자리에
  /// 놓인 쪽 하나만 밝아진다.
  bool _snappedTo(EditorTextLayer layer, bool isStart) =>
      _dragLayerId == layer.id &&
      _snappedMs != null &&
      (isStart ? layer.startMs : layer.endMs) == _snappedMs;

  void _markSnap(int? landed) {
    if (landed == _snappedMs) return;
    if (landed != null) unawaited(HapticFeedback.selectionClick());
    setState(() => _snappedMs = landed);
  }

  void _endDrag() {
    if (_dragLayerId == null) return;
    setState(() {
      _dragLayerId = null;
      _draggingStart = false;
      _sliding = false;
      _snappedMs = null;
    });
    widget.onEditCommitted();
  }

  void _startCut(bool isStart, double trackWidth) {
    final clip = widget.scope;
    setState(() {
      _cutDragging = true;
      _cutDraggingStart = isStart;
      _cutTravelPx = 0;
      // 눈금 배율은 잡은 순간의 것으로 고정한다. 자르는 동안 클립이 짧아지는데
      // 배율까지 따라 바뀌면 손가락 아래에서 그림이 달아난다.
      _cutMsPerPx = widget.span / math.max(1.0, trackWidth);
      _cutAnchorStartMs = clip.sourceStartMs;
      _cutAnchorEndMs = clip.sourceEndMs;
      _cutStartMs = clip.sourceStartMs;
      _cutEndMs = clip.sourceEndMs;
    });
  }

  void _updateCut(double deltaPx) {
    if (!_cutDragging) return;
    _cutTravelPx += deltaPx;
    final moved = (_cutTravelPx * _cutMsPerPx).round();
    const minimum = EditorProjectController.minimumClipDurationMs;
    var start = _cutAnchorStartMs;
    var end = _cutAnchorEndMs;
    if (_cutDraggingStart) {
      start = _frameAligned(_cutAnchorStartMs + moved).clamp(0, end - minimum);
    } else {
      end = _frameAligned(
        _cutAnchorEndMs + moved,
      ).clamp(start + minimum, widget.project.sourceDurationMs);
    }
    if (start == _cutStartMs && end == _cutEndMs) return;
    setState(() {
      _cutStartMs = start;
      _cutEndMs = end;
    });
    widget.onClipTrimChanged(start, end, _cutDraggingStart);
  }

  void _endCut() {
    if (!_cutDragging) return;
    setState(() => _cutDragging = false);
    widget.onClipTrimCommitted();
  }

  void _startScrub(double trackWidth) {
    _scrubbing = true;
    _playheadDragStartMs = widget.project.playheadMs;
    _playheadTravelPx = 0;
    _scrubMsPerPx = widget.span / math.max(1.0, trackWidth);
    // 자석의 허용 거리도 지금 배율로 잰다 — 자막 손잡이와 같은 셈이다.
    _msPerPx = _scrubMsPerPx;
    _snappedMs = null;
  }

  /// 재생 봉을 끈다. 자막 손잡이와 **같은 자석**을 쓴다 — 클립의 처음·끝과
  /// 자막들의 시작·끝에 달라붙는다.
  ///
  /// **왜 봉에도 자석이 필요한가**: 자막 끝을 봉에 맞추는 일만큼이나 봉을
  /// 자막 끝에 맞추는 일이 잦다("이 자막 끝나는 데서 잘라야지"). 1px이 수십~
  /// 수백 ms라 손가락으로는 늘 몇 프레임씩 어긋났고, 자막 쪽에만 자석이 있어
  /// 어느 쪽에서 맞추느냐에 따라 되고 안 되고가 갈렸다.
  void _updateScrub(double deltaPx) {
    _playheadTravelPx += deltaPx;
    final raw =
        _playheadDragStartMs + (_playheadTravelPx * _scrubMsPerPx).round();
    final landed = _snapTarget(raw, '', includePlayhead: false);
    final next = (landed ?? _frameAligned(raw)).clamp(
      widget.clipTimelineStart,
      widget.clipTimelineStart + widget.span,
    );
    // 클립 밖으로 밀려났으면 붙은 게 아니다.
    _markSnap(next == landed ? landed : null);
    widget.onSeek(next);
  }

  void _endScrub() {
    _scrubbing = false;
    _markSnap(null);
  }

  /// 배율을 올리면 띠가 화면보다 넓어진다. 재생 봉이 보이는 자리 밖으로
  /// 나가면 따라간다 — 손으로 끄는 중에는 손가락을 이긴다는 인상을 주므로
  /// 건드리지 않는다.
  void _revealPlayhead() {
    if (!mounted || _scrubbing || _zoom == 1) return;
    if (!_horizontal.hasClients) return;
    final position = _horizontal.position;
    if (!position.haveDimensions) return;
    final viewport = position.viewportDimension;
    final x = _xOf(widget.project.playheadMs, viewport * _zoom);
    const margin = 36.0;
    if (x > position.pixels + margin &&
        x < position.pixels + viewport - margin) {
      return;
    }
    _horizontal.jumpTo(
      (x - viewport / 2).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
  }

  int _frameAligned(int milliseconds) {
    const frameRate = 30;
    final frame = (milliseconds * frameRate / 1000).round();
    return (frame * 1000 / frameRate).round();
  }
}

/// 막대 하나가 줄 칸 어디에 그려지는지. 그릴 때와 "가장 가까운 막대"를 찾을
/// 때가 같은 값을 봐야, 눈에 보이는 자리와 손끝이 닿는 자리가 어긋나지 않는다.
class _CaptionPlacement {
  const _CaptionPlacement({
    required this.layer,
    required this.lane,
    required this.left,
    required this.width,
  });

  final EditorTextLayer layer;
  final int lane;
  final double left;
  final double width;
}

/// 줄 칸에 담기지 않아 +N 배지로 접힌 겹침 한 덩이.
class _CaptionOverflowCluster {
  const _CaptionOverflowCluster({
    required this.right,
    required this.atMs,
    required this.count,
  });

  /// 덩이의 오른쪽 끝(띠 좌표). 배지는 그 아래에 걸친다.
  final double right;

  /// 덩이가 다 함께 떠 있는 순간. 배지를 누르면 여기로 재생 봉이 간다.
  final int atMs;

  /// **접힌 줄 수**. 자막 수가 아니다 — 세 줄까지는 눈에 그대로 보이므로,
  /// 배지가 답해야 하는 물음은 "여기 몇 줄이 더 있나"다. 네 번째 줄부터
  /// 세기 시작해 한 줄이 접히면 +1, 두 줄이면 +2다.
  final int count;
}

/// 자막 카드 하나. 왼쪽 색 줄과 번호가 타임라인 막대와 짝을 이룬다 — 색만
/// 보고도 "저 막대가 이 카드"임을 안다.
class _CaptionCard extends StatelessWidget {
  const _CaptionCard({
    required this.keyValue,
    required this.layer,
    required this.order,
    required this.accent,
    required this.selected,
    required this.onTap,
    this.onEdit,
  });

  static const _radius = 15.0;

  final Key keyValue;
  final EditorTextLayer layer;
  final int order;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;

  /// 연필. 고른 카드에만 선다 — 카드마다 놓으면 좁은 카드가 아이콘밭이 된다.
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) => Material(
    // 고른 카드만 제 색을 아주 옅게 깐다. 나머지는 흰 바닥이다 — 카드 스무
    // 장이 저마다 물들어 있으면 "지금 고른 것"이 어디인지 알 수 없다.
    color: selected ? accent.withValues(alpha: 0.08) : Colors.white,
    shape: RoundedRectangleBorder(
      // 테두리 색이 곧 자막의 종류다 — 직접은 코랄, AI는 올리브. 고르지 않은
      // 카드는 같은 색을 옅게 써서 줄 전체가 색밭이 되지 않게 한다.
      side: BorderSide(color: accent.withValues(alpha: selected ? 1 : 0.4)),
      borderRadius: BorderRadius.circular(_radius),
    ),
    child: InkWell(
      key: keyValue,
      onTap: onTap,
      borderRadius: BorderRadius.circular(_radius),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(11, 8, 6, 8),
        child: Row(
          children: [
            // 번호는 글자 옆이 아니라 **앞 칸**에 선다 — 타임라인 막대의 색과
            // 짝지어 읽는 이름표라, 문구에 딸린 군더더기로 보이면 안 된다.
            Text(
              '$order',
              style: TextStyle(
                color: accent,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    layer.text,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: EditorColorTokens.ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_formatMs(layer.startMs)}–${_formatMs(layer.endMs)}',
                    maxLines: 1,
                    style: const TextStyle(
                      color: EditorColorTokens.subtle,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            // 연필도 고른 카드에만 선다. 스무 장에 다 놓으면 좁은 카드가
            // 아이콘밭이 되고, 무엇을 고쳤는지도 알 수 없다.
            if (selected && onEdit != null)
              GestureDetector(
                key: Key('editor-caption-card-edit-${layer.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: onEdit,
                child: const SizedBox(
                  width: 28,
                  height: 44,
                  child: Icon(
                    Icons.edit_outlined,
                    size: 17,
                    color: EditorColorTokens.subtle,
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// 한 시점에 겹친 자막을 다 펼쳐 놓는 시트. 타임라인에서 +N 배지를 누르면
/// 열린다.
///
/// 오른쪽 아이콘은 **눈**(보이기/숨기기)과 **손잡이**(순서)다. 예전 시안의
/// 라디오 단추는 "고른다"만 할 수 있었는데, 이미 줄을 눌러도 골라진다 —
/// 자리만 잡아먹었다.
class _CaptionOverlapSheet extends StatefulWidget {
  const _CaptionOverlapSheet({
    required this.controller,
    required this.scope,
    required this.atMs,
    required this.onSelect,
    this.onEdit,
    this.onDelete,
  });

  final EditorProjectController controller;
  final EditorClip scope;
  final int atMs;
  final ValueChanged<EditorTextLayer> onSelect;
  final ValueChanged<String>? onEdit;
  final ValueChanged<String>? onDelete;

  @override
  State<_CaptionOverlapSheet> createState() => _CaptionOverlapSheetState();
}

class _CaptionOverlapSheetState extends State<_CaptionOverlapSheet> {
  /// 이 시트 안에서만 흐려 두는 자막. 자막 모델에는 아직 '보임' 값이 없다 —
  /// 실제로 미리보기에서 감추는 일은 그 값이 생기면 여기에 잇는다.
  final Set<String> _dimmed = <String>{};

  /// 이 시트 안에서만 쓰는 순서. 겹친 자막 중 누가 위에 오는지도 아직 모델에
  /// 없어, 끌어 옮겨 보는 자리만 먼저 세운다.
  List<String> _sequence = const [];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      // 목록은 매번 프로젝트에서 다시 뽑는다 — 시트가 떠 있는 동안 자막을
      // 지우거나 고쳐도 줄이 옛 값을 붙들고 있지 않다.
      final all = _textLayersOfClip(widget.controller.project, widget.scope)
        ..sort((a, b) {
          final byStart = a.startMs.compareTo(b.startMs);
          return byStart != 0 ? byStart : a.id.compareTo(b.id);
        });
      final rows = _ordered([
        for (final layer in all)
          if (layer.startMs <= widget.atMs && widget.atMs < layer.endMs) layer,
      ]);
      return DecoratedBox(
        decoration: const BoxDecoration(
          color: EditorColorTokens.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 34,
                height: 4,
                decoration: BoxDecoration(
                  color: EditorColorTokens.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              _header(rows.length),
              Flexible(
                child: rows.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.fromLTRB(16, 4, 16, 20),
                        child: Text(
                          '이 시점에 떠 있는 자막이 없어요.',
                          style: TextStyle(
                            color: EditorColorTokens.muted,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : ReorderableListView.builder(
                        key: const Key('editor-caption-overlap-rows'),
                        padding: const EdgeInsets.only(bottom: 8),
                        shrinkWrap: true,
                        buildDefaultDragHandles: false,
                        itemCount: rows.length,
                        onReorderItem: (oldIndex, newIndex) =>
                            _reorder(rows, oldIndex, newIndex),
                        itemBuilder: (context, index) =>
                            _row(all: all, layer: rows[index], index: index),
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _header(int count) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
    child: Row(
      children: [
        Text(
          '현재 시점 자막 $count개',
          style: const TextStyle(
            color: EditorColorTokens.ink,
            fontSize: 14,
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: EditorColorTokens.background,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            _formatMs(widget.atMs),
            style: const TextStyle(
              color: EditorColorTokens.muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const Spacer(),
        IconButton(
          key: const Key('editor-caption-overlap-close'),
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.close_rounded, size: 20),
          color: EditorColorTokens.muted,
        ),
      ],
    ),
  );

  Widget _row({
    required List<EditorTextLayer> all,
    required EditorTextLayer layer,
    required int index,
  }) {
    final order = all.indexWhere((item) => item.id == layer.id);
    final accent = _captionAccent(layer, order < 0 ? 0 : order);
    final selected = widget.controller.project.selectedLayerId == layer.id;
    final dimmed = _dimmed.contains(layer.id);
    return Padding(
      key: Key('editor-caption-overlap-${layer.id}'),
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 4),
      child: Material(
        color: selected ? EditorColorTokens.selected : Colors.transparent,
        shape: RoundedRectangleBorder(
          side: BorderSide(
            color: selected ? accent : Colors.transparent,
            width: 1.6,
          ),
          borderRadius: BorderRadius.circular(11),
        ),
        child: InkWell(
          onTap: () => widget.onSelect(layer),
          borderRadius: BorderRadius.circular(11),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 7, 4, 7),
            child: Opacity(
              opacity: dimmed ? 0.45 : 1,
              child: Row(
                children: [
                  Container(
                    width: 3,
                    height: 22,
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${order + 1}',
                    style: TextStyle(
                      color: accent,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      layer.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: EditorColorTokens.ink,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${_formatMs(layer.startMs)}–${_formatMs(layer.endMs)}',
                    style: const TextStyle(
                      color: EditorColorTokens.muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  _rowAction(
                    keyValue: Key('editor-caption-overlap-eye-${layer.id}'),
                    icon: dimmed
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    onTap: () => setState(
                      () => dimmed
                          ? _dimmed.remove(layer.id)
                          : _dimmed.add(layer.id),
                    ),
                  ),
                  // 연필·휴지통은 고른 줄에만. 줄마다 넷을 세우면 411dp
                  // 너비에서 자막 글이 설 자리가 없다.
                  if (selected && widget.onEdit != null)
                    _rowAction(
                      keyValue: Key('editor-caption-overlap-edit-${layer.id}'),
                      icon: Icons.edit_outlined,
                      onTap: () => widget.onEdit!(layer.id),
                    ),
                  if (selected && widget.onDelete != null)
                    _rowAction(
                      keyValue: Key(
                        'editor-caption-overlap-delete-${layer.id}',
                      ),
                      icon: Icons.delete_outline_rounded,
                      onTap: () => widget.onDelete!(layer.id),
                    ),
                  ReorderableDragStartListener(
                    index: index,
                    child: const SizedBox(
                      width: 26,
                      height: 30,
                      child: Icon(
                        Icons.drag_handle_rounded,
                        size: 17,
                        color: EditorColorTokens.border,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rowAction({
    required Key keyValue,
    required IconData icon,
    required VoidCallback onTap,
  }) => GestureDetector(
    key: keyValue,
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: SizedBox(
      width: 28,
      height: 30,
      child: Icon(icon, size: 16, color: EditorColorTokens.muted),
    ),
  );

  /// 손잡이로 끌어 놓은 순서를 얹는다. 아직 끌지 않았으면 시작 시각 순이다.
  List<EditorTextLayer> _ordered(List<EditorTextLayer> rows) {
    if (_sequence.isEmpty) return rows;
    final ranked = [...rows];
    ranked.sort((a, b) => _rank(a, rows).compareTo(_rank(b, rows)));
    return ranked;
  }

  int _rank(EditorTextLayer layer, List<EditorTextLayer> rows) {
    final moved = _sequence.indexOf(layer.id);
    // 끌어 놓은 적이 없는 자막(시트가 열린 뒤에 생긴 것)은 뒤로 보낸다.
    return moved >= 0
        ? moved
        : _sequence.length + rows.indexWhere((item) => item.id == layer.id);
  }

  /// [newIndex]는 끌어낸 줄을 이미 빼낸 자리다(`onReorderItem`) — 따로
  /// 보정하지 않는다.
  void _reorder(List<EditorTextLayer> rows, int oldIndex, int newIndex) {
    final ids = rows.map((layer) => layer.id).toList();
    ids.insert(newIndex, ids.removeAt(oldIndex));
    setState(() => _sequence = ids);
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
  bool captionEmptyState = false,
}) {
  // 컷은 타임라인 칸이, 자막은 [_CaptionTimelinePanel]이 아래 자리를 통째로
  // 맡는다. 자막이 하나도 없을 때만 도구 칸에 만드는 두 갈래가 선다.
  if (project.selectedTool == EditorTool.cut) return 0;
  if (project.selectedTool == EditorTool.text && !captionEmptyState) return 0;
  final wanted = switch (project.selectedTool) {
    // 만드는 두 갈래 카드 한 줄.
    EditorTool.text => layout.toolPanelHeight * 1.3,
    // 장면 카드 한 줄과 배율 슬라이더 한 줄.
    EditorTool.zoom => layout.toolPanelHeight * 1.45,
    // 비율 선택 한 줄과 확대 슬라이더 한 줄.
    EditorTool.ratio => layout.toolPanelHeight * 1.5,
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
              // 단계에 맞는 제목 하나만 보인다. 업로드 중인데 "만드는 중"이
              // 남아 있으면 두 단계가 섞여 보인다.
              switch ((status ?? '', progress)) {
                (final s, final p) when s.contains('서버에 올리고') =>
                  p == null ? '서버에 올리는 중' : '서버에 올리는 중 ${(p * 100).round()}%',
                (final s, _) when s.contains('갤러리') => '거의 다 됐어요',
                (_, null) => '영상을 준비하고 있어요',
                (_, final p?) => '영상 만드는 중 ${(p * 100).round()}%',
              },
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
    required this.saving,
    required this.onBack,
    required this.onSaveDraft,
    required this.onSave,
  });

  final double height;
  final bool saving;
  final VoidCallback onBack;

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
      color: EditorColorTokens.canvas,
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

class _HistoryButton extends StatelessWidget {
  const _HistoryButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: EditorColorTokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: EditorColorTokens.border),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(
            icon,
            color: onTap == null
                ? EditorColorTokens.border
                : EditorColorTokens.ink,
            size: 20,
          ),
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
    required this.captionEmptyState,
    required this.onDirectCaptionAddMode,
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

  /// 자막 탭인데 이 클립에 자막이 하나도 없는가. 이때만 자막 도구 칸이
  /// 만드는 두 갈래를 띄운다.
  final bool captionEmptyState;
  final VoidCallback onDirectCaptionAddMode;
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
    // 컷은 타임라인 칸이, 자막은 자막 판이 아래 자리를 통째로 쓴다. 자막이
    // 하나도 없을 때만 자막 탭이 이 칸을 빌려 만드는 두 갈래를 띄운다.
    if (project.selectedTool == EditorTool.cut ||
        (project.selectedTool == EditorTool.text && !captionEmptyState)) {
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
          EditorTool.text => _CaptionEmptyPanel(
            onDirect: onDirectCaptionAddMode,
            onAi: onAiCaption,
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
          // AI 자막은 재생 줄의 버튼으로, AR은 스티커 탭의 줄로 들어갔다.
          // 하단 네비에는 없지만 enum은 남아 있어 빈 칸으로 답한다.
          EditorTool.aiCaption || EditorTool.ar => const SizedBox.shrink(),
          // 위에서 먼저 걸러진다 — 스위치가 빠짐없이 답하도록만 둔다.
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

/// 자막이 하나도 없을 때의 자막 탭. 만드는 두 갈래만 크게 보여 준다.
///
/// **왜 타임라인을 안 띄우는가**: 아직 손댈 자막이 없다. 빈 눈금과 빈 줄
/// 칸을 먼저 보여 주면 "여기서 뭘 해야 하지"가 한 박자 늦는다. 하나라도
/// 만들어지면 그때 [_CaptionTimelinePanel]이 이 자리를 넘겨받는다.
class _CaptionEmptyPanel extends StatelessWidget {
  const _CaptionEmptyPanel({required this.onDirect, required this.onAi});

  /// "지금 위치에 넣어요" 안내 카드를 먼저 띄운다.
  final VoidCallback onDirect;
  final VoidCallback onAi;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _PanelTitle('자막 · 이 클립의 자막'),
      const SizedBox(height: 8),
      Expanded(
        child: Row(
          children: [
            Expanded(
              child: _SubtitleEntryCard(
                keyValue: const Key('editor-open-text-sheet'),
                icon: Icons.keyboard_alt_outlined,
                iconColor: EditorColorTokens.coral,
                title: '직접 자막',
                description: '원하는 문장을 입력해요',
                onTap: onDirect,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SubtitleEntryCard(
                keyValue: const Key('editor-open-ai-caption'),
                icon: Icons.graphic_eq_rounded,
                iconColor: AppColors.sageDark,
                title: '자동 자막',
                description: '영상 속 대사를 만들어요',
                badge: 'AI',
                onTap: onAi,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _DirectCaptionAddCard extends StatelessWidget {
  const _DirectCaptionAddCard({required this.playheadMs, required this.onAdd});

  final int playheadMs;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('editor-direct-caption-add-card'),
    padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: EditorColorTokens.border),
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              width: 24,
              height: 38,
              child: Stack(
                alignment: Alignment.topCenter,
                children: [
                  Positioned(
                    top: 15,
                    bottom: 0,
                    child: ColoredBox(
                      color: AppColors.coral,
                      child: SizedBox(width: 1),
                    ),
                  ),
                  Icon(
                    Icons.location_on_rounded,
                    size: 22,
                    color: AppColors.coral,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '직접 자막 추가',
                    style: TextStyle(
                      color: EditorColorTokens.ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text.rich(
                    TextSpan(
                      style: const TextStyle(
                        color: EditorColorTokens.muted,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                      ),
                      children: [
                        const TextSpan(text: '현재 위치 '),
                        TextSpan(
                          text: _formatMs(playheadMs),
                          style: const TextStyle(
                            color: AppColors.coral,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const TextSpan(text: '부터 '),
                        const TextSpan(
                          text: '3초간',
                          style: TextStyle(
                            color: AppColors.coral,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const TextSpan(text: ' 표시돼요'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 20),
              child: Text(
                '시간은 추가 후 조절할 수 있어요',
                style: TextStyle(
                  color: EditorColorTokens.muted,
                  fontSize: 8,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          height: 38,
          child: FilledButton.icon(
            key: const Key('editor-direct-caption-add-at-playhead'),
            onPressed: onAdd,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.coral,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(11),
              ),
            ),
            icon: const Icon(Icons.add_rounded, size: 22),
            label: const Text(
              '이 위치에 자막 추가',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ],
    ),
  );
}

/// 자막을 만드는 두 단추. 재생 줄 오른쪽에 나란히 선다 — 테두리만 있는
/// 올리브(AI)와 꽉 찬 코랄(직접).
///
/// 고정 높이 SizedBox로 감싸지 않는다. 크기는 스타일의 minimumSize로 정한다
/// (까닭은 [EditorTopBar] 주석에 있다).
class _SubtitleActionButton extends StatelessWidget {
  const _SubtitleActionButton({
    required this.keyValue,
    required this.label,
    required this.color,
    required this.onPressed,
    this.icon,
    this.filled = false,
    this.borderColor,
  });

  final Key keyValue;
  final String label;
  final IconData? icon;
  final Color color;
  final bool filled;

  /// 테두리만 있는 단추의 선 색. null이면 글자와 같은 색이다. 'AI 자막'처럼
  /// **흰 바닥에 있는 듯 없는 듯한 선**만 두르는 단추가 이 값을 쓴다.
  final Color? borderColor;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(11),
    );
    // 좌우 패딩을 줄여 제목·단추 둘·휴지통이 한 줄에 다 들어간다.
    const minimumSize = Size(52, 36);
    const padding = EdgeInsets.symmetric(horizontal: 11);
    // 글씨 모양은 버튼 스타일이 아니라 라벨에 준다. 스타일의 textStyle은
    // 테마가 쥐여 준 글꼴(NotoSansKR)을 통째로 갈아치워, 한글이 시스템
    // 기본 글꼴로 떨어진다 — 다른 단추들과 같은 방식이다([EditorTopBar]).
    final label = Text(
      this.label,
      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
    );
    final icon = this.icon == null
        ? const SizedBox.shrink()
        : Icon(this.icon, size: 17);
    if (filled) {
      return FilledButton.icon(
        key: keyValue,
        onPressed: onPressed,
        icon: icon,
        label: label,
        style: FilledButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          minimumSize: minimumSize,
          padding: padding,
          shape: shape,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }
    return OutlinedButton.icon(
      key: keyValue,
      onPressed: onPressed,
      icon: icon,
      label: label,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        backgroundColor: Colors.white,
        side: BorderSide(color: borderColor ?? color),
        minimumSize: minimumSize,
        padding: padding,
        shape: shape,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _SubtitleEntryCard extends StatelessWidget {
  const _SubtitleEntryCard({
    required this.keyValue,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.description,
    required this.onTap,
    this.badge,
  });

  final Key keyValue;
  final IconData icon;
  final Color iconColor;
  final String title;
  final String description;
  final String? badge;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      side: const BorderSide(color: EditorColorTokens.border),
      borderRadius: BorderRadius.circular(14),
    ),
    child: InkWell(
      key: keyValue,
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
            child: Row(
              children: [
                Icon(icon, color: iconColor, size: 30),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: EditorColorTokens.ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
          if (badge != null)
            Positioned(
              right: 8,
              top: 7,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.sageSoft,
                  borderRadius: BorderRadius.circular(99),
                ),
                child: Text(
                  badge!,
                  style: const TextStyle(
                    color: AppColors.sageDark,
                    fontSize: 8,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
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
    // 강조·벗기기는 지금 보고 있는 클립의 얼굴 스티커 기준이다 —
    // 얼굴 스티커도 자막처럼 클립에 귀속되고, 사람마다 하나씩 붙는다.
    final scope = _scopeClip(project);
    final wornFaceValues = {
      for (final layer in project.stickerLayers)
        if (layer.tracksFace &&
            (layer.clipId == null || layer.clipId == scope?.id))
          layer.value,
    };
    final faceReady =
        project.faceTrack.isNotEmpty || project.faceTracks.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _PanelTitle('스티커 · 이 클립에 붙어요'),
        const SizedBox(height: 1),
        const Text(
          '끌어 옮기고 모서리로 크기를, 아래 타임라인으로 구간을 조절해요.',
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
              const Expanded(child: _PanelTitle('AR · 얼굴을 따라다니는 스티커')),
              if (wornFaceValues.isNotEmpty)
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
                                color: wornFaceValues.contains(sticker)
                                    ? EditorColorTokens.coral
                                    : EditorColorTokens.border,
                                width: wornFaceValues.contains(sticker)
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

  /// 흰 바닥에 머리카락 같은 구분선 하나. 예전에는 둥근 모서리와 그림자로
  /// 띄워 놓은 판이었는데, 도구 일곱 개를 담는 줄이 그렇게까지 앞으로 나설
  /// 이유가 없다 — 눈은 위쪽 타임라인에 있어야 한다.
  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: 2),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(top: BorderSide(color: EditorColorTokens.hairline)),
    ),
    child: Row(
      children: [
        for (final item in [..._clipItems, ..._globalItems])
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
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        decoration: BoxDecoration(
          color: selected ? EditorColorTokens.directWash : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: iconSize,
              color: selected ? AppColors.coral : EditorColorTokens.subtle,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.clip,
              softWrap: false,
              style: TextStyle(
                color: selected ? AppColors.coral : EditorColorTokens.subtle,
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
