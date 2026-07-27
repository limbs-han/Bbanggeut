import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/banuba_video_editor.dart';
import '../core/models.dart';
import '../core/portrait_video_canvas.dart';
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
  final _editor = BanubaVideoEditor();
  final _portraitCanvas = PortraitVideoCanvas();
  VideoPlayerController? _preview;
  String? _sourcePath;
  double _progress = 0;
  bool _loading = true;
  bool _launching = false;
  String? _status;
  String? _error;
  SavedBanubaEdit? _savedEdit;

  bool get _editorReady =>
      _sourcePath != null && _preview?.value.isInitialized == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _prepare());
  }

  Future<void> _prepare() async {
    setState(() {
      _loading = true;
      _error = null;
      _status = widget.openDrafts
          ? '저장된 초안을 불러오는 중이에요'
          : '이벤트 영상을 안전하게 불러오는 중이에요';
    });

    if (widget.openDrafts) {
      await _openDrafts();
      return;
    }

    try {
      final sourcePath = await _downloadSource();
      final preview = VideoPlayerController.file(File(sourcePath));
      await preview.initialize();
      preview.addListener(_onPreviewChanged);
      if (!mounted) {
        await preview.dispose();
        return;
      }
      setState(() {
        _sourcePath = sourcePath;
        _preview = preview;
        _loading = false;
        _status = null;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$failure';
      });
    }
  }

  Future<void> _openDrafts() async {
    setState(() => _launching = true);
    try {
      final result = await _editor.openDrafts(
        outputName: _safeTitle(widget.video.title),
      );
      if (!mounted) return;
      if (result == null) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        _loading = false;
        _launching = false;
        _savedEdit = result;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _launching = false;
        _error = '$failure';
      });
    }
  }

  Future<void> _launchEditor({bool enableAiCaptions = false}) async {
    if (!await _canLaunchEditor()) return;
    final sourcePath = _sourcePath!;
    await _preview?.pause();
    if (!mounted) return;
    setState(() {
      _launching = true;
      _error = null;
    });

    try {
      final result = await _editor.edit(
        sourcePaths: [sourcePath],
        outputName: _safeTitle(widget.video.title),
        enableAiCaptions: enableAiCaptions,
      );
      if (!mounted) return;
      setState(() {
        _launching = false;
        _savedEdit = result;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _launching = false;
        _error = '$failure';
      });
      showAppSnack(context, '$failure', error: true);
    }
  }

  Future<void> _launchPortraitAiEdit() async {
    if (!await _canLaunchEditor()) return;
    final sourcePath = _sourcePath!;
    await _preview?.pause();
    if (!mounted) return;
    setState(() {
      _launching = true;
      _error = null;
      _status = '위·아래 여백을 넣어 9:16 AI 영상을 만드는 중이에요';
    });

    try {
      final portraitPath = await _portraitCanvas.fitToNineBySixteen(
        inputPath: sourcePath,
        outputName: _safeTitle(widget.video.title),
      );
      if (!mounted) return;
      setState(() => _status = 'Banuba AI 편집기를 여는 중이에요');

      final result = await _editor.aiEdit(
        sourcePaths: [portraitPath],
        outputName: '${_safeTitle(widget.video.title)}_ai',
      );
      if (!mounted) return;
      setState(() {
        _launching = false;
        _status = null;
        _savedEdit = result;
      });
    } catch (failure) {
      if (!mounted) return;
      setState(() {
        _launching = false;
        _status = null;
        _error = '$failure';
      });
      showAppSnack(context, '$failure', error: true);
    }
  }

  Future<bool> _canLaunchEditor() async {
    if (_launching) return false;
    final configured = await _editor.isConfigured;
    if (!mounted) return false;
    if (!configured) {
      showAppSnack(
        context,
        'Banuba 토큰이 적용되지 않았어요. 토큰 설정으로 앱을 다시 실행해 주세요.',
        error: true,
      );
      return false;
    }
    if (_sourcePath == null) {
      showAppSnack(context, '영상을 불러오는 중이에요. 잠시만 기다려 주세요.');
      return false;
    }
    return true;
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
    if (mounted) setState(() {});
  }

  Future<void> _togglePlayback() async {
    final preview = _preview;
    if (preview == null) return;
    if (preview.value.isPlaying) {
      await preview.pause();
    } else {
      if (preview.value.position >= preview.value.duration) {
        await preview.seekTo(Duration.zero);
      }
      await preview.play();
    }
  }

  Future<void> _seek(double milliseconds) async {
    await _preview?.seekTo(Duration(milliseconds: milliseconds.round()));
  }

  String _safeTitle(String title) {
    final value = title.replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]'), '_');
    return value.isEmpty ? 'bbanggeut_edit' : value;
  }

  String _time(Duration value) {
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Future<void> _share() async {
    final result = _savedEdit;
    if (result == null) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(result.videoPath)],
        text: '${widget.video.title} 편집본',
      ),
    );
  }

  void _retry() {
    _progress = 0;
    widget.openDrafts ? _openDrafts() : _prepare();
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
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF171918),
    appBar: AppBar(
      backgroundColor: AppColors.cream,
      foregroundColor: AppColors.ink,
      centerTitle: true,
      title: const Text('편집'),
      actions: [
        if (_editorReady || _savedEdit != null)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton(
              onPressed: _launching
                  ? null
                  : _savedEdit != null
                  ? () => Navigator.pop(context, _savedEdit)
                  : _launchEditor,
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.sageDark,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppColors.sage,
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
              child: Text(_savedEdit != null ? '완료' : '저장'),
            ),
          ),
      ],
    ),
    body: SafeArea(
      child: _savedEdit != null
          ? _completed()
          : _loading
          ? _preparing()
          : _launching && _status != null
          ? _aiPreparing()
          : !_editorReady
          ? _failed()
          : _editorShell(),
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
              value: widget.openDrafts || _progress == 0 ? null : _progress,
              color: AppColors.sage,
              backgroundColor: Colors.white24,
              borderRadius: BorderRadius.circular(10),
            ),
            const SizedBox(height: 12),
            const Text(
              '불러오기가 끝나면 영상 미리보기와 AI 편집 버튼이 열려요.',
              style: TextStyle(color: Colors.white60, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
      _EditorToolbar(onTap: _launchEditor, enabled: false),
    ],
  );

  Widget _aiPreparing() => Column(
    children: [
      Expanded(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_preview != null)
              Center(child: _NineBySixteenPreview(controller: _preview!))
            else
              const ColoredBox(color: Colors.black),
            ColoredBox(color: Colors.black.withValues(alpha: 0.45)),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox.square(
                    dimension: 42,
                    child: CircularProgressIndicator(
                      color: AppColors.sage,
                      strokeWidth: 4,
                    ),
                  ),
                  const SizedBox(height: 18),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Text(
                      _status ?? 'AI 영상을 준비하는 중이에요',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      _EditorToolbar(onTap: _launchEditor, enabled: false),
    ],
  );

  Widget _editorShell() {
    final preview = _preview!;
    final duration = preview.value.duration;
    final position = preview.value.position > duration
        ? duration
        : preview.value.position;
    final maxMilliseconds = duration.inMilliseconds <= 0
        ? 1.0
        : duration.inMilliseconds.toDouble();

    return Column(
      children: [
        Expanded(
          child: ColoredBox(
            color: const Color(0xFF111312),
            child: Center(child: _NineBySixteenPreview(controller: preview)),
          ),
        ),
        Container(
          height: 302,
          color: const Color(0xFF171918),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: _AiCircleButton(
                  enabled: !_launching,
                  onPressed: _launchPortraitAiEdit,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    onPressed: _togglePlayback,
                    iconSize: 38,
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
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Icon(
                    Icons.undo_rounded,
                    size: 30,
                    color: Colors.white38,
                  ),
                  const SizedBox(width: 20),
                  const Icon(
                    Icons.redo_rounded,
                    size: 30,
                    color: Colors.white38,
                  ),
                ],
              ),
              const Divider(color: Colors.white12, height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: List.generate(5, (index) {
                  final point = duration.inMilliseconds * index ~/ 4;
                  return Text(
                    _time(Duration(milliseconds: point)),
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  );
                }),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 72,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Row(
                        children: List.generate(
                          5,
                          (_) => const Expanded(
                            child: FamilyReferenceImage(borderRadius: 0),
                          ),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: Colors.transparent,
                          inactiveTrackColor: Colors.transparent,
                          trackHeight: 72,
                          thumbColor: AppColors.cream,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 8,
                          ),
                          overlayShape: SliderComponentShape.noOverlay,
                        ),
                        child: Slider(
                          min: 0,
                          max: maxMilliseconds,
                          value: position.inMilliseconds
                              .clamp(0, maxMilliseconds)
                              .toDouble(),
                          onChanged: _seek,
                        ),
                      ),
                    ),
                    IgnorePointer(
                      child: Container(
                        width: 3,
                        height: 88,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '도구를 선택하면 Banuba 고급 편집기가 열려요',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
        _EditorToolbar(onTap: _launchEditor, enabled: !_launching),
      ],
    );
  }

  Widget _completed() => Column(
    children: [
      Expanded(
        child: ColoredBox(
          color: const Color(0xFF111312),
          child: Center(
            child: _preview == null
                ? const FamilyReferenceImage(borderRadius: 0)
                : _NineBySixteenPreview(controller: _preview!),
          ),
        ),
      ),
      Container(
        color: const Color(0xFF171918),
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 30),
        child: Column(
          children: [
            const Icon(
              Icons.check_circle_rounded,
              color: AppColors.sage,
              size: 54,
            ),
            const SizedBox(height: 12),
            const Text(
              '편집 영상 저장 완료',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '앱 저장소의 edited_videos 폴더에 MP4로 보관했어요.',
              style: TextStyle(color: Colors.white60),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _share,
                icon: const Icon(Icons.ios_share_rounded),
                label: const Text('편집 영상 공유하기'),
              ),
            ),
          ],
        ),
      ),
      _EditorToolbar(onTap: _launchEditor),
    ],
  );

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

