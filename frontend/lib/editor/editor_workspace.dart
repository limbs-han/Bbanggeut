import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

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
    required this.onAr,
    required this.onToolSelected,
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
  final VoidCallback onAr;
  final ValueChanged<EditorTool> onToolSelected;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final project = controller.project;
      final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
      return ColoredBox(
        color: EditorColorTokens.background,
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final layout = EditorLayoutTokens.fromHeight(
                constraints.maxHeight,
                keyboardVisible: keyboardVisible,
              );
              return Column(
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
                      height: project.selectedTool == EditorTool.cut
                          ? layout.timelineHeight
                          : 74,
                      thumbnailHeight: project.selectedTool == EditorTool.cut
                          ? layout.thumbnailHeight
                          : 50,
                      project: project,
                      thumbnails: thumbnails,
                      expanded: project.selectedTool == EditorTool.cut,
                      canDelete: controller.canDeleteSelectedClip,
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
                        onRatioSelected: onRatioSelected,
                        onText: onText,
                        onVolumeChanged: onVolumeChanged,
                        onMutedChanged: onMutedChanged,
                        onStickerSelected: onStickerSelected,
                        onAr: onAr,
                      ),
                    ),
                  if (!keyboardVisible)
                    EditorBottomNavigation(
                      height: layout.bottomNavigationHeight,
                      selectedTool: project.selectedTool,
                      onSelected: onToolSelected,
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

class EditorTimelineSection extends StatelessWidget {
  const EditorTimelineSection({
    super.key,
    required this.height,
    required this.thumbnailHeight,
    required this.project,
    required this.thumbnails,
    required this.expanded,
    required this.canDelete,
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
  final EditorProject project;
  final List<String> thumbnails;
  final bool expanded;
  final bool canDelete;
  final ValueChanged<int> onSeek;
  final ValueChanged<String> onClipSelected;
  final VoidCallback onSplit;
  final VoidCallback onDelete;
  final VoidCallback onDuplicate;
  final ValueChanged<int> onTrimStartChanged;
  final ValueChanged<int> onTrimEndChanged;

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
              height: expanded ? 18 : 8,
              child: expanded
                  ? Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '0:00',
                          style: TextStyle(
                            color: EditorColorTokens.muted,
                            fontSize: 10,
                          ),
                        ),
                        Text(
                          _formatMs(project.durationMs),
                          style: const TextStyle(
                            color: EditorColorTokens.muted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    )
                  : null,
            ),
            if (expanded)
              if (project.selectedClip case final selectedClip?)
                SizedBox(
                  height: 38,
                  child: Row(
                    children: [
                      SizedBox(
                        width: 42,
                        child: Text(
                          _formatMs(selectedClip.sourceStartMs),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: EditorColorTokens.muted,
                            fontSize: 10,
                          ),
                        ),
                      ),
                      Expanded(
                        child: RangeSlider(
                          key: const Key('editor-trim-range'),
                          min: 0,
                          max: project.sourceDurationMs.toDouble(),
                          values: RangeValues(
                            selectedClip.sourceStartMs.toDouble(),
                            selectedClip.sourceEndMs.toDouble(),
                          ),
                          labels: RangeLabels(
                            _formatMs(selectedClip.sourceStartMs),
                            _formatMs(selectedClip.sourceEndMs),
                          ),
                          onChanged: (values) {
                            final nextStart = values.start.round();
                            final nextEnd = values.end.round();
                            if (nextStart != selectedClip.sourceStartMs) {
                              onTrimStartChanged(nextStart);
                            }
                            if (nextEnd != selectedClip.sourceEndMs) {
                              onTrimEndChanged(nextEnd);
                            }
                          },
                        ),
                      ),
                      SizedBox(
                        width: 42,
                        child: Text(
                          _formatMs(selectedClip.sourceEndMs),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: EditorColorTokens.muted,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            Expanded(
              child: _ThumbnailTrack(
                height: thumbnailHeight,
                project: project,
                thumbnails: thumbnails,
                onSeek: onSeek,
                onClipSelected: onClipSelected,
              ),
            ),
            if (expanded)
              SizedBox(
                height: 42,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _TimelineAction(
                      label: '분할',
                      icon: Icons.content_cut_rounded,
                      onPressed: onSplit,
                    ),
                    _TimelineAction(
                      label: '삭제',
                      icon: Icons.delete_outline_rounded,
                      onPressed: canDelete ? onDelete : null,
                    ),
                    _TimelineAction(
                      label: '복제',
                      icon: Icons.copy_rounded,
                      onPressed: onDuplicate,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

class _ThumbnailTrack extends StatelessWidget {
  const _ThumbnailTrack({
    required this.height,
    required this.project,
    required this.thumbnails,
    required this.onSeek,
    required this.onClipSelected,
  });

  final double height;
  final EditorProject project;
  final List<String> thumbnails;
  final ValueChanged<int> onSeek;
  final ValueChanged<String> onClipSelected;

  @override
  Widget build(BuildContext context) {
    final progress = project.durationMs <= 0
        ? 0.0
        : project.playheadMs / project.durationMs;
    return LayoutBuilder(
      builder: (context, constraints) {
        final trackWidth = constraints.maxWidth <= 0
            ? 1.0
            : constraints.maxWidth;
        return Listener(
          onPointerDown: (event) {
            if (project.durationMs <= 0) return;
            final timelineMs =
                (event.localPosition.dx / trackWidth * project.durationMs)
                    .round()
                    .clamp(0, project.durationMs);
            var startMs = 0;
            for (final clip in project.clips) {
              final endMs = startMs + clip.durationMs;
              if (timelineMs >= startMs && timelineMs <= endMs) {
                onClipSelected(clip.id);
                break;
              }
              startMs = endMs;
            }
          },
          child: Stack(
            alignment: Alignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(EditorRadiusTokens.video),
                child: Row(
                  children: [
                    for (var index = 0; index < thumbnails.length; index++)
                      Expanded(
                        child: _Thumbnail(
                          path: thumbnails[index],
                          isFirst: index == 0,
                        ),
                      ),
                    if (thumbnails.isEmpty)
                      const Expanded(
                        child: ColoredBox(
                          color: EditorColorTokens.border,
                          child: Center(
                            child: SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: EditorColorTokens.coral,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Positioned.fill(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 0,
                    thumbColor: Colors.transparent,
                    overlayColor: Colors.transparent,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 12,
                      elevation: 0,
                      pressedElevation: 0,
                    ),
                  ),
                  child: Slider(
                    key: const Key('editor-timeline-slider'),
                    value: progress.clamp(0.0, 1.0),
                    onChanged: (value) =>
                        onSeek((project.durationMs * value).round()),
                  ),
                ),
              ),
              IgnorePointer(
                child: Align(
                  key: const Key('editor-playhead'),
                  alignment: Alignment(-1 + progress * 2, 0),
                  child: Container(
                    width: 2,
                    height: height,
                    color: EditorColorTokens.coral,
                  ),
                ),
              ),
              IgnorePointer(
                child: Align(
                  alignment: Alignment(-1 + progress * 2, -1),
                  child: Container(
                    width: 10,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: EditorColorTokens.coral,
                      borderRadius: BorderRadius.vertical(
                        bottom: Radius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Row(
                    children: [
                      for (final clip in project.clips)
                        Expanded(
                          flex: math.max(1, clip.durationMs),
                          child: Container(
                            key: Key('editor-clip-${clip.id}'),
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: clip.id == project.selectedClipId
                                    ? EditorColorTokens.coral
                                    : Colors.white54,
                                width: clip.id == project.selectedClipId
                                    ? 3
                                    : 1,
                              ),
                              borderRadius: BorderRadius.circular(
                                EditorRadiusTokens.video,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.path, required this.isFirst});

  final String path;
  final bool isFirst;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(
        left: BorderSide(
          color: isFirst ? Colors.transparent : EditorColorTokens.border,
          width: 1,
        ),
      ),
    ),
    child: Image.file(
      File(path),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) =>
          const ColoredBox(color: EditorColorTokens.border),
    ),
  );
}

class SelectedToolPanel extends StatelessWidget {
  const SelectedToolPanel({
    super.key,
    required this.project,
    required this.onRatioSelected,
    required this.onText,
    required this.onVolumeChanged,
    required this.onMutedChanged,
    required this.onStickerSelected,
    required this.onAr,
  });

  final EditorProject project;
  final ValueChanged<EditorCanvasRatio> onRatioSelected;
  final VoidCallback onText;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<bool> onMutedChanged;
  final ValueChanged<String> onStickerSelected;
  final VoidCallback onAr;

  @override
  Widget build(BuildContext context) {
    if (project.selectedTool == EditorTool.cut) {
      return const SizedBox.shrink();
    }
    final height = switch (project.selectedTool) {
      EditorTool.ratio => 112.0,
      EditorTool.text => 96.0,
      EditorTool.audio => 120.0,
      EditorTool.sticker => 112.0,
      EditorTool.ar => 112.0,
      EditorTool.cut => 0.0,
    };
    return Container(
      height: height,
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
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
        EditorTool.ar => _ArPanel(onOpen: onAr),
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
      const SizedBox(height: 8),
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
      const Spacer(),
      SizedBox(
        width: double.infinity,
        height: 44,
        child: OutlinedButton.icon(
          onPressed: onText,
          icon: const Icon(Icons.title_rounded, size: 21),
          label: const Text('텍스트 입력 및 자막 관리'),
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
      Row(
        children: [
          const Expanded(child: _PanelTitle('원본 오디오')),
          TextButton.icon(
            onPressed: () => onMutedChanged(!audio.muted),
            icon: Icon(
              audio.muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
              size: 20,
            ),
            label: Text(audio.muted ? '음소거 해제' : '음소거'),
          ),
        ],
      ),
      Slider(
        value: audio.sourceVolume,
        onChanged: audio.muted ? null : onVolumeChanged,
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

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _PanelTitle('기본 스티커'),
      const SizedBox(height: 8),
      Expanded(
        child: Row(
          children: [
            for (final sticker in const ['😊', '😂', '🥳', '❤️', '⭐'])
              Expanded(
                child: InkWell(
                  onTap: () => onSelected(sticker),
                  borderRadius: BorderRadius.circular(
                    EditorRadiusTokens.control,
                  ),
                  child: Center(
                    child: Text(sticker, style: const TextStyle(fontSize: 28)),
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

class _ArPanel extends StatelessWidget {
  const _ArPanel({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const _PanelTitle('앱 안에서 Banuba 얼굴 AR'),
      const SizedBox(height: 8),
      Expanded(
        child: FilledButton.icon(
          key: const Key('open-banuba-ar-editor'),
          onPressed: onOpen,
          icon: const Icon(Icons.face_retouching_natural, size: 21),
          label: const Text('현재 영상에 AR 적용'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(double.infinity, 44),
            backgroundColor: EditorColorTokens.coral,
            foregroundColor: Colors.white,
          ),
        ),
      ),
    ],
  );
}

class EditorBottomNavigation extends StatelessWidget {
  const EditorBottomNavigation({
    super.key,
    required this.height,
    required this.selectedTool,
    required this.onSelected,
  });

  final double height;
  final EditorTool selectedTool;
  final ValueChanged<EditorTool> onSelected;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: 4),
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
        _NavigationItem(
          tool: EditorTool.cut,
          label: '컷 편집',
          icon: Icons.content_cut_rounded,
          selected: selectedTool == EditorTool.cut,
          onSelected: onSelected,
        ),
        _NavigationItem(
          tool: EditorTool.ratio,
          label: '비율',
          icon: Icons.aspect_ratio_rounded,
          selected: selectedTool == EditorTool.ratio,
          onSelected: onSelected,
        ),
        _NavigationItem(
          tool: EditorTool.text,
          label: '텍스트',
          icon: Icons.title_rounded,
          selected: selectedTool == EditorTool.text,
          onSelected: onSelected,
        ),
        _NavigationItem(
          tool: EditorTool.audio,
          label: '오디오',
          icon: Icons.music_note_rounded,
          selected: selectedTool == EditorTool.audio,
          onSelected: onSelected,
        ),
        _NavigationItem(
          tool: EditorTool.sticker,
          label: '스티커',
          icon: Icons.emoji_emotions_outlined,
          selected: selectedTool == EditorTool.sticker,
          onSelected: onSelected,
        ),
        _NavigationItem(
          tool: EditorTool.ar,
          label: 'AR',
          icon: Icons.face_retouching_natural,
          selected: selectedTool == EditorTool.ar,
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
    required this.onSelected,
  });

  final EditorTool tool;
  final String label;
  final IconData icon;
  final bool selected;
  final ValueChanged<EditorTool> onSelected;

  @override
  Widget build(BuildContext context) => Expanded(
    child: InkWell(
      onTap: () => onSelected(tool),
      borderRadius: BorderRadius.circular(EditorRadiusTokens.control),
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
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
              size: 21,
              color: selected
                  ? EditorColorTokens.coral
                  : EditorColorTokens.muted,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                color: selected
                    ? EditorColorTokens.coral
                    : EditorColorTokens.muted,
                fontSize: EditorTypographyTokens.navigation,
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
    icon: Icon(icon, size: 20),
    label: Text(label, style: const TextStyle(fontSize: 12)),
    style: TextButton.styleFrom(
      foregroundColor: EditorColorTokens.ink,
      disabledForegroundColor: EditorColorTokens.border,
      minimumSize: const Size(86, 40),
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
        constraints: const BoxConstraints(minWidth: 56, minHeight: 44),
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
