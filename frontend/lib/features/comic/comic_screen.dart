/// 4컷 만화 만들기 화면.
///
/// 전사문(자막 기능이 만든 것)으로 구성을 받고, 대사를 고치고, 그림을 받아
/// 자막을 얹어 갤러리에 저장한다. 로직은 ComicController에 있고 여기는 화면만 본다.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../../app/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../ui/widgets.dart';
import 'comic_controller.dart';
import 'comic_gateway.dart';
import 'comic_script.dart';
import 'panel_subtitle.dart';

class ComicScreen extends StatefulWidget {
  const ComicScreen({
    super.key,
    required this.api,
    required this.video,
    this.controller,
  });

  final ApiClient api;
  final VideoMemory video;

  /// 주입되면 그대로 쓴다. 위젯 테스트가 가짜 상태를 넣는 통로다.
  final ComicController? controller;

  @override
  State<ComicScreen> createState() => _ComicScreenState();
}

class _ComicScreenState extends State<ComicScreen> {
  /// 화면을 PNG로 뜰 때 쓰는 경계.
  final _canvasKey = GlobalKey();

  /// 대사 입력칸은 화면이 소유한다 — 다이얼로그마다 만들어 닫힌 직후 dispose하면
  /// 리빌드가 죽은 컨트롤러를 만져 화면이 빈다(자막 작업에서 겪었다).
  final _dialogueField = TextEditingController();

  late final ComicController _controller =
      widget.controller ??
      ComicController(
        gateway: defaultComicGateway(widget.api),
        videoId: widget.video.id,
      );

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    // 빌드 페이즈 밖에서 시작한다.
    Future.microtask(_controller.start);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    if (widget.controller == null) _controller.dispose();
    _dialogueField.dispose();
    super.dispose();
  }

  Future<void> _editDialogue(int index) async {
    _dialogueField.text = _controller.cuts[index].dialogue ?? '';
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${index + 1}컷 대사'),
        content: TextField(
          key: const ValueKey('comic-dialogue-field'),
          controller: _dialogueField,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(hintText: '들린 그대로 적어 주세요'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, _dialogueField.text),
            child: const Text('넣기'),
          ),
        ],
      ),
    );
    if (text == null || !mounted) return;
    _controller.editDialogue(index, text);
  }

  /// 화면을 PNG로 떠서 공유 시트로 넘긴다. 거기서 '이미지 저장'으로 갤러리에
  /// 들어간다 — 갤러리 전용 플러그인을 새로 넣지 않는다.
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final boundary =
          _canvasKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('만화 영역을 찾지 못했어요.');
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('이미지로 바꾸지 못했어요.');

      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}comic_${widget.video.id}.png',
      );
      await file.writeAsBytes(data.buffer.asUint8List());

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: '${widget.video.title} 4컷 만화',
        ),
      );
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('4컷 만화 만들기')),
    body: SafeArea(child: _body()),
  );

  Widget _body() => switch (_controller.state) {
    ComicNeedsTranscript() => const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Text(
          '대사를 먼저 알아들어야 만화를 만들 수 있어요.\n'
          '영상 편집 화면에서 자막을 한 번 열어 주세요.',
          textAlign: TextAlign.center,
        ),
      ),
    ),
    ComicLoadingScript() => const _Busy('이야기를 짜고 있어요'),
    ComicLoadingImage() => const _Busy('그림을 그리고 있어요'),
    ComicScriptReady(:final cuts) => _cutList(cuts),
    ComicFailed(:final reason, :final cuts) => _failed(reason, cuts),
    ComicReady(:final cuts, :final image) => _finished(cuts, image),
  };

  Widget _cutList(List<ComicCut> cuts, {String? error}) => Column(
    children: [
      if (error != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(error, style: const TextStyle(color: AppColors.coral)),
        ),
      Expanded(
        child: ListView.builder(
          itemCount: cuts.length,
          itemBuilder: (_, index) => ListTile(
            key: ValueKey('comic-cut-$index'),
            leading: Text('${index + 1}컷'),
            title: Text(cuts[index].dialogue ?? '(대사 없음)'),
            subtitle: Text(cuts[index].scene),
            trailing: const Icon(Icons.edit_rounded, size: 18),
            onTap: () => _editDialogue(index),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('comic-make-image'),
            onPressed: _controller.makeImage,
            icon: const Icon(Icons.auto_awesome_rounded),
            label: Text(error == null ? '그림 만들기' : '다시 만들기'),
          ),
        ),
      ),
    ],
  );

  /// 구성이 남아 있으면 목록을 그대로 보여준다 — 고친 대사를 잃지 않는다.
  Widget _failed(String reason, List<ComicCut>? cuts) => cuts == null
      ? Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: EmptyState(
              icon: Icons.cloud_off_rounded,
              title: '만화를 만들지 못했어요',
              message: reason,
              action: FilledButton.icon(
                onPressed: _controller.start,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('다시 시도'),
              ),
            ),
          ),
        )
      : _cutList(cuts, error: reason);

  Widget _finished(List<ComicCut> cuts, Uint8List image) => Column(
    children: [
      Expanded(
        child: Center(
          child: RepaintBoundary(
            key: _canvasKey,
            child: ComicCanvas(image: image, cuts: cuts),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('comic-save'),
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.ios_share_rounded),
            label: Text(_saving ? '저장하는 중이에요' : '만화 저장하기'),
          ),
        ),
      ),
    ],
  );
}

class _Busy extends StatelessWidget {
  const _Busy(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(message),
      ],
    ),
  );
}
