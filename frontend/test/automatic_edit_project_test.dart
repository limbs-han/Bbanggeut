import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/editor/edit_recommendation_client.dart';
import 'package:william_james_app/editor/editor_project.dart';
import 'package:william_james_app/editor/editor_project_controller.dart';

void main() {
  test('같은 원본에서 한 프레임 이내로 붙은 클립은 끊김 없이 이어진다', () {
    const first = EditorClip(
      id: 'first',
      sourcePath: '/tmp/source.mp4',
      sourceStartMs: 1000,
      sourceEndMs: 5000,
    );
    const next = EditorClip(
      id: 'next',
      sourcePath: '/tmp/source.mp4',
      sourceStartMs: 5034,
      sourceEndMs: 8000,
    );
    const jumped = EditorClip(
      id: 'jumped',
      sourcePath: '/tmp/source.mp4',
      sourceStartMs: 5100,
      sourceEndMs: 8000,
    );

    expect(first.isPlaybackContiguousWith(next), isTrue);
    expect(first.isPlaybackContiguousWith(jumped), isFalse);
  });

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
