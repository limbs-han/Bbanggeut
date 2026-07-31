import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import '../core/saved_video_edit.dart';
import '../core/video_edit_state.dart';
import '../core/video_exporter.dart';
import '../editor/editor_project.dart';
import '../editor/editor_project_controller.dart';
import '../editor/editor_platform.dart';
import '../editor/editor_workspace.dart';
import '../features/stt/caption_auto_section.dart';
import '../features/stt/caption_controller.dart';
import 'widgets.dart';

const _editorSurface = Color(0xFF292521);
const _editorMuted = Color(0xFFAAA198);

class LocalEditScreen extends StatefulWidget {
  const LocalEditScreen({
    super.key,
    required this.controller,
    required this.video,
    this.openDrafts = false,
  });

  final AppController controller;
  final VideoMemory video;
  final bool openDrafts;

  @override
  State<LocalEditScreen> createState() => _LocalEditScreenState();
}

class _LocalEditScreenState extends State<LocalEditScreen> {
  final _exporter = VideoEditorExporter();
  final _editorPlatform = const EditorPlatform();
  VideoPlayerController? _preview;
  String? _sourcePath;
  List<String> _thumbnails = [];
  double _progress = 0;
  bool _loading = true;
  bool _saving = false;
  final Set<String> _appliedTools = <String>{};
  String _captionText = '';
  Color _captionColor = AppColors.cream;
  double _audioVolume = 1;
  final String _selectedFilter = 'none';
  String _arSticker = '';
  String? _status;
  String? _error;
  late VideoEditState _editState;
  EditorProjectController? _projectController;
  int _playingClipIndex = 0;

  /// 들린 대사로 만드는 자동 자막. 상태와 편집 로직은 전부 이쪽에 있다.
  final _autoCaptions = CaptionController();

  /// 자막 입력칸 컨트롤러는 화면이 소유한다.
  ///
  /// 시트가 열릴 때 만들어 닫힌 직후 dispose하면 안 된다 — showModalBottomSheet의
  /// Future는 Navigator.pop 시점에 끝나지만 **닫히는 애니메이션은 그 뒤에도
  /// 재생된다.** 그 사이 키보드가 내려가며(autofocus로 올라와 있다)
  /// MediaQuery.viewInsetsOf가 바뀌어 시트가 다시 그려지고, 죽은 컨트롤러를
  /// 만져 빨간 화면이 뜬다. 실기기에서 확인한 예외:
  /// "A TextEditingController was used after being disposed."
  final _captionField = TextEditingController();

  bool get _editorReady =>
      _sourcePath != null && _preview?.value.isInitialized == true;

  @override
  void initState() {
    super.initState();
    _editState = VideoEditState(durationMs: 0, originalAspectRatio: 16 / 9);
    // 전사가 끝나면 미리보기 겹쳐보기가 바로 나타나야 한다. 이걸 안 걸면
    // 다음 재생 위치 갱신 때까지 자막이 안 보인다.
    _autoCaptions.addListener(_onCaptionsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  void _onCaptionsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _prepare() async {
    setState(() {
      _loading = true;
      _progress = 0.06;
      _error = null;
      _status = widget.openDrafts
          ? '저장된 편집 상태를 불러오고 있어요'
          : '추억 영상을 안전하게 불러오고 있어요';
    });

    try {
      final sourcePath = await _downloadSource();
      if (mounted) {
        setState(() {
          _progress = 0.88;
          _status = '편집 화면과 미리보기를 준비하고 있어요';
        });
      }
      final preview = VideoPlayerController.file(File(sourcePath));
      await preview.initialize();
      preview.addListener(_onPreviewChanged);
      if (!mounted) {
        await preview.dispose();
        return;
      }
      final durationMs = preview.value.duration.inMilliseconds;
      final aspectRatio = preview.value.size.aspectRatio > 0
          ? preview.value.size.aspectRatio
          : 16 / 9;
      final sourceWidth = preview.value.size.width.round();
      final sourceHeight = preview.value.size.height.round();
      setState(() {
        _sourcePath = sourcePath;
        _preview = preview;
        _progress = 1;
        _loading = false;
        _editState = VideoEditState(
          durationMs: durationMs,
          originalAspectRatio: aspectRatio,
        );
        _projectController = EditorProjectController(
          EditorProject.fromSource(
            sourceVideoPath: sourcePath,
            sourceDurationMs: durationMs,
            sourceSize: EditorSourceSize(
              width: sourceWidth,
              height: sourceHeight,
            ),
          ),
        );
        _status = null;
        // 영상이 기기에 내려온 직후 한 번. 캐시가 있으면 즉시 끝난다.
        _autoCaptions.start(widget.video.id, sourcePath);
      });
      await _loadThumbnails();
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$failure';
      });
    }
  }

