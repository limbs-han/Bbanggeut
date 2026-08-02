import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/editor/edit_recommendation_client.dart';
import 'package:william_james_app/editor/editor_project.dart';
import 'package:william_james_app/editor/editor_project_controller.dart';

void main() {
  test('automatic recipe applies cut and maps zoom to edited timeline', () {
    final controller = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: '/tmp/source.mp4',
        sourceDurationMs: 120000,
        sourceSize: const EditorSourceSize(width: 1280, height: 720),
      ),
    );
    controller.applyRecommendation(
      const EditRecommendation(
        cutStartMs: 58000,
        cutEndMs: 120000,
        durationPreset: 'medium',
        zoomSegments: [
          {
            'startMs': 103125,
            'endMs': 107125,
            'scale': 1.73,
            'focusX': 0.14,
            'focusY': 0.71,
          },
        ],
      ),
    );

    expect(controller.project.durationMs, 62000);
    expect(controller.project.zoomAtTimeline(45125), isNotNull);
    final platform = controller.project.toPlatformMap(
      outputPath: '/tmp/out.mp4',
    );
    final zoom = (platform['zoomSegments'] as List).single as Map;
    expect(zoom['startMs'], 45125);
    expect(zoom['endMs'], 49125);
  });
}
