import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/editor/editor_ar_effects.dart';
import 'package:william_james_app/editor/editor_project.dart';
import 'package:william_james_app/editor/editor_project_controller.dart';
import 'package:william_james_app/editor/editor_workspace.dart';

void main() {
  EditorProjectController newController() => EditorProjectController(
    EditorProject.fromSource(
      sourceVideoPath: '/tmp/source.mp4',
      sourceDurationMs: 12000,
      sourceSize: const EditorSourceSize(width: 1920, height: 1080),
    ),
  );

  /// 편집 화면 한 벌. 테스트마다 필요한 콜백만 바꿔 넘긴다.
  Widget workspace(
    EditorProjectController controller, {
    ValueChanged<int>? onSeek,
    VoidCallback? onSplit,
    VoidCallback? onDelete,
    VoidCallback? onDuplicate,
    ValueChanged<int>? onTrimStartChanged,
    ValueChanged<int>? onTrimEndChanged,
    ValueChanged<EditorArEffect>? onArEffectSelected,
    VoidCallback? onArEffectCleared,
    VoidCallback? onAiCaption,
    bool saving = false,
  }) => MaterialApp(
    home: Scaffold(
      body: EditorWorkspace(
        controller: controller,
        preview: const ColoredBox(color: Colors.black),
        thumbnails: const [],
        playing: false,
        currentTime: '00:00',
        totalTime: '00:12',
        saving: saving,
        onBack: () {},
        onSave: () {},
        onPlay: () {},
        onSeek: onSeek ?? (_) {},
        onSplit: onSplit ?? () {},
        onDelete: onDelete ?? () {},
        onDuplicate: onDuplicate ?? () {},
        onTrimStartChanged: onTrimStartChanged ?? (_) {},
        onTrimEndChanged: onTrimEndChanged ?? (_) {},
        onRatioSelected: (_) {},
        onText: () {},
        onVolumeChanged: (_) {},
        onMutedChanged: (_) {},
        onStickerSelected: (_) {},
        onArEffectSelected: onArEffectSelected ?? (_) {},
        onArEffectCleared: onArEffectCleared ?? () {},
        onAiCaption: onAiCaption ?? () {},
        onToolSelected: controller.selectTool,
      ),
    ),
  );

  for (final size in const [
    Size(360, 740),
    Size(390, 844),
    Size(412, 915),
    // 갤럭시 S24+ 기본 해상도의 논리 크기.
    Size(411, 890),
  ]) {
    testWidgets('${size.width.toInt()}×${size.height.toInt()}에서 넘치지 않는다', (
      tester,
    ) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = newController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(workspace(controller));

      expect(find.text('영상 편집'), findsOneWidget);
      for (final label in const [
        '컷 편집',
        '비율',
        '텍스트',
        '오디오',
        '스티커',
        'AI자막',
        'AR',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '$label 탭이 없다');
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in const [Size(360, 660), Size(360, 740), Size(411, 890)]) {
    testWidgets(
      '${size.width.toInt()}×${size.height.toInt()}에서 모든 도구 패널이 넘치지 않는다',
      (tester) async {
        tester.view
          ..physicalSize = size
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = newController();
        addTearDown(controller.dispose);

        await tester.pumpWidget(workspace(controller));

        for (final tool in EditorTool.values) {
          controller.selectTool(tool);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(tester.takeException(), isNull, reason: '$tool 패널이 넘쳤다');
        }
        // 효과를 켜면 "효과 끄기"가 나타나 머리 줄이 커진다. 그때도 넘치지 않아야 한다.
        controller
          ..selectTool(EditorTool.ar)
          ..applyArEffect(EditorArEffect.all.first);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('AI자막 버튼은 하단 네비게이션에서 AR 왼쪽에 있다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(workspace(controller));

    final aiCaption = tester.getCenter(
      find.byKey(const Key('editor-nav-aiCaption')),
    );
    final ar = tester.getCenter(find.byKey(const Key('editor-nav-ar')));
    final sticker = tester.getCenter(
      find.byKey(const Key('editor-nav-sticker')),
    );
    expect(aiCaption.dx, lessThan(ar.dx));
    expect(aiCaption.dx, greaterThan(sticker.dx));
  });

  testWidgets('AI자막 탭에서 자동 자막 화면을 연다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);
    var opened = false;

    await tester.pumpWidget(
      workspace(controller, onAiCaption: () => opened = true),
    );
    await tester.tap(find.byKey(const Key('editor-nav-aiCaption')));
    // 썸네일이 아직 없으면 칸에 무한 회전 표시가 있어 pumpAndSettle이 멈추지 않는다.
    // 도구 패널은 AnimatedSize로 열리므로 시작 프레임 한 번 + 진행 프레임 한 번.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('editor-open-ai-caption')));

    expect(opened, isTrue);
  });

  testWidgets('타임라인을 끌면 재생 위치와 표시선이 함께 움직인다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      workspace(
        controller,
        onSeek: controller.setPlayhead,
        onSplit: () => controller.splitAt(controller.project.playheadMs),
        onDelete: controller.deleteSelectedClip,
        onDuplicate: controller.duplicateSelectedClip,
      ),
    );

    await tester.drag(
      find.byKey(const Key('editor-timeline-scrub')),
      const Offset(60, 0),
    );
    await tester.pump();

    expect(controller.project.playheadMs, greaterThan(0));
    expect(find.byKey(const Key('editor-playhead')), findsOneWidget);
  });

  testWidgets('구간 손잡이를 끌면 고른 클립의 시작과 끝이 바뀐다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      workspace(
        controller,
        onTrimStartChanged: (value) =>
            controller.trimSelectedClip(sourceStartMs: value),
        onTrimEndChanged: (value) =>
            controller.trimSelectedClip(sourceEndMs: value),
      ),
    );

    await tester.drag(
      find.byKey(const Key('editor-trim-start-handle')),
      const Offset(40, 0),
    );
    await tester.pump();
    expect(controller.project.selectedClip!.sourceStartMs, greaterThan(0));

    await tester.drag(
      find.byKey(const Key('editor-trim-end-handle')),
      const Offset(-40, 0),
    );
    await tester.pump();
    expect(controller.project.selectedClip!.sourceEndMs, lessThan(12000));
  });

  testWidgets('분할·복제·삭제 버튼이 클립 목록을 실제로 바꾼다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      workspace(
        controller,
        onSplit: () => controller.splitAt(controller.project.playheadMs),
        onDelete: controller.deleteSelectedClip,
        onDuplicate: controller.duplicateSelectedClip,
      ),
    );

    // 재생 위치가 0이면 한쪽이 0초라 분할할 수 없다. 버튼도 흐려져 있어야 한다.
    expect(tester.widget<TextButton>(_action('분할')).onPressed, isNull);

    controller.setPlayhead(4000);
    await tester.pump();
    await tester.tap(find.text('분할'));
    await tester.pump();
    expect(controller.project.clips, hasLength(2));

    await tester.tap(find.text('복제'));
    await tester.pump();
    expect(controller.project.clips, hasLength(3));

    await tester.tap(find.text('삭제'));
    await tester.pump();
    expect(controller.project.clips, hasLength(2));
  });

  testWidgets('텍스트를 만진 뒤에도 컷 편집 버튼이 살아 있다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..addTextLayer(text: '우리 가족');
    addTearDown(controller.dispose);
    // 예전에는 레이어를 고르면 선택 클립이 지워져 컷 편집이 전부 실패했다.
    controller.selectLayer(controller.project.textLayers.single.id);
    controller.setPlayhead(5000);

    await tester.pumpWidget(
      workspace(
        controller,
        onDuplicate: controller.duplicateSelectedClip,
        onSplit: () => controller.splitAt(controller.project.playheadMs),
      ),
    );

    expect(controller.project.selectedClip, isNotNull);
    await tester.tap(find.text('복제'));
    await tester.pump();
    expect(controller.project.clips, hasLength(2));
  });

  testWidgets('AR 탭에서 앱 안 효과를 켜고 끈다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.ar);
    addTearDown(controller.dispose);
    EditorArEffect? applied;
    var cleared = false;

    await tester.pumpWidget(
      workspace(
        controller,
        onArEffectSelected: (effect) {
          applied = effect;
          controller.applyArEffect(effect);
        },
        onArEffectCleared: () {
          cleared = true;
          controller.clearArEffect();
        },
      ),
    );

    await tester.tap(find.byKey(const Key('editor-ar-effect-puppy')));
    await tester.pump();

    expect(applied?.id, 'puppy');
    expect(controller.project.arEffectId, 'puppy');
    expect(controller.project.look, EditorLook.soft);
    expect(controller.project.stickerLayers, isNotEmpty);

    await tester.tap(find.byKey(const Key('editor-clear-ar-effect')));
    await tester.pump();

    expect(cleared, isTrue);
    expect(controller.project.arEffectId, isNull);
    expect(controller.project.look, EditorLook.none);
    expect(controller.project.stickerLayers, isEmpty);
  });

  testWidgets('저장 중에는 진행 표시가 편집 화면을 덮는다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(workspace(controller, saving: true));

    expect(find.byKey(const Key('editor-export-blocker')), findsOneWidget);
    expect(tester.widget<FilledButton>(_saveButton()).onPressed, isNull);
  });
}

Finder _action(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(TextButton),
);

Finder _saveButton() => find.byKey(const Key('editor-save'));
