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

  TranscriptStore storeWith(VideoTranscriber transcriber) =>
      TranscriptStore(transcriber: transcriber, root: () async => temporary);

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
    expect(subject.message(), contains('알아듣지 못했'));
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

  test('고친 자막은 캐시 파일에도 저장된다 — 만화 구성이 그 파일을 읽는다', () async {
    final store = storeWith((_) async => _lines());
    final subject = CaptionController(store: store);
    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    subject.edit(0, '그거 만지면 안 돼');
    await subject.pendingWrite;

    // 메모리가 아니라 파일을 다시 읽는다 — ComicController가 읽는 그 경로다.
    final persisted = await store.read('v1');
    expect(persisted, isNotNull);
    expect(persisted!.first.text, '그거 만지면 안 돼');
    expect(persisted[1].text, '안 만졌는데요', reason: '고치지 않은 줄은 그대로');
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
