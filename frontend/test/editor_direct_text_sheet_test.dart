import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/app/app_theme.dart';
import 'package:william_james_app/editor/editor_direct_text_sheet.dart';

void main() {
  testWidgets('직접 자막 시트에서 문구, 위치, 시간, 스타일을 정해 반환한다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    EditorDirectTextResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showEditorDirectTextSheet(
                  context,
                  startMs: 2000,
                  maxEndMs: 10000,
                  initialColor: AppColors.cream,
                );
              },
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    expect(find.text('직접 텍스트 추가'), findsOneWidget);
    expect(find.text('상단'), findsOneWidget);
    expect(find.text('가운데'), findsOneWidget);
    expect(find.text('하단'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('editor-direct-text-input')),
      '우리 가족의 특별한 하루',
    );
    await tester.pump();
    tester.testTextInput.hide();
    final top = find.byKey(const Key('editor-direct-position-top'));
    await tester.ensureVisible(top);
    tester.widget<OutlinedButton>(top).onPressed!();
    final duration = find.byKey(const Key('editor-direct-duration-3'));
    await tester.ensureVisible(duration);
    tester.widget<ChoiceChip>(duration).onSelected!(true);
    final bold = find.byKey(const Key('editor-direct-bold'));
    await tester.ensureVisible(bold);
    await tester.tap(bold, warnIfMissed: false);
    await tester.pump();
    final submit = find.byKey(const Key('editor-direct-text-submit'));
    await tester.ensureVisible(submit);
    tester.widget<FilledButton>(submit).onPressed!();
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.text, '우리 가족의 특별한 하루');
    expect(result!.position, EditorTextScreenPosition.top);
    expect(result!.position.point.y, 0.22);
    expect(result!.startMs, 2000);
    expect(result!.endMs, 5000);
    expect(result!.style.bold, isFalse);
  });

  testWidgets('표시 시간은 현재 클립 끝을 넘지 않는다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    EditorDirectTextResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showEditorDirectTextSheet(
                  context,
                  startMs: 8000,
                  maxEndMs: 10000,
                  initialColor: Colors.white,
                );
              },
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('열기'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('editor-direct-text-input')),
      '클립 끝 자막',
    );
    await tester.pump();
    tester.testTextInput.hide();
    final submit = find.byKey(const Key('editor-direct-text-submit'));
    await tester.ensureVisible(submit);
    tester.widget<FilledButton>(submit).onPressed!();
    await tester.pumpAndSettle();

    expect(result!.startMs, 8000);
    expect(result!.endMs, 10000);
  });
}
