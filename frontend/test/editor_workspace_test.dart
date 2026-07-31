import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/editor/editor_project.dart';
import 'package:william_james_app/editor/editor_project_controller.dart';
import 'package:william_james_app/editor/editor_workspace.dart';

void main() {
  for (final size in const [Size(360, 740), Size(390, 844), Size(412, 915)]) {
    testWidgets('${size.width.toInt()}×${size.height.toInt()}에서 넘치지 않는다', (
      tester,
    ) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = EditorProjectController(
        EditorProject.fromSource(
          sourceVideoPath: '/tmp/source.mp4',
          sourceDurationMs: 12000,
          sourceSize: const EditorSourceSize(width: 1920, height: 1080),
        ),
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EditorWorkspace(
              controller: controller,
              preview: const ColoredBox(color: Colors.black),
              thumbnails: const [],
              playing: false,
              currentTime: '00:00',
              totalTime: '00:12',
              saving: false,
              onBack: () {},
              onSave: () {},
              onPlay: () {},
              onSeek: (_) {},
              onSplit: () {},
              onDelete: () {},
              onDuplicate: () {},
              onTrimStartChanged: (_) {},
              onTrimEndChanged: (_) {},
              onRatioSelected: (_) {},
              onText: () {},
              onVolumeChanged: (_) {},
              onMutedChanged: (_) {},
              onStickerSelected: (_) {},
              onAr: () {},
              onToolSelected: controller.selectTool,
            ),
          ),
        ),
      );

      expect(find.text('영상 편집'), findsOneWidget);
      expect(find.text('컷 편집'), findsOneWidget);
      expect(find.text('비율'), findsOneWidget);
      expect(find.text('텍스트'), findsOneWidget);
      expect(find.text('오디오'), findsOneWidget);
      expect(find.text('스티커'), findsOneWidget);
      expect(find.text('AR'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('중앙 재생 바를 드래그하면 재생 헤드 위치와 표시선이 함께 움직인다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: '/tmp/source.mp4',
        sourceDurationMs: 12000,
        sourceSize: const EditorSourceSize(width: 1920, height: 1080),
      ),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorWorkspace(
            controller: controller,
            preview: const ColoredBox(color: Colors.black),
            thumbnails: const [],
            playing: false,
            currentTime: '00:00',
            totalTime: '00:12',
            saving: false,
            onBack: () {},
            onSave: () {},
            onPlay: () {},
            onSeek: controller.setPlayhead,
            onSplit: () => controller.splitAt(controller.project.playheadMs),
            onDelete: controller.deleteSelectedClip,
            onDuplicate: controller.duplicateSelectedClip,
            onTrimStartChanged: (value) {
              controller.trimSelectedClip(sourceStartMs: value);
            },
            onTrimEndChanged: (value) {
              controller.trimSelectedClip(sourceEndMs: value);
            },
            onRatioSelected: (_) {},
            onText: () {},
            onVolumeChanged: (_) {},
            onMutedChanged: (_) {},
            onStickerSelected: (_) {},
            onAr: () {},
            onToolSelected: controller.selectTool,
          ),
        ),
      ),
    );

    final slider = find.byKey(const Key('editor-timeline-slider'));
    expect(slider, findsOneWidget);
    await tester.drag(slider, const Offset(120, 0));
    await tester.pump();

    expect(controller.project.playheadMs, greaterThan(0));
    final playhead = tester.widget<Align>(
      find.byKey(const Key('editor-playhead')),
    );
    final alignment = playhead.alignment as Alignment;
    final expectedX = -1 + 2 * controller.project.playheadMs / 12000;
    expect(alignment.x, closeTo(expectedX, 0.01));

    final range = tester.widget<RangeSlider>(
      find.byKey(const Key('editor-trim-range')),
    );
    range.onChanged!(const RangeValues(1000, 11000));
    await tester.pump();
    expect(controller.project.selectedClip?.sourceStartMs, 1000);
    expect(controller.project.selectedClip?.sourceEndMs, 11000);

    await tester.tap(find.text('복제'));
    await tester.pump();
    expect(controller.project.clips, hasLength(2));

    await tester.tap(find.text('삭제'));
    await tester.pump();
    expect(controller.project.clips, hasLength(1));

    controller.setPlayhead(4000);
    await tester.pump();
    await tester.tap(find.text('분할'));
    await tester.pump();
    expect(controller.project.clips, hasLength(2));
  });

  testWidgets('AR 탭에서 Banuba 얼굴 AR 편집기를 실행한다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: '/tmp/source.mp4',
        sourceDurationMs: 12000,
        sourceSize: const EditorSourceSize(width: 1920, height: 1080),
      ),
    )..selectTool(EditorTool.ar);
    addTearDown(controller.dispose);
    var opened = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorWorkspace(
            controller: controller,
            preview: const ColoredBox(color: Colors.black),
            thumbnails: const [],
            playing: false,
            currentTime: '00:00',
            totalTime: '00:12',
            saving: false,
            onBack: () {},
            onSave: () {},
            onPlay: () {},
            onSeek: controller.setPlayhead,
            onSplit: () {},
            onDelete: () {},
            onDuplicate: () {},
            onTrimStartChanged: (_) {},
            onTrimEndChanged: (_) {},
            onRatioSelected: (_) {},
            onText: () {},
            onVolumeChanged: (_) {},
            onMutedChanged: (_) {},
            onStickerSelected: (_) {},
            onAr: () => opened = true,
            onToolSelected: controller.selectTool,
          ),
        ),
      ),
    );

    final button = find.byKey(const Key('open-banuba-ar-editor'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    expect(opened, isTrue);
  });
}