  Future<void> _loadThumbnails() async {
    final sourcePath = _sourcePath;
    if (sourcePath == null) return;
    try {
      final generated = await _exporter.generateThumbnails(
        inputPath: sourcePath,
        count: 8,
      );
      if (!mounted) return;
      setState(() => _thumbnails = generated);
    } catch (_) {
      if (mounted) setState(() => _thumbnails = const <String>[]);
    }
  }

  Future<String> _downloadSource() async {
    final signed = await widget.controller.api.createDownloadUrl(
      widget.video.id,
    );
    if (mounted) {
      setState(() {
        _progress = 0.12;
        _status = '추억 영상을 휴대폰으로 가져오고 있어요';
      });
    }
    final temporary = await getTemporaryDirectory();
    final input = File(
      '${temporary.path}${Platform.pathSeparator}event-${widget.video.id}.mp4',
    );
    await Dio().download(
      signed.url,
      input.path,
      deleteOnError: true,
      onReceiveProgress: (received, total) {
        if (mounted && total > 0) {
          final downloadProgress = (received / total)
              .clamp(0.0, 1.0)
              .toDouble();
          setState(() => _progress = 0.12 + downloadProgress * 0.72);
        }
      },
    );
    return input.path;
  }

  void _onPreviewChanged() {
    final preview = _preview;
    final projectController = _projectController;
    if (!mounted || preview == null || projectController == null) return;
    final project = projectController.project;
    if (project.clips.isEmpty) return;
    _playingClipIndex = _playingClipIndex.clamp(0, project.clips.length - 1);
    final clip = project.clips[_playingClipIndex];
    final sourcePositionMs = preview.value.position.inMilliseconds;
    final timelineStartMs = project.timelineStartFor(clip.id);
    projectController.setPlayhead(
      timelineStartMs +
          (sourcePositionMs - clip.sourceStartMs).clamp(0, clip.durationMs),
      notify: false,
    );
    if (preview.value.isPlaying && sourcePositionMs >= clip.sourceEndMs) {
      if (_playingClipIndex + 1 < project.clips.length) {
        _playingClipIndex++;
        final next = project.clips[_playingClipIndex];
        unawaited(
          preview.seekTo(Duration(milliseconds: next.sourceStartMs)).then((_) {
            if (mounted && !preview.value.isPlaying) {
              return preview.play();
            }
          }),
        );
      } else {
        unawaited(preview.pause());
        projectController.setPlaying(false);
        projectController.setPlayhead(project.durationMs, notify: false);
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _togglePlayback() async {
    final preview = _preview;
    final projectController = _projectController;
    if (preview == null || projectController == null) return;
    if (preview.value.isPlaying) {
      await preview.pause();
      projectController.setPlaying(false);
    } else {
      if (projectController.project.playheadMs >=
          projectController.project.durationMs) {
        await _seekToPosition(0);
      } else {
        await _seekToPosition(projectController.project.playheadMs);
      }
      await preview.play();
      projectController.setPlaying(true);
    }
  }

  Future<void> _seekToPosition(int milliseconds) async {
    final preview = _preview;
    final projectController = _projectController;
    if (preview == null || projectController == null) return;
    final project = projectController.project;
    var timelineStartMs = 0;
    for (var index = 0; index < project.clips.length; index++) {
      final clip = project.clips[index];
      final timelineEndMs = timelineStartMs + clip.durationMs;
      if (milliseconds <= timelineEndMs || index == project.clips.length - 1) {
        _playingClipIndex = index;
        projectController.selectClip(clip.id);
        final offsetMs = (milliseconds - timelineStartMs).clamp(
          0,
          clip.durationMs,
        );
        projectController.setPlayhead(milliseconds);
        await preview.seekTo(
          Duration(milliseconds: clip.sourceStartMs + offsetMs),
        );
        break;
      }
      timelineStartMs = timelineEndMs;
    }
    if (mounted) setState(() {});
  }

  Future<void> _showCaptionEditor() async {
    _captionField.text = _captionText;
    var pendingColor = _captionColor;
    final applied = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _editorSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            18,
            20,
            MediaQuery.viewInsetsOf(context).bottom + 18,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _EditorSheetHeader(title: '자막'),
              const SizedBox(height: 16),
              TextField(
                controller: _captionField,
                autofocus: true,
                maxLength: 60,
                style: const TextStyle(color: AppColors.ink),
                decoration: const InputDecoration(
                  hintText: '영상에 표시할 자막을 입력하세요',
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                children:
                    [
                          AppColors.cream,
                          AppColors.sage,
                          AppColors.coral,
                          AppColors.yellow,
                        ]
                        .map(
                          (color) => _ColorOption(
                            color: color,
                            selected: color == pendingColor,
                            onTap: () =>
                                setSheetState(() => pendingColor = color),
                          ),
                        )
                        .toList(),
              ),
              CaptionAutoSection(
                controller: _autoCaptions,
                // whisper는 진행률을 주지 않는다. 영상 길이에 실측 비율을 곱해
                // 대략만 알려준다 (갤럭시 S24에서 약 0.9배).
                estimateSeconds: _editState.durationMs > 0
                    ? (_editState.durationMs / 1000 * 0.9).round()
                    : null,
                // 자막 수정도 저장 안 된 변경이다.
                onChanged: () =>
                    setState(() => _editState.markExternalEditApplied()),
              ),
              const SizedBox(height: 18),
              _SheetApplyButton(
                label: '자막 적용',
                onPressed: () => Navigator.pop(sheetContext, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (applied == true && mounted) {
      setState(() {
        _captionText = _captionField.text.trim();
        _captionColor = pendingColor;
        _editState.markExternalEditApplied();
        if (_captionText.isEmpty) {
          _appliedTools.remove('caption');
        } else {
          _appliedTools.add('caption');
        }
      });
    }
  }

  Future<void> _saveEdit() async {
    final projectController = _projectController;
    if (_saving ||
        _preview == null ||
        _sourcePath == null ||
        projectController == null) {
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
      _status = '편집 영상을 렌더링하고 있어요';
    });
    projectController.setExportState(
      const EditorExportState(phase: EditorExportPhase.preparing, progress: 0),
    );

    try {
      var exportProject = projectController.project;
      if (_captionText.trim().isNotEmpty) {
        exportProject = exportProject.copyWith(
          textLayers: [
            ...exportProject.textLayers,
            EditorTextLayer(
              id: 'manual-caption',
              text: _captionText.trim(),
              position: NormalizedPoint(0.5, 0.82),
              startMs: 0,
              endMs: exportProject.durationMs,
              color: _captionColor,
            ),
          ],
        );
      }
      projectController.setExportState(
        const EditorExportState(
          phase: EditorExportPhase.rendering,
          progress: 0,
        ),
      );
      final outputPath = await _editorPlatform.exportProject(
        project: exportProject,
        outputPath: _buildOutputPath(),
        captions: _captionsForProject(
          exportProject,
          _autoCaptions.forExport(startMs: 0, endMs: _editState.durationMs),
        ),
      );
      final file = File(outputPath);
      if (!await file.exists() || (await file.length()) == 0) {
        throw const VideoExportException('렌더링된 파일이 비어 있어요.');
      }
      await _editorPlatform.saveToGallery(
        inputPath: outputPath,
        title: _safeTitle(widget.video.title),
      );
      if (!mounted) return;
      _editState.markSaved();
      projectController.setExportState(
        const EditorExportState(
          phase: EditorExportPhase.completed,
          progress: 1,
        ),
      );
      setState(() {
        _saving = false;
        _status = '갤러리에 저장되었습니다';
      });
      showAppSnack(context, '갤러리에 저장되었습니다');
      Navigator.pop(context, SavedVideoEdit(videoPath: outputPath));
    } on EditorPlatformException catch (failure) {
      if (!mounted) return;
      projectController.setExportState(
        EditorExportState(phase: EditorExportPhase.failed, message: '$failure'),
      );
      setState(() {
        _saving = false;
        _error = '$failure';
        _status = null;
      });
      showAppSnack(context, '$failure', error: true);
    } catch (failure) {
      if (!mounted) return;
      projectController.setExportState(
        EditorExportState(phase: EditorExportPhase.failed, message: '$failure'),
      );
      setState(() {
        _saving = false;
        _error = '$failure';
        _status = null;
      });
      showAppSnack(context, '$failure', error: true);
    }
  }

  List<Map<String, Object>> _captionsForProject(
    EditorProject project,
    List<Map<String, Object>> sourceCaptions,
  ) {
    if (project.textLayers.isNotEmpty || sourceCaptions.isEmpty) {
      return const [];
    }
    final mapped = <Map<String, Object>>[];
    var timelineStartMs = 0;
    for (final clip in project.clips) {
      for (final caption in sourceCaptions) {
        final startMs = (caption['startMs'] as num?)?.toInt();
        final endMs = (caption['endMs'] as num?)?.toInt();
        final text = caption['text'] as String?;
        if (startMs == null ||
            endMs == null ||
            text == null ||
            text.trim().isEmpty) {
          continue;
        }
        final overlapStart = startMs.clamp(
          clip.sourceStartMs,
          clip.sourceEndMs,
        );
        final overlapEnd = endMs.clamp(clip.sourceStartMs, clip.sourceEndMs);
        if (overlapEnd <= overlapStart) continue;
        mapped.add({
          'startMs': timelineStartMs + overlapStart - clip.sourceStartMs,
          'endMs': timelineStartMs + overlapEnd - clip.sourceStartMs,
          'text': text,
        });
      }
      timelineStartMs += clip.durationMs;
    }
    return mapped;
  }

  String _buildOutputPath({String? prefix}) {
    final sourcePath = _sourcePath;
    final directory = sourcePath == null
        ? Directory.systemTemp
        : File(sourcePath).parent;
    final baseName = _safeTitle(widget.video.title);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final suffix = prefix == null ? '' : '_$prefix';
    return '${directory.path}${Platform.pathSeparator}'
        '$baseName${suffix}_$timestamp.mp4';
  }

  void _retry() {
    _progress = 0;
    _prepare();
  }

  @override
  void dispose() {
    final preview = _preview;
    if (preview != null) {
      preview.removeListener(_onPreviewChanged);
      preview.dispose();
    }
    _projectController?.dispose();
    _captionField.dispose();
    _autoCaptions
      ..removeListener(_onCaptionsChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_editState.hasUnsavedChanges || _saving,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) return;
      if (_editState.hasUnsavedChanges && !_saving) {
        showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('편집을 그만둘까요?'),
            content: const Text('현재 편집 내용은 저장되지 않아요.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('계속 편집'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(dialogContext);
                  Navigator.pop(context);
                },
                child: const Text('폐기'),
              ),
            ],
          ),
        );
      } else {
        Navigator.pop(context);
      }
    },
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: const Color(0xFFFFF7EE),
        resizeToAvoidBottomInset: true,
        body: _loading
            ? _preparing()
            : !_editorReady
            ? SafeArea(child: _failed())
            : _editorShell(),
      ),
    ),
  );

  Widget _preparing() => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxHeight < 740;
      final percent = (_progress * 100).round().clamp(1, 99);
      return Stack(
        key: const Key('editor-preparing-screen'),
        children: [
          const Positioned(
            left: -82,
            top: -96,
            child: _PreparingBlob(
              size: 210,
              colors: [Color(0xFFFF947F), Color(0xFFFFC2AD)],
            ),
          ),
          const Positioned(
            right: -82,
            top: -92,
            child: _PreparingBlob(
              size: 190,
              colors: [Color(0xFFD6E29B), Color(0xFFF0F3C7)],
            ),
          ),
          const Positioned(
            left: -104,
            bottom: -116,
            child: _PreparingBlob(
              size: 230,
              colors: [Color(0xFFCFE09A), Color(0xFFF0F3C9)],
            ),
          ),
          const Positioned(
            right: -96,
            bottom: -124,
            child: _PreparingBlob(
              size: 240,
              colors: [Color(0xFFFF8F79), Color(0xFFFFC1A9)],
            ),
          ),
          SafeArea(
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight:
                      constraints.maxHeight -
                      MediaQuery.paddingOf(context).vertical,
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    24,
                    compact ? 8 : 14,
                    24,
                    compact ? 20 : 28,
                  ),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          IconButton(
                            key: const Key('editor-preparing-close'),
                            tooltip: '닫기',
                            onPressed: () => Navigator.maybePop(context),
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.72,
                              ),
                              foregroundColor: AppColors.inkSoft,
                            ),
                            icon: const Icon(Icons.close_rounded),
                          ),
                          const Spacer(),
                          const _PreparingWordmark(),
                          const Spacer(),
                          const SizedBox(width: 48),
                        ],
                      ),
                      SizedBox(height: compact ? 4 : 10),
                      Text(
                        '추억 영상을\n불러오고 있어요',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: const Color(0xFF4D3425),
                          fontSize: compact ? 30 : 35,
                          height: 1.25,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '곧 편집을 시작할 수 있어요',
                        style: TextStyle(
                          color: Color(0xFF8D7968),
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: compact ? 8 : 14),
                      _PreparingMascot(height: compact ? 205 : 255),
                      SizedBox(height: compact ? 8 : 14),
                      KeyedSubtree(
                        key: const Key('editor-loading-percentage'),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              const TextSpan(text: '준비 중 '),
                              TextSpan(
                                text: '$percent%',
                                style: const TextStyle(color: AppColors.coral),
                              ),
                            ],
                          ),
                          key: const Key('editor-preparing-percent'),
                          style: TextStyle(
                            color: const Color(0xFF4D3425),
                            fontSize: compact ? 21 : 24,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _PreparingProgressBar(value: _progress),
                      const SizedBox(height: 9),
                      Text(
                        _status ?? '편집기를 준비하는 중이에요',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF8D7968),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: compact ? 14 : 20),
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text('🌱', style: TextStyle(fontSize: 15)),
                          SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              '기다리는 동안 편집 기능을 확인해 보세요',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Color(0xFF796555),
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          SizedBox(width: 6),
                          Text('🌱', style: TextStyle(fontSize: 15)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: compact ? 92 : 108,
                        child: const Row(
                          children: [
                            Expanded(
                              child: _PreparingFeatureCard(
                                icon: Icons.content_cut_rounded,
                                label: '자르기',
                                iconColor: Color(0xFF82A84C),
                                iconBackground: Color(0xFFEAF2C9),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: _PreparingFeatureCard(
                                icon: Icons.music_note_rounded,
                                label: '음악',
                                iconColor: AppColors.coral,
                                iconBackground: Color(0xFFFFE1D7),
                              ),
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: _PreparingFeatureCard(
                                icon: Icons.star_rounded,
                                label: '스티커',
                                iconColor: Color(0xFFF1AD39),
                                iconBackground: Color(0xFFFFF0B8),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );

  Widget _editorShell() {
    final preview = _preview!;
    final projectController = _projectController!;
    final project = projectController.project;
    return EditorWorkspace(
      controller: projectController,
      preview: _PreviewSurface(
        controller: preview,
        projectController: projectController,
        canvas: project.canvas,
        captionText: _captionText,
        captionColor: _captionColor,
        filter: _selectedFilter,
        arSticker: _arSticker,
        autoCaptionText: autoCaptionAt(
          _autoCaptions,
          preview.value.position.inMilliseconds,
        ),
      ),
      thumbnails: _thumbnails,
      playing: preview.value.isPlaying,
      currentTime: _time(Duration(milliseconds: project.playheadMs)),
      totalTime: _time(Duration(milliseconds: project.durationMs)),
      saving: _saving,
      onBack: () => Navigator.maybePop(context),
      onSave: _saveEdit,
      onPlay: _togglePlayback,
      onSeek: _seekToPosition,
      onSplit: _splitClip,
      onDelete: _deleteClip,
      onDuplicate: _duplicateClip,
      onTrimStartChanged: _trimSelectedClipStart,
      onTrimEndChanged: _trimSelectedClipEnd,
      onRatioSelected: _selectCanvasRatio,
      onText: _showCaptionEditor,
      onVolumeChanged: _setAudioVolume,
      onMutedChanged: _setMuted,
      onStickerSelected: _addSticker,
      onToolSelected: _selectEditorTool,
    );
  }

  void _selectEditorTool(EditorTool tool) {
    if (_saving) return;
    _projectController?.selectTool(tool);
    if (mounted) setState(() {});
  }

  void _selectCanvasRatio(EditorCanvasRatio ratio) {
    _projectController?.setCanvasRatio(ratio);
    _editState.selectRatio(switch (ratio) {
      EditorCanvasRatio.original => VideoEditRatio.original,
      EditorCanvasRatio.vertical => VideoEditRatio.shortForm,
      EditorCanvasRatio.landscape => VideoEditRatio.landscape,
      EditorCanvasRatio.square => VideoEditRatio.square,
      EditorCanvasRatio.portrait => VideoEditRatio.portrait,
    });
    if (mounted) setState(() {});
  }

  void _splitClip() {
    final projectController = _projectController;
    if (projectController == null) return;
    if (!projectController.splitAt(projectController.project.playheadMs)) {
      showAppSnack(context, '클립 양쪽에 최소 0.1초가 남는 위치에서 분할해 주세요.');
      return;
    }
    _editState.markExternalEditApplied();
    if (mounted) setState(() {});
  }

  void _deleteClip() {
    final projectController = _projectController;
    if (projectController == null || !projectController.deleteSelectedClip()) {
      showAppSnack(context, '마지막 클립은 삭제할 수 없어요.');
      return;
    }
    _playingClipIndex = _playingClipIndex.clamp(
      0,
      projectController.project.clips.length - 1,
    );
    _editState.markExternalEditApplied();
    unawaited(
      _seekToPosition(
        projectController.project.playheadMs.clamp(
          0,
          projectController.project.durationMs,
        ),
      ),
    );
  }

  void _duplicateClip() {
    final projectController = _projectController;
    if (projectController == null ||
        !projectController.duplicateSelectedClip()) {
      return;
    }
    _editState.markExternalEditApplied();
    if (mounted) setState(() {});
  }

  void _trimSelectedClipStart(int sourceStartMs) {
    final projectController = _projectController;
    if (projectController == null ||
        !projectController.trimSelectedClip(sourceStartMs: sourceStartMs)) {
      return;
    }
    _editState.markExternalEditApplied();
    unawaited(_seekToPosition(projectController.project.playheadMs));
  }

  void _trimSelectedClipEnd(int sourceEndMs) {
    final projectController = _projectController;
    if (projectController == null ||
        !projectController.trimSelectedClip(sourceEndMs: sourceEndMs)) {
      return;
    }
    _editState.markExternalEditApplied();
    unawaited(_seekToPosition(projectController.project.playheadMs));
  }

  void _setAudioVolume(double volume) {
    _projectController?.setSourceVolume(volume);
    _audioVolume = volume;
    _editState.markExternalEditApplied();
    unawaited(_preview?.setVolume(volume) ?? Future<void>.value());
    if (mounted) setState(() {});
  }

  void _setMuted(bool muted) {
    final projectController = _projectController;
    if (projectController == null) return;
    projectController.setMuted(muted);
    _audioVolume = projectController.project.audio.effectiveVolume;
    _editState.markExternalEditApplied();
    unawaited(_preview?.setVolume(_audioVolume) ?? Future<void>.value());
    if (mounted) setState(() {});
  }

  void _addSticker(String sticker) {
    _projectController?.addSticker(sticker);
    setState(() {
      _arSticker = sticker;
      _appliedTools.add('ar');
      _editState.markExternalEditApplied();
    });
  }

  String _time(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String _safeTitle(String title) {
    final value = title.replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]'), '_');
    return value.isEmpty ? 'bbanggeut_edit' : value;
  }

  Widget _failed() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: EmptyState(
        icon: Icons.video_settings_outlined,
        title: '편집기를 열지 못했어요',
        message: _error ?? '잠시 후 다시 시도해 주세요.',
        action: FilledButton.icon(
          onPressed: _retry,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('다시 시도'),
        ),
      ),
    ),
  );
}

class _PreparingWordmark extends StatelessWidget {
  const _PreparingWordmark();

  @override
  Widget build(BuildContext context) => const Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '빵긋',
        style: TextStyle(
          color: AppColors.coral,
          fontSize: 25,
          fontWeight: FontWeight.w900,
          letterSpacing: -1,
        ),
      ),
      Padding(
        padding: EdgeInsets.only(left: 2),
        child: Text('🌱', style: TextStyle(fontSize: 14)),
      ),
    ],
  );
}

