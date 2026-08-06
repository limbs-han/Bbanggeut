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
import 'package:william_james_app/features/stt/transcript_store.dart';

/// 파일을 만들지 않는 저장소. read/write만 갈아끼우면 나머지 흐름은 그대로다.
class _MemoryStore extends TranscriptStore {
  _MemoryStore(VideoTranscriber transcriber)
    : super(
        transcriber: (path, [onProgress]) {
          _captured = onProgress;
          return transcriber(path, onProgress);
        },
        // root는 쓰이지 않는다 — read/write를 덮어썼다.
        root: () async => Directory.systemTemp,
      );

  /// 대역 전사기가 받은 진행률 통로. 제품 코드와 **같은 길**로 흘려보내려고
  /// 잡아 둔다 — 저장소에 테스트 전용 구멍을 뚫는 대신 실제 콜백을 쓴다.
  static TranscribeProgress? _captured;

  void report(TranscriptStage stage, int percent) =>
      _captured!(stage, percent);

  List<CaptionLine>? _saved;

  @override
  Future<List<CaptionLine>?> read(String videoId) async => _saved;

  @override
  Future<void> write(String videoId, List<CaptionLine> lines) async {
    _saved = lines;
  }

  // read·write와 같은 층이다. 이것을 안 덮으면 다시 만들기가 진짜 파일을
  // 만지러 가서, 가짜 시계에 걸린 위젯 테스트가 끝나지 않는다.
  @override
  Future<void> clear(String videoId) async {
    _saved = null;
  }
}

