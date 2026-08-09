/// 저장한 초안을 그대로 열어 내보낼 때 얼굴 추적이 살아 있는가.
///
/// 서버에 저장된 실제 초안(65b83210, revision 8)과 같은 모양으로 확인한다 —
/// 초안에는 창 모델과 키프레임이 들어 있는데 내보낸 영상이 따라가지 않는다는
/// 보고가 있었다.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/editor/editor_project.dart';
import 'package:william_james_app/editor/editor_project_controller.dart';

void main() {
  test('초안으로 연 자동 줌은 내보내기까지 초점 키프레임을 들고 간다', () {
    final controller = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: '/tmp/source.mp4',
        sourceDurationMs: 120000,
        sourceSize: const EditorSourceSize(width: 1280, height: 720),
      ),
    );

    // 서버 초안과 같은 모양(toDraftMap이 굽는 그대로).
    controller.loadDraftRecipe({
      'type': 'draft-v1',
      'sourceDurationMs': 120000,
      'clips': [
        {
          'id': 'clip-1',
          'sourceStartMs': 0,
          'sourceEndMs': 97000,
          'automatic': true,
        },
      ],
      'zoomSegments': [
        {
          'id': 'auto-zoom-0',
          'sourceStartMs': 2600,
          'sourceEndMs': 6600,
          'scale': 2.53,
          'focusX': 0.52,
          'focusY': 0.18,
          'automatic': true,
          'clipId': 'clip-1',
          'focusModel': 'window',
          'focusTrack': [
            {'ms': 2600, 'dx': 0.0, 'dy': 0.0},
            {'ms': 4600, 'dx': -0.05, 'dy': 0.04},
            {'ms': 6600, 'dx': -0.10, 'dy': 0.08},
          ],
        },
      ],
    });

    final zoom = controller.project.zoomSegments.single;
    expect(zoom.focusModel, EditorZoomFocusModel.window, reason: '초안의 창 모델이 안 읽혔다');
    expect(zoom.focusTrack, hasLength(3), reason: '초안의 초점 키프레임이 안 읽혔다');
    expect(zoom.tracksFace, isTrue);

    final platform = controller.project.toPlatformMap(outputPath: '/tmp/out.mp4');
    final exported = (platform['zoomSegments'] as List).single as Map;
    final track = (exported['focusTrack'] as List?)?.cast<Map>();

    expect(track, isNotNull, reason: '내보내기 지도에 초점 키프레임이 안 실렸다');
    expect(track, isNotEmpty);
    // 사람이 왼쪽으로 갔으니 기준점도 왼쪽으로 가야 한다.
    final first = (track!.first['x'] as num).toDouble();
    final last = (track.last['x'] as num).toDouble();
    expect(last, lessThan(first), reason: '키프레임이 있는데 기준점이 안 움직인다');
    // 네이티브가 그대로 쓰는 값이므로 0~1을 벗어나면 안 된다.
    for (final sample in track) {
      expect((sample['x'] as num).toDouble(), inInclusiveRange(0.0, 1.0));
      expect((sample['y'] as num).toDouble(), inInclusiveRange(0.0, 1.0));
    }
  });
}
