/// 자막 편집 화면이 기준 기기(갤럭시 S24+)에 들어가는지 본다.
///
/// **왜 따로 두는가**: 넘침은 크기마다 다르게 나고, 자막 기능은 화면이 넷이다
/// (자막 탭 패널·자막 타임라인·직접 텍스트 시트·AI 자막 시트). 각 파일의
/// 기능 테스트에 흩어 두면 "S24+에서 다 되나"를 한 번에 확인할 수 없다.
///
/// **인셋을 넣는 이유**: S24+는 위에 상태바, 아래에 제스처바가 있다. 논리
/// 411×891 중 실제로 쓸 수 있는 세로는 840 남짓이다. 인셋 없이 재면 화면
/// 맨 아래에 붙은 버튼이 제스처바에 가리는 것을 놓친다 — 실제로 직접 텍스트
/// 시트의 [취소]·[텍스트 추가]가 그렇게 잘려 있었다.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/editor/editor_direct_text_sheet.dart';
import 'package:william_james_app/features/stt/caption_auto_section.dart';
import 'package:william_james_app/features/stt/caption_controller.dart';
import 'package:william_james_app/features/stt/caption_line.dart';
import 'package:william_james_app/features/stt/transcript_store.dart';

/// 갤럭시 S24+ 논리 크기와 시스템 영역.
const _s24Size = Size(411, 891);
const _s24TopInset = 32.0;
const _s24BottomInset = 24.0;

/// 파일을 만들지 않는 저장소. 가짜 시계에 걸린 위젯 테스트에서 실제 파일
/// 입출력은 끝나지 않는다.
class _MemoryStore extends TranscriptStore {
  _MemoryStore(VideoTranscriber transcriber)
    : super(transcriber: transcriber, root: () async => throw StateError('안 씀'));

  List<CaptionLine>? _saved;

  @override
  Future<List<CaptionLine>?> read(String videoId) async => _saved;

  @override
  Future<void> write(String videoId, List<CaptionLine> lines) async {
    _saved = lines;
  }

  @override
  Future<void> clear(String videoId) async {
    _saved = null;
  }
}

void main() {
  void useS24(WidgetTester tester) {
    tester.view
      ..physicalSize = _s24Size
      ..devicePixelRatio = 1
      ..padding = const FakeViewPadding(
        top: _s24TopInset,
        bottom: _s24BottomInset,
      )
      ..viewPadding = const FakeViewPadding(
        top: _s24TopInset,
        bottom: _s24BottomInset,
      );
    addTearDown(tester.view.reset);
  }

  /// 위젯이 제스처바 위에서 끝나는가. 화면 안에 있는 것만으로는 부족하다 —
  /// 제스처바에 걸친 버튼은 눌러도 시스템이 먼저 먹는다.
  void expectAboveGestureBar(WidgetTester tester, Finder finder, String what) {
    final bottom = tester.getRect(finder).bottom;
    expect(
      bottom,
      lessThanOrEqualTo(_s24Size.height - _s24BottomInset),
      reason: '$what이(가) 제스처바에 걸쳤다 (아래끝 $bottom)',
    );
  }

  group('직접 텍스트 시트', () {
    Future<void> openSheet(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showEditorDirectTextSheet(
                  context,
                  startMs: 2000,
                  maxEndMs: 10000,
                  initialColor: AppColors.cream,
                ),
                child: const Text('열기'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();
    }

    testWidgets('S24+에서 끝까지 내리면 추가 버튼이 제스처바 위에 온다', (tester) async {
      useS24(tester);
      await openSheet(tester);

      final submit = find.byKey(const Key('editor-direct-text-submit'));
      await tester.ensureVisible(submit);
      await tester.pumpAndSettle();

      expect(submit.hitTestable(), findsOneWidget);
      expectAboveGestureBar(tester, submit, '텍스트 추가 버튼');
      expectAboveGestureBar(tester, find.text('취소'), '취소 버튼');
      expect(tester.takeException(), isNull);
    });

    testWidgets('S24+에서 키보드가 올라와도 넘치지 않는다', (tester) async {
      useS24(tester);
      await openSheet(tester);

      // 키보드가 화면 아래 절반쯤을 덮는다.
      tester.view.viewInsets = const FakeViewPadding(bottom: 340);
      // 키보드가 덮은 만큼 제스처바 여백은 사라진다 — 실제 기기와 같다.
      tester.view.padding = const FakeViewPadding(top: _s24TopInset);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      await tester.ensureVisible(
        find.byKey(const Key('editor-direct-text-input')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  group('AI 자막 시트', () {
    Widget host(CaptionController controller) => MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 20),
            child: CaptionAutoSection(
              controller: controller,
              onCancel: () {},
              onDone: () {},
            ),
          ),
        ),
      ),
    );

    testWidgets('S24+에서 만드는 중 화면이 넘치지 않는다', (tester) async {
      useS24(tester);
      final gate = Completer<List<CaptionLine>>();
      final store = _MemoryStore((_) => gate.future);
      final controller = CaptionController(store: store);
      addTearDown(controller.dispose);
      controller.start('v1', '/video/v1.mp4');

      await tester.pumpWidget(host(controller));
      await tester.pump();

      expect(find.byKey(const ValueKey('auto-caption-loading')), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 파형은 계속 돌므로 pumpAndSettle을 쓰면 끝나지 않는다.
      gate.complete(const []);
      await store.pending;
      await tester.pump();
    });

    testWidgets('S24+에서 검토 완료 버튼이 제스처바 위에 온다', (tester) async {
      useS24(tester);
      final store = _MemoryStore(
        (_) async => [
          for (var index = 0; index < 12; index++)
            CaptionLine(
              startMs: index * 2000,
              endMs: index * 2000 + 1500,
              text: '$index번째 줄이에요',
            ),
        ],
      );
      final controller = CaptionController(store: store);
      addTearDown(controller.dispose);
      controller.start('v1', '/video/v1.mp4');
      await store.pending;

      await tester.pumpWidget(host(controller));
      await tester.pumpAndSettle();

      final done = find.byKey(const ValueKey('auto-caption-done'));
      await tester.ensureVisible(done);
      await tester.pumpAndSettle();

      expect(done.hitTestable(), findsOneWidget);
      expectAboveGestureBar(tester, done, '자막 검토 완료 버튼');
      expect(tester.takeException(), isNull);
    });

    testWidgets('S24+에서 줄 수정 창이 키보드 위에 다 보인다', (tester) async {
      useS24(tester);
      final store = _MemoryStore(
        (_) async => [CaptionLine(startMs: 0, endMs: 1500, text: '고쳐 볼 문장')],
      );
      final controller = CaptionController(store: store);
      addTearDown(controller.dispose);
      controller.start('v1', '/video/v1.mp4');
      await store.pending;

      await tester.pumpWidget(host(controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('auto-caption-row-0')));
      await tester.pumpAndSettle();

      tester.view.viewInsets = const FakeViewPadding(bottom: 340);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey('auto-caption-edit-submit')).hitTestable(),
        findsOneWidget,
      );
    });
  });
}
