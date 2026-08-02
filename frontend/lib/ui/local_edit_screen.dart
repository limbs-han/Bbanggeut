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
import '../editor/editor_project.dart';
import '../editor/editor_project_controller.dart';
import '../editor/edit_recommendation_client.dart';
import '../editor/editor_text_style_bar.dart';
import '../editor/editor_platform.dart';
import '../editor/editor_workspace.dart';
import 'widgets.dart';

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
  final _recommendations = EditRecommendationClient();

  /// 정해 둔 구간만 돌려 보는 중인가. 이때는 구간 끝에서 다음 클립으로
  /// 넘어가지 않고 선다.
  bool _rangePreview = false;

  /// 지금 영상 위에서 글을 쓰고 있는 레이어. null이면 편집 중이 아니다.
  String? _editingTextLayerId;
  final _textInput = TextEditingController();
  final _textFocus = FocusNode();
  EditorTextDraft _textDraft = const EditorTextDraft();

  VideoPlayerController? _preview;
  String? _sourcePath;
  List<String> _thumbnails = [];
  double _progress = 0;
  bool _loading = true;
  bool _saving = false;
  final Set<String> _appliedTools = <String>{};
  Color _captionColor = AppColors.cream;
  double _audioVolume = 1;
  String? _status;
  String? _error;

  /// 렌더링 진행률(0~1). 네이티브에서 주기적으로 읽어 온다. null이면 아직 모른다.
  double? _exportProgress;
  Timer? _exportProgressTimer;

  /// 사용자가 렌더링을 그만뒀는지. 실패 안내와 취소 안내를 구별한다.
  bool _exportCancelled = false;

  /// 저장하는 동안 미리보기 재생기를 놓아 뒀는가.
  ///
  /// 재생기는 멈춰 있어도 하드웨어 디코더 한 자리를 계속 붙잡는다. 기기에
  /// 있는 디코더 수는 넉넉하지 않아서, 그 자리 때문에 내보내기가 소프트웨어
  /// 디코더로 밀려나면 몇 배 느려진다. 저장 직전에 놓아주고, 실패해서 화면에
  /// 남게 되면 그때 다시 만든다.
  bool _previewReleased = false;
  late VideoEditState _editState;
  EditorProjectController? _projectController;
  int _playingClipIndex = 0;
  int? _pendingPreviewSeekMs;
  bool _seekingPreview = false;

  bool get _editorReady =>
      _sourcePath != null && _preview?.value.isInitialized == true;

  @override
  void initState() {
    super.initState();
    _editState = VideoEditState(durationMs: 0, originalAspectRatio: 16 / 9);
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
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
      await _replaceEditorSource(sourcePath);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$failure';
      });
    }
  }

  Future<void> _replaceEditorSource(String sourcePath) async {
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

    String? recommendationStatus;
    try {
      final recommendation = await _recommendations.recommend(
        videoId: widget.video.id,
        capturedAt: widget.video.capturedStartAt,
      );
      nextProjectController.applyRecommendation(recommendation);
      final seconds = nextProjectController.project.durationMs / 1000;
      recommendationStatus =
          '자동 편집 적용 · ${seconds.toStringAsFixed(1)}초 · 줌 ${nextProjectController.project.zoomSegments.length}개';
    } catch (_) {
      recommendationStatus = '자동 추천 서버에 연결하지 못해 원본 구간으로 열었어요';
    }

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
      _status = recommendationStatus;
    });

    previousProjectController?.dispose();
    await previousPreview?.dispose();
    // 자동 자막은 제품 범위에서 제거했다. 텍스트는 사용자가 직접 추가한다.
    // 썸네일은 편집에 필수 데이터가 아니다. 편집 화면을 먼저 열고 준비되는
    // 순서대로 타임라인에 채워 긴 네이티브 추출 작업이 진입을 막지 않게 한다.
    unawaited(_loadThumbnails());
  }

  /// 타임라인 프레임을 두 번에 나눠 뽑는다.
  ///
  /// 한 번에 열두 장을 뽑으면 그동안 띠가 비어 있다. 먼저 네 장으로 띠를
  /// 채워 "지금 어디쯤인지"를 바로 보여 주고, 이어서 촘촘한 것으로 갈아
  /// 끼운다. 총 작업량은 조금 늘지만 눈에 보이기까지의 시간이 크게 줄어든다.
  Future<void> _loadThumbnails() async {
    final sourcePath = _sourcePath;
    if (sourcePath == null) return;
    if (!await _extractThumbnails(sourcePath, 4)) return;
    await _extractThumbnails(sourcePath, 12);
  }

  /// 성공 여부. 화면이 사라졌거나 원본이 바뀌면 false를 준다.
  Future<bool> _extractThumbnails(String sourcePath, int count) async {
    try {
      final generated = await _exporter.generateThumbnails(
        inputPath: sourcePath,
        count: count,
      );
      if (!mounted || _sourcePath != sourcePath) return false;
      // 늦게 도착한 성긴 결과가 촘촘한 것을 덮어쓰지 않게 한다.
      if (generated.length < _thumbnails.length) return true;
      setState(() => _thumbnails = generated);
      return true;
    } catch (_) {
      if (mounted && _sourcePath == sourcePath && _thumbnails.isEmpty) {
        setState(() => _thumbnails = const <String>[]);
      }
      return false;
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
    // 정해 둔 구간 앞쪽은 건너뛴다. 구간을 정한 뒤 재생하면 잘라낸 앞부분이
    // 그대로 나오던 문제 — 정한 구간만 재생돼야 "구간이 먹혔다"고 느낀다.
    if (preview.value.isPlaying &&
        sourcePositionMs < clip.sourceStartMs - 120) {
      unawaited(preview.seekTo(Duration(milliseconds: clip.sourceStartMs)));
      return;
    }
    if (preview.value.isPlaying && sourcePositionMs >= clip.sourceEndMs) {
      if (_rangePreview) {
        // 구간 재생은 그 구간 끝에서 선다. 다음 클립으로 넘어가면 "방금 정한
        // 구간이 어디서 끝나는지"를 확인할 수 없다.
        _rangePreview = false;
        unawaited(preview.pause());
        projectController.setPlaying(false);
        projectController.setPlayhead(
          timelineStartMs + clip.durationMs,
          notify: false,
        );
      } else if (_playingClipIndex + 1 < project.clips.length) {
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
    // 위쪽 재생 단추는 편집 결과 전체를 튼다. 구간 재생 중이었다면 그 모드를 끈다.
    _rangePreview = false;
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
      // **왜 `<`인가**: 이음매(앞 클립의 끝 = 뒤 클립의 시작)를 `<=`로 따지면
      // 그 시각이 앞 클립으로 잡힌다. 뒤 클립을 골라 두고 그 시작으로 옮기면
      // 앞 클립이 대신 골라지고, 재생은 앞 클립 맨 끝에서 곧바로 멈췄다.
      if (milliseconds < timelineEndMs || index == project.clips.length - 1) {
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

  /// 원본 시각으로 미리보기만 옮긴다.
  ///
  /// 구간 손잡이를 끄는 동안 쓴다. 손가락은 초당 수십 번 움직이는데 seek은
  /// 그보다 느리다 — 마지막 목표만 남기고 앞의 것들은 버려서 밀리지 않게 한다.
  /// 화면 상태(setState)는 건드리지 않는다. 막대가 제 손으로 그리고 있다.
  Future<void> _seekPreviewToSource(int sourceMs) async {
    final preview = _preview;
    if (preview == null) return;
    _pendingPreviewSeekMs = math.max(0, sourceMs);
    if (_seekingPreview) return;
    _seekingPreview = true;
    try {
      while (_pendingPreviewSeekMs != null) {
        final targetMs = _pendingPreviewSeekMs!;
        _pendingPreviewSeekMs = null;
        await preview.seekTo(Duration(milliseconds: targetMs));
      }
    } finally {
      _seekingPreview = false;
    }
  }

  /// 글자 넣기·고치기. 영상 위 제자리에서 바로 쓴다.
  ///
  /// **왜 입력 상자를 없앴나**: 화면 한가운데에 커다란 입력칸을 띄우면 그
  /// 상자가 영상을 가려, 정작 글이 영상 위에서 어떻게 보이는지 알 수 없다.
  /// 이제 글자 레이어를 영상 위에 바로 놓고 그 자리에서 타이핑한다. 다 쓰고
  /// 완료를 누르면 그대로 골라진 채 남아, 끌어 옮기고 모서리로 크기를 바꿀 수
  /// 있다.
  ///
  /// [layerId]를 주면 그 글자를 고치고, 주지 않으면 **새로** 하나 놓는다.
  /// 예전에는 "골라져 있는 글자가 있으면 그걸 고친다"였는데, 그러면 방금 쓴
  /// 글자가 골라진 채로 남아 있어 '텍스트 넣기'를 다시 눌러도 두 번째 글자가
  /// 생기지 않았다 — 넣기 단추가 넣지를 못했다.
  void _startTextEditing({String? layerId}) {
    final projectController = _projectController;
    if (projectController == null || _saving) return;
    if (_editingTextLayerId != null) return;

    // 재생 중이면 세운다. 글을 쓰는 사이 화면이 흘러가면 어느 장면에 얹히는지
    // 알 수 없고, 재생 위치가 끝을 넘어가면 방금 놓은 글자가 사라져 보인다.
    final preview = _preview;
    if (preview != null && preview.value.isPlaying) {
      unawaited(preview.pause());
      projectController.setPlaying(false);
    }

    EditorTextLayer? existing;
    for (final layer in projectController.project.textLayers) {
      if (layer.id == layerId) existing = layer;
    }
    if (existing != null) {
      projectController.selectLayer(existing.id);
      _textDraft = EditorTextDraft.fromLayer(existing);
      _textInput.text = existing.text;
      _editingTextLayerId = existing.id;
      projectController.beginGesture();
    } else {
      _textDraft = EditorTextDraft(color: _captionColor);
      _textInput.clear();
      _editingTextLayerId = projectController.beginTextLayer(
        color: _textDraft.color,
        backgroundColor: _textDraft.backgroundColor,
        fontSize: _textDraft.fontSize,
        bold: _textDraft.bold,
        italic: _textDraft.italic,
        align: _textDraft.align,
      );
    }
    // 먼저 입력칸을 그린 다음에 키보드를 부른다. 붙일 곳이 아직 없는데
    // 포커스부터 주면 키보드만 올라오고 커서가 어디에도 없다.
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editingTextLayerId != null) _textFocus.requestFocus();
    });
  }

  void _onEditingTextChanged(String value) {
    final id = _editingTextLayerId;
    if (id == null) return;
    _projectController?.updateTextLayer(id, text: value);
    _editState.markExternalEditApplied();
  }

  void _onEditingStyleChanged(EditorTextDraft draft) {
    final id = _editingTextLayerId;
    if (id == null) return;
    setState(() => _textDraft = draft);
    _projectController?.updateTextLayer(
      id,
      color: draft.color,
      backgroundColor: draft.backgroundColor,
      fontSize: draft.fontSize,
      bold: draft.bold,
      italic: draft.italic,
      align: draft.align,
    );
    _captionColor = draft.color;
    _editState.markExternalEditApplied();
  }

  /// 다 썼다. 빈 글자면 방금 놓은 레이어를 걷어낸다.
  void _finishTextEditing() {
    final id = _editingTextLayerId;
    if (id == null) return;
    final projectController = _projectController;
    _editingTextLayerId = null;
    _textFocus.unfocus();
    if (_textInput.text.trim().isEmpty) {
      projectController?.removeLayer(id);
    } else {
      _appliedTools.add('caption');
      _editState.markExternalEditApplied();
    }
    // 만들기부터 여기까지가 되돌리기 한 칸이다.
    projectController?.endGesture();
    if (mounted) setState(() {});
  }

  /// 영상 전체 색감. 앱 안에서 바로 입히고 저장할 때 함께 구워진다.
  void _setLook(EditorLook look) {
    final projectController = _projectController;
    if (_saving || projectController == null) return;
    projectController.setLook(look);
    setState(() {
      if (look == EditorLook.none) {
        _appliedTools.remove('look');
      } else {
        _appliedTools.add('look');
      }
      _editState.markExternalEditApplied();
    });
  }

  Future<void> _saveEdit() async {
    _finishTextEditing();
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
    // 미리보기가 쥔 디코더와 화면 갱신을 렌더링에 넘긴다.
    await _releasePreviewForExport();
    projectController.setExportState(
      const EditorExportState(phase: EditorExportPhase.preparing, progress: 0),
    );

    // 권한 왕복을 렌더링과 겹쳐 둔다. 저장이 끝난 뒤에 물으면 그 시간이
    // 고스란히 사용자를 기다리게 하는데, 여기서 시작하면 렌더링이 끝날 즈음엔
    // 이미 답이 와 있다.
    final galleryAccess = _requestGalleryAccess();

    try {
      final exportProject = projectController.project;
      const exportCaptions = <Map<String, Object>>[];
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
      try {
        await _recommendations.saveProject(
          videoId: widget.video.id,
          revision: exportProject.revision + 1,
          recipe: exportProject.toPlatformMap(outputPath: outputPath),
        );
      } catch (_) {
        // 로컬 recipe 저장 실패가 휴대폰 영상 저장까지 막아서는 안 된다.
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
      // 편집을 이어가야 하므로 재생기를 되살린다.
      await _restorePreviewAfterExport();
    }
  }

  /// 렌더링을 시작하기 전에 미리보기 재생기를 통째로 놓아준다.
  Future<void> _releasePreviewForExport() async {
    final preview = _preview;
    if (preview == null) return;
    preview.removeListener(_onPreviewChanged);
    if (mounted) {
      setState(() {
        _preview = null;
        _previewReleased = true;
      });
    }
    await preview.dispose();
  }

  /// 저장이 실패해 편집 화면에 남을 때만 다시 만든다.
  Future<void> _restorePreviewAfterExport() async {
    final sourcePath = _sourcePath;
    if (!_previewReleased || sourcePath == null) return;
    try {
      final next = VideoPlayerController.file(File(sourcePath));
      await next.initialize();
      if (!mounted) {
        await next.dispose();
        return;
      }
      await next.setVolume(_audioVolume);
      next.addListener(_onPreviewChanged);
      setState(() {
        _preview = next;
        _previewReleased = false;
      });
      unawaited(_seekToPosition(_projectController?.project.playheadMs ?? 0));
    } catch (_) {
      if (mounted) setState(() => _previewReleased = false);
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
    _exportProgressTimer = Timer.periodic(const Duration(milliseconds: 400), (
      _,
    ) async {
      try {
        final progress = await _editorPlatform.getExportProgress();
        if (!mounted || _exportProgressTimer == null) return;
        setState(() => _exportProgress = progress);
      } catch (_) {
        // 진행률은 부가 정보다. 못 읽어도 내보내기는 계속 돈다.
      }
    });
  }

  void _stopExportProgressPolling() {
    _exportProgressTimer?.cancel();
    _exportProgressTimer = null;
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
    _textInput.dispose();
    _textFocus.dispose();
    _stopExportProgressPolling();
    final preview = _preview;
    if (preview != null) {
      preview.removeListener(_onPreviewChanged);
      preview.dispose();
    }
    _projectController?.dispose();
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
        // 키보드 자리는 [_editorShell]이 직접 뺀다. 이유는 그쪽 설명 참고.
        resizeToAvoidBottomInset: false,
        body: _previewReleased
            // 재생기를 놓은 동안에는 편집 화면을 그릴 수 없다. 진행 표시만
            // 남기면 화면 갱신 비용도 렌더링에 양보하게 된다.
            ? ColoredBox(
                color: const Color(0xFF231A14),
                child: EditorExportBlocker(
                  progress: _exportProgress,
                  status: _status,
                  onCancel: _cancelExport,
                ),
              )
            : _loading
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

  /// 편집 화면 + (글을 쓰는 중이면) 키보드 바로 위 꾸밈 줄.
  ///
  /// 키보드 자리를 어떻게 빼는지, 왜 Scaffold에 맡기지 않는지는
  /// [EditorKeyboardShell] 설명에 있다.
  Widget _editorShell() {
    final editing = _editingTextLayerId != null;
    return EditorKeyboardShell(
      bottomBar: editing
          ? EditorTextStyleBar(
              draft: _textDraft,
              onChanged: _onEditingStyleChanged,
              onDone: _finishTextEditing,
            )
          : null,
      child: _workspace(textEditing: editing),
    );
  }

  Widget _workspace({bool textEditing = false}) {
    final preview = _preview!;
    final projectController = _projectController!;
    final project = projectController.project;
    return EditorWorkspace(
      controller: projectController,
      preview: _PreviewSurface(
        controller: preview,
        projectController: projectController,
        editingLayerId: _editingTextLayerId,
        textInput: _textInput,
        textFocus: _textFocus,
        onEditingTextChanged: _onEditingTextChanged,
        onEditingDone: _finishTextEditing,
        onEditLayer: (id) => _startTextEditing(layerId: id),
        captionColor: _captionColor,
        onLayerChanged: () => setState(_editState.markExternalEditApplied),
        autoCaptionText: null,
      ),
      thumbnails: _thumbnails,
      playing: preview.value.isPlaying,
      currentTime: _time(Duration(milliseconds: project.playheadMs)),
      totalTime: _time(Duration(milliseconds: project.durationMs)),
      saving: _saving,
      textEditing: textEditing,
      rangePreviewing: _rangePreview,
      exportProgress: _exportProgress,
      exportStatus: _status,
      onExportCancel: _cancelExport,
      aiCaptionSummary: null,
      onBack: () => Navigator.maybePop(context),
      onSave: _saveEdit,
      onPlay: _togglePlayback,
      onSeek: _seekToPosition,
      onUndo: _undoEdit,
      onRedo: _redoEdit,
      onSplit: _splitClip,
      onDelete: _deleteClip,
      onDuplicate: _duplicateClip,
      onTrimChanged: _onTrimChanged,
      onTrimCommitted: _onTrimCommitted,
      onPlayRange: _toggleRangePreview,
      onBlocked: _showBlockedReason,
      onRatioSelected: _selectCanvasRatio,
      onText: _startTextEditing,
      onVolumeChanged: _setAudioVolume,
      onVolumeCommitted: _commitAudioVolume,
      onMutedChanged: _setMuted,
      onStickerSelected: _addSticker,
      onLookSelected: _setLook,
      onAiCaption: () {},
      onZoomAdd: () {
        projectController.addZoomAtPlayhead();
        _editState.markExternalEditApplied();
        setState(() {});
      },
      onZoomChanged: (zoom) {
        projectController.updateZoom(zoom);
        _editState.markExternalEditApplied();
        setState(() {});
      },
      onZoomRemove: (zoom) {
        projectController.removeZoom(zoom);
        _editState.markExternalEditApplied();
        setState(() {});
      },
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

  /// 분할·복제·삭제는 눈에 보이는 변화가 작다. 띠에는 여전히 고른 클립 하나가
  /// 그려지므로, 한 줄 안내를 띄우지 않으면 "눌러도 아무 일이 없다"로 읽힌다.
  void _splitClip() {
    final projectController = _projectController;
    if (projectController == null) return;
    _stopRangePreview();
    if (!projectController.splitAt(projectController.project.playheadMs)) {
      showAppSnack(context, '클립 양쪽에 최소 0.1초가 남는 위치에서 나눌 수 있어요.');
      return;
    }
    _editState.markExternalEditApplied();
    showAppSnack(
      context,
      '클립을 둘로 나눴어요 (${projectController.project.clips.length}개)',
    );
    if (mounted) setState(() {});
  }

  void _deleteClip() {
    final projectController = _projectController;
    if (projectController == null) return;
    _stopRangePreview();
    if (!projectController.deleteSelectedClip()) {
      showAppSnack(context, '지울 것이 없어요. 구간을 좁히거나 클립을 나눈 뒤에 지울 수 있어요.');
      return;
    }
    _playingClipIndex = _playingClipIndex.clamp(
      0,
      projectController.project.clips.length - 1,
    );
    _editState.markExternalEditApplied();
    showAppSnack(context, '고른 구간을 지웠어요');
    unawaited(
      _seekToPosition(
        projectController.timelineCenterOfSelectedClip() ??
            projectController.project.playheadMs.clamp(
              0,
              projectController.project.durationMs,
            ),
      ),
    );
  }

  void _duplicateClip() {
    final projectController = _projectController;
    if (projectController == null) return;
    _stopRangePreview();
    if (!projectController.duplicateSelectedClip()) {
      showAppSnack(context, '복제할 클립을 먼저 골라 주세요.');
      return;
    }
    _editState.markExternalEditApplied();
    showAppSnack(
      context,
      '클립을 복제했어요 (${projectController.project.clips.length}개)',
    );
    if (mounted) setState(() {});
  }

  /// 흐린 단추를 눌렀다. 왜 안 되는지 알려 준다 — 흐린 단추는 눌러도 아무 일이
  /// 없어서 "고장"과 구분되지 않는다.
  void _showBlockedReason(String reason) => showAppSnack(context, reason);

  /// 구간 손잡이를 끄는 동안.
  ///
  /// 되돌리기 이력에 쌓지 않고, 편집 화면 전체를 다시 그리지도 않는다. 막대는
  /// 제 손으로 움직이고 있고, 여기서는 값과 미리보기 프레임만 따라간다.
  void _onTrimChanged(int startMs, int endMs, bool startHandle) {
    final projectController = _projectController;
    if (projectController == null || _saving) return;
    projectController.beginGesture();
    final changed = projectController.trimSelectedClip(
      sourceStartMs: startMs,
      sourceEndMs: endMs,
      commit: false,
      notify: false,
    );
    if (!changed) return;
    _editState.markExternalEditApplied();
    // 잡고 있는 쪽 프레임을 보여 준다 — 아이폰처럼 "어디서 잘리는지"가 보인다.
    unawaited(_seekPreviewToSource(startHandle ? startMs : endMs - 1));
  }

  /// 손잡이에서 손을 뗐다. 여기서 한 번만 이력에 쌓고 화면을 맞춘다.
  ///
  /// 재생 위치는 **정한 구간 가운데**로 들인다. 구간 맨 앞에 붙어 있으면 앞쪽에
  /// 남는 길이가 0이라 분할이 아예 불가능하고(단추가 흐려진다), 재생 봉이 시작
  /// 손잡이에 겹쳐 붙어 "움직이지 않는 선"처럼 보인다.
  void _onTrimCommitted() {
    final projectController = _projectController;
    if (projectController == null) return;
    projectController.endGesture();
    final project = projectController.project;
    final selected = project.selectedClip;
    if (selected != null) {
      _playingClipIndex = project.clips.indexOf(selected);
    }
    _editState.markExternalEditApplied();
    _stopRangePreview();
    unawaited(
      _seekToPosition(
        projectController.timelineCenterOfSelectedClip() ?? project.playheadMs,
      ),
    );
    if (mounted) setState(() {});
  }

  /// 정해 둔 구간만 처음부터 끝까지 보여 준다.
  ///
  /// **왜 따로 있나**: 위쪽 재생 단추는 편집 결과 **전체**를 잇달아 튼다. 구간을
  /// 정한 직후 확인하고 싶은 것은 "이 구간이 맞나"인데, 전체 재생으로는 다음
  /// 클립까지 넘어가 버려 방금 정한 구간이 어디서 끝나는지 알 수 없었다.
  /// 이 재생은 구간 끝에 닿으면 선다.
  Future<void> _toggleRangePreview() async {
    final preview = _preview;
    final projectController = _projectController;
    if (preview == null || projectController == null || _saving) return;
    if (_rangePreview) {
      _rangePreview = false;
      await preview.pause();
      projectController.setPlaying(false);
      if (mounted) setState(() {});
      return;
    }
    final project = projectController.project;
    final selected = project.selectedClip;
    if (selected == null) return;
    setState(() => _rangePreview = true);
    // 고른 클립을 그대로 유지한다. `_seekToPosition`은 시각으로 클립을 되찾는데,
    // 여기서 넘기는 시각은 이 클립의 시작이라 이음매에 걸린다 — 그러면 사용자가
    // 고른 클립이 바뀐다.
    _playingClipIndex = project.clips.indexOf(selected);
    projectController.setPlayhead(project.timelineStartFor(selected.id));
    await _seekPreviewToSource(selected.sourceStartMs);
    if (!mounted || !_rangePreview) return;
    await preview.play();
    projectController.setPlaying(true);
    if (mounted) setState(() {});
  }

  /// 구간 재생을 끈다. 구간이 바뀌거나 다른 재생이 시작될 때 부른다.
  void _stopRangePreview() {
    if (!_rangePreview) return;
    _rangePreview = false;
    unawaited(_preview?.pause());
    _projectController?.setPlaying(false);
  }

  /// 되돌리기·다시 실행.
  ///
  /// 컨트롤러만 되돌리면 화면과 재생기가 어긋난다 — 볼륨은 옛 값으로,
  /// 재생 위치는 없어진 구간을 가리킨 채 남는다. 그래서 여기서 함께 맞춘다.
  void _undoEdit() => _applyHistory((controller) => controller.undo());

  void _redoEdit() => _applyHistory((controller) => controller.redo());

  void _applyHistory(void Function(EditorProjectController) action) {
    final projectController = _projectController;
    if (projectController == null || _saving) return;
    final preview = _preview;
    if (preview != null && preview.value.isPlaying) {
      unawaited(preview.pause());
      projectController.setPlaying(false);
    }
    action(projectController);
    final project = projectController.project;
    _playingClipIndex = _playingClipIndex.clamp(
      0,
      math.max(0, project.clips.length - 1),
    );
    _audioVolume = project.audio.effectiveVolume;
    unawaited(preview?.setVolume(_audioVolume) ?? Future<void>.value());
    _editState.markExternalEditApplied();
    unawaited(_seekToPosition(project.playheadMs));
    if (mounted) setState(() {});
  }

  void _setAudioVolume(double volume) {
    _projectController?.setSourceVolume(volume);
    _audioVolume = volume;
    _editState.markExternalEditApplied();
    unawaited(_preview?.setVolume(volume) ?? Future<void>.value());
    if (mounted) setState(() {});
  }

  /// 볼륨 손잡이에서 손을 뗐다. 끄는 내내 쌓지 않고 여기서 한 칸만 쌓는다.
  void _commitAudioVolume() => _projectController?.endGesture();

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

class _PreviewSurface extends StatelessWidget {
  const _PreviewSurface({
    required this.controller,
    required this.projectController,
    required this.captionColor,
    required this.onLayerChanged,
    required this.onEditingTextChanged,
    this.editingLayerId,
    this.textInput,
    this.textFocus,
    this.onEditingDone,
    this.onEditLayer,
    this.autoCaptionText,
  });

  final VideoPlayerController controller;
  final EditorProjectController projectController;

  final Color captionColor;

  /// 글자·스티커를 옮기거나 크기를 바꾸거나 지웠을 때. 화면이 "저장 안 된
  /// 변경"으로 표시한다.
  final VoidCallback onLayerChanged;

  /// 지금 영상 위에서 글을 쓰고 있는 레이어. 이 레이어만 입력칸으로 그린다.
  final String? editingLayerId;
  final TextEditingController? textInput;
  final FocusNode? textFocus;
  final ValueChanged<String> onEditingTextChanged;

  /// 글을 쓰는 도중 영상 빈 곳을 눌렀다. 다 쓴 것으로 본다 — 완료 단추를
  /// 찾아 누르지 않아도 되는 게 자연스럽다.
  final VoidCallback? onEditingDone;

  /// 이미 올려 둔 글자를 두 번 눌러 다시 고친다.
  final ValueChanged<String>? onEditLayer;

  /// 지금 재생 위치의 자동 자막. 손 자막이 있으면 그리지 않는다 — 같은 자리라
  /// 겹치면 읽을 수 없다.
  final String? autoCaptionText;

  /// 화면에 실제로 그릴 자동 자막.
  String? get _captionOnScreen {
    final auto = autoCaptionText;
    return auto != null && auto.isNotEmpty ? auto : null;
  }

  /// 글자 레이어 하나를 그린다. 편집 중인 레이어만 제자리 입력칸이 된다.
  ///
  /// 입력칸은 [InputDecoration]과 앱 테마를 통째로 벗긴다. 그러지 않으면
  /// 테마가 정한 크림색 채움과 코랄 테두리가 영상 위에 커다란 알약처럼
  /// 얹혀 정작 영상을 가린다.
  Widget _textLayerBody(
    BuildContext context, {
    required EditorTextLayer layer,
    required double previewWidth,
    required double scale,
  }) {
    final boxed = layer.backgroundColor.a != 0;
    final editing = layer.id == editingLayerId && textInput != null;
    final style = TextStyle(
      color: layer.color,
      height: 1.2,
      fontSize: (layer.fontSize * previewWidth / _referenceCanvasWidth * scale)
          .clamp(9.0, 220.0),
      fontWeight: layer.bold ? FontWeight.w900 : FontWeight.w400,
      fontStyle: layer.italic ? FontStyle.italic : FontStyle.normal,
      // 상자를 깔면 그림자는 지저분하기만 하다.
      shadows: boxed
          ? null
          : const [
              Shadow(
                color: Color(0xB3000000),
                blurRadius: 6,
                offset: Offset(0, 1),
              ),
            ],
    );
    final textAlign = switch (layer.align) {
      EditorTextAlign.left => TextAlign.left,
      EditorTextAlign.center => TextAlign.center,
      EditorTextAlign.right => TextAlign.right,
    };

    final Widget body = editing
        ? IntrinsicWidth(
            // 빈 칸일 때도 손가락이 닿을 만한 너비는 남긴다. 글자 폭에만
            // 맞추면 첫 글자를 쓰기 전에는 칸이 사실상 0이라, 커서가 어디
            // 있는지도 보이지 않고 눌러도 잡히지 않는다.
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: previewWidth * 0.3),
              child: Theme(
                // 앱 테마의 입력칸 꾸밈(채움색·테두리)을 통째로 지운다.
                data: Theme.of(
                  context,
                ).copyWith(inputDecorationTheme: const InputDecorationTheme()),
                child: TextField(
                  key: const Key('editor-inline-text-field'),
                  controller: textInput,
                  focusNode: textFocus,
                  maxLines: null,
                  maxLength: 120,
                  textAlign: textAlign,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  cursorColor: layer.color,
                  style: style,
                  onChanged: onEditingTextChanged,
                  decoration: InputDecoration(
                    isCollapsed: true,
                    filled: false,
                    counterText: '',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: '내용을 입력하세요',
                    hintStyle: style.copyWith(
                      color: layer.color.withValues(alpha: 0.45),
                    ),
                  ),
                ),
              ),
            ),
          )
        : Text(layer.text, textAlign: textAlign, style: style);

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: previewWidth * 0.86),
      child: boxed
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: layer.backgroundColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: body,
              ),
            )
          : body,
    );
  }

  /// 미리보기는 **스스로** 프로젝트 변화를 듣는다.
  ///
  /// **왜 필요한가**: 이 위젯은 편집 화면이 만들어 `EditorWorkspace`에 통째로
  /// 넘긴다. 워크스페이스가 컨트롤러 알림으로 다시 그려져도, 넘겨받은 위젯
  /// 인스턴스는 **같은 객체**라 Flutter가 그 아래를 다시 그리지 않는다. 그래서
  /// 스티커를 놓거나 레이어를 골라도 영상 위에는 아무 일도 일어나지 않았다.
  /// 여기서 직접 들으면 편집 화면 전체를 다시 그리지 않고도 영상 위 레이어만
  /// 제때 갱신된다.
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: projectController,
    builder: (context, _) => _buildCanvas(context),
  );

  Widget _buildCanvas(BuildContext context) {
    // 넘겨받은 값이 아니라 지금 프로젝트에서 읽는다. 위젯 인스턴스는 편집
    // 화면이 다시 그려질 때만 새로 만들어지므로, 여기서 읽어야 색감·비율
    // 변경이 곧바로 화면에 반영된다.
    final project = projectController.project;
    final canvas = project.canvas;
    final look = project.look;
    final zoom = project.zoomAtTimeline(project.playheadMs);
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
                      onTap: editingLayerId == null ? null : onEditingDone,
                      child: ClipRect(
                        child: Transform.scale(
                          scale: zoom?.scale ?? 1,
                          alignment: zoom == null
                              ? Alignment.center
                              : Alignment(
                                  zoom.focus.x * 2 - 1,
                                  zoom.focus.y * 2 - 1,
                                ),
                          child: Center(
                            child: ColorFiltered(
                              colorFilter: look.colorFilter,
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
                        editing: layer.id == editingLayerId,
                        // 두 번 누르면 그 글자를 다시 고친다.
                        onDoubleTap: onEditLayer == null
                            ? null
                            : () => onEditLayer!(layer.id),
                        // 배경 없는 글자. 크기는 Transform이 아니라 글자 크기
                        // 자체에 곱한다 — 그래야 상자(테두리·손잡이)가 글자와
                        // 같이 커지고 줄어든다.
                        childBuilder: (context, previewWidth, scale) =>
                            _textLayerBody(
                              context,
                              layer: layer,
                              previewWidth: previewWidth,
                              scale: scale,
                            ),
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
    this.editing = false,
    this.onDoubleTap,
  });

  final EditorProjectController controller;
  final EditorTimedLayer layer;
  final _LayerChildBuilder childBuilder;
  final VoidCallback onChanged;

  /// 두 번 눌렀을 때. 글자 레이어만 쓴다 — 다시 고치기.
  final VoidCallback? onDoubleTap;

  /// 지금 이 레이어에 글을 쓰고 있는가.
  ///
  /// 쓰는 동안에는 테두리·손잡이를 걷고 끌기·확대 제스처도 넘기지 않는다.
  /// 그러지 않으면 글자 가운데를 눌러 커서를 옮기려던 손가락이 "상자 끌기"로
  /// 먹히고, ✕ 손잡이가 글자 위에 겹쳐 오타를 지우려다 레이어를 지운다.
  /// 다 쓰고 완료를 누르면 곧바로 손잡이가 돌아와 옮기고 키울 수 있다.
  final bool editing;

  @override
  State<_EditableLayerOverlay> createState() => _EditableLayerOverlayState();
}

class _EditableLayerOverlayState extends State<_EditableLayerOverlay> {
  static const _handleInset = 15.0;
  static const _handleSize = 30.0;

  /// 조작 중인 값. 손가락이 움직이는 동안에는 **여기**만 바뀐다.
  ///
  /// **왜 따로 들고 있나**: 예전에는 프레임마다 컨트롤러가 `notifyListeners()`를
  /// 했다. 그러면 편집 화면 전체(타임라인 썸네일, 도구 패널, 하단 네비까지)가
  /// 통째로 다시 그려진다. 손가락은 초당 60~120번 움직이는데 그 비용을 매번
  /// 치르니 글자가 손끝을 못 따라오고 뚝뚝 끊겼다. 이제 조작 중에는 이 위젯만
  /// 다시 그리고, 모델에는 조용히 값만 넣어 둔다. 손을 뗄 때 한 번만 알린다.
  NormalizedPoint? _livePosition;
  double? _liveScale;
  double? _liveRotation;

  NormalizedPoint _startPosition = NormalizedPoint.center;
  double _startScale = 1;
  double _startRotation = 0;

  /// 모서리 손잡이를 잡았을 때의 기준. 상자 중심에서 손가락까지의 거리 비율로
  /// 크기를 정한다 — 상자가 크든 작든 "잡아 늘이는" 감각이 같다.
  final _boxKey = GlobalKey();
  Offset? _resizeCenter;
  double _resizeStartDistance = 0;
  double _resizeStartScale = 1;

  NormalizedPoint get _position => _livePosition ?? widget.layer.position;
  double get _scale => _liveScale ?? widget.layer.scale;
  double get _rotation => _liveRotation ?? widget.layer.rotationDegrees;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth <= 0 ? 1.0 : constraints.maxWidth;
        final height = constraints.maxHeight <= 0 ? 1.0 : constraints.maxHeight;
        // 쓰는 중에는 테두리도 손잡이도 없다. 커서와 글자만 보인다.
        final selected =
            !widget.editing &&
            widget.controller.project.selectedLayerId == widget.layer.id;
        final Widget box = DecoratedBox(
          key: _boxKey,
          decoration: BoxDecoration(
            border: selected
                ? Border.all(color: AppColors.coral, width: 1.6)
                : null,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            child: widget.childBuilder(context, width, _scale),
          ),
        );
        return CustomSingleChildLayout(
          delegate: _LayerCenterLayout(_position),
          child: RepaintBoundary(
            child: Transform.rotate(
              angle: _rotation * math.pi / 180,
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(_handleInset),
                    child: widget.editing
                        ? box
                        : GestureDetector(
                            key: Key('editor-layer-${widget.layer.id}'),
                            behavior: HitTestBehavior.opaque,
                            onTap: () =>
                                widget.controller.selectLayer(widget.layer.id),
                            onDoubleTap: widget.onDoubleTap,
                            onScaleStart: (_) => _beginTransform(),
                            onScaleUpdate: (details) => _updateTransform(
                              details,
                              width: width,
                              height: height,
                            ),
                            onScaleEnd: (_) => _endGesture(),
                            child: box,
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
                        onPanStart: _beginResize,
                        onPanUpdate: _updateResize,
                        onPanEnd: _endGesture,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  void _beginTransform() {
    _startPosition = _position;
    _startScale = _scale;
    _startRotation = _rotation;
    widget.controller.beginLayerGesture(widget.layer.id);
  }

  void _updateTransform(
    ScaleUpdateDetails details, {
    required double width,
    required double height,
  }) {
    // 손가락이 움직인 만큼만 옮긴다. 두 손가락이면 벌린 만큼 커지고 돌린
    // 만큼 돌아간다 — 한 손가락일 때 scale은 1, rotation은 0이라 이동만 된다.
    final moved = (_livePosition ?? _startPosition).translate(
      details.focalPointDelta.dx / width,
      details.focalPointDelta.dy / height,
    );
    setState(() {
      _livePosition = moved;
      _liveScale = (_startScale * details.scale).clamp(0.2, 4.0);
      _liveRotation = _startRotation + details.rotation * 180 / math.pi;
    });
    widget.controller.updateSelectedLayerTransform(
      position: _livePosition!,
      scale: _liveScale!,
      rotationDegrees: _liveRotation!,
      notify: false,
    );
  }

  void _beginResize(Offset globalPosition) {
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    final center = box != null && box.hasSize
        ? box.localToGlobal(box.size.center(Offset.zero))
        : null;
    _resizeCenter = center;
    _resizeStartDistance = center == null
        ? 0
        : (globalPosition - center).distance;
    _resizeStartScale = _scale;
    widget.controller.beginLayerGesture(widget.layer.id);
  }

  void _updateResize(Offset globalPosition) {
    final center = _resizeCenter;
    // 잡은 자리가 중심과 너무 가까우면 비율이 폭발한다. 그럴 땐 손대지 않는다.
    if (center == null || _resizeStartDistance < 12) return;
    final ratio = (globalPosition - center).distance / _resizeStartDistance;
    final next = (_resizeStartScale * ratio).clamp(0.2, 4.0);
    setState(() => _liveScale = next);
    widget.controller.updateSelectedLayerScale(next, notify: false);
  }

  /// 손을 뗐다. 여기서 한 번만 알리고 되돌리기 이력에 한 칸 쌓는다.
  void _endGesture() {
    _livePosition = null;
    _liveScale = null;
    _liveRotation = null;
    _resizeCenter = null;
    widget.controller.endLayerGesture();
    widget.onChanged();
  }

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

  /// 화면 기준 손가락 위치를 그대로 넘긴다. 상자 중심에서의 거리로 크기를
  /// 정하려면 누적 delta가 아니라 절대 좌표가 있어야 한다.
  final ValueChanged<Offset>? onPanStart;
  final ValueChanged<Offset>? onPanUpdate;
  final VoidCallback? onPanEnd;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    onPanStart: onPanStart == null
        ? null
        : (details) => onPanStart!(details.globalPosition),
    onPanUpdate: onPanUpdate == null
        ? null
        : (details) => onPanUpdate!(details.globalPosition),
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
    this.onTap,
  });

  final EditorProjectController controller;
  final EditorCanvas canvas;
  final Widget child;

  /// 영상 빈 곳을 눌렀을 때. null이면 손잡이만 감춘다.
  final VoidCallback? onTap;

  @override
  State<_CanvasGestureLayer> createState() => _CanvasGestureLayerState();
}

class _CanvasGestureLayerState extends State<_CanvasGestureLayer> {
  double _startScale = 1;
  double _startRotation = 0;
  double _startOffsetX = 0;
  double _startOffsetY = 0;

  /// 조작 중인 값. 레이어 조작과 같은 이유로 여기만 먼저 바꾼다 — 두 손가락이
  /// 움직이는 내내 편집 화면 전체를 다시 그리면 화면이 손가락을 못 따라온다.
  EditorCanvas? _liveCanvas;

  EditorCanvas get _canvas => _liveCanvas ?? widget.canvas;

  @override
  void didUpdateWidget(_CanvasGestureLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.canvas, widget.canvas)) _liveCanvas = null;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 영상 빈 곳을 누르면 글자·스티커 조절 손잡이를 감춘다. 글을 쓰는
      // 중이었다면 다 쓴 것으로 본다.
      onTap: widget.onTap ?? widget.controller.deselectLayer,
      onDoubleTap: () {
        _liveCanvas = null;
        widget.controller.resetCanvasTransform();
      },
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
          notify: false,
        );
        setState(() => _liveCanvas = widget.controller.project.canvas);
      },
      onScaleEnd: (_) {
        _liveCanvas = null;
        widget.controller.endCanvasGesture();
      },
      child: Transform.translate(
        offset: Offset(
          _canvas.offsetX * constraints.maxWidth / 2,
          _canvas.offsetY * constraints.maxHeight / 2,
        ),
        child: Transform.rotate(
          angle: _canvas.rotationDegrees * math.pi / 180,
          child: Transform.scale(scale: _canvas.scale, child: widget.child),
        ),
      ),
    ),
  );
}
