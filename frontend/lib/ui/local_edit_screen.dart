import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/banuba_video_editor.dart';
import '../core/models.dart';
import '../core/video_edit_state.dart';
import '../core/video_exporter.dart';
import '../features/stt/caption_auto_section.dart';
import '../features/stt/caption_controller.dart';
import 'widgets.dart';

const _editorBackground = Color(0xFF1E1B18);
const _editorSurface = Color(0xFF292521);
const _editorSurfaceRaised = Color(0xFF35302B);
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
  VideoPlayerController? _preview;
  String? _sourcePath;
  List<String> _thumbnails = [];
  double _progress = 0;
  bool _loading = true;
  bool _saving = false;
  bool _clipSelected = true;
  final Set<String> _appliedTools = <String>{};
  String _captionText = '';
  Color _captionColor = AppColors.cream;
  double _audioVolume = 1;
  String _selectedFilter = 'none';
  String _arSticker = '';
  String _selectedAnimation = 'none';
  String? _status;
  String? _error;
  late VideoEditState _editState;
  String _selectedTool = 'cut';

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
      _error = null;
      _status = widget.openDrafts ? '저장된 편집 상태를 불러오고 있어요' : '이벤트 영상을 불러오고 있어요';
    });

    try {
      final sourcePath = await _downloadSource();
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
      setState(() {
        _sourcePath = sourcePath;
        _preview = preview;
        _loading = false;
        _editState = VideoEditState(
          durationMs: durationMs,
          originalAspectRatio: aspectRatio,
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
          setState(() => _progress = received / total);
        }
      },
    );
    return input.path;
  }

  void _onPreviewChanged() {
    final preview = _preview;
    if (!mounted || preview == null) return;
    if (preview.value.isPlaying &&
        preview.value.position.inMilliseconds >= _editState.endMs) {
      preview.pause();
      preview.seekTo(Duration(milliseconds: _editState.startMs));
      if (mounted) setState(() {});
      return;
    }
    if (mounted) setState(() {});
  }

  Future<void> _togglePlayback() async {
    final preview = _preview;
    if (preview == null) return;
    if (preview.value.isPlaying) {
      await preview.pause();
    } else {
      final startMs = _editState.startMs;
      final target = preview.value.position.inMilliseconds >= _editState.endMs
          ? startMs
          : preview.value.position.inMilliseconds;
      if (target != preview.value.position.inMilliseconds) {
        await preview.seekTo(Duration(milliseconds: target));
      }
      await preview.play();
    }
  }

  Future<void> _seekToPosition(int milliseconds) async {
    await _preview?.seekTo(Duration(milliseconds: milliseconds));
    if (mounted) setState(() {});
  }

  void _selectTool(String tool) {
    if (_saving) return;
    setState(() {
      _selectedTool = tool;
      _editState.selectTool(tool);
      _clipSelected = tool == 'cut';
    });
    switch (tool) {
      case 'caption':
        unawaited(_showCaptionEditor());
      case 'audio':
        unawaited(_showAudioEditor());
      case 'effect':
        unawaited(_showEffectEditor());
      case 'ar':
        unawaited(_showArEditor());
    }
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

  Future<void> _showAudioEditor() async {
    var pendingVolume = _audioVolume;
    final selected = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: _editorSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _EditorSheetHeader(title: '볼륨'),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Icon(
                      pendingVolume == 0
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      color: AppColors.sage,
                    ),
                    Expanded(
                      child: Slider(
                        value: pendingVolume,
                        min: 0,
                        max: 1,
                        divisions: 20,
                        label: '${(pendingVolume * 100).round()}%',
                        onChanged: (value) {
                          setSheetState(() => pendingVolume = value);
                          _preview?.setVolume(value);
                        },
                      ),
                    ),
                    Text(
                      '${(pendingVolume * 100).round()}%',
                      style: const TextStyle(
                        color: AppColors.cream,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _SheetApplyButton(
                  label: '볼륨 적용',
                  onPressed: () => Navigator.pop(sheetContext, pendingVolume),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected == null) {
      await _preview?.setVolume(_audioVolume);
      return;
    }
    if (!mounted) return;
    setState(() {
      _audioVolume = selected;
      _editState.markExternalEditApplied();
      _appliedTools.add('audio');
    });
  }

  Future<void> _showEffectEditor() async {
    final selected = await _showChoiceSheet(
      title: '편집효과',
      selected: _selectedFilter,
      choices: const {
        'none': ('원본', Icons.hide_image_outlined),
        'warm': ('따뜻하게', Icons.wb_sunny_outlined),
        'vivid': ('선명하게', Icons.color_lens_outlined),
        'mono': ('흑백', Icons.monochrome_photos_outlined),
      },
    );
    if (selected != null && mounted) {
      setState(() {
        _selectedFilter = selected;
        _editState.markExternalEditApplied();
        if (selected == 'none') {
          _appliedTools.remove('effect');
        } else {
          _appliedTools.add('effect');
        }
      });
    }
  }

  Future<void> _showArEditor() async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _editorSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _EditorSheetHeader(title: 'AR 스티커'),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: ['', '😊', '😂', '🥳', '❤️']
                    .map(
                      (sticker) => _StickerOption(
                        sticker: sticker,
                        selected: sticker == _arSticker,
                        onTap: () => Navigator.pop(sheetContext, sticker),
                      ),
                    )
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        _arSticker = selected;
        _editState.markExternalEditApplied();
        if (selected.isEmpty) {
          _appliedTools.remove('ar');
        } else {
          _appliedTools.add('ar');
        }
      });
    }
  }

  Future<void> _showAnimationEditor() async {
    final selected = await _showChoiceSheet(
      title: '애니메이션',
      selected: _selectedAnimation,
      choices: const {
        'none': ('없음', Icons.block_rounded),
        'fade': ('페이드', Icons.blur_on_rounded),
        'zoom': ('확대', Icons.zoom_out_map_rounded),
      },
    );
    if (selected != null && mounted) {
      setState(() {
        _selectedAnimation = selected;
        _editState.markExternalEditApplied();
      });
    }
  }

  Future<String?> _showChoiceSheet({
    required String title,
    required String selected,
    required Map<String, (String, IconData)> choices,
  }) => showModalBottomSheet<String>(
    context: context,
    backgroundColor: _editorSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
    ),
    builder: (sheetContext) => SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _EditorSheetHeader(title: title),
            const SizedBox(height: 18),
            Row(
              children: choices.entries
                  .map(
                    (entry) => Expanded(
                      child: _ChoiceOption(
                        label: entry.value.$1,
                        icon: entry.value.$2,
                        selected: entry.key == selected,
                        onTap: () => Navigator.pop(sheetContext, entry.key),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    ),
  );

  void _selectRatio(VideoEditRatio ratio) {
    setState(() {
      _editState.selectRatio(ratio);
    });
  }

  Future<void> _discardSelectedClip() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('클립을 제거할까요?'),
        content: const Text('편집 타임라인에서만 제거되며 원본 영상은 삭제되지 않아요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('클립 제거'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      _editState.markSaved();
      Navigator.pop(context);
    }
  }

  Future<void> _saveEdit() async {
    if (_saving || _preview == null || _sourcePath == null) return;

    setState(() {
      _saving = true;
      _error = null;
      _status = '편집 영상을 렌더링하고 있어요';
    });

    try {
      final outputPath = await _exporter.exportEditedVideo(
        inputPath: _sourcePath!,
        outputPath: _buildOutputPath(),
        startMs: _editState.startMs,
        endMs: _editState.endMs,
        aspectRatio: _editState.previewAspectRatio,
        audioVolume: _audioVolume,
        captionText: _captionText,
        captionColor: _captionColor.toARGB32(),
        filter: _selectedFilter,
        arSticker: _arSticker,
        // 자른 구간 밖은 버리고 시각을 클립 기준으로 옮긴다. 전사가 실패했으면
        // 빈 목록이 되어 종전과 똑같이 저장된다.
        captions: _autoCaptions.forExport(
          startMs: _editState.startMs,
          endMs: _editState.endMs,
        ),
      );
      final file = File(outputPath);
      if (!await file.exists() || (await file.length()) == 0) {
        throw const VideoExportException('렌더링된 파일이 비어 있어요.');
      }
      await _exporter.saveToGallery(
        inputPath: outputPath,
        title: _safeTitle(widget.video.title),
      );
      if (!mounted) return;
      _editState.markSaved();
      setState(() {
        _saving = false;
        _status = '갤러리에 저장되었습니다';
      });
      showAppSnack(context, '갤러리에 저장되었습니다');
      Navigator.pop(context, SavedBanubaEdit(videoPath: outputPath));
    } on VideoExportException catch (failure) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$failure';
        _status = null;
      });
      showAppSnack(context, '$failure', error: true);
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = '$failure';
        _status = null;
      });
      showAppSnack(context, '$failure', error: true);
    }
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
    child: Scaffold(
      backgroundColor: _editorBackground,
      appBar: AppBar(
        toolbarHeight: 64,
        leadingWidth: 104,
        titleSpacing: 0,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        backgroundColor: _editorBackground,
        foregroundColor: AppColors.cream,
        centerTitle: true,
        leading: Row(
          children: [
            IconButton(
              tooltip: '닫기',
              onPressed: () => Navigator.maybePop(context),
              icon: const Icon(Icons.close_rounded, size: 30),
            ),
            if (_editorReady)
              IconButton(
                tooltip: '미리보기 확대',
                onPressed: _showFullscreenPreview,
                icon: const Icon(Icons.zoom_out_map_rounded, size: 25),
              ),
          ],
        ),
        title: _editorReady
            ? _RatioMenu(
                ratio: _editState.selectedRatio,
                onSelected: _selectRatio,
              )
            : const Text(
                '편집',
                style: TextStyle(
                  color: AppColors.cream,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
        actions: [
          if (_editorReady)
            Padding(
              padding: const EdgeInsets.only(right: 10),
              child: FilledButton(
                onPressed: _saving ? null : _saveEdit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.sage,
                  foregroundColor: AppColors.ink,
                  disabledBackgroundColor: _editorSurfaceRaised,
                  disabledForegroundColor: _editorMuted,
                  minimumSize: const Size(92, 46),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(15),
                  ),
                ),
                child: Text(
                  _saving ? '저장 중' : '내보내기',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? _preparing()
            : !_editorReady
            ? _failed()
            : _editorShell(),
      ),
    ),
  );

  Widget _preparing() => Column(
    children: [
      Expanded(
        child: Stack(
          fit: StackFit.expand,
          children: [
            const FamilyReferenceImage(borderRadius: 0),
            Container(color: Colors.black.withValues(alpha: 0.38)),
            Center(
              child: Container(
                width: 86,
                height: 86,
                decoration: const BoxDecoration(
                  color: Color(0xD91E211F),
                  shape: BoxShape.circle,
                ),
                padding: const EdgeInsets.all(25),
                child: const CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 3,
                ),
              ),
            ),
          ],
        ),
      ),
      Container(
        color: const Color(0xFF171918),
        padding: const EdgeInsets.fromLTRB(28, 26, 28, 34),
        child: Column(
          children: [
            Text(
              _status ?? '편집기를 준비하는 중이에요',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 14),
            LinearProgressIndicator(
              value: _progress == 0 ? null : _progress,
              color: AppColors.sage,
              backgroundColor: Colors.white24,
              borderRadius: BorderRadius.circular(10),
            ),
            const SizedBox(height: 12),
            const Text(
              '편집 전 영상과 타임라인을 불러온 뒤 바로 편집할 수 있어요.',
              style: TextStyle(color: Colors.white60, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ],
  );

  Widget _editorShell() {
    final preview = _preview!;
    final duration = preview.value.duration;
    final position = preview.value.position > duration
        ? duration
        : preview.value.position;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 690;
        return Column(
          children: [
            Expanded(
              child: ColoredBox(
                color: _editorBackground,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 24 : 34,
                    compact ? 2 : 8,
                    compact ? 24 : 34,
                    compact ? 2 : 8,
                  ),
                  child: Center(
                    child: _PreviewSurface(
                      controller: preview,
                      canvasAspectRatio: _editState.previewAspectRatio,
                      captionText: _captionText,
                      captionColor: _captionColor,
                      filter: _selectedFilter,
                      arSticker: _arSticker,
                      autoCaptionText: autoCaptionAt(
                        _autoCaptions,
                        preview.value.position.inMilliseconds,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _PreviewControlBar(
              playing: preview.value.isPlaying,
              currentTime: _time(position),
              totalTime: _time(duration),
              onPlay: _togglePlayback,
              onFullscreen: _showFullscreenPreview,
              onEffect: () => _selectTool('effect'),
            ),
            SizedBox(
              height: 176,
              child: _TrackTimeline(
                state: _editState,
                thumbnails: _thumbnails,
                position: position,
                duration: duration,
                onSeek: _seekToPosition,
                onStartChanged: (ms) => _updateTrim(startMs: ms),
                onEndChanged: (ms) => _updateTrim(endMs: ms),
                onAddClip: () => _selectTool('cut'),
                onAudio: () => _selectTool('audio'),
                onCaption: () => _selectTool('caption'),
                onClipSelected: () => setState(() => _clipSelected = true),
                captionApplied: _appliedTools.contains('caption'),
                audioApplied: _appliedTools.contains('audio'),
              ),
            ),
            _ToolToolbar(
              selectedTool: _selectedTool,
              onToolChanged: _selectTool,
              busy: _saving,
              clipSelected: _clipSelected,
              onCloseClipTools: () => setState(() => _clipSelected = false),
              onSplit: () => _selectTool('cut'),
              onVolume: _showAudioEditor,
              onAnimation: _showAnimationEditor,
              onEffect: _showEffectEditor,
              onDelete: _discardSelectedClip,
              onAr: _showArEditor,
            ),
          ],
        );
      },
    );
  }

  Future<void> _showFullscreenPreview() async {
    final preview = _preview;
    if (preview == null) return;
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      builder: (dialogContext) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: AspectRatio(
                  aspectRatio: preview.value.aspectRatio,
                  child: VideoPlayer(preview),
                ),
              ),
              Positioned(
                left: 12,
                top: 12,
                child: IconButton.filled(
                  tooltip: '미리보기 닫기',
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () => Navigator.pop(dialogContext),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
              Center(
                child: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: preview,
                  builder: (context, value, _) => IconButton.filled(
                    tooltip: value.isPlaying ? '일시정지' : '재생',
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black54,
                      foregroundColor: Colors.white,
                      iconSize: 40,
                    ),
                    onPressed: _togglePlayback,
                    icon: Icon(
                      value.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _updateTrim({int? startMs, int? endMs}) {
    setState(() {
      if (startMs != null) {
        _editState.updateTrimRange(startMs: startMs, endMs: _editState.endMs);
      }
      if (endMs != null) {
        _editState.updateTrimRange(startMs: _editState.startMs, endMs: endMs);
      }
      if (_preview != null && _preview!.value.isInitialized) {
        _preview!.seekTo(Duration(milliseconds: _editState.startMs));
      }
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

class _StickerOption extends StatelessWidget {
  const _StickerOption({
    required this.sticker,
    required this.selected,
    required this.onTap,
  });

  final String sticker;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(16),
    onTap: onTap,
    child: Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(
        color: selected
            ? AppColors.sage.withValues(alpha: 0.18)
            : _editorSurfaceRaised,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: selected ? AppColors.sage : Colors.transparent,
          width: 2,
        ),
      ),
      alignment: Alignment.center,
      child: sticker.isEmpty
          ? const Icon(Icons.block_rounded, color: _editorMuted)
          : Text(sticker, style: const TextStyle(fontSize: 30)),
    ),
  );
}

class _ChoiceOption extends StatelessWidget {
  const _ChoiceOption({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        height: 84,
        decoration: BoxDecoration(
          color: selected
              ? AppColors.sage.withValues(alpha: 0.18)
              : _editorSurfaceRaised,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppColors.sage : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: selected ? AppColors.sage : AppColors.cream),
            const SizedBox(height: 7),
            Text(
              label,
              style: TextStyle(
                color: selected ? AppColors.sage : _editorMuted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _PreviewSurface extends StatelessWidget {
  const _PreviewSurface({
    required this.controller,
    required this.canvasAspectRatio,
    required this.captionText,
    required this.captionColor,
    required this.filter,
    required this.arSticker,
    this.autoCaptionText,
  });

  final VideoPlayerController controller;
  final double canvasAspectRatio;
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
            aspectRatio: canvasAspectRatio,
            child: Container(
              constraints: BoxConstraints(
                maxWidth: availableWidth,
                maxHeight: availableHeight,
              ),
              decoration: BoxDecoration(
                color: Colors.black,
                border: Border.all(color: AppColors.sage, width: 2),
                borderRadius: BorderRadius.circular(18),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 22,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
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

class _RatioMenu extends StatelessWidget {
  const _RatioMenu({required this.ratio, required this.onSelected});

  final VideoEditRatio ratio;
  final ValueChanged<VideoEditRatio> onSelected;

  @override
  Widget build(BuildContext context) => Material(
    color: _editorSurfaceRaised,
    borderRadius: BorderRadius.circular(15),
    child: InkWell(
      borderRadius: BorderRadius.circular(15),
      onTap: () => _showRatioSheet(context),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.auto_awesome_rounded,
              size: 17,
              color: AppColors.sage,
            ),
            const SizedBox(width: 7),
            Text(
              'AI ${_ratioLabel(ratio)}',
              style: const TextStyle(
                color: AppColors.cream,
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: AppColors.cream,
            ),
          ],
        ),
      ),
    ),
  );

  Future<void> _showRatioSheet(BuildContext context) async {
    var pendingRatio = ratio;
    final selected = await showModalBottomSheet<VideoEditRatio>(
      context: context,
      backgroundColor: _editorSurface,
      barrierColor: Colors.black54,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          top: false,
          child: SizedBox(
            height: 292,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 42,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 150,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    children: VideoEditRatio.values
                        .map(
                          (option) => _RatioOption(
                            ratio: option,
                            selected: option == pendingRatio,
                            onTap: () =>
                                setSheetState(() => pendingRatio = option),
                          ),
                        )
                        .toList(),
                  ),
                ),
                const Divider(height: 1, color: Colors.white10),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 14, 18, 10),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '비율',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: AppColors.cream,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '비율 적용',
                          onPressed: () =>
                              Navigator.pop(sheetContext, pendingRatio),
                          color: AppColors.sage,
                          iconSize: 34,
                          icon: const Icon(Icons.check_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected != null) onSelected(selected);
  }

  static String _ratioLabel(VideoEditRatio ratio) => switch (ratio) {
    VideoEditRatio.original => '원본',
    VideoEditRatio.shortForm => '9:16',
    VideoEditRatio.square => '1:1',
    VideoEditRatio.landscape => '16:9',
    VideoEditRatio.classic => '4:3',
    VideoEditRatio.portrait => '3:4',
  };
}

class _RatioOption extends StatelessWidget {
  const _RatioOption({
    required this.ratio,
    required this.selected,
    required this.onTap,
  });

  final VideoEditRatio ratio;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final previewRatio = switch (ratio) {
      VideoEditRatio.original => 4 / 3,
      VideoEditRatio.shortForm => 9 / 16,
      VideoEditRatio.square => 1.0,
      VideoEditRatio.landscape => 16 / 9,
      VideoEditRatio.classic => 4 / 3,
      VideoEditRatio.portrait => 3 / 4,
    };
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: SizedBox(
            width: 86,
            child: Column(
              children: [
                Container(
                  width: 78,
                  height: 100,
                  decoration: BoxDecoration(
                    color: selected
                        ? AppColors.sage.withValues(alpha: 0.16)
                        : _editorSurfaceRaised,
                    borderRadius: BorderRadius.circular(17),
                    border: Border.all(
                      color: selected ? AppColors.sage : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                  child: Center(
                    child: SizedBox(
                      width: previewRatio >= 1 ? 48 : 34,
                      child: AspectRatio(
                        aspectRatio: previewRatio,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: selected
                                  ? AppColors.sage
                                  : AppColors.cream,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _RatioMenu._ratioLabel(ratio),
                  style: TextStyle(
                    color: selected ? AppColors.sage : _editorMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewControlBar extends StatelessWidget {
  const _PreviewControlBar({
    required this.playing,
    required this.currentTime,
    required this.totalTime,
    required this.onPlay,
    required this.onFullscreen,
    required this.onEffect,
  });

  final bool playing;
  final String currentTime;
  final String totalTime;
  final VoidCallback onPlay;
  final VoidCallback onFullscreen;
  final VoidCallback onEffect;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 50,
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned(
          left: 12,
          child: Row(
            children: [
              IconButton(
                tooltip: '미리보기 확대',
                onPressed: onFullscreen,
                color: AppColors.cream,
                icon: const Icon(Icons.fullscreen_rounded, size: 26),
              ),
              Text(
                '$currentTime / $totalTime',
                style: const TextStyle(
                  color: _editorMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: playing ? '일시정지' : '재생',
          onPressed: onPlay,
          color: AppColors.cream,
          iconSize: 34,
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        Positioned(
          right: 12,
          child: Row(
            children: [
              IconButton(
                tooltip: '효과 추가',
                onPressed: onEffect,
                color: AppColors.sage,
                icon: const Icon(Icons.auto_awesome_motion_rounded),
              ),
              const IconButton(
                tooltip: '실행 취소',
                onPressed: null,
                icon: Icon(Icons.undo_rounded, color: Colors.white24),
              ),
              const IconButton(
                tooltip: '다시 실행',
                onPressed: null,
                icon: Icon(Icons.redo_rounded, color: Colors.white24),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _TrackTimeline extends StatelessWidget {
  const _TrackTimeline({
    required this.state,
    required this.thumbnails,
    required this.position,
    required this.duration,
    required this.onSeek,
    required this.onStartChanged,
    required this.onEndChanged,
    required this.onAddClip,
    required this.onAudio,
    required this.onCaption,
    required this.onClipSelected,
    required this.captionApplied,
    required this.audioApplied,
  });

  final VideoEditState state;
  final List<String> thumbnails;
  final Duration position;
  final Duration duration;
  final ValueChanged<int> onSeek;
  final ValueChanged<int> onStartChanged;
  final ValueChanged<int> onEndChanged;
  final VoidCallback onAddClip;
  final VoidCallback onAudio;
  final VoidCallback onCaption;
  final VoidCallback onClipSelected;
  final bool captionApplied;
  final bool audioApplied;

  @override
  Widget build(BuildContext context) => Container(
    color: _editorSurface,
    padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
    child: LayoutBuilder(
      builder: (context, constraints) {
        const labelWidth = 54.0;
        const addWidth = 42.0;
        const gap = 8.0;
        final trackWidth =
            constraints.maxWidth - labelWidth - addWidth - gap * 2;
        final durationMs = duration.inMilliseconds;
        final progress = durationMs <= 0
            ? 0.0
            : (position.inMilliseconds / durationMs).clamp(0.0, 1.0);
        final playheadLeft = labelWidth + gap + trackWidth * progress;

        return Stack(
          children: [
            Column(
              children: [
                SizedBox(
                  height: 24,
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: labelWidth + gap,
                      right: addWidth + gap,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: List.generate(
                        3,
                        (index) => Text(
                          _formatTrackTime(durationMs * index ~/ 2),
                          style: const TextStyle(
                            color: _editorMuted,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 58,
                  child: Row(
                    children: [
                      const _TrackLabel(
                        icon: Icons.movie_creation_outlined,
                        label: '영상',
                      ),
                      const SizedBox(width: gap),
                      Expanded(
                        child: _TrimTimeline(
                          state: state,
                          thumbnails: thumbnails,
                          onTap: (milliseconds) {
                            onClipSelected();
                            onSeek(milliseconds);
                          },
                          onStartChanged: onStartChanged,
                          onEndChanged: onEndChanged,
                        ),
                      ),
                      const SizedBox(width: gap),
                      SizedBox.square(
                        dimension: addWidth,
                        child: IconButton.filled(
                          tooltip: '클립 추가',
                          onPressed: onAddClip,
                          style: IconButton.styleFrom(
                            backgroundColor: AppColors.cream,
                            foregroundColor: AppColors.ink,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          icon: const Icon(Icons.add_rounded, size: 29),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                _TrackActionRow(
                  icon: Icons.music_note_rounded,
                  label: '오디오',
                  hint: audioApplied ? '오디오 편집됨' : '+ 오디오 추가',
                  color: AppColors.sage,
                  onTap: onAudio,
                ),
                const SizedBox(height: 4),
                _TrackActionRow(
                  icon: Icons.title_rounded,
                  label: '자막',
                  hint: captionApplied ? '자막 편집됨' : '+ 자막 추가',
                  color: AppColors.coral,
                  onTap: onCaption,
                ),
              ],
            ),
            Positioned(
              left: playheadLeft,
              top: 20,
              bottom: 0,
              child: IgnorePointer(
                child: Column(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: AppColors.cream,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Expanded(
                      child: Container(width: 2, color: AppColors.cream),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  static String _formatTrackTime(int milliseconds) {
    final value = Duration(milliseconds: milliseconds);
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _TrackLabel extends StatelessWidget {
  const _TrackLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 54,
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 21, color: _editorMuted),
        const SizedBox(height: 2),
        Text(
          label,
          style: const TextStyle(
            color: _editorMuted,
            fontSize: 9,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _TrackActionRow extends StatelessWidget {
  const _TrackActionRow({
    required this.icon,
    required this.label,
    required this.hint,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String hint;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 36,
    child: Row(
      children: [
        _TrackLabel(icon: icon, label: label),
        const SizedBox(width: 8),
        Expanded(
          child: Material(
            color: color.withValues(alpha: 0.17),
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    hint,
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 50),
      ],
    ),
  );
}

class _TrimTimeline extends StatefulWidget {
  const _TrimTimeline({
    required this.state,
    required this.thumbnails,
    required this.onTap,
    required this.onStartChanged,
    required this.onEndChanged,
  });

  final VideoEditState state;
  final List<String> thumbnails;
  final ValueChanged<int> onTap;
  final ValueChanged<int> onStartChanged;
  final ValueChanged<int> onEndChanged;

  @override
  State<_TrimTimeline> createState() => _TrimTimelineState();
}

class _TrimTimelineState extends State<_TrimTimeline> {
  @override
  Widget build(BuildContext context) {
    final duration = widget.state.durationMs;
    final startRatio = duration <= 0 ? 0.0 : widget.state.startMs / duration;
    final endRatio = duration <= 0 ? 1.0 : widget.state.endMs / duration;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final startX = startRatio * width;
        final endX = endRatio * width;
        final selectionLeft = startX.clamp(0.0, width);
        final selectionRight = endX.clamp(0.0, width);
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTapDown: (details) {
                  final x = details.localPosition.dx.clamp(0.0, width);
                  final ms = ((x / width) * duration).round().clamp(
                    0,
                    duration,
                  );
                  widget.onTap(ms);
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF11100F),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: List.generate(
                      widget.thumbnails.isEmpty ? 6 : widget.thumbnails.length,
                      (index) {
                        final imagePath = widget.thumbnails.length > index
                            ? widget.thumbnails[index]
                            : null;
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 1),
                            child: imagePath == null
                                ? ColoredBox(
                                    color: index.isEven
                                        ? _editorSurfaceRaised
                                        : const Color(0xFF423A33),
                                  )
                                : Image.file(
                                    File(imagePath),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const SizedBox.expand(),
                                  ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: selectionLeft,
              right: width - selectionRight,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.sage, width: 3),
                    borderRadius: BorderRadius.circular(9),
                  ),
                ),
              ),
            ),
            Positioned(
              left: selectionLeft - 8,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onHorizontalDragUpdate: (details) {
                  final nextX = (selectionLeft + (details.primaryDelta ?? 0))
                      .clamp(0.0, width);
                  widget.onStartChanged(
                    ((nextX / width) * duration).round().clamp(0, duration),
                  );
                },
                child: Container(
                  width: 16,
                  decoration: BoxDecoration(
                    color: AppColors.cream,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.drag_handle_rounded,
                    size: 13,
                    color: AppColors.ink,
                  ),
                ),
              ),
            ),
            Positioned(
              left: selectionRight - 8,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onHorizontalDragUpdate: (details) {
                  final nextX = (selectionRight + (details.primaryDelta ?? 0))
                      .clamp(0.0, width);
                  widget.onEndChanged(
                    ((nextX / width) * duration).round().clamp(0, duration),
                  );
                },
                child: Container(
                  width: 16,
                  decoration: BoxDecoration(
                    color: AppColors.cream,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.drag_handle_rounded,
                    size: 13,
                    color: AppColors.ink,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ToolToolbar extends StatelessWidget {
  const _ToolToolbar({
    required this.selectedTool,
    required this.onToolChanged,
    required this.busy,
    required this.clipSelected,
    required this.onCloseClipTools,
    required this.onSplit,
    required this.onVolume,
    required this.onAnimation,
    required this.onEffect,
    required this.onDelete,
    required this.onAr,
  });

  final String selectedTool;
  final ValueChanged<String> onToolChanged;
  final bool busy;
  final bool clipSelected;
  final VoidCallback onCloseClipTools;
  final VoidCallback onSplit;
  final VoidCallback onVolume;
  final VoidCallback onAnimation;
  final VoidCallback onEffect;
  final VoidCallback onDelete;
  final VoidCallback onAr;

  @override
  Widget build(BuildContext context) {
    if (clipSelected) {
      return _ClipToolToolbar(
        busy: busy,
        onBack: onCloseClipTools,
        onSplit: onSplit,
        onVolume: onVolume,
        onAnimation: onAnimation,
        onEffect: onEffect,
        onDelete: onDelete,
        onAr: onAr,
      );
    }
    return Container(
      height: 80,
      decoration: const BoxDecoration(
        color: _editorSurfaceRaised,
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          _Tool(
            icon: Icons.content_cut_rounded,
            label: '분할',
            selected: selectedTool == 'cut',
            onTap: busy ? null : () => onToolChanged('cut'),
          ),
          _Tool(
            icon: Icons.subtitles_rounded,
            label: '자막',
            selected: selectedTool == 'caption',
            onTap: busy ? null : () => onToolChanged('caption'),
          ),
          _Tool(
            icon: Icons.volume_up_rounded,
            label: '오디오',
            selected: selectedTool == 'audio',
            onTap: busy ? null : () => onToolChanged('audio'),
          ),
          _Tool(
            icon: Icons.auto_awesome_rounded,
            label: '편집효과',
            selected: selectedTool == 'effect',
            onTap: busy ? null : () => onToolChanged('effect'),
          ),
          _Tool(
            icon: Icons.face_retouching_natural_rounded,
            label: 'AR',
            selected: selectedTool == 'ar',
            onTap: busy ? null : () => onToolChanged('ar'),
          ),
        ],
      ),
    );
  }
}

class _ClipToolToolbar extends StatelessWidget {
  const _ClipToolToolbar({
    required this.busy,
    required this.onBack,
    required this.onSplit,
    required this.onVolume,
    required this.onAnimation,
    required this.onEffect,
    required this.onDelete,
    required this.onAr,
  });

  final bool busy;
  final VoidCallback onBack;
  final VoidCallback onSplit;
  final VoidCallback onVolume;
  final VoidCallback onAnimation;
  final VoidCallback onEffect;
  final VoidCallback onDelete;
  final VoidCallback onAr;

  @override
  Widget build(BuildContext context) => Container(
    height: 92,
    decoration: const BoxDecoration(
      color: _editorSurfaceRaised,
      border: Border(top: BorderSide(color: Colors.white10)),
    ),
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 10, right: 6),
          child: SizedBox(
            width: 54,
            height: 72,
            child: IconButton.filled(
              tooltip: '기본 도구로 돌아가기',
              onPressed: busy ? null : onBack,
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFF4A443E),
                foregroundColor: AppColors.cream,
                disabledBackgroundColor: _editorSurface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.chevron_left_rounded, size: 34),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _ClipAction(
                icon: Icons.vertical_split_rounded,
                label: '분할',
                onTap: busy ? null : onSplit,
              ),
              _ClipAction(
                icon: Icons.volume_up_rounded,
                label: '볼륨',
                onTap: busy ? null : onVolume,
              ),
              _ClipAction(
                icon: Icons.animation_rounded,
                label: '애니메이션',
                onTap: busy ? null : onAnimation,
              ),
              _ClipAction(
                icon: Icons.auto_awesome_rounded,
                label: '편집효과',
                onTap: busy ? null : onEffect,
              ),
              _ClipAction(
                icon: Icons.delete_outline_rounded,
                label: '삭제',
                onTap: busy ? null : onDelete,
              ),
              _ClipAction(
                icon: Icons.face_retouching_natural_rounded,
                label: 'AR',
                accent: true,
                onTap: busy ? null : onAr,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _ClipAction extends StatelessWidget {
  const _ClipAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 70,
    child: InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 7),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: accent ? AppColors.sage : AppColors.cream,
                ),
                if (accent)
                  const Positioned(
                    right: -8,
                    top: -8,
                    child: Icon(
                      Icons.auto_awesome_rounded,
                      size: 13,
                      color: AppColors.sage,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                color: accent ? AppColors.sage : _editorMuted,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _Tool extends StatelessWidget {
  const _Tool({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Material(
      color: selected
          ? AppColors.sage.withValues(alpha: 0.16)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        borderRadius: BorderRadius.circular(15),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                color: selected ? AppColors.sage : AppColors.cream,
                size: 23,
              ),
              const SizedBox(height: 5),
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.sage : _editorMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
