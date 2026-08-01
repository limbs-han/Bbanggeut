import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/editor/editor_project.dart';
import 'package:william_james_app/editor/editor_project_controller.dart';
import 'package:william_james_app/editor/editor_text_style_bar.dart';

void main() {
  EditorProjectController newController() => EditorProjectController(
    EditorProject.fromSource(
      sourceVideoPath: '/tmp/source.mp4',
      sourceDurationMs: 12000,
      sourceSize: const EditorSourceSize(width: 1920, height: 1080),
    ),
  );

  /// 편집 화면이 스타일 줄을 쓰는 방식 그대로 이어 붙인 껍데기.
  Widget host(
    EditorTextDraft draft,
    ValueChanged<EditorTextDraft> onChanged, {
    VoidCallback? onDone,
  }) => MaterialApp(
    home: Scaffold(
      body: EditorTextStyleBar(
        draft: draft,
        onChanged: onChanged,
        onDone: onDone ?? () {},
      ),
    ),
  );

  testWidgets('정렬은 가운데 → 왼쪽 → 오른쪽으로 돌아간다', (tester) async {
    var draft = const EditorTextDraft();
    await tester.pumpWidget(host(draft, (next) => draft = next));

    await tester.tap(find.byKey(const Key('editor-text-align')));
    await tester.pump();
    expect(draft.align, EditorTextAlign.left);
  });

  testWidgets('꾸밈을 고르면 굵기·기울임이 함께 바뀐다', (tester) async {
    var draft = const EditorTextDraft();
    await tester.pumpWidget(host(draft, (next) => draft = next));

    await tester.tap(find.byKey(const Key('editor-text-style-italic')));
    await tester.pump();

    expect(draft.italic, isTrue);
    expect(draft.bold, isFalse);
  });

  testWidgets('배경 단추는 글자색에 맞는 상자를 깐다', (tester) async {
    var draft = const EditorTextDraft();
    await tester.pumpWidget(host(draft, (next) => draft = next));

    await tester.tap(find.byKey(const Key('editor-text-background')));
    await tester.pump();

    expect(draft.hasBackground, isTrue);
    // 흰 글자에는 어두운 상자가 깔려야 읽힌다.
    expect(draft.backgroundColor.computeLuminance(), lessThan(0.5));
  });

  testWidgets('크기 단추를 누르면 슬라이더가 나온다', (tester) async {
    var draft = const EditorTextDraft();
    await tester.pumpWidget(host(draft, (next) => draft = next));

    expect(find.byKey(const Key('editor-text-size-slider')), findsNothing);
    await tester.tap(find.byKey(const Key('editor-text-size')));
    await tester.pump();
    expect(find.byKey(const Key('editor-text-size-slider')), findsOneWidget);
  });

  test('빈 글자 레이어를 만들고, 취소하면 흔적 없이 걷어낸다', () {
    final subject = newController();

    subject.beginGesture();
    final id = subject.beginTextLayer();
    expect(subject.project.textLayers, hasLength(1));
    expect(subject.project.selectedLayerId, id);

    subject.updateTextLayer(id, text: '우리 가족', italic: true);
    expect(subject.project.textLayers.single.text, '우리 가족');
    expect(subject.project.textLayers.single.italic, isTrue);
    // 쓰는 동안에는 이력이 쌓이지 않는다.
    expect(subject.canUndo, isFalse);

    subject.endGesture();
    expect(subject.canUndo, isTrue);

    subject.undo();
    expect(subject.project.textLayers, isEmpty);
  });

  test('한 글자도 안 쓴 레이어는 걷어내면 이력도 남기지 않는다', () {
    final subject = newController();

    subject.beginGesture();
    final id = subject.beginTextLayer();
    subject.removeLayer(id);
    subject.endGesture();

    expect(subject.project.textLayers, isEmpty);
    expect(subject.canUndo, isFalse);
  });

  test('영상 끝에서 놓은 스티커도 화면에 보인다', () {
    final subject = newController();
    // 끝까지 재생한 뒤 스티커를 놓는 상황.
    subject.setPlayhead(subject.project.durationMs);
    subject.addSticker('👑');

    final layer = subject.project.stickerLayers.single;
    expect(
      layer.isVisibleAt(subject.project.playheadMs),
      isTrue,
      reason: '끝 시각을 빼고 따지면 방금 놓은 스티커가 안 보인다',
    );
  });
}
