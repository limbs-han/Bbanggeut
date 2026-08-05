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
  _MemoryStore(this._saved, {List<CaptionLine> transcribed = const []})
    : super(
        transcriber: (_, [_]) async => transcribed,
        root: () async => Directory.systemTemp,
      );

  List<CaptionLine>? _saved;

  @override
  Future<List<CaptionLine>?> read(String videoId) async => _saved;

  @override
  Future<void> write(String videoId, List<CaptionLine> lines) async {
    _saved = lines;
  }
}

class _StubGateway implements ComicGateway {
  _StubGateway({this.scriptError, this.imageError, this.saved});

  final Object? scriptError;
  final Object? imageError;

  /// 서버가 들고 있는 작업 상태. null이면 만든 적이 없다.
  final ComicJobStatus? saved;
  List<ComicCut>? receivedCuts;

  /// 구성 요청 횟수. 화면을 다시 열 때 이것을 또 부르지 않는지 세어서 본다 —
  /// 그 호출은 과금이고, 새로 받으면 사용자가 고친 대사를 덮는다.
  int scriptCalls = 0;

  @override
  Future<List<ComicCut>> script(String videoId, List<CaptionLine> lines) async {
    scriptCalls++;
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
      saved ?? const ComicJobStatus(status: 'none');

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
    List<CaptionLine> transcribed = const [],
    Future<String> Function(void Function(int percent))? sourceProvider,
  }) => ComicController(
    gateway: gateway ?? _StubGateway(),
    videoId: 'v1',
    sourceProvider: sourceProvider,
    store: _MemoryStore(saved, transcribed: transcribed),
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

  // 나갔다 다시 들어왔을 때 **그림만 뜨고 대사가 사라지는** 문제. 서버는 구성을
  // 함께 주는데(script.json) 화면이 그것을 버리고 그림만 그리는 상태로 갔다.
  test('다시 열면 저장된 만화와 대사가 함께 나온다', () async {
    final gateway = _StubGateway(
      saved: ComicJobStatus(
        status: 'done',
        imageUrl: 'stub://comic',
        savedAt: DateTime.utc(2026, 8, 5, 12),
        cuts: [
          for (var i = 0; i < 4; i++)
            ComicCut(beat: '컷$i', scene: '장면$i', dialogue: '저장된 대사$i'),
        ],
      ),
    );
    final subject = controller(saved: _lines(), gateway: gateway);

    await subject.open();

    final state = subject.state;
    expect(state, isA<ComicReady>());
    expect((state as ComicReady).cuts, hasLength(4));
    expect(state.cuts[0].dialogue, '저장된 대사0');
    expect(state.savedAt, DateTime.utc(2026, 8, 5, 12));
    expect(gateway.scriptCalls, 0, reason: '구성을 다시 받으면 과금이고 고친 대사를 덮는다');
  });

  test('구성을 못 받은 옛 만화는 그림만 보여 준다', () async {
    final gateway = _StubGateway(
      saved: const ComicJobStatus(status: 'done', imageUrl: 'stub://comic'),
    );
    final subject = controller(saved: _lines(), gateway: gateway);

    await subject.open();

    expect(subject.state, isA<ComicSaved>());
    expect(gateway.scriptCalls, 0);
  });

  // 자막이 없을 때 이 화면에서 바로 만든다 — 편집 화면으로 보내지 않는다.
  test('자막을 만들면 이어서 구성까지 받는다', () async {
    var progress = <int>[];
    final subject = controller(
      transcribed: _lines(),
      sourceProvider: (onProgress) async {
        onProgress(40);
        return '/video/v1.mp4';
      },
    );
    subject.addListener(() {
      final state = subject.state;
      if (state is ComicTranscribing && state.percent != null) {
        progress.add(state.percent!);
      }
    });

    await subject.transcribe();

    expect(subject.state, isA<ComicScriptReady>());
    expect(subject.cuts, hasLength(4));
    expect(progress, contains(40), reason: '내려받기 진행률이 화면에 보여야 한다');
  });

  test('원본을 못 받으면 사유를 남긴다', () async {
    final subject = controller(
      transcribed: _lines(),
      sourceProvider: (_) async => throw StateError('연결 실패'),
    );

    await subject.transcribe();

    expect(subject.state, isA<ComicFailed>());
    expect((subject.state as ComicFailed).reason, contains('연결 실패'));
  });

  test('원본 통로가 없으면 자막 만들기는 아무 일도 하지 않는다', () async {
    final subject = controller();
    await subject.start();

    await subject.transcribe();

    expect(subject.state, isA<ComicNeedsTranscript>());
  });
}
