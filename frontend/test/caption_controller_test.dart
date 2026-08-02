/// CaptionController 회귀 테스트.
/// 화면은 이 클래스를 부르기만 한다. 상태 전이와 안내 문구가 여기서 다 결정되므로
/// 화면을 띄우지 않고 전부 검증할 수 있다.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/stt/caption_controller.dart';
import 'package:william_james_app/features/stt/caption_line.dart';
import 'package:william_james_app/features/stt/transcript_store.dart';

List<CaptionLine> _lines() => [
  CaptionLine(startMs: 1000, endMs: 3000, text: '그거 만지지 마'),
  CaptionLine(startMs: 5000, endMs: 7000, text: '안 만졌는데요'),
];

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('caption-controller-');
  });

  tearDown(() async {
    if (temporary.existsSync()) await temporary.delete(recursive: true);
  });

  TranscriptStore storeWith(VideoTranscriber transcriber) => TranscriptStore(
    transcriber: transcriber,
    root: () async => temporary,
  );

  CaptionController controllerWith(VideoTranscriber transcriber) =>
      CaptionController(store: storeWith(transcriber));

  test('시작 전에는 상태가 없고 줄도 없다', () {
    final subject = controllerWith((_) async => _lines());
    expect(subject.status, isNull);
    expect(subject.lines, isEmpty);
    expect(subject.message(), contains('준비'));
  });

  test('전사가 끝나면 줄이 들어오고 알림이 간다', () async {
    final store = storeWith((_) async => _lines());
    final subject = CaptionController(store: store);
    var notified = 0;
    subject.addListener(() => notified++);

    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    expect(subject.lines, hasLength(2));
    expect(subject.status, isA<TranscriptReady>());
    expect(notified, greaterThan(0));
    expect(subject.message(), contains('2줄'));
  });

  test('두 번 시작해도 전사는 한 번만 돈다', () async {
    var calls = 0;
    final store = storeWith((_) async {
      calls++;
      return _lines();
    });
    final subject = CaptionController(store: store);

    subject.start('v1', '/video/v1.mp4');
    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    expect(calls, 1);
  });

  test('전사가 실패해도 줄은 비고 상태만 실패가 된다', () async {
    final store = storeWith((_) async => throw StateError('모델 없음'));
    final subject = CaptionController(store: store);

    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    expect(subject.lines, isEmpty);
    expect(subject.status, isA<TranscriptFailed>());
  });

  test('연결·서버 실패와 무발화를 다른 문구로 안내한다', () async {
    // 비행기 모드인 사람에게 "대사를 못 알아들었어요"라고 하면 영상 탓으로 안다.
    final broken = storeWith((_) async => throw StateError('연결 안 됨'));
    final failed = CaptionController(store: broken);
    failed.start('v1', '/video/v1.mp4');
    await broken.pending;

    expect(failed.message(), contains('다시 시도'));
    expect(failed.message(), isNot(contains('알아듣지 못했')));
    expect(failed.canRetry, isTrue);

    final quiet = storeWith((_) async => const []);
    final silent = CaptionController(store: quiet);
    silent.start('v2', '/video/v2.mp4');
    await quiet.pending;

    expect(silent.message(), contains('알아듣지 못했'));
    expect(silent.canRetry, isFalse, reason: '조용한 영상은 다시 불러도 조용하다');
  });

  test('retry가 _job을 비워 다시 걸린다 — 화면을 나갔다 오지 않아도 된다', () async {
    var calls = 0;
    final store = storeWith((_) async {
      calls++;
      if (calls == 1) throw StateError('서버 없음');
      return _lines();
    });
    final subject = CaptionController(store: store);

    subject.start('v1', '/video/v1.mp4');
    await store.pending;
    expect(subject.lines, isEmpty);

    subject.retry();
    await store.pending;

    expect(calls, 2);
    expect(subject.lines, hasLength(2));
    expect(subject.status, isA<TranscriptReady>());
    expect(subject.canRetry, isFalse);
  });

  test('무발화는 retry가 아무 일도 하지 않는다 — 같은 요청을 계속 쏘지 않는다', () async {
    var calls = 0;
    final store = storeWith((_) async {
      calls++;
      return const <CaptionLine>[];
    });
    final subject = CaptionController(store: store);

    subject.start('v1', '/video/v1.mp4');
    await store.pending;
    subject.retry();
    await store.pending;

    expect(calls, 1);
  });

  test('도는 중이면 예상 시간을 알려준다', () async {
    final store = storeWith((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return _lines();
    });
    final subject = CaptionController(store: store);

    subject.start('v1', '/video/v1.mp4');

    expect(subject.message(estimateSeconds: 108), contains('108초'));
    expect(subject.message(), isNot(contains('초')));
    await store.pending;
  });

  test('사용자가 고치면 hasUserEdits가 켜지고 알림이 간다', () async {
    final store = storeWith((_) async => _lines());
    final subject = CaptionController(store: store);
    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    expect(subject.hasUserEdits, isFalse);
    var notified = 0;
    subject.addListener(() => notified++);

    subject.edit(0, '그거 만지면 안 돼');

    expect(subject.lines[0].text, '그거 만지면 안 돼');
    expect(subject.hasUserEdits, isTrue);
    expect(notified, 1);
  });

  test('없는 번호를 고치라고 해도 죽지 않고 수정으로 세지 않는다', () async {
    final store = storeWith((_) async => _lines());
    final subject = CaptionController(store: store);
    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    subject.edit(9, '아무거나');

    expect(subject.lines, hasLength(2));
    expect(subject.hasUserEdits, isFalse);
  });

  test('textAt과 forExport는 현재 줄을 그대로 쓴다', () async {
    final store = storeWith((_) async => _lines());
    final subject = CaptionController(store: store);
    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    expect(subject.textAt(2000), '그거 만지지 마');
    final exported = subject.forExport(startMs: 4000, endMs: 10000);
    expect(exported, hasLength(1));
    expect(exported.single['startMs'], 1000);
  });
}
