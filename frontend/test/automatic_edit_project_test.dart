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

  test('자동 줌은 사람이 움직이면 초점을 따라 옮긴다', () {
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
            'startMs': 100000,
            'endMs': 102000,
            'scale': 1.8,
            'focusX': 0.30,
            'focusY': 0.50,
            'faceTrackId': 'face-1',
            // 잡은 사람이 오른쪽으로 걸어간다.
            'focusTrack': [
              {'ms': 100000, 'dx': 0.0, 'dy': 0.0},
              {'ms': 101000, 'dx': 0.10, 'dy': 0.02},
              {'ms': 102000, 'dx': 0.20, 'dy': 0.04},
            ],
          },
        ],
      ),
    );

    final project = controller.project;
    final zoom = project.zoomSegments.single;
    expect(zoom.tracksFace, isTrue);
    expect(zoom.faceTrackId, 'face-1');
    // 구간 시작은 기준 초점 그대로, 뒤로 갈수록 사람을 따라 옮겨진다.
    expect(zoom.focusAt(100000).x, closeTo(0.30, 1e-9));
    expect(zoom.focusAt(101500).x, closeTo(0.45, 1e-9));
    expect(zoom.focusAt(102000).y, closeTo(0.54, 1e-9));
    // 구간 밖은 양 끝 값을 그대로 쓴다 — 초점이 튀지 않는다.
    expect(zoom.focusAt(99000).x, closeTo(0.30, 1e-9));
    expect(zoom.focusAt(109000).x, closeTo(0.50, 1e-9));

    // 초점을 손으로 끌면 따라가는 경로 전체가 같이 옮겨진다.
    final nudged = zoom.copyWith(focus: NormalizedPoint(0.40, 0.50));
    expect(nudged.focusAt(102000).x, closeTo(0.60, 1e-9));

    // 내보내기에는 타임라인 시각의 절대 초점 키프레임으로 구워 넘긴다.
    final platform = project.toPlatformMap(outputPath: '/tmp/out.mp4');
    final exported = (platform['zoomSegments'] as List).single as Map;
    final track = (exported['focusTrack'] as List).cast<Map>();
    expect(track.first['ms'], exported['startMs']);
    expect(track.last['ms'], exported['endMs']);
    expect(track.first['x'], closeTo(0.30, 1e-9));
    expect(track.last['x'], closeTo(0.50, 1e-9));
  });

  test('자동 줌은 얼굴을 화면의 45%까지 키우되 안전 상한을 넘지 않는다', () {
    EditorZoomSegment zoomFrom(Map<String, Object> raw) {
      final controller = EditorProjectController(
        EditorProject.fromSource(
          sourceVideoPath: '/tmp/source.mp4',
          sourceDurationMs: 120000,
          sourceSize: const EditorSourceSize(width: 1280, height: 720),
        ),
      );
      controller.applyRecommendation(
        EditRecommendation(
          cutStartMs: 0,
          cutEndMs: 120000,
          durationPreset: 'medium',
          zoomSegments: [raw],
        ),
      );
      return controller.project.zoomSegments.single;
    }

    const base = {
      'startMs': 10000,
      'endMs': 13000,
      'scale': 1.5,
      'focusX': 0.5,
      'focusY': 0.5,
      // 서버는 얼굴을 화면의 0.30으로 맞춘 배율을 준다.
      'targetFaceHeight': 0.30,
    };

    // 화면의 45%를 노리므로 서버 배율의 0.45/0.30배가 된다.
    expect(zoomFrom(base).scale, closeTo(2.25, 1e-9));

    // 가장자리에 선 얼굴은 서버가 계산한 상한이 먼저 막는다.
    expect(zoomFrom({...base, 'maxScale': 1.8}).scale, closeTo(1.8, 1e-9));

    // 상한이 여유로우면 그대로 키운다.
    expect(zoomFrom({...base, 'maxScale': 2.8}).scale, closeTo(2.25, 1e-9));
  });

  test('지운 AI 줌은 컷을 건드리지 않고 다시 불러올 수 있다', () {
    const recommendation = EditRecommendation(
      cutStartMs: 58000,
      cutEndMs: 120000,
      durationPreset: 'medium',
      zoomSegments: [
        {
          'startMs': 100000,
          'endMs': 102000,
          'scale': 1.5,
          'focusX': 0.3,
          'focusY': 0.5,
          'targetFaceHeight': 0.30,
        },
        {
          'startMs': 110000,
          'endMs': 112000,
          'scale': 1.5,
          'focusX': 0.6,
          'focusY': 0.5,
          'targetFaceHeight': 0.30,
        },
      ],
    );
    final controller = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: '/tmp/source.mp4',
        sourceDurationMs: 120000,
        sourceSize: const EditorSourceSize(width: 1280, height: 720),
      ),
    )..applyRecommendation(recommendation);

    // 사용자가 직접 만든 줌 하나를 섞어 둔다 — 되돌리기가 이걸 지우면 안 된다.
    controller.setPlayhead(2000);
    expect(controller.addZoomAtPlayhead(), isTrue);
    final manual = controller.project.zoomSegments
        .firstWhere((zoom) => !zoom.automatic)
        .id;

    for (final zoom in controller.project.zoomSegments
        .where((zoom) => zoom.automatic)
        .toList()) {
      controller.removeZoom(zoom);
    }
    final clip = controller.project.clips.single;
    expect(controller.project.zoomSegments.map((z) => z.id), [manual]);

    expect(controller.restoreAutomaticZooms(recommendation), isTrue);

    final zooms = controller.project.zoomSegments;
    expect(zooms.where((zoom) => zoom.automatic), hasLength(2));
    // 손으로 만든 줌은 그대로 남는다.
    expect(zooms.where((zoom) => zoom.id == manual), hasLength(1));
    // 컷은 손대지 않는다 — 되돌린 것은 줌뿐이다.
    expect(controller.project.clips.single.sourceStartMs, clip.sourceStartMs);
    expect(controller.project.clips.single.sourceEndMs, clip.sourceEndMs);
    // 되돌린 줌도 배율 규칙을 그대로 따른다(1.5 × 0.45/0.30).
    expect(
      zooms.firstWhere((zoom) => zoom.automatic).scale,
      closeTo(2.25, 1e-9),
    );
  });

  test('클립 구간 밖의 AI 줌은 되돌리지 않는다', () {
    const recommendation = EditRecommendation(
      cutStartMs: 0,
      cutEndMs: 10000,
      durationPreset: 'short',
      zoomSegments: [
        {
          'startMs': 100000,
          'endMs': 102000,
          'scale': 1.5,
          'focusX': 0.3,
          'focusY': 0.5,
          'targetFaceHeight': 0.30,
        },
      ],
    );
    final controller = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: '/tmp/source.mp4',
        sourceDurationMs: 120000,
        sourceSize: const EditorSourceSize(width: 1280, height: 720),
      ),
    );
    // 컷은 0~10초인데 줌은 100초대다 — 이미 잘려 나간 장면이다.
    controller.trimSelectedClip(sourceStartMs: 0, sourceEndMs: 10000);

    expect(controller.restoreAutomaticZooms(recommendation), isFalse);
    expect(controller.project.zoomSegments, isEmpty);
  });

  group('줌 기하', () {
    EditorZoomSegment zoom({
      required double scale,
      required NormalizedPoint focus,
      EditorZoomFocusModel model = EditorZoomFocusModel.window,
    }) => EditorZoomSegment(
      id: 'z',
      sourceStartMs: 0,
      sourceEndMs: 2000,
      scale: scale,
      focus: focus,
      focusModel: model,
    );

    test('창 모델은 초점을 창 중심으로 쓰고 프레임 안으로 밀어 넣는다', () {
      // 2배 확대면 창은 0.5 크기다 — 중심이 0.25보다 왼쪽으로 갈 수 없다.
      final edge = zoom(scale: 2, focus: NormalizedPoint(0.05, 0.5));
      expect(edge.windowCenterAt(0).x, closeTo(0.25, 1e-9));
      // 가운데 초점은 그대로다.
      final middle = zoom(scale: 2, focus: NormalizedPoint.center);
      expect(middle.windowCenterAt(0).x, closeTo(0.5, 1e-9));
    });

    test('창 중심에 있는 점은 화면 가운데로 간다', () {
      final segment = zoom(scale: 2, focus: NormalizedPoint(0.3, 0.6));
      final centre = segment.projectPoint(0.3, 0.6, 0);
      expect(centre.x, closeTo(0.5, 1e-9));
      expect(centre.y, closeTo(0.5, 1e-9));
    });

    test('가장자리 얼굴도 창 모델에서는 화면 안에 들어온다', () {
      // 얼굴 중심 0.14, 폭 0.12 -> 왼쪽 변 0.08. 2.5배로 키운다.
      final segment = zoom(scale: 2.5, focus: NormalizedPoint(0.14, 0.5));
      final left = segment.projectPoint(0.08, 0.5, 0).x;
      final right = segment.projectPoint(0.20, 0.5, 0).x;
      expect(left, greaterThanOrEqualTo(0.0));
      expect(right, lessThanOrEqualTo(1.0));

      // 옛(anchor) 방식에서는 같은 배율에 왼쪽 변이 화면을 벗어난다.
      final old = zoom(
        scale: 2.5,
        focus: NormalizedPoint(0.14, 0.5),
        model: EditorZoomFocusModel.anchor,
      );
      expect(old.projectPoint(0.08, 0.5, 0).x, lessThan(0));
    });

    test('기준점 환산은 미리보기 확대와 창 중심을 일치시킨다', () {
      for (final focusX in const [0.05, 0.2, 0.5, 0.8, 0.97]) {
        const scale = 2.0;
        final segment = zoom(scale: scale, focus: NormalizedPoint(focusX, 0.5));
        final pivot = segment.pivotAt(0);
        // Transform.scale(alignment: pivot)이 보여 주는 창의 중심.
        final shown = pivot.x + (0.5 - pivot.x) / scale;
        expect(shown, closeTo(segment.windowCenterAt(0).x, 1e-9));
        expect(pivot.x, inInclusiveRange(0.0, 1.0));
      }
    });

    test('옛 줌은 기준점이 초점 그대로다 — 저장해 둔 프레이밍이 안 바뀐다', () {
      final old = zoom(
        scale: 2,
        focus: NormalizedPoint(0.14, 0.71),
        model: EditorZoomFocusModel.anchor,
      );
      expect(old.pivotAt(0), NormalizedPoint(0.14, 0.71));
      expect(old.windowCenterAt(0), NormalizedPoint(0.14, 0.71));
    });
  });

  test('따라갈 궤적이 없는 줌은 초점이 고정이고 키프레임도 없다', () {
    final zoom = EditorZoomSegment(
      id: 'zoom-1',
      sourceStartMs: 1000,
      sourceEndMs: 3000,
      scale: 1.5,
      focus: NormalizedPoint(0.4, 0.6),
    );

    expect(zoom.tracksFace, isFalse);
    expect(zoom.focusAt(2000), NormalizedPoint(0.4, 0.6));
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
