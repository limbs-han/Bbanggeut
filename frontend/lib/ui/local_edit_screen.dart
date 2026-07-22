import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_trimmer/video_trimmer.dart';

import '../app/app_controller.dart';
import '../app/app_theme.dart';
import '../core/models.dart';
import 'widgets.dart';

class LocalEditScreen extends StatefulWidget {
  const LocalEditScreen({
    super.key,
    required this.controller,
    required this.video,
  });
  final AppController controller;
  final VideoMemory video;
  @override
  State<LocalEditScreen> createState() => _LocalEditScreenState();
}

class _LocalEditScreenState extends State<LocalEditScreen> {
  final trimmer = Trimmer();
  double startValue = 0;
  double endValue = 0;
  double progress = 0;
  bool loading = true;
  bool saving = false;
  bool playing = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final signed = await widget.controller.api.createDownloadUrl(
        widget.video.id,
      );
      final temporary = await getTemporaryDirectory();
      final input = File('${temporary.path}/wj-${widget.video.id}.mp4');
      await Dio().download(
        signed.url,
        input.path,
        onReceiveProgress: (received, total) {
          if (mounted && total > 0) setState(() => progress = received / total);
        },
      );
      await trimmer.loadVideo(videoFile: input);
      endValue = trimmer.videoPlayerController!.value.duration.inMilliseconds
          .toDouble();
      if (mounted) {
        setState(() => loading = false);
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$failure';
        });
      }
    }
  }

  Future<void> _save() async {
    setState(() => saving = true);
    final completer = Completer<String?>();
    await trimmer.saveTrimmedVideo(
      startValue: startValue,
      endValue: endValue,
      videoFolderName: 'WilliamJames',
      videoFileName:
          '${widget.video.title.replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]'), '_')}_${DateTime.now().millisecondsSinceEpoch}',
      onSave: completer.complete,
    );
    final output = await completer.future;
    if (!mounted) return;
    setState(() => saving = false);
    if (output == null) {
      showAppSnack(context, '편집본을 만들지 못했어요.', error: true);
      return;
    }
    await SharePlus.instance.share(
      ShareParams(files: [XFile(output)], text: '${widget.video.title} 편집본'),
    );
  }

  @override
  void dispose() {
    trimmer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('기기에서 구간 편집')),
    body: SafeArea(
      child: loading
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 18),
                    Text(
                      '안전한 원본을 내려받는 중이에요',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 10),
                    LinearProgressIndicator(
                      value: progress == 0 ? null : progress,
                    ),
                  ],
                ),
              ),
            )
          : error != null
          ? EmptyState(
              icon: Icons.cloud_off_rounded,
              title: '편집을 준비하지 못했어요',
              message: error!,
              action: FilledButton(
                onPressed: () {
                  setState(() {
                    loading = true;
                    error = null;
                  });
                  _prepare();
                },
                child: const Text('다시 시도'),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: Container(
                    color: AppColors.ink,
                    child: VideoViewer(trimmer: trimmer),
                  ),
                ),
                Container(
                  color: AppColors.cream,
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                  child: Column(
                    children: [
                      TrimViewer(
                        trimmer: trimmer,
                        viewerHeight: 62,
                        viewerWidth: MediaQuery.sizeOf(context).width - 40,
                        maxVideoLength: const Duration(minutes: 10),
                        onChangeStart: (value) => startValue = value,
                        onChangeEnd: (value) => endValue = value,
                        onChangePlaybackState: (value) =>
                            setState(() => playing = value),
                        editorProperties: const TrimEditorProperties(
                          borderPaintColor: AppColors.primary,
                          borderWidth: 4,
                          circlePaintColor: AppColors.peach,
                        ),
                        areaProperties: TrimAreaProperties(
                          thumbnailQuality: 55,
                        ),
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final state = await trimmer.videoPlaybackControl(
                            startValue: startValue,
                            endValue: endValue,
                          );
                          setState(() => playing = state);
                        },
                        icon: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        label: Text(playing ? '미리보기 멈춤' : '선택 구간 미리보기'),
                      ),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        onPressed: saving ? null : _save,
                        icon: saving
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.ios_share_rounded),
                        label: Text(saving ? '편집본 만드는 중' : '편집본 만들고 저장·공유'),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '편집 결과는 이 기기에만 생성되며 서버에 다시 저장되지 않습니다.',
                        style: TextStyle(fontSize: 12, color: AppColors.muted),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ],
            ),
    ),
  );
}