class _NineBySixteenPreview extends StatelessWidget {
  const _NineBySixteenPreview({required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    return AspectRatio(
      aspectRatio: 9 / 16,
      child: ColoredBox(
        color: Colors.black,
        child: Center(
          child: FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: size.width <= 0 ? 16 : size.width,
              height: size.height <= 0 ? 9 : size.height,
              child: VideoPlayer(controller),
            ),
          ),
        ),
      ),
    );
  }
}

class _AiCircleButton extends StatelessWidget {
  const _AiCircleButton({required this.enabled, required this.onPressed});

  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'AI 효과 편집',
    child: Material(
      color: enabled ? AppColors.sage : AppColors.sage.withValues(alpha: 0.5),
      shape: const CircleBorder(),
      elevation: 0,
      shadowColor: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onPressed : null,
        child: const SizedBox.square(
          dimension: 66,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                'AI',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Positioned(
                right: 12,
                top: 9,
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 15,
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

class _EditorToolbar extends StatelessWidget {
  const _EditorToolbar({required this.onTap, this.enabled = true});

  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Container(
    height: 106,
    color: AppColors.cream,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        _Tool(
          icon: Icons.crop_rounded,
          label: '자르기',
          selected: true,
          onTap: enabled ? onTap : null,
        ),
        _Tool(
          icon: Icons.text_fields_rounded,
          label: '자막',
          onTap: enabled ? onTap : null,
        ),
        _Tool(
          icon: Icons.music_note_rounded,
          label: '오디오',
          onTap: enabled ? onTap : null,
        ),
        _Tool(
          icon: Icons.auto_awesome_rounded,
          label: '효과',
          onTap: enabled ? onTap : null,
        ),
        _Tool(
          icon: Icons.view_in_ar_rounded,
          label: 'AR',
          onTap: enabled ? onTap : null,
        ),
      ],
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
              color: selected && onTap != null
                  ? AppColors.sageSoft
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              icon,
              color: onTap == null ? AppColors.muted : AppColors.inkSoft,
              size: 27,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)
                .copyWith(
                  color: onTap == null ? AppColors.muted : AppColors.inkSoft,
                ),
          ),
        ],
      ),
    ),
  );
}
