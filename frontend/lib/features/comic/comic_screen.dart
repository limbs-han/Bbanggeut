/// 4컷 만화 만들기 화면.
///
/// 전사문(자막 기능이 만든 것)으로 구성을 받고, 대사를 고치고, 그림을 받아
/// 자막을 얹어 갤러리에 저장한다. 로직은 ComicController에 있고 여기는 화면만 본다.
library;

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/rendering.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../../app/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../core/video_source_cache.dart';
import '../../ui/widgets.dart';
import '../analysis/analysis_notice.dart';
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
    this.seed,
  });

  final ApiClient api;
  final VideoMemory video;

  /// 주입되면 그대로 쓴다. 위젯 테스트가 가짜 상태를 넣는 통로다.
  final ComicController? controller;

  /// 부르는 쪽이 이미 받아 둔 만화. 있으면 화면이 곧바로 완성 상태로 열린다.
  final ComicSeed? seed;

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
        seed: widget.seed,
        // 자막을 이 화면에서 만들 수 있게 원본 통로를 넘긴다. 편집 화면과 같은
        // 캐시를 쓰므로 이미 받아 둔 영상이면 곧바로 전사로 넘어간다.
        sourceProvider: (onProgress) => VideoSourceCache.ensure(
          api: widget.api,
          videoId: widget.video.id,
          onProgress: (received, total) {
            if (total > 0) onProgress(received * 100 ~/ total);
          },
        ),
      );

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    // 빌드 페이즈 밖에서 시작한다. open()은 전에 만들어 둔 만화가 있으면
    // 그것을 먼저 보여 주고, 없으면 구성부터 받는다.
    Future.microtask(_controller.open);
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
          // 자막 편집칸(caption_auto_section)과 같은 40자다. 같은 성격의 글을 담는데
          // 두 화면이 다른 길이를 쓰면 한쪽에서 고친 대사가 다른 쪽에서 잘린다.
          maxLength: 40,
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

  /// 자막이 얹힌 화면 그대로를 PNG 파일로 뜬다.
  Future<File> _renderPng() async {
    final boundary =
        _canvasKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
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
    return file;
  }

  /// 갤러리(빵긋 앨범)에 바로 저장한다. 영상 저장(VideoGallerySaver)과 같은
  /// gal 경로다 — 처음엔 공유 시트로 대신했더니 "저장하기"를 눌렀는데 공유가
  /// 열린다는 혼란만 남았다.
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final file = await _renderPng();
      // 안드로이드 10부터는 내 앱이 만든 그림을 넣는 데 권한이 필요 없다.
      // 권한 확인이 실패해도 저장은 그대로 시도한다(영상 저장과 같은 판단).
      try {
        if (!await Gal.hasAccess()) await Gal.requestAccess();
      } catch (_) {}
      await Gal.putImage(file.path, album: '빵긋');
      if (mounted) showAppSnack(context, '갤러리의 빵긋 앨범에 저장했어요.');
    } on GalException catch (failure) {
      if (mounted) showAppSnack(context, failure.type.message, error: true);
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 공유 시트를 연다. 저장과 별개 동작이다.
  Future<void> _share() async {
    setState(() => _saving = true);
    try {
      final file = await _renderPng();
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
    body: SafeArea(
      child: Column(
        children: [
          if (!comicServerReady) const _SampleNotice(),
          // 분석이 끝난 뒤에 만들면 만화 칸이 실제로 무슨 일이 있었던 순간에서
          // 나온다. 진행 중이면 프레임을 등분해 뽑으므로, 알려 주고 기다릴
          // 기회를 준다 — 예전에는 아무 표시가 없어서 사용자가 그 결과를 "AI가
          // 원래 이 정도"로 받아들였다.
          AnalysisNoticeBar(api: widget.api, videoId: widget.video.id),
          Expanded(child: _body()),
        ],
      ),
    ),
  );

  Widget _body() => switch (_controller.state) {
    ComicNeedsTranscript() => _needsTranscript(),
    ComicTranscribing(:final label, :final percent) => _Busy(
      label,
      percent: percent,
      hint: '들린 대사로 만화 이야기를 짜요.',
    ),
    ComicLoadingScript() => const _Busy('이야기를 짜고 있어요'),
    // 서버가 뒤에서 그린다 — 화면을 벗어나도 되고 끝나면 알림이 온다.
    ComicLoadingImage(:final queuePosition) => _Busy(
      queuePosition > 0
          ? '앞에 $queuePosition개가 있어요. 순서를 기다리는 중이에요'
          : '그림을 그리고 있어요',
      hint: '이 화면을 나가도 계속 만들어요. 다 되면 알림으로 알려 드려요.',
    ),
    ComicScriptReady(:final cuts) => _cutList(cuts),
    ComicFailed(:final reason, :final cuts) => _failed(reason, cuts),
    ComicReady(:final cuts, :final image, :final savedAt) => _finished(
      cuts,
      image,
      savedAt,
    ),
    ComicSaved(:final image, :final savedAt) => _saved(image, savedAt),
  };

  /// 자막이 없어 만화를 시작할 수 없다. **여기서 바로 만들 수 있게 한다.**
  ///
  /// 예전에는 "편집 화면에서 자막을 열어 주세요"라고만 적어 두었다. 만화를
  /// 만들려고 들어온 사람을 다른 화면으로 보내 놓고 돌아오게 하는 길이라,
  /// 실제로는 여기서 멈췄다.
  Widget _needsTranscript() => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: EmptyState(
        icon: Icons.graphic_eq_rounded,
        title: '먼저 대사를 알아들어야 해요',
        message: '영상에서 들린 말로 만화 이야기를 짜요. 몇 분 걸릴 수 있어요.',
        action: _controller.sourceProvider == null
            ? null
            : FilledButton.icon(
                key: const ValueKey('comic-make-transcript'),
                onPressed: _controller.transcribe,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: const Text('AI 자막 만들기'),
              ),
      ),
    ),
  );

  /// 전에 만들어 둔 만화인데 구성을 함께 받지 못했다(서버가 구성을 남기기 전에
  /// 만든 옛 만화). 대사를 되살리려면 구성을 새로 받아야 한다.
  Widget _saved(Uint8List image, DateTime? savedAt) => Column(
    children: [
      if (savedAt != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            '${DateFormat('M월 d일 HH:mm').format(savedAt.toLocal())}에 만든 만화',
            style: const TextStyle(fontSize: 12, color: AppColors.muted),
          ),
        ),
      // 자막 띠는 구성(cuts)이 있어야 얹는다. 이 만화는 구성이 없으므로
      // 그림만 보여 준다 — 서버가 만든 그림에는 대사가 그려져 있지 않다.
      Expanded(child: Center(child: Image.memory(image))),
      Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            key: const ValueKey('comic-remake'),
            onPressed: _controller.start,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('대사 고쳐 다시 만들기'),
          ),
        ),
      ),
    ],
  );

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

  /// 완성 화면에서 되돌아갈 두 길을 함께 둔다.
  ///
  /// 글자가 섞여 나오거나 격자가 2x2로 안 나오는 것은 앱이 막을 수 없다(설계의
  /// "막을 수 없다"). 그때 사용자가 하는 일이 다시 만들기 또는 대사 고치기다. 없으면
  /// 뒤로 나가야 하고, 그러면 컨트롤러가 사라져 고친 대사 네 줄이 전부 날아간다.
  Widget _finished(
    List<ComicCut> cuts,
    Uint8List image,
    DateTime? savedAt,
  ) => Column(
    children: [
      if (savedAt != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            '${DateFormat('M월 d일 HH:mm').format(savedAt.toLocal())}에 만든 만화',
            style: const TextStyle(fontSize: 12, color: AppColors.muted),
          ),
        ),
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
        child: Column(
          children: [
            // 한 줄에 둘씩. 셋을 한 줄에 두면 반폭보다 좁아져 "다시 만
            // 들기"처럼 글자가 꺾인다 — 실제 기기에서 확인한 문제다.
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('comic-save'),
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.download_rounded),
                    label: Text(_saving ? '잠시만요' : '저장하기'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('comic-share'),
                    onPressed: _saving ? null : _share,
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('공유하기'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('comic-remake'),
                    onPressed: _saving ? null : _controller.makeImage,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('다시 만들기'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('comic-edit-cuts'),
                    onPressed: _saving ? null : _controller.backToCuts,
                    icon: const Icon(Icons.edit_rounded),
                    label: const Text('수정하기'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );
}

/// 견본으로 돌릴 때 화면에 붙는 알림.
///
/// 가짜 통로는 고정된 대사와 색 블록 그림을 돌려준다. 알리지 않으면 사용자가 그것을
/// 자기 가족의 말과 그림으로 오해한다. 기본은 실서버라 보이지 않고,
/// `--dart-define=COMIC_SERVER=false`로 견본을 켤 때만 나타난다.
class _SampleNotice extends StatelessWidget {
  const _SampleNotice();

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('comic-sample-notice'),
    width: double.infinity,
    color: AppColors.yellowSoft,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: const Text(
      '아직 만화 서버가 준비되지 않아 견본을 보여드려요.\n'
      '여기 나오는 대사와 그림은 이 영상에서 만든 것이 아니에요.',
      style: TextStyle(fontSize: 12, color: AppColors.inkSoft),
    ),
  );
}

class _Busy extends StatelessWidget {
  const _Busy(this.message, {this.hint, this.percent});

  final String message;

  /// 기다리는 동안 알아야 할 것. 그림 생성은 화면을 나가도 계속된다.
  final String? hint;

  /// 실제 진행률(0~99). 모르는 단계면 null이고 표시가 흐르기만 한다 — 없는
  /// 숫자를 만들어 보여 주면 한 값에 붙어 멈춘 것처럼 보인다.
  final int? percent;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(
            value: percent == null ? null : percent! / 100,
          ),
          const SizedBox(height: 16),
          Text(
            percent == null ? message : '$message · $percent%',
            textAlign: TextAlign.center,
          ),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: AppColors.muted),
            ),
          ],
        ],
      ),
    ),
  );
}
