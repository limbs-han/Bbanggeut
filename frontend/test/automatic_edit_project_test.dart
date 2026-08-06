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

    final project = controller.project;
    // 추천 컷은 이어진 한 구간이다 — 서버 셀렉터가 점수로 고른 58~120초.
    final clip = project.clips.single;
    expect(clip.sourceStartMs, 58000);
    expect(clip.sourceEndMs, 120000);
    expect(project.durationMs, 62000);
    expect(project.zoomAtTimeline(45125), isNotNull);
    final platform = project.toPlatformMap(outputPath: '/tmp/out.mp4');
    final zoom = (platform['zoomSegments'] as List).single as Map;
    expect(zoom['startMs'], 45125);
    expect(zoom['endMs'], 49125);
  });

  test('프리셋은 고른 클립의 구간만 바꾸고 다른 클립은 그대로 둔다', () {
    final controller = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: '/tmp/source.mp4',
        sourceDurationMs: 12000,
        sourceSize: const EditorSourceSize(width: 1920, height: 1080),
      ),
    )..splitAt(5000);
    // 나눈 뒤에는 오른쪽 조각이 골라져 있다. 왼쪽은 사용자가 남긴 클립이다.
    final clips = controller.project.clips;
    final kept = clips.first;
    final selectedId = controller.project.selectedClipId;

    controller.applyRecommendation(
      const EditRecommendation(
        cutStartMs: 2000,
        cutEndMs: 9000,
        durationPreset: 'short',
        zoomSegments: [],
      ),
    );

    // 클립 수는 그대로, 고른 클립만 추천 구간(이어진 한 구간)이 됐다.
    final project = controller.project;
    expect(project.clips, hasLength(2));
    expect(project.clips.first, kept, reason: '남긴 클립이 지워지거나 바뀌었다');
    final changed = project.clips.last;
    expect(changed.id, selectedId);
    expect(changed.sourceStartMs, 2000);
    expect(changed.sourceEndMs, 9000);
    expect(project.recommendationMarker?.preset, 'short');

    // 잘못 눌렀으면 되돌리기 한 번으로 이전 구간이 그대로 돌아온다.
    controller.undo();
    expect(
      controller.project.clips.map(
        (c) => '${c.sourceStartMs}-${c.sourceEndMs}',
      ),
      clips.map((c) => '${c.sourceStartMs}-${c.sourceEndMs}'),
    );
  });

  test('scoreTimeline의 eventScore가 클립 점수로 그대로 실린다', () {
    final controller = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: '/tmp/source.mp4',
        sourceDurationMs: 60000,
        sourceSize: const EditorSourceSize(width: 1920, height: 1080),
      ),
    );
    // 앞 6초는 웃음이 강한 장면(0.8), 뒤는 잔잔한 장면(0.2)이라고 서버가
    // 분석해 줬다 — adaptive_selector.build_timeline의 1초 bin 형식 그대로.
    controller.applyRecommendation(
      EditRecommendation(
        cutStartMs: 0,
        cutEndMs: 12000,
        durationPreset: 'short',
        zoomSegments: const [],
        scoreTimeline: [
          for (var startMs = 0; startMs < 12000; startMs += 1000)
            {
              'startMs': startMs,
              'endMs': startMs + 1000,
              'eventScore': startMs < 6000 ? 0.8 : 0.2,
            },
        ],
      ),
    );

    // 컷 구간의 사건 점수 평균이 클립에 그대로 실린다(0.8과 0.2의 절반씩).
    final clip = controller.project.clips.single;
    expect(clip.sourceStartMs, 0);
    expect(clip.sourceEndMs, 12000);
    expect(clip.score, closeTo(0.5, 0.01));
  });

  test('줌·자막은 클립에 묶여 함께 움직이고, 클립과 함께 사라진다', () {
    final controller = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: '/tmp/source.mp4',
        sourceDurationMs: 12000,
        sourceSize: const EditorSourceSize(width: 1920, height: 1080),
      ),
    )..splitAt(6000);
    final clipA = controller.project.clips.first; // 0~6초
    final clipB = controller.project.clips.last; // 6~12초

    // A 클립 안(재생 1초)에 줌, B 클립 구간(7~9초)에 자막을 만든다.
    controller.setPlayhead(1000);
    expect(controller.addZoomAtPlayhead(), isTrue);
    final zoom = controller.project.zoomSegments.single;
    expect(zoom.clipId, clipA.id);
    controller.addTextLayer(text: '자막', startMs: 7000, endMs: 9000);
    expect(controller.project.textLayers.single.clipId, clipB.id);

    // 순서를 바꾸면(B, A) 자막은 B를 따라 앞으로 온다.
    controller.reorderClip(0, 1);
    final movedLayer = controller.project.textLayers.single;
    expect(movedLayer.startMs, 1000);
    expect(movedLayer.endMs, 3000);
    // 줌도 A를 따라간다 — A의 원본 1초 지점은 이제 타임라인 7초다.
    expect(controller.project.zoomAtTimeline(7000)?.id, zoom.id);
    expect(controller.project.zoomAtTimeline(1000), isNull);

    // A 클립을 지우면 거기 묶인 줌도 함께 사라진다.
    controller.selectClip(clipA.id);
    expect(controller.deleteSelectedClip(), isTrue);
    expect(controller.project.zoomSegments, isEmpty);
    expect(controller.project.textLayers, hasLength(1), reason: 'B의 자막은 남는다');
  });

  test('서버 없이도 프리셋이 점수 규칙으로 여러 클립을 뽑는다', () {
    final controller = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: '/tmp/source.mp4',
        sourceDurationMs: 60000,
        sourceSize: const EditorSourceSize(width: 1920, height: 1080),
      ),
    );

    controller.applyPreset('short');

    // 짧게 = 이어진 45초 이하 한 구간. 서버 점수가 없으니 가운데를 남기고,
    // 점수는 표시하지 않는다(null).
    final project = controller.project;
    final clip = project.clips.single;
    expect(project.durationMs, 45000);
    expect(clip.sourceStartMs, 7500);
    expect(clip.sourceEndMs, 52500);
    expect(clip.score, isNull);
    expect(project.recommendationMarker?.preset, 'short');

    // 중간·길게는 90초 기준 — 60초 원본이면 전체가 남는다.
    controller.applyPreset('medium');
    expect(controller.project.durationMs, 60000);
    controller.applyPreset('long');
    expect(controller.project.durationMs, 60000);
  });
}
