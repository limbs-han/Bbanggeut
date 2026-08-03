import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import '../core/saved_video_edit.dart';
import '../core/video_edit_state.dart';
import '../core/video_exporter.dart';
import '../core/video_source_cache.dart';
import '../features/stt/caption_auto_section.dart';
import '../features/stt/caption_controller.dart';
import '../features/stt/mlkit_transcriber.dart';
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

  /// AI 자막 시트가 떠 있는가. 탭과 패널 버튼이 겹쳐 두 장 쌓이는 걸 막는다.
  bool _captionSheetOpen = false;

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
  final Map<String, EditRecommendation> _presetRecommendations = {};
  bool _recommendationLoading = false;

  /// 서버가 이 영상을 분석하는 동안 true. AI 컷 칩은 그동안 흐리게 잠긴다.
  bool _analysisRunning = false;
  Timer? _analysisPollTimer;
  bool _analysisPollBusy = false;

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

  /// 들린 대사로 만드는 자동 자막(전사). 전사가 끝나면 일반 자막 레이어로
  /// 합쳐진다 — 이후 편집·저장은 자막 탭과 같은 길이다.
  final _autoCaptions = CaptionController();

  /// 마지막으로 자막 레이어에 합친 전사 내용의 서명.
  ///
  /// **왜 필요한가**: 병합은 전사 완료 알림과 시트 닫힘, 두 군데서 불린다.
  /// 같은 내용을 두 번 합치면 자막 탭에서 사용자가 고쳐 둔 AI 자막이
  /// 이유 없이 원문으로 되돌아간다. 내용이 실제로 바뀌었을 때만 합친다.
  String? _mergedTranscriptSignature;

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
    if (!mounted) return;
    // 전사가 끝나는 순간 자막 탭으로 합친다. 예전에는 시트를 닫을 때만
    // 합쳤는데, 전사 중에 닫아 버리면 끝나도 아무 일이 없어 "적용이 안
    // 된다"로 보였다.
    _mergeTranscriptIntoTextLayers();
    setState(() {});
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
    final sourceProject = EditorProject.fromSource(
      sourceVideoPath: sourcePath,
      sourceDurationMs: durationMs,
      sourceSize: EditorSourceSize(width: sourceWidth, height: sourceHeight),
    );
    // 영상은 제 비율 그대로 연다. 16:9 원본을 9:16 캔버스에 담아 위아래를
    // 검은 여백으로 채우던 기본값은 화면만 낭비했다 — 다른 비율이 필요하면
    // 비율 탭에서 고르고, 그때는 여백 없이 가득 채운다.
    final nextProjectController = EditorProjectController(sourceProject);

    // **화면부터 연다.** 초안 조회와 AI 추천은 네트워크라 언제 올지 모른다 —
    // 예전에는 이 둘을 기다렸다가 화면을 열어서, 서버가 안 닿으면 연결
    // 타임아웃(4초×2)이 고스란히 진입 시간에 얹혔다. 이제 원본 구간으로
    // 먼저 열고, 도착하면 그때 적용한다.
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
      _status = '자동 편집을 불러오고 있어요';
    });

    previousProjectController?.dispose();
    await previousPreview?.dispose();
    // 전사는 여기서 시작하지 않는다 — 오디오를 처음부터 끝까지 훑는 일이라
    // 편집 진입·재생과 CPU를 다툰다. AI자막 탭을 눌렀을 때만
    // [_startAutoCaptions]가 돈다.
    // 썸네일은 편집에 필수 데이터가 아니다. 편집 화면을 먼저 열고 준비되는
    // 순서대로 타임라인에 채워 긴 네이티브 추출 작업이 진입을 막지 않게 한다.
    unawaited(_loadThumbnails());
    unawaited(_applyDraftOrRecommendation(nextProjectController));
  }

  /// 저장해 둔 초안이나 자동 추천을 **편집 화면을 연 뒤에** 얹는다.
  ///
  /// **왜 기다리지 않는가**: 둘 다 편집 서버 왕복이고, 추천 쪽은 서버가
  /// 영상을 분석하는 동안 수 초가 걸린다. 예전에는 그 시간을 준비 화면에서
  /// 통째로 기다렸다 — 원본이 이미 기기에 있어도 편집기가 열리지 않았다.
  /// 미리보기가 준비된 순간 편집 화면을 열고, 결과가 오면 그때 얹는다.
  ///
  /// 기다리는 동안 사용자가 무언가 만졌다면 얹지 않는다. 손으로 한 편집을
  /// 뒤늦게 도착한 추천이 덮는 것이 훨씬 나쁘다.
  Future<void> _applyDraftOrRecommendation(
    EditorProjectController projectController,
  ) async {
    Future<void> finish(String status, {bool cutChanged = false}) async {
      if (!mounted || !identical(_projectController, projectController)) return;
      setState(() => _status = status);
      // 컷이 바뀌었으면 재생기를 새 구간 머리에 맞춘다. 맞추지 않으면 첫
      // 재생이 잘려 나간 앞부분에서 시작한다.
      if (cutChanged) {
        await _seekToPosition(projectController.project.playheadMs);
      }
      // 프리셋 미리 받기는 여기서 시작한다. 진입에 필요한 추천 한 건과
      // 서버·CPU를 다투지 않게 한 발 뒤로 물린다.
      unawaited(_loadPresetRecommendations());
    }

    bool userTouchedIt() =>
        !mounted ||
        !identical(_projectController, projectController) ||
        // 되돌리기 이력이 생겼다 = 실제 편집이 한 번은 들어갔다. 탭을 옮기거나
        // 재생 위치를 움직이는 것은 이력을 남기지 않으므로 여기 걸리지 않는다.
        projectController.canUndo ||
        _editState.hasUnsavedChanges ||
        // 저장을 누른 뒤라면 지금 화면에 있는 그대로가 사용자가 고른 것이다.
        // 그 밑에서 컷을 갈아 끼우지 않는다.
        _saving;

    // 저장해 둔 초안이 있으면 그것부터 — "이어서 편집"이 기본이다.
    Map<String, dynamic>? draft;
    try {
      draft = await _recommendations.loadDraft(widget.video.id);
    } catch (_) {
      draft = null;
    }
    if (userTouchedIt()) return;
    if (draft != null && draft['recipe'] is Map) {
      projectController.loadDraftRecipe(
        Map<String, dynamic>.from(draft['recipe'] as Map),
      );
      await finish('저장한 편집을 이어서 열었어요', cutChanged: true);
      return;
    }

    try {
      final recommendation = await _recommendations.recommend(
        videoId: widget.video.id,
        capturedAt: widget.video.capturedStartAt,
      );
      if (userTouchedIt()) return;
      projectController.applyRecommendation(recommendation);
      if (const {
        'short',
        'medium',
        'long',
      }.contains(recommendation.durationPreset)) {
        _presetRecommendations[recommendation.durationPreset] = recommendation;
      }
      final seconds = projectController.project.durationMs / 1000;
      await finish(
        '자동 편집 적용 · ${seconds.toStringAsFixed(1)}초 · '
        '줌 ${projectController.project.zoomSegments.length}개',
        cutChanged: true,
      );
    } catch (failure) {
      if (EditRecommendationClient.isAnalysisRequired(failure)) {
        // 서버는 있는데 이 영상은 처음 본다 — 원본을 분석시키고, 끝나면
        // 스낵바로 알린 뒤 AI 컷과 자동 줌을 연다. 편집은 그동안 계속된다.
        final sourcePath = _sourcePath;
        if (mounted && sourcePath != null) {
          unawaited(_beginServerAnalysis(sourcePath));
          if (mounted) setState(() => _status = 'AI가 영상을 분석하고 있어요');
        }
      } else {
        await finish('자동 추천 서버에 연결하지 못해 원본 구간으로 열었어요');
      }
    }
  }

  /// AI자막 탭을 눌렀을 때만 전사를 시작한다.
  void _startAutoCaptions() {
    final sourcePath = _sourcePath;
    if (sourcePath == null) return;
    // 두 번 불러도 CaptionController가 한 번만 돌린다.
    _autoCaptions.start(widget.video.id, sourcePath);
  }

  /// 짧게·중간·길게 프리셋을 **한 번에 하나씩** 미리 받아 둔다.
  ///
  /// **왜 나란히 부르지 않는가**: 요청 하나가 서버에서 영상 한 편을 분석하는
  /// 일이다. 셋을 한꺼번에 던지면 서버가 셋을 나눠 처리하느라 다 같이 느려지고,
  /// 그 사이 편집 화면에서 실제로 필요한 요청(썸네일·초안 저장)까지 뒤로 밀린다.
  /// 차례로 받으면 첫 프리셋은 훨씬 빨리 손에 들어오고, 그 뒤는 사용자가 화면을
  /// 보는 동안 조용히 채워진다.
  Future<void> _loadPresetRecommendations() async {
    if (_recommendationLoading) return;
    final missing = const ['short', 'medium', 'long']
        .where((preset) => !_presetRecommendations.containsKey(preset))
        .toList(growable: false);
    if (missing.isEmpty) return;
    if (mounted) setState(() => _recommendationLoading = true);
    try {
      for (final preset in missing) {
        final value = await _recommendations.recommend(
          videoId: widget.video.id,
          capturedAt: widget.video.capturedStartAt,
          durationPreset: preset,
        );
        if (!mounted) return;
        setState(() => _presetRecommendations[value.durationPreset] = value);
      }
    } catch (_) {
      // 기본 자동 추천은 이미 적용됐다. 프리셋 일부를 못 가져와도 편집은 계속한다.
    } finally {
      if (mounted) setState(() => _recommendationLoading = false);
    }
  }

  /// 원본을 편집 서버에 올려 분석을 시작하고 2초마다 상태를 확인한다.
  /// 그동안 AI 컷 칩은 잠기고, 끝나면 자동 추천(컷+자동 줌)을 적용한 뒤
  /// 스낵바로 알린다. 실패해도 수동 편집은 그대로 계속된다.
  Future<void> _beginServerAnalysis(String sourcePath) async {
    if (_analysisRunning) return;
    _analysisRunning = true;
    _recommendationLoading = true;
    try {
      // 원본이 이미 서버(MinIO)에 있으므로 presigned URL을 넘겨 서버가
      // 직접 받게 한다. URL 발급이 안 되면 로컬 원본을 통째로 올린다.
      String? sourceUrl;
      try {
        sourceUrl = (await widget.controller.api.createDownloadUrl(
          widget.video.id,
        )).url;
      } catch (_) {
        sourceUrl = null;
      }
      final status = await _recommendations.requestAnalysis(
        videoId: widget.video.id,
        filePath: sourcePath,
        sourceUrl: sourceUrl,
      );
      if (!mounted) return;
      if (status.isDone) {
        await _finishServerAnalysis();
        return;
      }
      if (status.isFailed) {
        _failServerAnalysis(status.error);
        return;
      }
      showAppSnack(context, 'AI가 영상을 분석하고 있어요 — 끝나면 알려드릴게요');
      _analysisPollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _pollServerAnalysis(),
      );
    } catch (_) {
      _failServerAnalysis(null);
    }
  }

  Future<void> _pollServerAnalysis() async {
    if (_analysisPollBusy) return;
    _analysisPollBusy = true;
    try {
      final status = await _recommendations.analysisStatus(widget.video.id);
      if (!mounted) return;
      if (status.isDone) {
        await _finishServerAnalysis();
      } else if (status.isFailed || status.status == 'none') {
        // none은 분석 도중 서버가 재시작해 작업이 사라진 경우다.
        _failServerAnalysis(status.error);
      }
      // running이면 다음 폴링까지 기다린다.
    } catch (_) {
      // 일시적 오류는 다음 폴링에서 다시 확인한다.
    } finally {
      _analysisPollBusy = false;
    }
  }

  Future<void> _finishServerAnalysis() async {
    _stopServerAnalysis();
    try {
      final recommendation = await _recommendations.recommend(
        videoId: widget.video.id,
        capturedAt: widget.video.capturedStartAt,
      );
      final controller = _projectController;
      if (!mounted || controller == null) return;
      if (const {
        'short',
        'medium',
        'long',
      }.contains(recommendation.durationPreset)) {
        _presetRecommendations[recommendation.durationPreset] = recommendation;
      }
      // 분석을 기다리는 동안 사용자가 이미 편집을 시작했다면 컷·줌을
      // 덮지 않는다 — 프리셋 칩만 열어 주고, 원하면 직접 누르게 한다.
      final untouched =
          !controller.canUndo && !_editState.hasUnsavedChanges && !_saving;
      if (untouched) {
        controller.applyRecommendation(recommendation);
        _editState.markExternalEditApplied();
      }
      setState(() => _recommendationLoading = false);
      showAppSnack(context, 'AI 분석이 끝났어요 — AI 컷과 자동 줌을 쓸 수 있어요');
      if (untouched) await _seekToPosition(controller.project.playheadMs);
      unawaited(_loadPresetRecommendations());
    } catch (_) {
      if (!mounted) return;
      setState(() => _recommendationLoading = false);
      showAppSnack(context, 'AI 추천을 불러오지 못했어요', error: true);
    }
  }

  void _failServerAnalysis(String? error) {
    _stopServerAnalysis();
    if (!mounted) return;
    setState(() => _recommendationLoading = false);
    showAppSnack(
      context,
      error == null || error.isEmpty
          ? 'AI 분석에 실패했어요 — 수동 편집은 계속할 수 있어요'
          : 'AI 분석 실패: $error',
      error: true,
    );
  }

  void _stopServerAnalysis() {
    _analysisPollTimer?.cancel();
    _analysisPollTimer = null;
    _analysisRunning = false;
    _analysisPollBusy = false;
  }

  Future<void> _selectRecommendationPreset(String preset) async {
    if (_recommendationLoading) return;
    var recommendation = _presetRecommendations[preset];
    if (recommendation == null) {
      setState(() => _recommendationLoading = true);
      try {
        recommendation = await _recommendations.recommend(
          videoId: widget.video.id,
          capturedAt: widget.video.capturedStartAt,
          durationPreset: preset,
        );
        _presetRecommendations[preset] = recommendation;
      } catch (_) {
        // 추천 서버가 없어도 단추는 일해야 한다. 조각 점수 규칙으로 대신
        // 고른다 — 예전에는 여기서 그냥 돌아가서 "짧게·중간·길게가 눌리지
        // 않는다"로 보였다.
      } finally {
        if (mounted) setState(() => _recommendationLoading = false);
      }
    }
    final controller = _projectController;
    if (!mounted || controller == null) return;
    if (recommendation != null) {
      controller.applyRecommendation(recommendation);
    } else {
      controller.applyPreset(preset);
    }
    _editState.markExternalEditApplied();
    final project = controller.project;
    // 프리셋이 무엇을 했는지 바로 알려 준다. 고른 클립 하나만 바뀌고
    // 나머지는 그대로라는 것까지 말해 준다.
    final changed = project.selectedClip;
    showAppSnack(
      context,
      '${switch (preset) {
        'short' => '짧게',
        'medium' => '중간',
        _ => '길게',
      }} 컷 적용 · 고른 클립을 이어진 '
      '${((changed?.durationMs ?? project.durationMs) / 1000).toStringAsFixed(1)}초'
      ' 구간으로 (다른 클립은 그대로)',
    );
    await _seekToPosition(project.playheadMs);
    if (mounted) setState(() {});
  }

  /// 타임라인 프레임을 두 번에 나눠 뽑는다.
  ///
  /// 한 번에 촘촘한 프레임을 뽑으면 그동안 띠가 비어 있다. 먼저 네 장으로 띠를
  /// 채워 "지금 어디쯤인지"를 바로 보여 주고, 이어서 촘촘한 것으로 갈아
  /// 끼운다. 총 작업량은 조금 늘지만 눈에 보이기까지의 시간이 크게 줄어든다.
  Future<void> _loadThumbnails() async {
    final sourcePath = _sourcePath;
    if (sourcePath == null) return;
    if (!await _extractThumbnails(sourcePath, 4)) return;
    final durationMs = _projectController?.project.sourceDurationMs ?? 0;
    // 타임라인을 8배 확대해도 같은 사진 한 장만 커지지 않게 약 4초마다
    // 실제 프레임을 준비한다. 긴 영상에서도 72장을 넘기지 않아 진입과 메모리를
    // 막지 않는다. 첫 네 장이 이미 화면을 채웠으므로 이 작업은 뒤에서 진행된다.
    final detailCount = (durationMs / 4000).ceil().clamp(24, 72);
    await _extractThumbnails(sourcePath, detailCount);
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
        final next = 0.12 + downloadProgress * 0.72;
        // 진행률 콜백은 내려받는 조각마다 온다 — 초당 수십 번이다. 그때마다
        // 다시 그리면 준비 화면(FittedBox + 일러스트)을 초당 수십 번 재배치하게
        // 되고, 정작 다운로드에 쓸 시간을 화면 갱신이 먹는다. 눈에 보이는
        // 단위(1%)가 바뀔 때만 그린다.
        if ((next * 100).floor() == (_progress * 100).floor()) return;
        setState(() {
          _progress = next;
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
        projectController.selectClip(next.id);
        // 분할한 두 클립이 원본에서도 바로 붙어 있으면 재생기는 이미 다음
        // 프레임을 읽고 있다. 여기서 같은 시각으로 다시 seek하면 짧게 멈췄다가
        // 재생되어 컷 경계가 튄다. 한 프레임 이내로 이어진 클립은 그대로 흘리고,
        // 순서를 바꿨거나 떨어진 구간으로 넘어갈 때만 실제 위치를 옮긴다.
        if (!clip.isPlaybackContiguousWith(next)) {
          unawaited(
            preview.seekTo(Duration(milliseconds: next.sourceStartMs)).then((
              _,
            ) {
              if (mounted && !preview.value.isPlaying) {
                return preview.play();
              }
            }),
          );
        }
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

  /// 편집본(초안)만 서버에 저장한다. 렌더링 없이 몇 초면 끝난다.
  /// 추억 > 편집 중 목록에서 이어서 연다.
  Future<bool> _saveDraft({bool quiet = false}) async {
    final projectController = _projectController;
    if (projectController == null) return false;
    final project = projectController.project;
    try {
      await _recommendations.saveProject(
        videoId: widget.video.id,
        revision: project.revision + 1,
        recipe: project.toDraftMap(),
      );
      _editState.markSaved();
      if (mounted && !quiet) {
        showAppSnack(context, '편집본을 저장했어요. 추억 > 편집 중에서 이어서 열 수 있어요.');
        setState(() {});
      }
      return true;
    } catch (failure) {
      debugPrint('editor draft save failed: $failure');
      if (mounted && !quiet) {
        showAppSnack(context, '편집본 저장에 실패했어요. 편집 서버 연결을 확인해 주세요.', error: true);
      }
      return false;
    }
  }

  /// AI 자막 시트. 자막을 만들고 고치는 일은 전부 [CaptionAutoSection]이
  /// 그대로 한다 — 여기서는 열어 주기만 한다.
  Future<void> _showAiCaptionSheet() async {
    if (_saving || _captionSheetOpen) return;
    // 이미 합쳐 둔 AI 자막이 있으면, 다시 만들 때 그것들(자막 탭에서 고친
    // 내용 포함)이 새 결과로 바뀐다는 것을 먼저 알린다.
    if (_projectController?.hasTranscriptCaptions == true) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('AI 자막을 다시 만들까요?'),
          content: const Text(
            '자막 탭에 있는 AI 자막이 새로 만든 결과로 바뀌어요. '
            '직접 고친 부분도 함께 바뀌고, 직접 추가한 자막은 그대로예요.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('취소'),
            ),
            FilledButton(
              key: const Key('editor-ai-caption-replace'),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('다시 만들기'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
      // 사용자가 다시 만들기를 골랐다 — 같은 내용이라도 다시 합치도록
      // 서명을 지운다(고쳐 둔 것을 원문으로 되돌리는 것도 요청의 일부다).
      _mergedTranscriptSignature = null;
    }
    // 자막 탭에 들어온 것이 곧 "자막을 만들어 달라"는 뜻이다. 마이크 권한을
    // 여기서 먼저 묻는다 — 전사에 맡기면 오디오 추출이 끝난 몇 초 뒤에야
    // 대화상자가 떠서, 사용자가 무엇 때문에 묻는지 연결하기 어렵다.
    //
    // 파일로 자막을 만드는데 마이크를 요구하는 건 ML Kit의 요구사항이다.
    // 거부해도 시트는 연다 — 안에서 사유를 안내한다.
    await MlKitTranscriber().requestMicrophone();
    if (!mounted) return;

    // 전사는 이 버튼을 눌렀을 때만 시작한다 — 편집 진입과 CPU를 다투지 않는다.
    _startAutoCaptions();
    _captionSheetOpen = true;
    try {
      await _presentAiCaptionSheet();
    } finally {
      _captionSheetOpen = false;
    }
    if (!mounted) return;
    final merged = _mergeTranscriptIntoTextLayers();
    // 전사가 아직 도는 중에 닫았다. 끝나면 리스너가 알아서 합친다 —
    // 그 말을 안 해 주면 "눌렀는데 아무 일도 없다"로 보인다.
    if (!merged && _autoCaptions.lines.isEmpty) {
      showAppSnack(context, '대사를 아직 알아듣는 중이에요. 끝나면 자막 탭에 자동으로 들어가요.');
    }
    setState(() {});
  }

  /// 전사 결과를 **일반 자막 레이어로** 합친다. 실제로 합쳤으면 true.
  ///
  /// 전사 완료 알림과 시트 닫힘, 두 군데서 불리므로 내용 서명이 같으면
  /// 건너뛴다 — 자막 탭에서 고쳐 둔 AI 자막이 원문으로 되돌아가지 않는다.
  bool _mergeTranscriptIntoTextLayers() {
    final projectController = _projectController;
    if (projectController == null) return false;
    final lines = _autoCaptions.lines;
    if (lines.isEmpty) return false;
    final signature = [
      for (final line in lines) '${line.startMs}:${line.endMs}:${line.text}',
    ].join('|');
    if (signature == _mergedTranscriptSignature) return false;
    _mergedTranscriptSignature = signature;
    projectController.applyTranscriptCaptions([
      for (final line in lines)
        (startMs: line.startMs, endMs: line.endMs, text: line.text),
    ]);
    _editState.markExternalEditApplied();
    showAppSnack(
      context,
      'AI 자막 ${lines.length}줄을 자막 탭에 넣었어요. 자막 탭에서 고칠 수 있어요.',
    );
    // 전사는 긴 영상에서 한참 걸려 그동안 다른 앱을 보는 사람이 많다 —
    // 앱이 뒤로 가 있으면 스낵이 안 보이니 시스템 알림으로도 알린다.
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      unawaited(
        _editorPlatform.showLocalNotification(
          title: 'AI 자막이 준비됐어요',
          body: '자막 ${lines.length}줄을 넣었어요. 편집기에서 다듬어 보세요.',
        ),
      );
    }
    return true;
  }

  Future<void> _presentAiCaptionSheet() async {
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
  }

  Future<void> _saveEdit() async {
    _finishTextEditing();
    final preview = _preview;
    final projectController = _projectController;
    if (_saving) return;
    if (preview == null || _sourcePath == null || projectController == null) {
      // 조용히 돌아가면 "저장이 안 된다"로만 보인다. 왜 안 되는지 말한다.
      debugPrint(
        'editor save blocked: preview=${preview != null} '
        'source=${_sourcePath != null} controller=${projectController != null}',
      );
      showAppSnack(context, '미리보기를 준비하는 중이에요. 잠시 후 다시 눌러 주세요.');
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

    try {
      final exportProject = projectController.project;
      // 편집 초안부터 서버에 남긴다 — 렌더링이 실패해도 편집본은 산다.
      //
      // 기다리지는 않는다. 초안 저장은 편집 서버 왕복 한 번인데, 서버가 멀거나
      // 응답이 없으면 그 시간(연결 대기만 4초)이 통째로 "저장 버튼을 눌렀는데
      // 아무 일도 안 일어나는" 시간이 됐다. 렌더링과 나란히 보내면 어차피 더
      // 오래 걸리는 렌더링 시간 안에 숨는다.
      final draftSaved = _recommendations
          .saveProject(
            videoId: widget.video.id,
            revision: exportProject.revision + 1,
            recipe: exportProject.toDraftMap(),
          )
          .then((_) => debugPrint('editor draft saved before export'))
          .catchError(
            (Object failure) => debugPrint('editor draft save failed: $failure'),
          );

      // 컷·줌만 있는 프로젝트는 서버가 만든다 — 레시피(몇 KB)만 보내므로
      // 렌더링과 완성본 업로드 시간이 통째로 사라진다. 서버가 안 받아 주면
      // 기존 앱 렌더링·업로드로 그대로 이어 간다.
      if (exportProject.requiresRendering() && exportProject.serverRenderable) {
        final handedOff = await _tryServerRender(exportProject);
        if (handedOff) {
          await draftSaved;
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
            _status = '서버가 편집본을 만들고 있어요';
          });
          showAppSnack(
            context,
            '서버가 편집본을 만들고 있어요 — 업로드 없이 잠시 뒤 '
            '추억 > 편집 완료에 나타나요.',
          );
          Navigator.pop(
            context,
            SavedVideoEdit(videoPath: exportProject.sourceVideoPath),
          );
          return;
        }
      }

      // AI 자막은 이미 일반 자막 레이어로 합쳐져 textLayers에 들어 있다 —
      // 별도 자막 트랙을 넘기지 않는다.
      final requiresRendering = exportProject.requiresRendering();
      final String outputPath;
      if (requiresRendering) {
        projectController.setExportState(
          const EditorExportState(
            phase: EditorExportPhase.rendering,
            progress: 0,
          ),
        );
        if (mounted) {
          setState(() {
            _exportProgress = null;
            _status = '편집 내용을 영상으로 만들고 있어요';
          });
        }
        _startExportProgressPolling();
        try {
          outputPath = await _editorPlatform.exportProject(
            project: exportProject,
            outputPath: _buildOutputPath(),
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
      // 완성 영상은 **서버에만** 올리되, 올리는 일은 OS 백그라운드 작업
      // (WorkManager)에 맡긴다. 셀룰러에서 몇 분씩 걸리는 업로드를 편집기가
      // 붙잡고 기다리게 했더니 사용자가 앱을 껐고 업로드도 함께 끊겼다 —
      // 이제 앱을 나가거나 꺼도 계속 올라가고, 진행률은 상단 알림에 보인다.
      await _editorPlatform.enqueueEditedUpload(
        videoId: widget.video.id,
        filePath: outputPath,
        uploadUrl: _recommendations.editedVideoUploadUrl(
          videoId: widget.video.id,
          title: widget.video.title,
          durationMs: exportProject.durationMs,
          capturedAt: widget.video.capturedStartAt,
        ),
        title: widget.video.title,
        // 렌더링 산출물(임시 파일)만 지운다. 원본을 그대로 올릴 때는 캐시라
        // 지우면 다음 편집 진입이 도로 내려받는다.
        deleteAfter: requiresRendering,
      );
      // 초안 저장은 렌더링 내내 돌고 있었다. 여기서 결과만 거둔다.
      await draftSaved;
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
        _status = '업로드를 시작했어요';
      });
      showAppSnack(
        context,
        '영상을 서버에 올리는 중이에요. 앱을 닫아도 계속 올라가요 — '
        '끝나면 알림이 오고, 추억 > 편집 완료에서 볼 수 있어요.',
      );
      Navigator.pop(context, SavedVideoEdit(videoPath: outputPath));
    } catch (failure) {
      debugPrint('editor save failed: $failure');
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

  /// 서버 렌더링을 요청한다. 성공하면 true — 이후는 서버 몫이라 편집기는
  /// 바로 닫아도 된다. 어떤 이유로든 실패하면 false를 돌려 앱 렌더링으로
  /// 폴백한다(오프라인·구버전 서버·presigned 발급 실패 전부 포함).
  Future<bool> _tryServerRender(EditorProject exportProject) async {
    try {
      final signed = await widget.controller.api.createDownloadUrl(
        widget.video.id,
      );
      final status = await _recommendations.requestServerRender(
        videoId: widget.video.id,
        sourceUrl: signed.url,
        recipe: exportProject.toServerRenderRecipe(),
        title: widget.video.title,
        capturedAt: widget.video.capturedStartAt,
      );
      return status.isRunning || status.isDone;
    } catch (failure) {
      debugPrint('server render unavailable, falling back: $failure');
      return false;
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

  /// [baseName]을 주면 제목 대신 그것을 쓴다. 사람이 볼 일 없는 중간 파일에서
  /// 이름에 든 글자가 문제를 일으키지 않게 할 때만 쓴다.
  String _buildOutputPath({String? prefix, String? baseName}) {
    final sourcePath = _sourcePath;
    final directory = sourcePath == null
        ? Directory.systemTemp
        : File(sourcePath).parent;
    final name = baseName ?? _safeTitle(widget.video.title);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final suffix = prefix == null ? '' : '_$prefix';
    return '${directory.path}${Platform.pathSeparator}'
        '$name${suffix}_$timestamp.mp4';
  }

  void _retry() {
    _progress = 0;
    _prepare();
  }

  @override
  void dispose() {
    _autoCaptions
      ..removeListener(_onCaptionsChanged)
      ..dispose();
    _textInput.dispose();
    _textFocus.dispose();
    _stopExportProgressPolling();
    _stopServerAnalysis();
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
    // 편집이 남아 있으면 무엇으로 나가든(버튼·시스템 제스처) 먼저 묻는다 —
    // "편집본을 저장할까요?". 조용히 버리지도, 조용히 저장하지도 않는다.
    canPop: !_editState.hasUnsavedChanges || _saving,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('편집본을 저장할까요?'),
          content: const Text('저장하면 추억 > 편집 중 목록에서 이어서 편집할 수 있어요.'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                Navigator.pop(context);
              },
              child: const Text('저장 안 함'),
            ),
            FilledButton(
              key: const Key('editor-exit-save'),
              onPressed: () async {
                final navigator = Navigator.of(context);
                Navigator.pop(dialogContext);
                // 저장 결과는 스낵바가 알려 준다. 실패해도 붙잡지 않는다.
                await _saveDraft();
                if (mounted) navigator.pop();
              },
              child: const Text('저장하고 나가기'),
            ),
          ],
        ),
      );
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
                                  cacheWidth: decodePixels(
                                    context,
                                    contentWidth,
                                  ),
                                  filterQuality: FilterQuality.medium,
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
        // AI 자막은 전사가 끝나면 일반 자막 레이어로 합쳐진다 — 별도
        // 오버레이로 그리지 않는다.
        autoCaptionText: null,
      ),
      thumbnails: _thumbnails,
      playing: preview.value.isPlaying,
      saving: _saving,
      textEditing: textEditing,
      rangePreviewing: _rangePreview,
      exportProgress: _exportProgress,
      exportStatus: _status,
      presetRecommendations: Map.unmodifiable(_presetRecommendations),
      recommendationLoading: _recommendationLoading,
      onRecommendationSelected: _selectRecommendationPreset,
      onExportCancel: _cancelExport,
      onBack: () => Navigator.maybePop(context),
      onSaveDraft: _saveDraft,
      onSave: _saveEdit,
      onPlay: _togglePlayback,
      onSeek: _seekToPosition,
      onUndo: _undoEdit,
      onRedo: _redoEdit,
      onClipAdd: _addClip,
      onDelete: _deleteClip,
      onClipReorder: (oldIndex, newIndex) {
        projectController.reorderClip(oldIndex, newIndex);
        _editState.markExternalEditApplied();
        setState(() {});
      },
      onTrimChanged: _onTrimChanged,
      onTrimCommitted: _onTrimCommitted,
      onPlayRange: _toggleRangePreview,
      onBlocked: _showBlockedReason,
      onRatioSelected: _selectCanvasRatio,
      // 슬라이더·구간 손잡이·핀치에서 손을 뗐다. 이력을 한 칸으로 확정한다.
      onEditCommitted: () {
        projectController.endGesture();
        _editState.markExternalEditApplied();
        if (mounted) setState(() {});
      },
      onText: _startTextEditing,
      onTextEdit: (id) {
        // 자막 시작으로 옮겨 놓고 바로 그 위에서 고친다.
        final layer = projectController.project.textLayers
            .where((item) => item.id == id)
            .firstOrNull;
        if (layer != null) unawaited(_seekToPosition(layer.startMs));
        _startTextEditing(layerId: id);
      },
      onTextRemove: (id) {
        projectController.removeTextLayer(id);
        _editState.markExternalEditApplied();
        setState(() {});
      },
      onVolumeChanged: _setAudioVolume,
      onVolumeCommitted: _commitAudioVolume,
      onMutedChanged: _setMuted,
      onStickerSelected: _addSticker,
      onFaceStickerSelected: (value) {
        // 재생 위치에 얼굴이 없으면 붙일 수 없다 — 얼굴이 잡힌 장면으로
        // 옮겨 달라고 안내한다.
        if (!projectController.setFaceSticker(value)) {
          showAppSnack(
            context,
            '이 장면에서는 얼굴을 찾지 못했어요. 얼굴이 나오는 장면으로 이동한 뒤 붙여 주세요.',
            error: true,
          );
          return;
        }
        _editState.markExternalEditApplied();
        setState(() {});
      },
      onLookSelected: _setLook,
      onAiCaption: _showAiCaptionSheet,
      onZoomAdd: () {
        if (!projectController.addZoomAtPlayhead()) {
          showAppSnack(context, '이 클립은 줌으로 가득 찼어요. 기존 줌을 지우거나 줄여 주세요.');
          setState(() {});
          return;
        }
        _editState.markExternalEditApplied();
        setState(() {});
      },
      onZoomRemove: (zoom) {
        projectController.removeZoom(zoom);
        _editState.markExternalEditApplied();
        setState(() {});
      },
      onZoomSelected: (zoom) {
        projectController.selectZoom(zoom.id);
        unawaited(_seekToPosition(projectController.project.playheadMs));
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

  /// 추가·삭제는 눈에 보이는 변화가 작을 수 있다. 한 줄 안내를 띄우지 않으면
  /// "눌러도 아무 일이 없다"로 읽힌다.
  void _addClip() {
    final projectController = _projectController;
    if (projectController == null) return;
    _stopRangePreview();
    if (!projectController.addClipAtPlayhead()) {
      showAppSnack(context, '클립을 추가할 자리가 없어요.');
      return;
    }
    _editState.markExternalEditApplied();
    showAppSnack(
      context,
      '재생 위치에 3초 클립을 추가했어요 (${projectController.project.clips.length}개).'
      ' 노란 창을 끌어 원하는 장면으로 옮겨 보세요.',
    );
    if (mounted) setState(() {});
  }

  void _deleteClip() {
    final projectController = _projectController;
    if (projectController == null) return;
    _stopRangePreview();
    if (!projectController.deleteSelectedClip()) {
      showAppSnack(context, '지울 것이 없어요. 구간을 좁히거나 클립을 추가한 뒤에 지울 수 있어요.');
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
          cacheHeight: decodePixels(context, height),
          filterQuality: FilterQuality.medium,
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

  /// 얼굴 추적 스티커의 이 순간 화면 위치·배율. 일반 스티커는 그대로
  /// 돌려준다.
  ///
  /// 저장된 [EditorStickerLayer.position]은 얼굴 중심 기준 **오프셋**이라
  /// (0.5, 0.5)면 얼굴 정중앙이다. 배치 계산은 모델과 공유한다 — 앵커한
  /// 얼굴의 경로만 따르고, 얼굴 크기·구간 줌에 맞춰 위치와 크기가 함께
  /// 움직인다. 얼굴 궤적이 없으면 오프셋을 그대로 화면 좌표로 쓴다 —
  /// 안 보이는 것보다 가운데라도 보이는 쪽이 덜 놀란다.
  EditorStickerLayer _resolveFaceSticker(EditorStickerLayer layer) {
    if (!layer.tracksFace) return layer;
    final project = projectController.project;
    final placed = project.faceStickerPlacementAt(layer, project.playheadMs);
    if (placed == null) return layer;
    return layer.copyWith(
      position: placed.position,
      scale: layer.scale * placed.scale,
    );
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
    // 캔버스는 폭에 맞춰 그리고, 세로로 넘치는 검은 여백은 잘라 보여 준다.
    // 자를 수 있는 조건은 EditorPreviewGeometry가 정한다 — 캔버스 탭이나
    // 여백에 걸친 레이어가 보이는 동안에는 전체 캔버스로 돌아간다.
    return EditorCanvasViewport(
      geometry: EditorPreviewGeometry.of(project),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _CanvasGestureLayer(
              controller: projectController,
              mode: switch (project.selectedTool) {
                EditorTool.zoom => _PreviewGestureMode.zoomSegment,
                EditorTool.ratio => _PreviewGestureMode.canvasWindow,
                _ => _PreviewGestureMode.none,
              },
              activeZoom: zoom,
              onTap: editingLayerId == null ? null : onEditingDone,
              childBuilder: (liveZoom, liveCanvas) => _BoundedVideoViewport(
                sourceAspectRatio: width / height,
                canvas: liveCanvas ?? canvas,
                zoom: liveZoom ?? zoom,
                // 비율 탭에서는 영상 창 테두리를 그려 "검은 띠가 어디까지
                // 인지"를 눈으로 보며 조절하게 한다.
                showWindowGuide: project.selectedTool == EditorTool.ratio,
                child: ColorFiltered(
                  colorFilter: look.colorFilter,
                  child: SizedBox(
                    width: width,
                    height: height,
                    child: VideoPlayer(controller),
                  ),
                ),
              ),
            ),
            for (final layer in projectController.project.textLayers.where(
              (layer) =>
                  layer.isVisibleAt(projectController.project.playheadMs),
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
                childBuilder: (context, previewWidth, scale) => _textLayerBody(
                  context,
                  layer: layer,
                  previewWidth: previewWidth,
                  scale: scale,
                ),
              ),
            for (final layer
                in projectController.project.stickerLayers
                    .where(
                      (layer) => layer.isVisibleAt(
                        projectController.project.playheadMs,
                      ),
                    )
                    // 얼굴 추적 스티커는 이 순간의 얼굴 위치로 바꿔 그린다.
                    // 저장된 position은 얼굴 기준 오프셋이다.
                    .map(_resolveFaceSticker))
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
    );
  }
}

/// 글자·스티커 크기의 기준 캔버스 너비. 내보내기 쪽도 같은 값을 쓴다 —
/// 미리보기에서 본 크기가 저장된 영상에서도 같아야 한다.
const _referenceCanvasWidth = 1280.0;

/// 스티커 기본 글자 크기(EditorLayerOverlay.kt와 같은 값).
const _referenceStickerFontSize = 110.0;

/// 원본 영상이 차지하는 사각형(영상 창)을 그리고, 구간 줌은 그 안에서만 돈다.
///
/// 9:16처럼 영상과 캔버스 비율이 다르면(contain) 영상 창 밖은 검은 띠다.
/// 캔버스의 확대(scale)·이동(offset)은 **창 자체**를 키우고 옮긴다 — 검은
/// 띠의 크기와 위치를 사용자가 정하는 값이다. 내보내기(EditorProjectExporter.kt
/// 의 CanvasMatrixTransformation)도 레터박스 프레임을 같은 식으로 움직이므로
/// 미리보기에서 본 그대로 저장된다. 구간 줌은 창 ClipRect 안쪽에 걸려 아무리
/// 키워도 창 밖(검은 띠)으로 나가지 않는다.
class _BoundedVideoViewport extends StatelessWidget {
  const _BoundedVideoViewport({
    required this.sourceAspectRatio,
    required this.canvas,
    required this.zoom,
    required this.child,
    this.showWindowGuide = false,
  });

  final double sourceAspectRatio;
  final EditorCanvas canvas;
  final EditorZoomSegment? zoom;
  final Widget child;

  /// 영상 창 테두리를 그린다. 비율 탭에서 검은 띠를 조절할 때만 켠다.
  final bool showWindowGuide;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final canvasWidth = math.max(1.0, constraints.maxWidth);
      final canvasHeight = math.max(1.0, constraints.maxHeight);
      final canvasAspect = canvasWidth / canvasHeight;
      final contain = canvas.fit == EditorCanvasFit.contain;

      // contain 계산은 원본과 캔버스 중 어느 쪽이 더 넓은지로 정한다.
      final fittedWidth = contain
          ? (sourceAspectRatio >= canvasAspect
                ? canvasWidth
                : canvasHeight * sourceAspectRatio)
          : canvasWidth;
      final fittedHeight = contain
          ? (sourceAspectRatio >= canvasAspect
                ? canvasWidth / sourceAspectRatio
                : canvasHeight)
          : canvasHeight;
      final alignment = zoom == null
          ? Alignment.center
          : Alignment(zoom!.focus.x * 2 - 1, zoom!.focus.y * 2 - 1);

      // 창 = 기본 맞춤 크기 × 확대, 캔버스 중심 + 이동만큼 옮긴 자리.
      // EditorCanvas.copyWith가 이동을 캔버스 안으로 이미 잘라 둔다.
      final windowWidth = fittedWidth * canvas.scale;
      final windowHeight = fittedHeight * canvas.scale;
      final centerX = canvasWidth / 2 + canvas.offsetX * canvasWidth / 2;
      final centerY = canvasHeight / 2 + canvas.offsetY * canvasHeight / 2;

      final window = ClipRect(
        child: Transform.scale(
          scale: zoom?.scale ?? 1,
          alignment: alignment,
          child: FittedBox(fit: BoxFit.cover, child: child),
        ),
      );

      return Stack(
        children: [
          Positioned(
            left: centerX - windowWidth / 2,
            top: centerY - windowHeight / 2,
            width: windowWidth,
            height: windowHeight,
            child: SizedBox(
              key: const Key('editor-source-video-viewport'),
              child: window,
            ),
          ),
          if (showWindowGuide && contain) ...[
            // 창의 위·아래 경계를 캔버스 폭 전체에 긋는다 — 검은 띠가
            // 정확히 어디서 시작하는지 보인다.
            Positioned(
              left: 0,
              right: 0,
              top: (centerY - windowHeight / 2).clamp(0.0, canvasHeight),
              height: 1.5,
              child: const IgnorePointer(
                child: ColoredBox(color: Colors.white54),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: (centerY + windowHeight / 2).clamp(0.0, canvasHeight),
              height: 1.5,
              child: const IgnorePointer(
                child: ColoredBox(color: Colors.white54),
              ),
            ),
            Positioned(
              left: centerX - windowWidth / 2,
              top: centerY - windowHeight / 2,
              width: windowWidth,
              height: windowHeight,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white70, width: 1.5),
                  ),
                ),
              ),
            ),
          ],
        ],
      );
    },
  );
}

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
        return Stack(
          fit: StackFit.expand,
          children: [
            if (_livePosition != null)
              _LayerGuides(position: _position, rotationDegrees: _rotation),
            CustomSingleChildLayout(
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
                                onTap: () => widget.controller.selectLayer(
                                  widget.layer.id,
                                ),
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
            ),
          ],
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
    final rawPosition = (_livePosition ?? _startPosition).translate(
      details.focalPointDelta.dx / width,
      details.focalPointDelta.dy / height,
    );
    final moved = NormalizedPoint(
      _snapNormalized(rawPosition.x),
      _snapNormalized(rawPosition.y),
    );
    final rotation = _snapLayerAngle(
      _startRotation + details.rotation * 180 / math.pi,
    );
    setState(() {
      _livePosition = moved;
      _liveScale = (_startScale * details.scale).clamp(0.2, 4.0);
      _liveRotation = rotation;
    });
    widget.controller.updateSelectedLayerTransform(
      position: _livePosition!,
      scale: _liveScale!,
      rotationDegrees: _liveRotation!,
      notify: false,
    );
  }

  double _snapNormalized(double value) {
    for (final target in const [0.1, 0.5, 0.9]) {
      if ((value - target).abs() <= 0.018) return target;
    }
    return value.clamp(0.04, 0.96);
  }

  double _snapLayerAngle(double value) {
    for (final target in const [-180.0, -90.0, -45.0, 0.0, 45.0, 90.0, 180.0]) {
      if ((value - target).abs() <= 2.5) return target;
    }
    return value;
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

/// 영상 위 손가락 조작이 향하는 곳.
enum _PreviewGestureMode {
  none,

  /// 줌 탭 — 활성 줌 구간의 배율(핀치)·초점(드래그).
  zoomSegment,

  /// 비율 탭 — 영상 창의 크기(핀치)·위치(드래그). 9:16의 검은 띠를
  /// 사용자가 직접 조절하는 손이다.
  canvasWindow,
}

/// 영상 위 손가락 조작 층. 탭(도구)에 따라 조작 대상이 다르다.
///
/// 줌 탭에서는 두 손가락으로 벌리면 구간 줌의 배율이, 끌면 확대 초점이
/// 움직인다. 비율 탭에서는 같은 손짓이 영상 창(검은 띠의 경계)을 키우고
/// 옮긴다. 그리는 쪽([_BoundedVideoViewport])이 창 밖을 잘라 내므로 어느
/// 조작도 검은 띠를 침범하지 않는다.
class _CanvasGestureLayer extends StatefulWidget {
  const _CanvasGestureLayer({
    required this.controller,
    required this.mode,
    required this.activeZoom,
    required this.childBuilder,
    this.onTap,
  });

  final EditorProjectController controller;
  final _PreviewGestureMode mode;

  /// 지금 재생 위치에 걸려 있는 줌. null이면 줌 모드에서 만질 것이 없다.
  final EditorZoomSegment? activeZoom;

  /// 조작 중인 값을 반영해 영상을 그린다. 손가락이 움직이는 내내 편집 화면
  /// 전체를 다시 그리지 않으려고 이 층 안에서만 갱신한다.
  final Widget Function(EditorZoomSegment? liveZoom, EditorCanvas? liveCanvas)
  childBuilder;

  /// 영상 빈 곳을 눌렀을 때. null이면 손잡이만 감춘다.
  final VoidCallback? onTap;

  @override
  State<_CanvasGestureLayer> createState() => _CanvasGestureLayerState();
}

class _CanvasGestureLayerState extends State<_CanvasGestureLayer> {
  double _startScale = 1.35;
  NormalizedPoint _startFocus = NormalizedPoint.center;
  double _startOffsetX = 0;
  double _startOffsetY = 0;
  Offset _startFocalPoint = Offset.zero;
  EditorZoomSegment? _liveZoom;
  EditorCanvas? _liveCanvas;

  bool get _interactive => switch (widget.mode) {
    _PreviewGestureMode.zoomSegment => widget.activeZoom != null,
    _PreviewGestureMode.canvasWindow => true,
    _PreviewGestureMode.none => false,
  };

  @override
  void didUpdateWidget(_CanvasGestureLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeZoom?.id != widget.activeZoom?.id) _liveZoom = null;
    if (oldWidget.mode != widget.mode) {
      _liveZoom = null;
      _liveCanvas = null;
    }
  }

  void _startGesture(ScaleStartDetails details) {
    _startFocalPoint = details.focalPoint;
    if (widget.mode == _PreviewGestureMode.zoomSegment) {
      final zoom = _liveZoom ?? widget.activeZoom!;
      _startScale = zoom.scale;
      _startFocus = zoom.focus;
    } else {
      final canvas = widget.controller.project.canvas;
      _startScale = canvas.scale;
      _startOffsetX = canvas.offsetX;
      _startOffsetY = canvas.offsetY;
    }
    widget.controller.beginGesture();
  }

  void _updateGesture(ScaleUpdateDetails details, BoxConstraints constraints) {
    final width = math.max(1.0, constraints.maxWidth);
    final height = math.max(1.0, constraints.maxHeight);
    final dx = details.focalPoint.dx - _startFocalPoint.dx;
    final dy = details.focalPoint.dy - _startFocalPoint.dy;
    if (widget.mode == _PreviewGestureMode.zoomSegment) {
      final zoom = widget.activeZoom!;
      final scale = (_startScale * details.scale).clamp(1.05, 2.8);
      // 두 손가락 핀치 중에는 배율만 바꾼다. 두 손가락의 가운데 점은
      // 손을 벌리는 동안 크게 흔들리는데, 그걸 초점 이동으로 받으면
      // 그림이 널뛰다가 손을 떼는 순간 엉뚱한 곳으로 "돌아간" 것처럼
      // 보인다. 초점은 한 손가락 드래그가 맡는다.
      final pinching = details.pointerCount > 1;
      // 배율 s로 키운 그림을 dx만큼 옮기려면 초점은 dx/(s-1)만큼
      // 반대로 가야 한다. s가 1에 가까우면 옮길 것도 없다.
      final divisor = math.max(0.15, scale - 1);
      final next = zoom.copyWith(
        scale: scale,
        focus: pinching
            ? _startFocus
            : NormalizedPoint(
                _startFocus.x - dx / width / divisor,
                _startFocus.y - dy / height / divisor,
              ),
      );
      // 알림을 켜 둔다 — 패널의 배율 슬라이더가 핀치를 실시간으로 따라온다.
      widget.controller.updateZoomGesture(next);
      setState(() => _liveZoom = next);
      return;
    }
    // 영상 창을 손가락 그대로 옮긴다. 이동 한도는 컨트롤러 쪽 copyWith가
    // 캔버스 안으로 잘라 준다.
    widget.controller.updateCanvasGesture(
      scale: (_startScale * details.scale).clamp(1.0, 3.5),
      offsetX: _startOffsetX + dx / (width / 2),
      offsetY: _startOffsetY + dy / (height / 2),
      rotationDegrees: 0,
      notify: false,
    );
    setState(() => _liveCanvas = widget.controller.project.canvas);
  }

  void _endGesture() {
    _liveZoom = null;
    _liveCanvas = null;
    widget.controller.endGesture();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 영상 빈 곳을 누르면 글자·스티커 조절 손잡이를 감춘다. 글을 쓰는
      // 중이었다면 다 쓴 것으로 본다.
      onTap: widget.onTap ?? widget.controller.deselectLayer,
      onScaleStart: _interactive ? _startGesture : null,
      onScaleUpdate: _interactive
          ? (details) => _updateGesture(details, constraints)
          : null,
      onScaleEnd: _interactive ? (_) => _endGesture() : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.childBuilder(_liveZoom, _liveCanvas),
          if (widget.mode == _PreviewGestureMode.zoomSegment && _interactive)
            const Positioned.fill(child: IgnorePointer(child: _CanvasGuides())),
        ],
      ),
    ),
  );
}