class _PreparingMascot extends StatelessWidget {
  const _PreparingMascot({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 16,
          bottom: 28,
          child: Transform.rotate(
            angle: -0.14,
            child: const Icon(
              Icons.favorite_rounded,
              color: Color(0xFFFF957E),
              size: 36,
            ),
          ),
        ),
        Positioned(
          right: 18,
          top: 62,
          child: Transform.rotate(
            angle: 0.18,
            child: const Icon(
              Icons.add_rounded,
              color: Color(0xFFFFB49F),
              size: 35,
            ),
          ),
        ),
        Positioned(
          left: 2,
          top: 62,
          child: Container(
            width: 13,
            height: 13,
            decoration: const BoxDecoration(
              color: Color(0xFFD5E59B),
              shape: BoxShape.circle,
            ),
          ),
        ),
        Image.asset(
          'assets/images/calendar_header_mascot.png',
          height: height,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
        Positioned(
          bottom: 34,
          child: Transform.rotate(
            angle: -0.035,
            child: Container(
              width: 94,
              height: 69,
              decoration: BoxDecoration(
                color: AppColors.coral,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x2E9D4F35),
                    blurRadius: 14,
                    offset: Offset(0, 7),
                  ),
                ],
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: -2,
                    right: -2,
                    top: -12,
                    height: 24,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF514B45),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _ClapperStripe(color: Colors.white),
                          _ClapperStripe(color: Color(0xFF514B45)),
                          _ClapperStripe(color: Colors.white),
                          _ClapperStripe(color: Color(0xFF514B45)),
                          _ClapperStripe(color: Colors.white),
                        ],
                      ),
                    ),
                  ),
                  const Center(
                    child: Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 42,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 18,
          right: 18,
          bottom: 2,
          child: Container(
            height: 8,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(99),
              gradient: const LinearGradient(
                colors: [
                  Color(0xFFFF8872),
                  Color(0xFFFFB287),
                  Color(0xFFC7DB85),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _ClapperStripe extends StatelessWidget {
  const _ClapperStripe({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Transform(
    transform: Matrix4.skewX(-0.45),
    alignment: Alignment.center,
    child: Container(width: 13, height: 20, color: color),
  );
}

class _PreparingProgressBar extends StatelessWidget {
  const _PreparingProgressBar({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) => Container(
    key: const Key('editor-preparing-progress'),
    height: 12,
    decoration: BoxDecoration(
      color: const Color(0xFFF1E6D8),
      borderRadius: BorderRadius.circular(99),
    ),
    clipBehavior: Clip.antiAlias,
    child: Align(
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: value.clamp(0.02, 1.0).toDouble(),
        child: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFFF806D), Color(0xFFFFAE86), Color(0xFFC8DC85)],
            ),
          ),
          child: SizedBox.expand(),
        ),
      ),
    ),
  );
}

class _PreparingFeatureCard extends StatelessWidget {
  const _PreparingFeatureCard({
    required this.icon,
    required this.label,
    required this.iconColor,
    required this.iconBackground,
  });

  final IconData icon;
  final String label;
  final Color iconColor;
  final Color iconBackground;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.7),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: const Color(0xFFEBDCCB)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0F7B5A3B),
          blurRadius: 12,
          offset: Offset(0, 5),
        ),
      ],
    ),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: iconBackground,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: iconColor, size: 27),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF574133),
            fontSize: 14,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    ),
  );
}