void main() {
  Future<CaptionController> readyWith(List<CaptionLine> lines) async {
    final store = _MemoryStore((_, [_]) async => lines);
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
    VoidCallback? onCancel,
    VoidCallback? onDone,
    bool disableAnimations = false,
  }) => tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: disableAnimations),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              CaptionAutoSection(
                controller: controller,
                onChanged: onChanged,
                estimateSeconds: estimateSeconds,
                onCancel: onCancel,
                onDone: onDone,
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
    await tester.pump();
    final submit = find.byKey(const ValueKey('auto-caption-edit-submit'));
    await tester.ensureVisible(submit);
    tester.widget<FilledButton>(submit).onPressed!();
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
    final cancel = find.text('취소');
    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();

    expect(find.text('그거 만지지 마'), findsOneWidget);
    expect(changed, 0);
  });

  testWidgets('자막 수정 카드는 키보드 위에 모두 보이고 원문 듣기가 없다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1
      ..viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.reset);

    await pumpSection(tester, await ready());
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('auto-caption-row-0')));
    await tester.pumpAndSettle();
    expect(find.text('1번째 자막 수정'), findsOneWidget);
    expect(find.text('원문 듣기'), findsNothing);
    final dialog = find.byKey(const ValueKey('auto-caption-edit-dialog'));
    expect(dialog, findsOneWidget);
    expect(
      tester
          .getBottomRight(
            find.byKey(const ValueKey('auto-caption-edit-submit')),
          )
          .dy,
      lessThanOrEqualTo(570),
    );
    expect(
      find.descendant(of: dialog, matching: find.byType(SingleChildScrollView)),
      findsNothing,
    );
  });

  testWidgets('자막 검토 완료는 닫기와 별도의 적용 콜백을 호출한다', (tester) async {
    var cancelled = 0;
    var applied = 0;
    await pumpSection(
      tester,
      await ready(),
      onCancel: () => cancelled++,
      onDone: () => applied++,
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('auto-caption-done')));
    expect(applied, 1);
    expect(cancelled, 0);
  });

  testWidgets('줄이 없으면 목록 없이 안내만 보여준다', (tester) async {
    await pumpSection(tester, await readyWith(const []));
    await tester.pump();

    expect(find.textContaining('알아듣지 못했'), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-caption-row-0')), findsNothing);
  });

  testWidgets('도는 중이면 고정 위치의 여덟 반짝이와 반복 파형을 보여준다', (tester) async {
    // 기준 기기인 갤럭시 S24+의 세로 논리 크기에서 진행 화면을 검증한다.
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    // Completer로 붙잡는다 — 타이머를 쓰면 가짜 시계에 걸려 진행되지 않는다.
    final gate = Completer<List<CaptionLine>>();
    final store = _MemoryStore((_, [_]) => gate.future);
    final controller = CaptionController(store: store);
    addTearDown(controller.dispose);
    controller.start('v1', '/video/v1.mp4');

    await pumpSection(tester, controller, estimateSeconds: 108);
    await tester.pump();

    expect(find.textContaining('108초'), findsOneWidget);
    expect(find.byType(AnimatedCaptionWaveform), findsOneWidget);
    final wave = find.byKey(const ValueKey('auto-caption-wave'));
    expect(wave, findsOneWidget);
    expect(
      find.descendant(of: wave, matching: find.byType(DecoratedBox)),
      findsNothing,
    );

    // 자리는 고정이다 — 반짝이는 것은 밝기·크기·기울기뿐이라, 여덟 개가
    // 매 프레임 자리를 옮기며 화면을 어지럽히지 않는다.
    const sparkleIds = [
      'coral-top-left',
      'olive-top-right',
      'olive-bottom-left',
      'coral-bottom-right',
      'coral-mid-left',
      'olive-mid-right',
      'olive-top-center',
      'coral-bottom-center',
    ];
    final beforePositions = [
      for (final id in sparkleIds)
        tester.getTopLeft(find.byKey(ValueKey('auto-caption-sparkle-$id'))),
    ];
    final paintFinder = find.byKey(const ValueKey('auto-caption-wave-paint'));
    final beforePainter = tester.widget<CustomPaint>(paintFinder).painter;
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pump(const Duration(milliseconds: 300));
    final afterPainter = tester.widget<CustomPaint>(paintFinder).painter;
    final afterPositions = [
      for (final id in sparkleIds)
        tester.getTopLeft(find.byKey(ValueKey('auto-caption-sparkle-$id'))),
    ];
    expect(find.byKey(const ValueKey('auto-caption-loading')), findsOneWidget);
    expect(afterPositions, beforePositions);
    expect(identical(afterPainter, beforePainter), isFalse);

    // 완료되면 로딩 파형이 사라지고 내부 컨트롤러도 함께 dispose된다.
    gate.complete(const []);
    await store.pending;
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedCaptionWaveform), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // 예전에는 이 설정에서 파형을 세웠다. 개발자 옵션으로 애니메이터 배율을
  // 꺼 둔 기기에서 로딩 화면이 통째로 굳어 "앱이 멎었다"로 보였다 — 진행
  // 표시는 기다리라는 말을 하는 그림이라 이 설정에서 뺀다.
  testWidgets('애니메이션 감소 설정에서도 파형은 계속 움직인다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final gate = Completer<List<CaptionLine>>();
    final store = _MemoryStore((_, [_]) => gate.future);
    final controller = CaptionController(store: store);
    addTearDown(controller.dispose);
    controller.start('v1', '/video/v1.mp4');

    await pumpSection(
      tester,
      controller,
      estimateSeconds: 108,
      disableAnimations: true,
    );
    await tester.pump();
    final sparkle = find.byKey(
      const ValueKey('auto-caption-sparkle-coral-top-left'),
    );
    final before = tester.getTopLeft(sparkle);
    final paintFinder = find.byKey(const ValueKey('auto-caption-wave-paint'));
    final beforePainter = tester.widget<CustomPaint>(paintFinder).painter;
    await tester.pump(const Duration(milliseconds: 300));

    // 반짝이의 자리는 고정이다. 움직이는 것은 그리는 내용뿐이다.
    expect(tester.getTopLeft(sparkle), before);
    expect(
      identical(tester.widget<CustomPaint>(paintFinder).painter, beforePainter),
      isFalse,
    );
    expect(tester.binding.hasScheduledFrame, isTrue);

    gate.complete(const []);
    await store.pending;
    await tester.pumpAndSettle();
  });

  testWidgets('animate:false로 세워 두면 프레임을 잡아먹지 않는다', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AnimatedCaptionWaveform(animate: false)),
      ),
    );
    final paintFinder = find.byKey(const ValueKey('auto-caption-wave-paint'));
    final before = tester.widget<CustomPaint>(paintFinder).painter;
    await tester.pump(const Duration(seconds: 2));

    expect(
      identical(tester.widget<CustomPaint>(paintFinder).painter, before),
      isTrue,
    );
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('자동 자막 취소 버튼은 기존 취소 콜백을 그대로 호출한다', (tester) async {
    final gate = Completer<List<CaptionLine>>();
    final store = _MemoryStore((_, [_]) => gate.future);
    final controller = CaptionController(store: store);
    addTearDown(controller.dispose);
    controller.start('v1', '/video/v1.mp4');
    var cancelled = 0;

    await pumpSection(tester, controller, onCancel: () => cancelled++);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('auto-caption-cancel')));
    expect(cancelled, 1);

    // 실제 화면 종료처럼 위젯을 제거해 애니메이션 컨트롤러를 dispose한다.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
    gate.complete(const []);
    await store.pending;
  });

  // **퍼센트를 짐작하지 않는다.** 예전에는 예상 시간으로 숫자를 만들어 늘 무언가
  // 보여 줬는데, 예상보다 오래 걸리면 95%에 붙어 멈춘 것처럼 보였고 시트를
  // 닫았다 열면 1%부터 다시 셌다. 이제 셀 근거가 있을 때만 숫자가 나온다 —
  // 모델 내려받기는 바이트, 대사 인식은 엔진에 먹인 오디오 양이다.
  testWidgets('셀 근거가 있는 동안만 퍼센트를 보여 준다', (tester) async {
    final gate = Completer<List<CaptionLine>>();
    final store = _MemoryStore((_, [_]) => gate.future);
    final controller = CaptionController(store: store);
    addTearDown(controller.dispose);
    addTearDown(() => mlkitDownloadPercent.value = null);
    controller.start('v1', '/video/v1.mp4');
    await pumpSection(tester, controller);
    await tester.pump();
    // 소리를 뽑는 단계에는 진행률이 없다. 숫자 없이 띠만 흐른다.
    expect(find.text('자동 자막 생성 중'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('auto-caption-bar')),
          )
          .value,
      isNull,
    );

    mlkitDownloadPercent.value = 62;
    await tester.pump();
    expect(find.text('자동 자막 생성 중 · 62%'), findsOneWidget);

    mlkitDownloadPercent.value = null;
    store.report(TranscriptStage.recognizing, 42);
    await tester.pump();
    expect(find.text('자동 자막 생성 중 · 42%'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const ValueKey('auto-caption-bar')),
          )
          .value,
      closeTo(0.42, 0.001),
    );
    expect(find.byType(AnimatedCaptionWaveform), findsOneWidget);

    gate.complete(const []);
    await store.pending;
    await tester.pumpAndSettle();
  });

  testWidgets('시트를 닫았다 열어도 퍼센트가 이어진다', (tester) async {
    final gate = Completer<List<CaptionLine>>();
    final store = _MemoryStore((_, [_]) => gate.future);
    final controller = CaptionController(store: store);
    addTearDown(controller.dispose);
    controller.start('v1', '/video/v1.mp4');
    await pumpSection(tester, controller);
    await tester.pump();
    store.report(TranscriptStage.recognizing, 73);
    await tester.pump();
    expect(find.text('자동 자막 생성 중 · 73%'), findsOneWidget);

    // 시트를 닫는다 — 위젯이 사라져도 세는 주체는 작업이다.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await pumpSection(tester, controller);
    await tester.pump();
    expect(find.text('자동 자막 생성 중 · 73%'), findsOneWidget);

    gate.complete(const []);
    await store.pending;
    await tester.pumpAndSettle();
  });

  test('24개 막대는 8~48dp 안에서 서로 다른 위상으로 움직인다', () {
    final first = [
      for (var index = 0; index < 24; index++)
        AnimatedCaptionWaveform.debugBarHeight(index, 0),
    ];
    final later = [
      for (var index = 0; index < 24; index++)
        AnimatedCaptionWaveform.debugBarHeight(index, 0.25),
    ];

    expect(first.every((height) => height >= 8 && height <= 48), isTrue);
    expect(later.every((height) => height >= 8 && height <= 48), isTrue);
    expect(
      List.generate(
        24,
        (index) => (first[index] - later[index]).abs(),
      ).where((difference) => difference > 1).length,
      greaterThan(12),
    );
    final centerAverage = (first[11] + first[12]) / 2;
    final edgeAverage = (first.first + first.last) / 2;
    expect(centerAverage, greaterThan(edgeAverage));
  });

  test('autoCaptionAt은 그 시각의 줄만 돌려준다', () async {
    final controller = await ready();
    expect(autoCaptionAt(controller, 2000), '그거 만지지 마');
    expect(autoCaptionAt(controller, 4000), isNull);
  });
}
