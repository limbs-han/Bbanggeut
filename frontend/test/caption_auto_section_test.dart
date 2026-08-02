/// 자동 자막 섹션 위젯 테스트.
/// 수정 다이얼로그를 섹션이 직접 들고 있으므로 편집 화면 없이 여기서 검증된다.
///
/// **저장소를 메모리로 대신하는 이유**: `testWidgets`는 가짜 시계로 이벤트 루프를
/// 잡기 때문에 실제 파일 입출력이 완료되지 않는다. `TranscriptStore`를 그대로
/// 쓰면 `await store.pending`이 영원히 기다린다. 파일 입출력 자체는
/// `stt_test.dart`에서 이미 검증했으므로 여기서는 위젯만 본다.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/stt/caption_auto_section.dart';
import 'package:william_james_app/features/stt/caption_controller.dart';
import 'package:william_james_app/features/stt/caption_line.dart';
import 'package:william_james_app/features/stt/transcript_api.dart'
    show transcriptServerReady;
import 'package:william_james_app/features/stt/transcript_store.dart';

/// 파일을 만들지 않는 저장소. read/write만 갈아끼우면 나머지 흐름은 그대로다.
class _MemoryStore extends TranscriptStore {
  _MemoryStore(VideoTranscriber transcriber)
    : super(
        transcriber: transcriber,
        // root는 쓰이지 않는다 — read/write를 덮어썼다.
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

void main() {
  Future<CaptionController> readyWith(List<CaptionLine> lines) async {
    final store = _MemoryStore((_) async => lines);
    final controller = CaptionController(store: store);
    controller.start('v1', '/video/v1.mp4');
    await store.pending;
    return controller;
  }

  Future<CaptionController> ready() => readyWith([
    CaptionLine(startMs: 1000, endMs: 3000, text: '그거 만지지 마'),
    CaptionLine(startMs: 5000, endMs: 7000, text: '안 만졌는데요'),
  ]);

  Future<void> pumpSection(
    WidgetTester tester,
    CaptionController controller, {
    VoidCallback? onChanged,
    int? estimateSeconds,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              CaptionAutoSection(
                controller: controller,
                onChanged: onChanged,
                estimateSeconds: estimateSeconds,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  testWidgets('줄마다 한 행씩 보여준다', (tester) async {
    await pumpSection(tester, await ready());
    await tester.pump();

    expect(find.text('그거 만지지 마'), findsOneWidget);
    expect(find.text('안 만졌는데요'), findsOneWidget);
  });

  testWidgets('행을 눌러 고치면 목록에 반영되고 onChanged가 불린다', (tester) async {
    var changed = 0;
    await pumpSection(tester, await ready(), onChanged: () => changed++);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('auto-caption-row-0')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('auto-caption-field')),
      '그거 만지면 안 돼',
    );
    await tester.tap(find.text('넣기'));
    await tester.pumpAndSettle();

    expect(find.text('그거 만지면 안 돼'), findsOneWidget);
    expect(find.text('그거 만지지 마'), findsNothing);
    expect(changed, 1);
  });

  testWidgets('취소하면 아무것도 바뀌지 않는다', (tester) async {
    var changed = 0;
    await pumpSection(tester, await ready(), onChanged: () => changed++);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('auto-caption-row-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    expect(find.text('그거 만지지 마'), findsOneWidget);
    expect(changed, 0);
  });

  testWidgets('줄이 없으면 목록 없이 안내만 보여준다', (tester) async {
    await pumpSection(tester, await readyWith(const []));
    await tester.pump();

    expect(find.textContaining('알아듣지 못했'), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-caption-row-0')), findsNothing);
  });

  testWidgets('도는 중이면 예상 시간을 보여준다', (tester) async {
    // Completer로 붙잡는다 — 타이머를 쓰면 가짜 시계에 걸려 진행되지 않는다.
    final gate = Completer<List<CaptionLine>>();
    final store = _MemoryStore((_) => gate.future);
    final controller = CaptionController(store: store);
    controller.start('v1', '/video/v1.mp4');

    await pumpSection(tester, controller, estimateSeconds: 108);
    await tester.pump();

    expect(find.textContaining('108초'), findsOneWidget);

    // 붙잡은 것을 풀어 준다 — 안 그러면 미완 작업을 남기고 끝난다.
    gate.complete(const []);
    await store.pending;
  });

  testWidgets('가짜 통로일 때 견본이라고 알린다 — 이 대사가 영상에 구워진다', (tester) async {
    // 만화 화면의 comic-sample-notice와 같은 이유다. COMIC_SERVER를 주지 않은
    // 빌드에서는 fakeTranscriber가 지어낸 대사 세 줄이 진짜처럼 보인다.
    expect(transcriptServerReady, isFalse, reason: '기본 빌드에서 도는 테스트다');

    await pumpSection(tester, await ready());
    await tester.pump();

    expect(find.byKey(const ValueKey('caption-sample-notice')), findsOneWidget);
    expect(find.textContaining('예시 대사'), findsOneWidget);
  });

  testWidgets('연결·서버 실패에는 다시 시도 버튼이 뜬다', (tester) async {
    final store = _MemoryStore((_) async => throw StateError('서버 없음'));
    final controller = CaptionController(store: store);
    controller.start('v1', '/video/v1.mp4');
    await store.pending;

    await pumpSection(tester, controller);
    await tester.pump();

    expect(find.byKey(const ValueKey('auto-caption-retry')), findsOneWidget);
  });

  test('autoCaptionAt은 그 시각의 줄만 돌려준다', () async {
    final controller = await ready();
    expect(autoCaptionAt(controller, 2000), '그거 만지지 마');
    expect(autoCaptionAt(controller, 4000), isNull);
  });
}