class _LayerGuides extends StatelessWidget {
  const _LayerGuides({required this.position, required this.rotationDegrees});

  final NormalizedPoint position;
  final double rotationDegrees;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Stack(
      children: [
        if (position.x == 0.5)
          Align(
            alignment: Alignment.center,
            child: Container(width: 1, color: const Color(0xE65A7CFF)),
          ),
        if (position.y == 0.5)
          Align(
            alignment: Alignment.center,
            child: Container(height: 1, color: const Color(0xE65A7CFF)),
          ),
        Positioned.fill(
          left: 24,
          right: 24,
          top: 24,
          bottom: 24,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0x80FFFFFF)),
            ),
          ),
        ),
        if ((rotationDegrees % 45).abs() < 0.01)
          Positioned(
            right: 8,
            top: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xD91B1B1B),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                child: Text(
                  '${rotationDegrees.round()}°',
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _CanvasGuides extends StatelessWidget {
  const _CanvasGuides();

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Align(
        alignment: Alignment.center,
        child: Container(width: 1, color: const Color(0xCC5A7CFF)),
      ),
      Align(
        alignment: Alignment.center,
        child: Container(height: 1, color: const Color(0xCC5A7CFF)),
      ),
      Positioned.fill(
        left: 24,
        right: 24,
        top: 24,
        bottom: 24,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0x99FFFFFF), width: 1),
          ),
        ),
      ),
    ],
  );
}
