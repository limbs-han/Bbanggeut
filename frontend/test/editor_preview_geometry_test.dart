import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/editor/editor_project.dart';
import 'package:william_james_app/editor/editor_workspace.dart';

void main() {
  EditorProject project({
    EditorCanvasRatio ratio = EditorCanvasRatio.vertical,
    EditorCanvasFit fit = EditorCanvasFit.contain,
    EditorTool tool = EditorTool.cut,
  }) {
    final base = EditorProject.fromSource(
      sourceVideoPath: '/tmp/source.mp4',
      sourceDurationMs: 12000,
      sourceSize: const EditorSourceSize(width: 1920, height: 1080),
    );
    return base.copyWith(
      selectedTool: tool,
      canvas: EditorCanvas(
        sourceAspectRatio: base.sourceSize.aspectRatio,
        ratio: ratio,
        fit: fit,
      ),
    );
  }

  group('EditorPreviewGeometry', () {
    test('9:16 검은 띠는 자막 자리이므로 어느 탭에서도 잘라 숨기지 않는다', () {
      // 예전에는 컷 탭에서 위아래 여백을 잘라 프레임 띠에 자리를 줬다.
      // 지금은 띠가 편집 대상(자막 자리)이라 항상 전체 캔버스를 보여 준다.
      for (final tool in EditorTool.values) {
        final geometry = EditorPreviewGeometry.of(project(tool: tool));
        expect(geometry.letterboxClippable, isFalse, reason: '$tool');
        expect(geometry.minimumVisibleHeightFraction, 1.0);
      }
    });

    test('영상 창 비율은 그대로 계산된다', () {
      final geometry = EditorPreviewGeometry.of(project());
      // 9:16 캔버스 안 16:9 영상 창: (9/16) / (16/9) ≈ 0.3164
      expect(geometry.videoHeightFraction, closeTo(0.3164, 0.001));
    });

    test('채우기(cover)·원본 비율은 여백이 없다', () {
      expect(
        EditorPreviewGeometry.of(
          project(fit: EditorCanvasFit.cover),
        ).videoHeightFraction,
        1.0,
      );
      expect(
        EditorPreviewGeometry.of(
          project(ratio: EditorCanvasRatio.original),
        ).videoHeightFraction,
        1.0,
      );
    });
  });

  group('EditorCanvasViewport', () {
    Widget host({
      required Size area,
      required EditorPreviewGeometry geometry,
    }) => MaterialApp(
      home: Center(
        child: SizedBox(
          width: area.width,
          height: area.height,
          child: EditorCanvasViewport(
            geometry: geometry,
            child: const ColoredBox(
              key: Key('viewport-content'),
              color: Colors.black,
            ),
          ),
        ),
      ),
    );

    testWidgets('세로 캔버스는 잘리지 않고 높이에 맞춘다', (tester) async {
      final geometry = EditorPreviewGeometry.of(project());
      await tester.pumpWidget(
        host(area: const Size(360, 420), geometry: geometry),
      );
      final viewport = tester.getSize(
        find.byKey(const Key('editor-canvas-viewport')),
      );
      // 9:16 캔버스 전체가 보인다 — 위아래 검은 띠 포함.
      expect(viewport.height, closeTo(420, 0.1));
      expect(viewport.width, closeTo(420 * 9 / 16, 0.5));
    });
  });
}
