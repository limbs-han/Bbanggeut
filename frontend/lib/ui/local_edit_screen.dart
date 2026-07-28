import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import '../core/video_edit_state.dart';
import '../core/video_exporter.dart';
import 'widgets.dart';

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
  String? _status;
  String? _error;
  late VideoEditState _editState;
  String _selectedTool = 'cut';

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
      _error = null;
      _status = widget.openDrafts
          ? '저장된 편집 상태를 불러오고 있어요'
          : '이벤트 영상을 불러오고 있어요';
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
    setState(() {
      _selectedTool = tool;
      _editState.selectTool(tool);
    });
  }

  void _selectRatio(VideoEditRatio ratio) {
    setState(() {
      _editState.selectRatio(ratio);
    });
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
      setState(() {
        _saving = false;
        _status = '갤러리에 저장되었습니다';
      });
      showAppSnack(context, '갤러리에 저장되었습니다');
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

  String _buildOutputPath() {
    final directory = Directory(
      Platform.isAndroid ? '/storage/emulated/0/Android/data' : '',
    );
    final baseName = _safeTitle(widget.video.title);
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    return '${directory.path}${Platform.pathSeparator}${baseName}_$timestamp.mp4';
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
      backgroundColor: const Color(0xFF171918),
      appBar: AppBar(
        backgroundColor: AppColors.cream,
        foregroundColor: AppColors.ink,
        centerTitle: true,
        title: const Text('편집'),
        actions: [
          if (_editorReady)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: _saving ? null : _saveEdit,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.sageDark,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppColors.sage,
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                child: Text(_saving ? '저장 중' : '저장'),
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
    return Column(
      children: [
        Expanded(
          child: ColoredBox(
            color: const Color(0xFF111312),
            child: Center(child: _PreviewSurface(controller: preview)),
          ),
        ),
        Container(
          color: const Color(0xFF171918),
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 20),
          child: Column(
            children: [
              Row(
                children: [
                  Text(
                    _editState.isShortForm ? '9:16 숏폼' : '원본 비율',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  _AiCircleButton(
                    enabled: true,
                    onPressed: () => _selectRatio(
                      _editState.isShortForm
                          ? VideoEditRatio.original
                          : VideoEditRatio.shortForm,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  IconButton(
                    onPressed: _togglePlayback,
                    iconSize: 34,
                    color: Colors.white,
                    icon: Icon(
                      preview.value.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${_time(position)} / ${_time(duration)}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => _seekToPosition(_editState.startMs),
                    icon: const Icon(Icons.restart_alt_rounded),
                    color: Colors.white70,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _TrimTimeline(
                state: _editState,
                thumbnails: _thumbnails,
                onTap: (ms) => _seekToPosition(ms),
                onStartChanged: (ms) => _updateTrim(startMs: ms),
                onEndChanged: (ms) => _updateTrim(endMs: ms),
              ),
              const SizedBox(height: 12),
              _ToolToolbar(
                selectedTool: _selectedTool,
                onToolChanged: _selectTool,
                onSave: _saveEdit,
                saving: _saving,
              ),
              const SizedBox(height: 8),
              _ToolPanel(
                selectedTool: _selectedTool,
                state: _editState,
                onRatioChanged: _selectRatio,
              ),
            ],
          ),
        ),
      ],
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

class _PreviewSurface extends StatelessWidget {
  const _PreviewSurface({required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    final width = size.width <= 0 ? 1280.0 : size.width.toDouble();
    final height = size.height <= 0 ? 720.0 : size.height.toDouble();
    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth.clamp(260.0, double.infinity);
        final availableHeight = constraints.maxHeight.clamp(220.0, double.infinity);
        final targetAspect = width / height;
        final maxWidth = availableWidth - 24;
        final maxHeight = availableHeight - 24;
        final fittedWidth = maxWidth;
        final fittedHeight = fittedWidth / targetAspect;
        final finalHeight = fittedHeight > maxHeight ? maxHeight : fittedHeight;
        final finalWidth = finalHeight * targetAspect;
        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: finalWidth, maxHeight: finalHeight),
            child: AspectRatio(
              aspectRatio: targetAspect,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
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
        );
      },
    );
  }
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
        return Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatMs(widget.state.startMs), style: const TextStyle(color: Colors.white70, fontSize: 11)),
                Text(_formatMs(widget.state.endMs), style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 94,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onTapDown: (details) {
                        final x = details.localPosition.dx.clamp(0.0, width);
                        final ms = ((x / width) * duration).round().clamp(0, duration);
                        widget.onTap(ms);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF232725),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          children: [
                            Expanded(
                              child: Row(
                                children: List.generate(
                                  widget.thumbnails.isEmpty ? 6 : widget.thumbnails.length,
                                  (index) {
                                    final imagePath = widget.thumbnails.length > index ? widget.thumbnails[index] : null;
                                    return Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 2),
                                        child: imagePath == null
                                            ? Container(
                                                decoration: BoxDecoration(
                                                  color: const Color(0xFF3C443F),
                                                  borderRadius: BorderRadius.circular(10),
                                                ),
                                              )
                                            : ClipRRect(
                                                borderRadius: BorderRadius.circular(10),
                                                child: Image.file(
                                                  File(imagePath),
                                                  fit: BoxFit.cover,
                                                  errorBuilder: (_, _, _) => const SizedBox.expand(),
                                                ),
                                              ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: List.generate(5, (index) {
                                final point = duration * index ~/ 4;
                                return Text(
                                  _formatMs(point),
                                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                                );
                              }),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: selectionLeft,
                    right: width - selectionRight,
                    top: 6,
                    bottom: 6,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.sage, width: 2),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  Positioned(
                    left: selectionLeft - 12,
                    top: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onHorizontalDragUpdate: (details) {
                        final delta = details.primaryDelta ?? 0;
                        final nextX = (selectionLeft + delta).clamp(0.0, width);
                        final ms = ((nextX / width) * duration).round().clamp(0, duration);
                        widget.onStartChanged(ms);
                      },
                      child: Container(
                        width: 24,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: selectionRight - 12,
                    top: 0,
                    bottom: 0,
                    child: GestureDetector(
                      onHorizontalDragUpdate: (details) {
                        final delta = details.primaryDelta ?? 0;
                        final nextX = (selectionRight + delta).clamp(0.0, width);
                        final ms = ((nextX / width) * duration).round().clamp(0, duration);
                        widget.onEndChanged(ms);
                      },
                      child: Container(
                        width: 24,
                        decoration: BoxDecoration(
                          color: AppColors.sage,
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: selectionLeft,
                    top: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      child: Container(width: 2, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  String _formatMs(int value) {
    final duration = Duration(milliseconds: value);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _ToolToolbar extends StatelessWidget {
  const _ToolToolbar({
    required this.selectedTool,
    required this.onToolChanged,
    required this.onSave,
    required this.saving,
  });

  final String selectedTool;
  final ValueChanged<String> onToolChanged;
  final VoidCallback onSave;
  final bool saving;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _Tool(icon: Icons.crop_rounded, label: '컷', selected: selectedTool == 'cut', onTap: () => onToolChanged('cut')),
          _Tool(icon: Icons.text_fields_rounded, label: '자막', selected: selectedTool == 'caption', onTap: () => onToolChanged('caption')),
          _Tool(icon: Icons.music_note_rounded, label: '오디오', selected: selectedTool == 'audio', onTap: () => onToolChanged('audio')),
          _Tool(icon: Icons.auto_awesome_rounded, label: '효과', selected: selectedTool == 'effect', onTap: () => onToolChanged('effect')),
          _Tool(icon: Icons.view_in_ar_rounded, label: 'AR', selected: selectedTool == 'ar', onTap: () => onToolChanged('ar')),
        ],
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: saving ? null : onSave,
          icon: const Icon(Icons.save_alt_rounded),
          label: Text(saving ? '저장 중' : '갤러리에 저장'),
        ),
      ),
    ],
  );
}

class _ToolPanel extends StatelessWidget {
  const _ToolPanel({
    required this.selectedTool,
    required this.state,
    required this.onRatioChanged,
  });

  final String selectedTool;
  final VideoEditState state;
  final ValueChanged<VideoEditRatio> onRatioChanged;

  @override
  Widget build(BuildContext context) {
    if (selectedTool == 'cut') {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surfaceWarm,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('컷 편집', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('시작과 종료 지점을 조절해 원하는 구간만 저장해요. 현재 ${state.startMs}ms ~ ${state.endMs}ms', style: const TextStyle(color: AppColors.muted)),
          ],
        ),
      );
    }

    if (selectedTool == 'caption') {
      return _ToolMessage('자막은 Banuba SDK의 현재 API 범위에서 직접 연결이 어렵기 때문에, 다음 단계에서 내장 자막 편집으로 교체할 예정입니다.');
    }
    if (selectedTool == 'audio') {
      return _ToolMessage('오디오는 현재 앱 저장 흐름과 연결 중이며, 후속 작업에서 다이얼로그 기반 편집으로 연결할 예정입니다.');
    }
    if (selectedTool == 'effect') {
      return _ToolMessage('효과 기능은 현재 내부 export 로직으로 연결돼 있으며, Banuba 전용 UI는 사용하지 않도록 정리했습니다.');
    }
    return _ToolMessage('AR 기능은 Banuba SDK의 현재 버전에서 별도 커스텀 UI 연결이 제한되어 있어, 앱 내부 편집 흐름과 분리해 두었습니다.');
  }
}

class _ToolMessage extends StatelessWidget {
  const _ToolMessage(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: AppColors.surfaceWarm,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Text(message, style: const TextStyle(color: AppColors.inkSoft)),
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
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) => InkWell(
    borderRadius: BorderRadius.circular(16),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: selected ? AppColors.sageSoft : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              icon,
              color: AppColors.inkSoft,
              size: 27,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)
                .copyWith(color: AppColors.inkSoft),
          ),
        ],
      ),
    ),
  );
}

class _AiCircleButton extends StatelessWidget {
  const _AiCircleButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'AI 비율 변경',
    child: Material(
      color: enabled ? AppColors.sage : AppColors.sage.withValues(alpha: 0.5),
      shape: const CircleBorder(),
      elevation: 0,
      shadowColor: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onPressed : null,
        child: const SizedBox.square(
          dimension: 54,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                'AI',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Positioned(
                right: 10,
                top: 7,
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 14,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