class _PreparingBlob extends StatelessWidget {
  const _PreparingBlob({required this.size, required this.colors});

  final double size;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) => Transform.rotate(
    angle: 0.22,
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.38),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
    ),
  );
}

class _EditorSheetHeader extends StatelessWidget {
  const _EditorSheetHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(
        title,
        style: const TextStyle(
          color: AppColors.cream,
          fontSize: 19,
          fontWeight: FontWeight.w900,
        ),
      ),
      const Spacer(),
      IconButton(
        tooltip: '닫기',
        onPressed: () => Navigator.pop(context),
        color: _editorMuted,
        icon: const Icon(Icons.close_rounded),
      ),
    ],
  );
}

class _SheetApplyButton extends StatelessWidget {
  const _SheetApplyButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.sage,
        foregroundColor: AppColors.ink,
      ),
      child: Text(label),
    ),
  );
}

class _ColorOption extends StatelessWidget {
  const _ColorOption({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    customBorder: const CircleBorder(),
    onTap: onTap,
    child: Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: selected ? Colors.white : Colors.transparent,
          width: 3,
        ),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, color: AppColors.ink, size: 22)
          : null,
    ),
  );
}

class _PreviewSurface extends StatelessWidget {
  const _PreviewSurface({
    required this.controller,
    required this.projectController,
    required this.canvas,
    required this.captionText,
    required this.captionColor,
    required this.filter,
    required this.arSticker,
    this.autoCaptionText,
  });

