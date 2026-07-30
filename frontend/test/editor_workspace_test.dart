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
}
