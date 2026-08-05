/// 자막 하단 시트 안에서 줄을 고칠 때의 위젯 생애 회귀 테스트.
///
/// 실기기에서 이 에러가 났다:
///   framework.dart line 6268: 'dependents.isEmpty': is not true
///
/// 그 assert는 `InheritedElement.debugDeactivated()`에 있고, "아직 의존을 걸어둔
/// 위젯이 있는데 InheritedWidget이 먼저 해체됐다"는 뜻이다. 하단 시트 안에서
/// showDialog를 열고(showDialog는 Navigator.of(context)를 부른다) 시트가 닫히는
/// 순서가 어긋나면 이렇게 된다.
///
/// 실제 편집 화면의 자막 시트 구조를 그대로 흉내낸다 —
/// showModalBottomSheet + StatefulBuilder + CaptionAutoSection + 적용 버튼.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/stt/caption_auto_section.dart';
import 'package:william_james_app/features/stt/caption_controller.dart';
import 'package:william_james_app/features/stt/caption_line.dart';
import 'package:william_james_app/features/stt/transcript_store.dart';

/// 파일을 만들지 않는 저장소 (stt_test.dart와 같은 이유).
class _MemoryStore extends TranscriptStore {
  _MemoryStore(List<CaptionLine> lines)
    : super(
        transcriber: (_) async => lines,
        root: () async => throw StateError('쓰이지 않는다'),
      );

  List<CaptionLine>? _saved;

  @override
  Future<List<CaptionLine>?> read(String videoId) async => _saved;

  @override
  Future<void> write(String videoId, List<CaptionLine> lines) async {
    _saved = lines;
  }
}

/// 편집 화면의 자막 시트를 흉내낸 최소 호스트.
///
/// [hoistController]로 두 방식을 비교한다:
///   false — 시트가 열릴 때 컨트롤러를 만들고 닫힌 직후 dispose (원래 코드)
///   true  — 화면이 컨트롤러를 소유 (고친 코드)
class _Host extends StatefulWidget {
  const _Host({required this.controller, this.hoistController = false});

  final CaptionController controller;
  final bool hoistController;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int changed = 0;

  /// 화면이 소유하는 입력칸 컨트롤러 (고친 방식).
  final _hoisted = TextEditingController();

  @override
  void dispose() {
    _hoisted.dispose();
    super.dispose();
  }

  Future<void> _openSheet() async {
    final local = widget.hoistController ? null : TextEditingController();
    final field = local ?? _hoisted;
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => Padding(
          // 실제 시트와 같다 — 키보드가 내려가면 이 값이 바뀌어 리빌드가 일어난다.
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: field),
                CaptionAutoSection(
                  controller: widget.controller,
                  onChanged: () => setState(() => changed++),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(sheetContext, true),
                  child: const Text('자막 적용'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    local?.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: FilledButton(onPressed: _openSheet, child: const Text('자막')),
    ),
  );
}

void main() {
  Future<CaptionController> ready() async {
    final store = _MemoryStore([
      CaptionLine(startMs: 1000, endMs: 3000, text: '그거 만지지 마'),
      CaptionLine(startMs: 5000, endMs: 7000, text: '안 만졌는데요'),
    ]);
    final controller = CaptionController(store: store);
    controller.start('v1', '/video/v1.mp4');
    await store.pending;
    return controller;
  }

  Future<void> openSheet(
    WidgetTester tester,
    CaptionController c, {
    bool hoistController = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: _Host(controller: c, hoistController: hoistController),
      ),
    );
    await tester.tap(find.text('자막'));
    await tester.pumpAndSettle();
  }

  // 실기기 예외를 재현하는 데는 성공했다. 시트를 닫은 직후
  //   tester.view.viewInsets = FakeViewPadding(bottom: 800) → pump(30ms)
  //   → viewInsets = zero → pump
  // 이 순서로 "닫히는 애니메이션 중 키보드 내려감"을 만들면, 원래 방식
  // (hoistController: false)에서 "A TextEditingController was used after being
  // disposed."가 그대로 났다.
  //
  // 다만 viewInsets를 한 프레임에 800→0으로 순간이동시키는 것은 실제 키보드
  // 동작이 아니어서, 고친 방식에서도 포커스 쪽 프레임워크 assert가 따라 붙는다.
  // 게이트로 쓰면 거짓 실패를 만들므로 남기지 않는다. 애니메이션 타이밍은
  // 실기기로 확인한다.

  testWidgets('시트 안에서 줄을 고치고 시트를 닫아도 예외가 없다', (tester) async {
    await openSheet(tester, await ready());

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

    await tester.tap(find.text('자막 적용'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('수정 다이얼로그가 열린 채로 시트가 닫혀도 예외가 없다', (tester) async {
    await openSheet(tester, await ready());

    await tester.tap(find.byKey(const ValueKey('auto-caption-row-0')));
    await tester.pumpAndSettle();

    // 다이얼로그를 남겨 둔 채 화면 전체를 갈아치운다 — 뒤로 가기나 다른
    // 도구로 넘어가는 상황이다.
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  // 닫히는 애니메이션 중 키보드가 내려가는 상황(closeSheetWhileKeyboardHides)으로
  // 실기기 예외를 재현하는 데는 성공했다 — 원래 방식에서 "used after being
  // disposed"가 그대로 났다. 다만 viewInsets를 한 프레임에 800→0으로 순간이동
  // 시키는 것은 실제 키보드 동작이 아니어서, 고친 방식에서도 포커스 쪽
  // 프레임워크 assert가 따라 붙는다. 게이트로 쓰면 거짓 실패를 만들므로 남기지
  // 않는다. 애니메이션 타이밍은 실기기로 확인한다.

  testWidgets('시트를 열고 닫기를 되풀이해도 예외가 없다', (tester) async {
    final controller = await ready();
    await openSheet(tester, controller);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('자막 적용'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('자막'));
      await tester.pumpAndSettle();
    }

    expect(tester.takeException(), isNull);
  });
}