  final VideoPlayerController controller;
  final EditorProjectController projectController;
  final EditorCanvas canvas;
  final String captionText;
  final Color captionColor;
  final String filter;
  final String arSticker;

  /// 지금 재생 위치의 자동 자막. 손 자막이 있으면 그리지 않는다 — 같은 자리라
  /// 겹치면 읽을 수 없다.
  final String? autoCaptionText;

  /// 화면에 실제로 그릴 자막. 손 자막이 우선이다.
  String? get _captionOnScreen {
    if (captionText.isNotEmpty) return captionText;
    final auto = autoCaptionText;
    return auto != null && auto.isNotEmpty ? auto : null;
  }

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    final width = size.width <= 0 ? 1280.0 : size.width.toDouble();
    final height = size.height <= 0 ? 720.0 : size.height.toDouble();
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth;
        final availableHeight = constraints.maxHeight;
        return Center(
          child: AspectRatio(
            aspectRatio: canvas.aspectRatio,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: availableWidth,
                maxHeight: availableHeight,
              ),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(4),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _CanvasGestureLayer(
                      controller: projectController,
                      canvas: canvas,
                      child: Center(
                        child: ColorFiltered(
                          colorFilter: _colorFilter(filter),
                          child: FittedBox(
                            fit: BoxFit.contain,
                            child: SizedBox(
                              width: width,
                              height: height,
                              child: VideoPlayer(controller),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (arSticker.isNotEmpty)
                      Align(
                        alignment: const Alignment(0, -0.28),
                        child: Text(
                          arSticker,
                          style: const TextStyle(
                            fontSize: 64,
                            shadows: [
                              Shadow(color: Colors.black38, blurRadius: 8),
                            ],
                          ),
                        ),
                      ),
                    // 손 자막이 있으면 그것을, 없으면 자동 자막을 그린다.
                    // 자리가 같아서 둘을 겹치면 읽을 수 없다.
                    if (_captionOnScreen != null)
                      Align(
                        alignment: const Alignment(0, 0.74),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            _captionOnScreen!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: captionColor,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              shadows: const [
                                Shadow(color: Colors.black, blurRadius: 3),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  ColorFilter _colorFilter(String filter) => switch (filter) {
    'mono' => const ColorFilter.matrix([
      0.2126,
      0.7152,
      0.0722,
      0,
      0,
      0.2126,
      0.7152,
      0.0722,
      0,
      0,
      0.2126,
      0.7152,
      0.0722,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]),
    'warm' => const ColorFilter.matrix([
      1.08,
      0.04,
      0,
      0,
      8,
      0,
      1.02,
      0,
      0,
      3,
      0,
      0,
      0.9,
      0,
      -4,
      0,
      0,
      0,
      1,
      0,
    ]),
    'vivid' => const ColorFilter.matrix([
      1.2,
      -0.1,
      -0.1,
      0,
      0,
      -0.1,
      1.2,
      -0.1,
      0,
      0,
      -0.1,
      -0.1,
      1.2,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]),
    _ => const ColorFilter.mode(Colors.transparent, BlendMode.dst),
  };
}

class _CanvasGestureLayer extends StatefulWidget {
  const _CanvasGestureLayer({
    required this.controller,
    required this.canvas,
    required this.child,
  });

  final EditorProjectController controller;
  final EditorCanvas canvas;
  final Widget child;

  @override
  State<_CanvasGestureLayer> createState() => _CanvasGestureLayerState();
}

class _CanvasGestureLayerState extends State<_CanvasGestureLayer> {
  double _startScale = 1;
  double _startRotation = 0;
  double _startOffsetX = 0;
  double _startOffsetY = 0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: widget.controller.resetCanvasTransform,
      onScaleStart: (_) {
        final canvas = widget.controller.project.canvas;
        _startScale = canvas.scale;
        _startRotation = canvas.rotationDegrees;
        _startOffsetX = canvas.offsetX;
        _startOffsetY = canvas.offsetY;
        widget.controller.beginCanvasGesture();
      },
      onScaleUpdate: (details) {
        final width = constraints.maxWidth <= 0 ? 1.0 : constraints.maxWidth;
        final height = constraints.maxHeight <= 0 ? 1.0 : constraints.maxHeight;
        widget.controller.updateCanvasGesture(
          scale: _startScale * details.scale,
          offsetX: _startOffsetX + details.focalPointDelta.dx / width * 2,
          offsetY: _startOffsetY + details.focalPointDelta.dy / height * 2,
          rotationDegrees: _startRotation + details.rotation * 180 / math.pi,
        );
      },
      onScaleEnd: (_) => widget.controller.endCanvasGesture(),
      child: Transform.translate(
        offset: Offset(
          widget.canvas.offsetX * constraints.maxWidth / 2,
          widget.canvas.offsetY * constraints.maxHeight / 2,
        ),
        child: Transform.rotate(
          angle: widget.canvas.rotationDegrees * math.pi / 180,
          child: Transform.scale(
            scale: widget.canvas.scale,
            child: widget.child,
          ),
        ),
      ),
    ),
  );
}
