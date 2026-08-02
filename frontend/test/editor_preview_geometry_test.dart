import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/editor/editor_project.dart';
import 'package:william_james_app/editor/editor_workspace.dart';

void main() {
  EditorProject project({
    EditorCanvasRatio ratio = EditorCanvasRatio.vertical,
    EditorCanvasFit fit = EditorCanvasFit.contain,
    EditorTool tool = EditorTool.cut,
    List<EditorTextLayer> textLayers = const [],
  }) {
    final base = EditorProject.fromSource(
      sourceVideoPath: '/tmp/source.mp4',
      sourceDurationMs: 12000,
      sourceSize: const EditorSourceSize(width: 1920, height: 1080),
    );
    return base.copyWith(
      selectedTool: tool,
      textLayers: textLayers,
      canvas: EditorCanvas(
        sourceAspectRatio: base.sourceSize.aspectRatio,
        ratio: ratio,
        fit: fit,
      ),
    );
  }

  EditorTextLayer layerAt(
    double y, {
    int startMs = 0,
    int endMs = 12000,
  }) => EditorTextLayer(
    id: 'text-1',
    text: '자막',
    position: NormalizedPoint(0.5, y),
    startMs: startMs,
    endMs: endMs,
  );

  group('EditorPreviewGeometry', () {
    test('세로 캔버스에 가로 원본이면 검은 여백을 잘라 보여 줄 수 있다', () {
      final geometry = EditorPreviewGeometry.of(project());
      expect(geometry.letterboxClippable, isTrue);
      // 9:16 캔버스 안 16:9 영상 창: (9/16) / (16/9) ≈ 0.3164
      expect(geometry.videoHeightFraction, closeTo(0.3164, 0.001));
      // 문맥 띠를 더한 최소 표시 범위.
      expect(geometry.minimumVisibleHeightFraction, closeTo(0.367, 0.001));
    });

    test('캔버스 탭에서는 전체 캔버스를 유지한다', () {
      final geometry = EditorPreviewGeometry.of(
        project(tool: EditorTool.ratio),
      );
      expect(geometry.letterboxClippable, isFalse);
      expect(geometry.minimumVisibleHeightFraction, 1.0);
    });

    test('채우기(cover)면 여백이 없으므로 자르지 않는다', () {
      final geometry = EditorPreviewGeometry.of(
        project(fit: EditorCanvasFit.cover),
      );
      expect(geometry.letterboxClippable, isFalse);
      expect(geometry.videoHeightFraction, 1.0);
    });

    test('원본 비율 캔버스는 여백이 없다', () {
      final geometry = EditorPreviewGeometry.of(
        project(ratio: EditorCanvasRatio.original),
      );
      expect(geometry.letterboxClippable, isFalse);
    });

    test('검은 여백에 걸친 글자가 보이는 동안에는 전체 캔버스로 돌아간다', () {
      final geometry = EditorPreviewGeometry.of(
        project(textLayers: [layerAt(0.85)]),
      );
      expect(geometry.letterboxClippable, isFalse);
    });

    test('여백 글자라도 지금 재생 위치에 없으면 다시 잘라 보여 준다', () {
      final geometry = EditorPreviewGeometry.of(
        project(textLayers: [layerAt(0.85, startMs: 6000, endMs: 9000)]),
      );
      // 재생 위치 0ms에는 보이지 않는 레이어다.
      expect(geometry.letterboxClippable, isTrue);
    });

    test('영상 창 위 글자는 잘라 보여 주기를 막지 않는다', () {
      final geometry = EditorPreviewGeometry.of(
        project(textLayers: [layerAt(0.5)]),
      );
      expect(geometry.letterboxClippable, isTrue);
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

    testWidgets('자를 수 있으면 캔버스를 폭에 맞추고 세로만 잘라낸다', (tester) async {
      final geometry = EditorPreviewGeometry.of(project());
      await tester.pumpWidget(
        host(area: const Size(360, 420), geometry: geometry),
      );
      final viewport = tester.getSize(
        find.byKey(const Key('editor-canvas-viewport')),
      );
      // 폭은 전부 쓰고(360), 세로는 주어진 420만 쓴다. 온전한 9:16 캔버스는
      // 640이 필요했다 — 그만큼 다른 조각이 쓸 수 있다.
      expect(viewport.width, closeTo(360, 0.1));
      expect(viewport.height, closeTo(420, 0.1));
      // 내용(캔버스)은 온전한 비율로 잘려 그려진다.
      final content = tester.getSize(
        find.byKey(const Key('viewport-content')),
      );
      expect(content.width, closeTo(360, 0.1));
      expect(content.height, closeTo(640, 0.1));
    });

    testWidgets('자를 수 없으면 예전처럼 높이에 맞춘다', (tester) async {
      final geometry = EditorPreviewGeometry.of(
        project(tool: EditorTool.ratio),
      );
      await tester.pumpWidget(
        host(area: const Size(360, 420), geometry: geometry),
      );
      final viewport = tester.getSize(
        find.byKey(const Key('editor-canvas-viewport')),
      );
      expect(viewport.height, closeTo(420, 0.1));
      expect(viewport.width, closeTo(420 * 9 / 16, 0.5));
    });

    testWidgets('영상 창과 문맥 띠조차 안 들어가면 폭을 줄인다', (tester) async {
      final geometry = EditorPreviewGeometry.of(project());
      await tester.pumpWidget(
        host(area: const Size(360, 120), geometry: geometry),
      );
      final viewport = tester.getSize(
        find.byKey(const Key('editor-canvas-viewport')),
      );
      // 최소 표시 높이 = 640 × 0.367 ≈ 235 > 120 → 폭이 그 비율로 준다.
      expect(viewport.height, closeTo(120, 0.1));
      expect(viewport.width, lessThan(360));
    });
  });
}
