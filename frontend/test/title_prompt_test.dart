/// 제목 바꾸기 창.
///
/// 이 창은 만화 제목과 영상 제목 두 곳에서 쓴다. 예전에는 창을 여는 함수가
/// `TextEditingController`를 만들고 `showDialog`가 끝나는 즉시 `finally`에서
/// 버렸다. Future는 라우트를 pop하는 순간 끝나지만 창은 닫히는 애니메이션 동안
/// 아직 살아 있어서, 죽은 컨트롤러를 붙잡은 TextField가 정리되며 프레임
/// 어서션으로 터졌다(빨간 화면). 그래서 여기서는 **닫힌 뒤 애니메이션이 끝날
/// 때까지 프레임을 계속 돌려** 아무 오류도 나지 않는지 본다.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/ui/widgets.dart';

void main() {
  /// 창을 띄우고, **아직 끝나지 않은** 결과 Future를 돌려준다. 테스트는 창을
  /// 닫은 뒤에 그 값을 확인한다.
  Future<Future<String?>> open(
    WidgetTester tester, {
    String initial = '',
    String? hint,
  }) async {
    Future<String?>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => result = promptForTitle(
                context,
                title: '만화 제목',
                initial: initial,
                hint: hint,
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    return result!;
  }

  testWidgets('저장하면 입력한 제목을 돌려주고 오류가 남지 않는다', (tester) async {
    final pending = await open(tester, initial: '옛 제목');

    await tester.enterText(find.byKey(const Key('title-prompt-field')), '새 제목');
    await tester.tap(find.byKey(const Key('title-prompt-save')));
    // 닫히는 애니메이션이 끝날 때까지 돌린다 — 예전 버그가 여기서 터졌다.
    await tester.pumpAndSettle();

    expect(await pending, '새 제목');
    expect(tester.takeException(), isNull);
  });

  testWidgets('취소하면 null이고 오류가 남지 않는다', (tester) async {
    final pending = await open(tester, initial: '옛 제목');

    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    expect(await pending, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('처음 값과 안내 글을 그대로 보여 준다', (tester) async {
    await open(tester, initial: '옛 제목', hint: '비워 두면 영상 제목을 써요');

    expect(find.text('만화 제목'), findsOneWidget);
    expect(find.text('옛 제목'), findsOneWidget);
    expect(find.text('비워 두면 영상 제목을 써요'), findsOneWidget);

    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
