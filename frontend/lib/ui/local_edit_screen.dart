import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import '../core/saved_video_edit.dart';
import '../core/video_edit_state.dart';
import '../core/video_exporter.dart';
import '../core/video_source_cache.dart';
import '../editor/editor_ar_effects.dart';
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
    this.cacheDirectoryProvider,
  });

  final AppController controller;
  final VideoMemory video;
  final bool openDrafts;
  final Future<Directory> Function()? cacheDirectoryProvider;

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
  String? _status;
  String? _error;

  /// 렌더링 진행률(0~1). 네이티브에서 주기적으로 읽어 온다. null이면 아직 모른다.
  double? _exportProgress;
  Timer? _exportProgressTimer;

  /// 사용자가 렌더링을 그만뒀는지. 실패 안내와 취소 안내를 구별한다.
  bool _exportCancelled = false;
  late VideoEditState _editState;
  EditorProjectController? _projectController;
  int _playingClipIndex = 0;
  int? _pendingPreviewSeekMs;
  bool _seekingPreview = false;
  /// 원본 영상에 자막이 이미 구워져 있는지.
  ///
  /// 외부 편집기(Banuba)를 다녀오면 결과 영상에 자막이 박혀 돌아왔기 때문에
  /// 이 값이 true가 됐다. AR을 앱 안에서 처리하도록 바꾼 뒤로는 원본이 바뀌지
  /// 않으므로 항상 false다 — 자막은 저장할 때 한 번만 얹힌다.
  final bool _captionsBakedIntoSource = false;

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
      await _replaceEditorSource(sourcePath, restartCaptions: true);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$failure';
      });
    }
  }

  Future<void> _replaceEditorSource(
    String sourcePath, {
    required bool restartCaptions,
  }) async {
    final nextPreview = VideoPlayerController.file(File(sourcePath));
    await nextPreview.initialize();
    if (!mounted) {
      await nextPreview.dispose();
      return;
    }

    final durationMs = nextPreview.value.duration.inMilliseconds;
    final aspectRatio = nextPreview.value.size.aspectRatio > 0
        ? nextPreview.value.size.aspectRatio
        : 16 / 9;
    final sourceWidth = nextPreview.value.size.width.round();
    final sourceHeight = nextPreview.value.size.height.round();
    final nextProjectController = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: sourcePath,
        sourceDurationMs: durationMs,
        sourceSize: EditorSourceSize(width: sourceWidth, height: sourceHeight),
      ),
    );

    final previousPreview = _preview;
    final previousProjectController = _projectController;
    previousPreview?.removeListener(_onPreviewChanged);
    nextPreview.addListener(_onPreviewChanged);
    setState(() {
      _sourcePath = sourcePath;
      _preview = nextPreview;
      _thumbnails = const [];
      _projectController = nextProjectController;
      _playingClipIndex = 0;
      _pendingPreviewSeekMs = null;
      _seekingPreview = false;
      _progress = 1;
      _loading = false;
      _editState = VideoEditState(
        durationMs: durationMs,
        originalAspectRatio: aspectRatio,
      );
      _status = null;
    });

    previousProjectController?.dispose();
    await previousPreview?.dispose();
    if (restartCaptions) {
      // 영상이 기기에 내려온 직후 한 번. 캐시가 있으면 즉시 끝난다.
      _autoCaptions.start(widget.video.id, sourcePath);
    }
    // 썸네일은 편집에 필수 데이터가 아니다. 편집 화면을 먼저 열고 준비되는
    // 순서대로 타임라인에 채워 긴 네이티브 추출 작업이 진입을 막지 않게 한다.
    unawaited(_loadThumbnails());
  }

  Future<void> _loadThumbnails() async {
    final sourcePath = _sourcePath;
    if (sourcePath == null) return;
    try {
      final generated = await _exporter.generateThumbnails(
        inputPath: sourcePath,
        count: 8,
      );
      if (!mounted || _sourcePath != sourcePath) return;
      setState(() => _thumbnails = generated);
    } catch (_) {
      if (mounted && _sourcePath == sourcePath) {
        setState(() => _thumbnails = const <String>[]);
      }
    }
  }

  Future<String> _downloadSource() async {
    // 같은 영상을 다시 편집하거나, 상세 화면이 미리 받아 뒀거나, 갤러리에
    // 저장한 적이 있으면 네트워크를 아예 타지 않는다.
    final cached = await VideoSourceCache.cachedPath(
      widget.video.id,
      cacheDirectoryProvider: widget.cacheDirectoryProvider,
    );
    if (cached != null) {
      if (mounted) {
        setState(() {
          _progress = 0.86;
          _status = '저장된 영상을 바로 불러오고 있어요';
        });
      }
      return cached;
    }

    // 상세 화면에서 미리 받기가 이미 돌고 있으면 그 다운로드에 올라탄다.
    // 같은 파일을 두 번 받지 않고, 진행률도 이어서 보인다.
    return VideoSourceCache.ensure(
      api: widget.controller.api,
      videoId: widget.video.id,
      cacheDirectoryProvider: widget.cacheDirectoryProvider,
      onProgress: (received, total) {
        if (!mounted || total <= 0) return;
        final downloadProgress = (received / total).clamp(0.0, 1.0).toDouble();
        setState(() {
          _progress = 0.12 + downloadProgress * 0.72;
          _status = '추억 영상을 휴대폰으로 가져오고 있어요';
        });
      },
    );
  }

  void _onPreviewChanged() {
    final preview = _preview;
    final projectController = _projectController;
    if (!mounted || preview == null || projectController == null) return;
    if (_seekingPreview) return;
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
        _pendingPreviewSeekMs = clip.sourceStartMs + offsetMs;
        break;
      }
      timelineStartMs = timelineEndMs;
    }
    if (_pendingPreviewSeekMs == null || _seekingPreview) return;
    _seekingPreview = true;
    try {
      while (_pendingPreviewSeekMs != null) {
        final targetMs = _pendingPreviewSeekMs!;
        _pendingPreviewSeekMs = null;
        await preview.seekTo(Duration(milliseconds: targetMs));
      }
    } finally {
      _seekingPreview = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _showCaptionEditor() async {
    final projectController = _projectController;
    if (projectController == null) return;
    final existing = projectController.project.selectedTextLayer;
    _captionField.text = existing?.text ?? '';
    var pendingColor = existing?.color ?? _captionColor;
    var pendingBold = existing?.bold ?? true;
    // 기준 캔버스 1280 기준 크기다. 64면 화면 너비의 5% 정도로, 배경 없이도
    // 한눈에 읽힌다.
    var pendingFontSize = existing?.fontSize ?? 64.0;
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
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '굵게',
                      style: TextStyle(
                        color: AppColors.cream,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Switch(
                    key: const Key('editor-text-bold'),
                    value: pendingBold,
                    onChanged: (value) =>
                        setSheetState(() => pendingBold = value),
                  ),
                ],
              ),
              Row(
                children: [
                  const Text(
                    '크기',
                    style: TextStyle(
                      color: AppColors.cream,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      key: const Key('editor-text-size'),
                      min: 24,
                      max: 144,
                      divisions: 24,
                      label: pendingFontSize.round().toString(),
                      value: pendingFontSize.clamp(24, 144),
                      onChanged: (value) =>
                          setSheetState(() => pendingFontSize = value),
                    ),
                  ),
                  SizedBox(
                    width: 38,
                    child: Text(
                      pendingFontSize.round().toString(),
                      textAlign: TextAlign.end,
                      style: const TextStyle(color: AppColors.cream),
                    ),
                  ),
                ],
              ),
              const Text(
                '배경 없는 글자로 얹혀요. 적용한 뒤 영상 위 글자 상자를 끌어 옮기고, '
                '오른쪽 아래 모서리를 끌어 크기를 바꿀 수 있어요.',
                style: TextStyle(
                  color: _editorMuted,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 18),
              _SheetApplyButton(
                label: '텍스트 적용',
                onPressed: () => Navigator.pop(sheetContext, true),
              ),
            ],
          ),
        ),
      ),
    );
    if (applied == true && mounted) {
      final text = _captionField.text.trim();
      if (text.isEmpty) return;
      final updated = projectController.updateSelectedTextLayer(
        text: text,
        color: pendingColor,
        fontSize: pendingFontSize,
        bold: pendingBold,
      );
      if (!updated) {
        projectController.addTextLayer(
          text: text,
          startMs: 0,
          endMs: projectController.project.durationMs,
          color: pendingColor,
          fontSize: pendingFontSize,
          bold: pendingBold,
        );
      }
      setState(() {
        _captionText = '';
        _captionColor = pendingColor;
        _editState.markExternalEditApplied();
        _appliedTools.add('caption');
      });
    }
  }

  EditorProject _projectWithManualCaption(EditorProject project) {
    final text = _captionText.trim();
    if (text.isEmpty) return project;
    return project.copyWith(
      textLayers: [
        ...project.textLayers,
        EditorTextLayer(
          id: 'manual-caption',
          text: text,
          position: NormalizedPoint(0.5, 0.82),
          startMs: 0,
          endMs: project.durationMs,
          color: _captionColor,
        ),
      ],
    );
  }

  List<Map<String, Object>> _sourceCaptionsForExport() {
    if (_captionsBakedIntoSource || !_autoCaptions.hasUserEdits) {
      return const [];
    }
    return _autoCaptions.forExport(startMs: 0, endMs: _editState.durationMs);
  }

  /// AR 효과를 앱 안에서 바로 입힌다.
  ///
  /// 예전에는 이 버튼이 Banuba 편집 화면(별도 Activity)을 띄웠다. 앱을 벗어나
  /// 다른 UI로 넘어갔고, 라이선스나 Activity 문제로 아무 일도 일어나지 않는
  /// 경우가 많았다. 이제 효과는 미리보기 위에 즉시 올라가고 저장할 때 함께
  /// 구워진다 — 화면을 벗어나지 않는다.
  void _applyArEffect(EditorArEffect effect) {
    final projectController = _projectController;
    if (_saving || projectController == null) return;
    projectController.applyArEffect(effect);
    setState(() {
      _appliedTools.add('ar');
      _editState.markExternalEditApplied();
    });
    showAppSnack(context, '${effect.label} 효과를 켰어요. ${effect.hint}');
  }

  void _clearArEffect() {
    final projectController = _projectController;
    if (_saving || projectController == null) return;
    projectController.clearArEffect();
    setState(() {
      _appliedTools.remove('ar');
      _editState.markExternalEditApplied();
    });
  }

  /// AI 자막 시트. 자막을 만들고 고치는 일은 전부 [CaptionAutoSection]이
  /// 그대로 한다 — 여기서는 열어 주기만 한다.
  Future<void> _showAiCaptionSheet() async {
    if (_saving) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFFFDFC),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          MediaQuery.viewInsetsOf(sheetContext).bottom + 18,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'AI 자막',
                  style: TextStyle(
                    color: AppColors.ink,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: '닫기',
                  onPressed: () => Navigator.pop(sheetContext),
                  color: AppColors.muted,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
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
            const SizedBox(height: 14),
            const Text(
              '만들어진 자막은 저장할 때 영상에 함께 구워져요. 줄을 눌러 고칠 수 있어요.',
              style: TextStyle(
                color: AppColors.muted,
                fontSize: 12,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _saveEdit() async {
    final preview = _preview;
    final projectController = _projectController;
    if (_saving ||
        preview == null ||
        _sourcePath == null ||
        projectController == null) {
      return;
    }

    // 렌더링 중 재생이 계속 돌면 디코더를 나눠 쓰다 내보내기가 깨진다.
    if (preview.value.isPlaying) {
      await preview.pause();
      projectController.setPlaying(false);
    }

    setState(() {
      _saving = true;
      _error = null;
      _exportProgress = null;
      _exportCancelled = false;
      _status = '편집 내용을 영상으로 만들고 있어요';
    });
    projectController.setExportState(
      const EditorExportState(phase: EditorExportPhase.preparing, progress: 0),
    );

    // 권한 왕복을 렌더링과 겹쳐 둔다. 저장이 끝난 뒤에 물으면 그 시간이
    // 고스란히 사용자를 기다리게 하는데, 여기서 시작하면 렌더링이 끝날 즈음엔
    // 이미 답이 와 있다.
    final galleryAccess = _requestGalleryAccess();

    try {
      final exportProject = _projectWithManualCaption(
        projectController.project,
      );
      final exportCaptions = _captionsForProject(
        exportProject,
        _sourceCaptionsForExport(),
      );
      final requiresRendering = exportProject.requiresRendering(
        hasCaptions: exportCaptions.isNotEmpty,
      );
      final String outputPath;
      if (requiresRendering) {
        projectController.setExportState(
          const EditorExportState(
            phase: EditorExportPhase.rendering,
            progress: 0,
          ),
        );
        _startExportProgressPolling();
        try {
          outputPath = await _editorPlatform.exportProject(
            project: exportProject,
            outputPath: _buildOutputPath(),
            captions: exportCaptions,
          );
        } finally {
          _stopExportProgressPolling();
        }
      } else {
        outputPath = exportProject.sourceVideoPath;
      }
      final file = File(outputPath);
      if (!await file.exists() || (await file.length()) == 0) {
        throw const VideoExportException('만들어진 영상 파일이 비어 있어요.');
      }
      if (mounted) {
        setState(() {
          _exportProgress = null;
          _status = requiresRendering
              ? '휴대폰 갤러리에 저장하고 있어요'
              : '원본 화질 그대로 갤러리에 저장하고 있어요';
        });
      }
      await _saveToPhoneGallery(outputPath, galleryAccess);
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
        _exportProgress = null;
        _status = '갤러리에 저장되었습니다';
      });
      showAppSnack(context, '휴대폰 갤러리에 저장되었습니다');
      Navigator.pop(context, SavedVideoEdit(videoPath: outputPath));
    } catch (failure) {
      _stopExportProgressPolling();
      if (!mounted) return;
      final cancelled = _exportCancelled;
      projectController.setExportState(
        EditorExportState(
          phase: cancelled
              ? EditorExportPhase.cancelled
              : EditorExportPhase.failed,
          message: '$failure',
        ),
      );
      setState(() {
        _saving = false;
        _exportProgress = null;
        _exportCancelled = false;
        // 사용자가 그만둔 것은 오류가 아니다. 편집 내용은 그대로 남는다.
        _error = cancelled ? null : '$failure';
        _status = null;
      });
      showAppSnack(
        context,
        cancelled ? '저장을 그만뒀어요. 편집 내용은 그대로 있어요.' : '저장하지 못했어요. $failure',
        error: !cancelled,
      );
    }
  }

  /// 갤러리 권한을 물어 둔다. 답을 기다리는 쪽은 렌더링이 끝난 뒤다.
  Future<void> _requestGalleryAccess() async {
    try {
      if (!await Gal.hasAccess()) await Gal.requestAccess();
    } catch (_) {
      // 권한 확인 자체가 실패하는 기기도 있다. 저장은 그대로 시도한다.
    }
  }

  /// 편집 결과를 휴대폰 갤러리에 넣는다.
  ///
  /// **왜 권한으로 막지 않는가**: 예전에는 `Gal.hasAccess()`가 false면 곧바로
  /// 예외를 던져 저장이 시작조차 못 했다. 안드로이드 10부터 MediaStore에 내
  /// 앱이 만든 영상을 넣는 데는 권한이 필요 없다 — 거절된 권한 하나 때문에
  /// 저장 전체가 막히는 게 실제 증상이었다. 그래서 권한은 요청만 해 보고,
  /// 저장은 MediaStore로 직접 한다. 그쪽이 실패하면 gal로 한 번 더 시도한다.
  Future<void> _saveToPhoneGallery(
    String videoPath,
    Future<void> galleryAccess,
  ) async {
    await galleryAccess;
    try {
      await _editorPlatform.saveToGallery(
        inputPath: videoPath,
        title: _safeTitle(widget.video.title),
      );
    } on EditorPlatformException catch (failure) {
      try {
        await Gal.putVideo(videoPath, album: '빵긋');
      } on GalException catch (galFailure) {
        throw EditorPlatformException('$failure (${galFailure.type.message})');
      }
    }
  }

  /// 렌더링을 중간에 그만둔다. 긴 영상에서 화면에 갇히지 않게 한다.
  Future<void> _cancelExport() async {
    if (!_saving || _exportCancelled) return;
    setState(() {
      _exportCancelled = true;
      _status = '만들던 영상을 정리하고 있어요';
    });
    try {
      await _editorPlatform.cancelExport();
    } catch (_) {
      // 이미 끝났거나 취소를 못 받아도 아래 catch에서 상태를 되돌린다.
    }
  }

  void _startExportProgressPolling() {
    _exportProgressTimer?.cancel();
    _exportProgressTimer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) async {
        try {
          final progress = await _editorPlatform.getExportProgress();
          if (!mounted || _exportProgressTimer == null) return;
          setState(() => _exportProgress = progress);
        } catch (_) {
          // 진행률은 부가 정보다. 못 읽어도 내보내기는 계속 돈다.
        }
      },
    );
  }

  void _stopExportProgressPolling() {
    _exportProgressTimer?.cancel();
    _exportProgressTimer = null;
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
    _stopExportProgressPolling();
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
      final percent = (_progress * 100).round().clamp(1, 99);
      final contentWidth = math.max(0.0, constraints.maxWidth - 48);
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        key: const Key('editor-preparing-close'),
                        tooltip: '닫기',
                        onPressed: () => Navigator.maybePop(context),
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.72),
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
                  Expanded(
                    child: FittedBox(
                      key: const Key('editor-preparing-fitted-content'),
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.center,
                      child: SizedBox(
                        width: contentWidth,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              '추억 영상을\n불러오고 있어요',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Color(0xFF4D3425),
                                fontSize: 35,
                                height: 1.2,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1.2,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              '곧 편집을 시작할 수 있어요',
                              style: TextStyle(
                                color: Color(0xFF8D7968),
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 10),
                            const _PreparingMascot(height: 235),
                            const SizedBox(height: 10),
                            KeyedSubtree(
                              key: const Key('editor-loading-percentage'),
                              child: Text.rich(
                                TextSpan(
                                  children: [
                                    const TextSpan(text: '준비 중 '),
                                    TextSpan(
                                      text: '$percent%',
                                      style: const TextStyle(
                                        color: AppColors.coral,
                                      ),
                                    ),
                                  ],
                                ),
                                key: const Key('editor-preparing-percent'),
                                style: const TextStyle(
                                  color: Color(0xFF4D3425),
                                  fontSize: 24,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            _PreparingProgressBar(value: _progress),
                            const SizedBox(height: 8),
                            Text(
                              _status ?? '편집기를 준비하는 중이에요',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Color(0xFF8D7968),
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 14),
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
                            const SizedBox(height: 10),
                            SizedBox(
                              key: const Key(
                                'editor-preparing-feature-illustration',
                              ),
                              width: contentWidth,
                              height: 72,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: Image.asset(
                                  'assets/images/editor_loading_features.png',
                                  fit: BoxFit.cover,
                                  filterQuality: FilterQuality.high,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
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
        look: project.look,
        captionText: _captionText,
        captionColor: _captionColor,
        onLayerChanged: () => setState(_editState.markExternalEditApplied),
        autoCaptionText: _captionsBakedIntoSource
            ? null
            : autoCaptionAt(
                _autoCaptions,
                preview.value.position.inMilliseconds,
              ),
      ),
      thumbnails: _thumbnails,
      playing: preview.value.isPlaying,
      currentTime: _time(Duration(milliseconds: project.playheadMs)),
      totalTime: _time(Duration(milliseconds: project.durationMs)),
      saving: _saving,
      exportProgress: _exportProgress,
      exportStatus: _status,
      onExportCancel: _cancelExport,
      aiCaptionSummary: _autoCaptions.message(
        estimateSeconds: _editState.durationMs > 0
            ? (_editState.durationMs / 1000 * 0.9).round()
            : null,
      ),
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
      onArEffectSelected: _applyArEffect,
      onArEffectCleared: _clearArEffect,
      onAiCaption: _showAiCaptionSheet,
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
      _appliedTools.add('sticker');
      _editState.markExternalEditApplied();
    });
    showAppSnack(context, '스티커를 놓았어요. 끌어 옮기고 모서리로 크기를 바꿔 보세요.');
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
    required this.look,
    required this.captionText,
    required this.captionColor,
    required this.onLayerChanged,
    this.autoCaptionText,
  });

  final VideoPlayerController controller;
  final EditorProjectController projectController;
  final EditorCanvas canvas;

  /// 영상 전체 색감. AR 효과가 정해 준다.
  final EditorLook look;

  final String captionText;
  final Color captionColor;

  /// 글자·스티커를 옮기거나 크기를 바꾸거나 지웠을 때. 화면이 "저장 안 된
  /// 변경"으로 표시한다.
  final VoidCallback onLayerChanged;

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
                          colorFilter: _lookFilter(look),
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
                    for (final layer
                        in projectController.project.textLayers.where(
                          (layer) => layer.isVisibleAt(
                            projectController.project.playheadMs,
                          ),
                        ))
                      _EditableLayerOverlay(
                        key: ValueKey(layer.id),
                        controller: projectController,
                        layer: layer,
                        onChanged: onLayerChanged,
                        // 배경 없는 글자. 크기는 Transform이 아니라 글자 크기
                        // 자체에 곱한다 — 그래야 상자(테두리·손잡이)가 글자와
                        // 같이 커지고 줄어든다.
                        childBuilder: (context, previewWidth, scale) {
                          final text = Text(
                            layer.text,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: layer.color,
                              height: 1.2,
                              fontSize:
                                  (layer.fontSize *
                                          previewWidth /
                                          _referenceCanvasWidth *
                                          scale)
                                      .clamp(9.0, 220.0),
                              fontWeight: layer.bold
                                  ? FontWeight.w900
                                  : FontWeight.w400,
                              shadows: const [
                                Shadow(
                                  color: Color(0xB3000000),
                                  blurRadius: 6,
                                  offset: Offset(0, 1),
                                ),
                              ],
                            ),
                          );
                          return ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: previewWidth * 0.86,
                            ),
                            child: layer.backgroundColor.a == 0
                                ? text
                                : DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: layer.backgroundColor,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: text,
                                  ),
                          );
                        },
                      ),
                    for (final layer
                        in projectController.project.stickerLayers.where(
                          (layer) => layer.isVisibleAt(
                            projectController.project.playheadMs,
                          ),
                        ))
                      _EditableLayerOverlay(
                        key: ValueKey(layer.id),
                        controller: projectController,
                        layer: layer,
                        onChanged: onLayerChanged,
                        childBuilder: (_, previewWidth, scale) => Text(
                          layer.value,
                          style: TextStyle(
                            // 내보내기(EditorLayerOverlay.kt)가 쓰는 기준
                            // 크기와 같은 비율로 그린다.
                            fontSize:
                                (previewWidth *
                                        _referenceStickerFontSize /
                                        _referenceCanvasWidth *
                                        scale)
                                    .clamp(14.0, 260.0),
                            shadows: const [
                              Shadow(color: Colors.black38, blurRadius: 6),
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

  /// 미리보기 색감. 내보내기 쪽(EditorProjectExporter.kt)이 같은 이름으로
  /// media3 필터를 붙인다.
  ColorFilter _lookFilter(EditorLook look) => switch (look) {
    EditorLook.mono => const ColorFilter.matrix([
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
    EditorLook.warm => const ColorFilter.matrix([
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
    EditorLook.vivid => const ColorFilter.matrix([
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
    // 살짝 밝고 채도를 낮춘 보정. 얼굴에 쓰는 부드러운 톤이다.
    EditorLook.soft => const ColorFilter.matrix([
      0.9056,
      0.0858,
      0.0086,
      0,
      12,
      0.0256,
      0.9658,
      0.0086,
      0,
      12,
      0.0256,
      0.0858,
      0.8886,
      0,
      14,
      0,
      0,
      0,
      1,
      0,
    ]),
    EditorLook.none => const ColorFilter.mode(
      Colors.transparent,
      BlendMode.dst,
    ),
  };
}

/// 글자·스티커 크기의 기준 캔버스 너비. 내보내기 쪽도 같은 값을 쓴다 —
/// 미리보기에서 본 크기가 저장된 영상에서도 같아야 한다.
const _referenceCanvasWidth = 1280.0;

/// 스티커 기본 글자 크기(EditorLayerOverlay.kt와 같은 값).
const _referenceStickerFontSize = 110.0;

typedef _LayerChildBuilder =
    Widget Function(BuildContext context, double previewWidth, double scale);

/// 영상 위에 얹힌 글자·스티커 하나를 그리고 조작한다.
///
/// **왜 [CustomSingleChildLayout]인가**: 예전에는 [Align]에 정규화 좌표를
/// 그대로 넣었다. Align의 alignment는 "부모 크기 - 자식 크기" 안에서의 비율
/// 이어서, 손가락을 1px 옮기면 상자는 1px보다 더 움직였다 — 끌면 손끝에서
/// 달아나 위치를 맞출 수 없었다. 이 델리게이트는 자식의 **중심**을 좌표에
/// 정확히 놓으므로 드래그가 손가락을 그대로 따라온다.
///
/// 손잡이는 상자 바깥이 아니라 [_handleInset]만큼 넓힌 여백 안쪽에 놓는다.
/// RenderBox는 자기 크기 밖의 좌표를 hit test에서 걸러내므로, 바깥에 두면
/// 눌러도 반응하지 않는다.
class _EditableLayerOverlay extends StatefulWidget {
  const _EditableLayerOverlay({
    super.key,
    required this.controller,
    required this.layer,
    required this.childBuilder,
    required this.onChanged,
  });

  final EditorProjectController controller;
  final EditorTimedLayer layer;
  final _LayerChildBuilder childBuilder;
  final VoidCallback onChanged;

  @override
  State<_EditableLayerOverlay> createState() => _EditableLayerOverlayState();
}

class _EditableLayerOverlayState extends State<_EditableLayerOverlay> {
  static const _handleInset = 15.0;
  static const _handleSize = 30.0;

  late NormalizedPoint _position;
  double _startScale = 1;
  double _startRotation = 0;
  double _resizeStartScale = 1;
  double _resizeTravel = 0;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth <= 0 ? 1.0 : constraints.maxWidth;
        final height = constraints.maxHeight <= 0 ? 1.0 : constraints.maxHeight;
        final selected =
            widget.controller.project.selectedLayerId == widget.layer.id;
        return CustomSingleChildLayout(
          delegate: _LayerCenterLayout(widget.layer.position),
          child: Transform.rotate(
            angle: widget.layer.rotationDegrees * math.pi / 180,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(_handleInset),
                  child: GestureDetector(
                    key: Key('editor-layer-${widget.layer.id}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.controller.selectLayer(widget.layer.id),
                    onScaleStart: (_) {
                      _position = widget.layer.position;
                      _startScale = widget.layer.scale;
                      _startRotation = widget.layer.rotationDegrees;
                      widget.controller.beginLayerGesture(widget.layer.id);
                    },
                    onScaleUpdate: (details) {
                      _position = _position.translate(
                        details.focalPointDelta.dx / width,
                        details.focalPointDelta.dy / height,
                      );
                      widget.controller.updateSelectedLayerTransform(
                        position: _position,
                        scale: _startScale * details.scale,
                        rotationDegrees:
                            _startRotation + details.rotation * 180 / math.pi,
                      );
                    },
                    onScaleEnd: (_) {
                      widget.controller.endLayerGesture();
                      widget.onChanged();
                    },
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: selected
                            ? Border.all(color: AppColors.coral, width: 1.6)
                            : null,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 3,
                        ),
                        child: widget.childBuilder(
                          context,
                          width,
                          widget.layer.scale,
                        ),
                      ),
                    ),
                  ),
                ),
                if (selected)
                  Positioned(
                    left: 0,
                    top: 0,
                    child: _LayerHandle(
                      dimension: _handleSize,
                      icon: Icons.close_rounded,
                      background: const Color(0xE6231A14),
                      onTap: _deleteLayer,
                    ),
                  ),
                if (selected)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: _LayerHandle(
                      key: Key('editor-layer-resize-${widget.layer.id}'),
                      dimension: _handleSize,
                      icon: Icons.open_in_full_rounded,
                      background: AppColors.coral,
                      onPanStart: () {
                        _resizeStartScale = widget.layer.scale;
                        _resizeTravel = 0;
                        widget.controller.beginLayerGesture(widget.layer.id);
                      },
                      onPanUpdate: (delta) {
                        // 오른쪽 아래로 끌면 커진다. 두 축을 평균 내면
                        // 대각선으로 끄는 느낌이 자연스럽다.
                        _resizeTravel += (delta.dx + delta.dy) / 2;
                        widget.controller.updateSelectedLayerScale(
                          (_resizeStartScale * (1 + _resizeTravel / 90)).clamp(
                            0.2,
                            4.0,
                          ),
                        );
                      },
                      onPanEnd: () {
                        widget.controller.endLayerGesture();
                        widget.onChanged();
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );

  void _deleteLayer() {
    widget.controller.selectLayer(widget.layer.id);
    if (widget.controller.deleteSelectedLayer()) widget.onChanged();
  }
}

/// 자식의 중심을 정규화 좌표에 정확히 놓는다.
class _LayerCenterLayout extends SingleChildLayoutDelegate {
  const _LayerCenterLayout(this.position);

  final NormalizedPoint position;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) => Offset(
    size.width * position.x - childSize.width / 2,
    size.height * position.y - childSize.height / 2,
  );

  @override
  bool shouldRelayout(_LayerCenterLayout oldDelegate) =>
      oldDelegate.position != position;
}

class _LayerHandle extends StatelessWidget {
  const _LayerHandle({
    super.key,
    required this.dimension,
    required this.icon,
    required this.background,
    this.onTap,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
  });

  final double dimension;
  final IconData icon;
  final Color background;
  final VoidCallback? onTap;
  final VoidCallback? onPanStart;
  final ValueChanged<Offset>? onPanUpdate;
  final VoidCallback? onPanEnd;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    onPanStart: onPanStart == null ? null : (_) => onPanStart!(),
    onPanUpdate: onPanUpdate == null
        ? null
        : (details) => onPanUpdate!(details.delta),
    onPanEnd: onPanEnd == null ? null : (_) => onPanEnd!(),
    child: Container(
      width: dimension,
      height: dimension,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.6),
      ),
      child: Icon(icon, color: Colors.white, size: dimension * 0.5),
    ),
  );
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
      // 영상 빈 곳을 누르면 글자·스티커 조절 손잡이를 감춘다.
      onTap: widget.controller.deselectLayer,
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
