/// 만화 상태 전이.
/// 이미지 요청이 실패해도 고친 대사를 잃지 않아야 한다 — 다시 만들 때 그대로 써야
/// 하고, 잃으면 사용자가 처음부터 다시 고쳐야 한다.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/comic/comic_controller.dart';
import 'package:william_james_app/features/comic/comic_gateway.dart';
import 'package:william_james_app/features/comic/comic_script.dart';
import 'package:william_james_app/features/stt/caption_line.dart';
import 'package:william_james_app/features/stt/transcript_store.dart';

/// 파일을 만들지 않는 저장소 (stt 테스트와 같은 이유 — 실제 입출력은 거기서 검증).
class _MemoryStore extends TranscriptStore {
  _MemoryStore(this._saved)
    : super(
        transcriber: (_) async => const [],
        root: () async => Directory.systemTemp,
      );

  final List<CaptionLine>? _saved;

  @override
  Future<List<CaptionLine>?> read(String videoId) async => _saved;
}

class _StubGateway implements ComicGateway {
  _StubGateway({this.scriptError, this.imageError});

  final Object? scriptError;
  final Object? imageError;
  List<ComicCut>? receivedCuts;

  @override
  Future<List<ComicCut>> script(String videoId, List<CaptionLine> lines) async {
    if (scriptError != null) throw scriptError!;
    return [
      for (var i = 0; i < 4; i++)
        ComicCut(beat: '컷$i', scene: '장면$i', dialogue: '대사$i'),
    ];
  }

  @override
  Future<Uint8List> image(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async {
    receivedCuts = cuts;
    if (imageError != null) throw imageError!;
    return Uint8List.fromList([9, 9, 9]);
  }

  @override
  Future<ComicJobStatus> enqueueImage(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async {
    receivedCuts = cuts;
    if (imageError != null) throw imageError!;
    return const ComicJobStatus(status: 'done', imageUrl: 'stub://comic');
  }

  @override
  Future<ComicJobStatus> jobStatus(String videoId) async =>
      const ComicJobStatus(status: 'none');

  @override
  Future<Uint8List> download(String imageUrl) async =>
      Uint8List.fromList([9, 9, 9]);
}

List<CaptionLine> _lines() => [
  CaptionLine(startMs: 1000, endMs: 3000, text: '그거 만지지 마'),
];

void main() {
  ComicController controller({
    List<CaptionLine>? saved,
    _StubGateway? gateway,
  }) => ComicController(
    gateway: gateway ?? _StubGateway(),
    videoId: 'v1',
    store: _MemoryStore(saved),
  );

  test('전사문이 없으면 만들 수 없다고 알린다', () async {
    final subject = controller();
    await subject.start();

    expect(subject.state, isA<ComicNeedsTranscript>());
    expect(subject.cuts, isEmpty);
  });

  test('전사문이 있으면 구성을 받아 온다', () async {
    final subject = controller(saved: _lines());
    var notified = 0;
    subject.addListener(() => notified++);

    await subject.start();

    expect(subject.state, isA<ComicScriptReady>());
    expect(subject.cuts, hasLength(4));
    expect(notified, greaterThan(0));
  });

  test('구성 요청이 실패하면 사유를 남긴다', () async {
    final subject = controller(
      saved: _lines(),
      gateway: _StubGateway(scriptError: StateError('서버 없음')),
    );
    await subject.start();

    expect(subject.state, isA<ComicFailed>());
    expect((subject.state as ComicFailed).reason, contains('서버 없음'));
  });

  test('대사를 고치면 구성에 반영된다', () async {
    final subject = controller(saved: _lines());
    await subject.start();

    subject.editDialogue(0, '고친 대사');

    expect(subject.cuts[0].dialogue, '고친 대사');
  });

  test('대사를 지우면 null이 된다 — 자막 띠를 그리지 않는다', () async {
    final subject = controller(saved: _lines());
    await subject.start();

    subject.editDialogue(0, '   ');

    expect(subject.cuts[0].dialogue, isNull);
  });

  test('없는 컷을 고치라고 해도 죽지 않는다', () async {
    final subject = controller(saved: _lines());
    await subject.start();

    subject.editDialogue(9, '아무거나');

    expect(subject.cuts, hasLength(4));
  });

  test('그림을 받으면 완료가 된다', () async {
    final subject = controller(saved: _lines());
    await subject.start();
    await subject.makeImage();

    expect(subject.state, isA<ComicReady>());
    expect((subject.state as ComicReady).image, [9, 9, 9]);
  });

  test('그림 요청은 고친 대사를 그대로 보낸다', () async {
    final gateway = _StubGateway();
    final subject = controller(saved: _lines(), gateway: gateway);
    await subject.start();
    subject.editDialogue(0, '고친 대사');

    await subject.makeImage();

    expect(gateway.receivedCuts![0].dialogue, '고친 대사');
  });

  test('그림 요청이 실패해도 고친 대사를 잃지 않는다', () async {
    final subject = controller(
      saved: _lines(),
      gateway: _StubGateway(imageError: StateError('생성 실패')),
    );
    await subject.start();
    subject.editDialogue(0, '고친 대사');

    await subject.makeImage();

    expect(subject.state, isA<ComicFailed>());
    expect(subject.cuts[0].dialogue, '고친 대사', reason: '다시 만들 때 써야 한다');
  });

  test('구성 없이 그림을 만들라고 하면 아무 일도 하지 않는다', () async {
    final gateway = _StubGateway();
    final subject = controller(gateway: gateway);
    await subject.start();

    await subject.makeImage();

    expect(gateway.receivedCuts, isNull);
  });
}
