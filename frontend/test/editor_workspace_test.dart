import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/editor/editor_ar_effects.dart';
import 'package:william_james_app/editor/editor_project.dart';
import 'package:william_james_app/editor/editor_project_controller.dart';
import 'package:william_james_app/editor/editor_trim_bar.dart';
import 'package:william_james_app/editor/editor_workspace.dart';
import 'package:william_james_app/editor/edit_recommendation_client.dart';

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
    VoidCallback? onClipAdd,
    VoidCallback? onDelete,
    void Function(int startMs, int endMs, bool startHandle)? onTrimChanged,
    VoidCallback? onTrimCommitted,
    ValueChanged<String>? onStickerSelected,
    ValueChanged<EditorLook>? onLookSelected,
    VoidCallback? onAiCaption,
    ValueChanged<EditorZoomSegment>? onZoomChanged,
    ValueChanged<String>? onTextEdit,
    VoidCallback? onPlayRange,
    ValueChanged<String>? onBlocked,
    List<String> thumbnails = const [],
    bool saving = false,
    bool textEditing = false,
    bool rangePreviewing = false,
    Map<String, EditRecommendation> presetRecommendations = const {},
    ValueChanged<String>? onRecommendationSelected,
  }) => MaterialApp(
    home: Scaffold(
      body: EditorWorkspace(
        controller: controller,
        preview: const ColoredBox(color: Colors.black),
        thumbnails: thumbnails,
        playing: false,
        saving: saving,
        textEditing: textEditing,
        rangePreviewing: rangePreviewing,
        onPlayRange: onPlayRange ?? () {},
        onBlocked: onBlocked ?? (_) {},
        onBack: () {},
        onSaveDraft: () {},
        onSave: () {},
        onPlay: () {},
        onSeek: onSeek ?? (_) {},
        onClipAdd: onClipAdd ?? () {},
        onDelete: onDelete ?? () {},
        onClipReorder: controller.reorderClip,
        onTrimChanged: onTrimChanged ?? (_, _, _) {},
        onTrimCommitted: onTrimCommitted ?? () {},
        onRatioSelected: (_) {},
        onEditCommitted: controller.endGesture,
        presetRecommendations: presetRecommendations,
        recommendationLoading: false,
        onRecommendationSelected: onRecommendationSelected ?? (_) {},
        onText: () {},
        onTextEdit: onTextEdit ?? (_) {},
        onTextRemove: (_) {},
        onVolumeChanged: (_) {},
        onMutedChanged: (_) {},
        onStickerSelected: onStickerSelected ?? (_) {},
        onLookSelected: onLookSelected ?? (_) {},
        onAiCaption: onAiCaption ?? () {},
        onZoomAdd: () {},
        onZoomRemove: (_) {},
        onZoomSelected: (_) {},
        onToolSelected: controller.selectTool,
      ),
    ),
  );

  /// 구간 막대와 화면을 잇는 배선. 실제 편집 화면이 하는 것과 같다 — 끄는
  /// 동안에는 이력을 쌓지 않고, 손을 뗄 때 한 칸만 쌓는다.
  Widget trimmableWorkspace(
    EditorProjectController controller, {
    List<String> thumbnails = const [],
  }) => workspace(
    controller,
    thumbnails: thumbnails,
    onTrimChanged: (startMs, endMs, _) {
      controller.beginGesture();
      controller.trimSelectedClip(
        sourceStartMs: startMs,
        sourceEndMs: endMs,
        commit: false,
        notify: false,
      );
    },
    onTrimCommitted: controller.endGesture,
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
        '줌',
        '자막',
        '오디오',
        '스티커',
        '효과',
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
        // 색감을 켜도 효과 패널이 넘치지 않아야 한다.
        controller
          ..selectTool(EditorTool.effect)
          ..setLook(EditorLook.mono);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(tester.takeException(), isNull);
      },
    );
  }

  /// 갤럭시 S24+ 기준. 논리 411×891dp에서 상태바·제스처바를 뺀 안쪽이다.
  const galaxyS24Plus = Size(411, 840);

  testWidgets('S24+에서 미리보기가 어느 탭에서도 화면의 절반을 넘게 쓴다', (tester) async {
    tester.view
      ..physicalSize = galaxyS24Plus
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      workspace(controller, onSeek: controller.setPlayhead),
    );

    for (final tool in EditorTool.values) {
      controller.selectTool(tool);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final preview = tester.getSize(find.byType(VideoPreviewWorkspace));
      expect(
        preview.height,
        greaterThan(galaxyS24Plus.height * 0.5),
        reason: '$tool 탭에서 미리보기가 눌렸다',
      );
      expect(tester.takeException(), isNull, reason: '$tool 탭이 넘쳤다');
    }
  });

  testWidgets('세로 비율을 골라도 채우기로 그려져 프레임 띠 높이가 유지된다', (tester) async {
    tester.view
      ..physicalSize = galaxyS24Plus
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(workspace(controller));
    final base = tester.getSize(find.byType(TrimRangeBar)).height;

    // 표시 방식 선택은 없앴다. 세로 비율도 채우기(cover)라 검은 여백이
    // 없고, 여백을 프레임 띠로 돌려주던 보정도 일어나지 않는다.
    controller.setCanvasRatio(EditorCanvasRatio.vertical);
    await tester.pump();

    expect(tester.getSize(find.byType(TrimRangeBar)).height, base);
    expect(tester.takeException(), isNull);
  });

  testWidgets('세로가 짧으면 도구 칸이 먼저 양보하고 미리보기는 지켜진다', (tester) async {
    // 효과 탭은 한 뼘 더 쓴다. 이 크기에서는 다 주면 미리보기가 눌린다.
    const short = Size(360, 480);
    tester.view
      ..physicalSize = short
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(workspace(controller));
    controller.selectTool(EditorTool.ar);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final panel = tester.getSize(find.byType(SelectedToolPanel));
    final preview = tester.getSize(find.byType(VideoPreviewWorkspace));
    // 도구 칸이 원하는 만큼(100×1.6=160) 다 가져가지 못했다.
    expect(panel.height, lessThanOrEqualTo(162));
    expect(preview.height, greaterThanOrEqualTo(190));
    expect(tester.takeException(), isNull);
  });

  testWidgets('키보드가 올라오면 꾸밈 줄이 그 바로 위에 붙는다', (tester) async {
    tester.view
      ..physicalSize = galaxyS24Plus
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const keyboard = 320.0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // 화면과 같은 설정. Scaffold가 키보드 자리를 빼면 껍데기가 한 번 더
          // 빼서 줄이 화면 위로 날아간다 — 그래서 여기서는 끈다.
          resizeToAvoidBottomInset: false,
          body: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(viewInsets: const EdgeInsets.only(bottom: keyboard)),
              child: const EditorKeyboardShell(
                bottomBar: SizedBox(
                  key: Key('style-bar'),
                  width: double.infinity,
                  height: 100,
                ),
                child: ColoredBox(color: Colors.black),
              ),
            ),
          ),
        ),
      ),
    );

    final bar = tester.getRect(find.byKey(const Key('style-bar')));
    // 줄의 아랫변이 키보드 윗변에 정확히 닿는다.
    expect(bar.bottom, moreOrLessEquals(galaxyS24Plus.height - keyboard));
    // 그리고 화면 안에 있다. 두 번 빼면 여기가 음수가 된다.
    expect(bar.top, greaterThanOrEqualTo(0));
  });

  testWidgets('글을 쓰는 동안에는 아래 도구가 접히고 미리보기가 넓어진다', (tester) async {
    tester.view
      ..physicalSize = galaxyS24Plus
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);
    controller.selectTool(EditorTool.text);

    await tester.pumpWidget(workspace(controller));
    final before = tester.getSize(find.byType(VideoPreviewWorkspace)).height;

    await tester.pumpWidget(workspace(controller, textEditing: true));

    // 타임라인·도구 칸·하단 네비가 전부 접힌다.
    expect(find.byKey(const Key('editor-timeline-strip')), findsNothing);
    expect(find.byKey(const Key('editor-open-text-sheet')), findsNothing);
    expect(find.byKey(const Key('editor-nav-text')), findsNothing);
    // 그만큼 미리보기가 넓어진다 — 쓰는 글이 영상 위에서 어떻게 보이는지가
    // 이 화면의 전부다.
    final after = tester.getSize(find.byType(VideoPreviewWorkspace)).height;
    expect(after, greaterThan(before));
    expect(tester.takeException(), isNull);
  });

  testWidgets('하단 네비게이션은 아홉 개 도구를 전부 제공한다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(workspace(controller));

    for (final tool in EditorTool.values) {
      expect(
        find.byKey(Key('editor-nav-${tool.name}')),
        findsOneWidget,
        reason: '${tool.name} 탭이 없다',
      );
    }
  });

  testWidgets('줌 탭에서 현재 위치에 줌을 추가한다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(workspace(controller));
    await tester.tap(find.byKey(const Key('editor-nav-zoom')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('줌 추가'), findsOneWidget);
  });

  testWidgets('타임라인을 끌면 재생 위치와 표시선이 함께 움직인다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      workspace(controller, onSeek: controller.setPlayhead),
    );

    // 오른쪽으로 끌면 재생 위치도 오른쪽(앞으로)이다. 예전에는 부호가
    // 뒤집혀 있어 왼쪽으로 끌어야 앞으로 갔다 — 반대로 가던 버그다.
    await tester.drag(
      find.byKey(const Key('editor-timeline-scrub')),
      const Offset(60, 0),
    );
    await tester.pump();

    expect(controller.project.playheadMs, greaterThan(0));

    final advanced = controller.project.playheadMs;
    await tester.drag(
      find.byKey(const Key('editor-timeline-scrub')),
      const Offset(-30, 0),
    );
    await tester.pump();

    expect(controller.project.playheadMs, lessThan(advanced));
    expect(find.byKey(const Key('editor-playhead')), findsOneWidget);
  });

  testWidgets('컷 편집 띠는 얇고 그 안은 프레임이 꽉 찬다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      workspace(controller, thumbnails: const ['/tmp/a.jpg', '/tmp/b.jpg']),
    );
    await tester.pump();

    // 프레임은 띠 높이를 남김없이 쓴다. 세로로 헐렁하게 두면 위아래가 빈다.
    final strip = tester.getSize(
      find.byKey(const Key('editor-timeline-strip')),
    );
    expect(strip.height, lessThan(140));
    final frame = tester.getSize(find.byType(Image).first);
    expect(frame.height, strip.height);
  });

  testWidgets('구간 손잡이를 끌면 고른 클립의 시작과 끝이 바뀐다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(trimmableWorkspace(controller));

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

  testWidgets('구간 손잡이는 30fps 프레임 경계에 맞춰진다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(trimmableWorkspace(controller));
    await tester.drag(
      find.byKey(const Key('editor-trim-start-handle')),
      const Offset(37, 0),
    );
    await tester.pump();

    final value = controller.project.selectedClip!.sourceStartMs;
    final frameAligned = ((value * 30 / 1000).round() * 1000 / 30).round();
    expect(value, frameAligned);
  });

  testWidgets('손잡이는 고른 구간 밖에 서고, 손잡이 사이가 곧 남는 구간이다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      trimmableWorkspace(controller, thumbnails: const ['/tmp/a.jpg']),
    );

    // 원본 전체가 고른 구간인 상태. 손잡이가 구간 **밖**에 서 있으면 노란 틀이
    // 프레임 띠보다 양옆으로 손잡이 폭만큼 넓다. 안쪽에 서 있으면 틀과 띠가 딱
    // 맞아떨어지는데, 그건 손잡이가 덮은 프레임까지 구간에 들어가 있다는 뜻이다
    // — 눈에는 안 보이면서 구간 재생에는 나오던 앞뒤가 그것이었다.
    final film = tester.getRect(find.byType(Image).first);
    final window = tester.getRect(find.byKey(const Key('editor-trim-window')));

    expect(window.left, lessThan(film.left), reason: '시작 손잡이가 프레임을 덮고 있다');
    expect(window.right, greaterThan(film.right), reason: '끝 손잡이가 프레임을 덮고 있다');
    // 틀에서 손잡이 둘을 빼면 프레임 띠와 정확히 같다 = 보이는 그림이 곧 남는 구간.
    expect(window.width - film.width, moreOrLessEquals(44, epsilon: 0.5));
  });

  testWidgets('손잡이를 영상 끝 가까이 끌면 끝에 딱 달라붙는다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(trimmableWorkspace(controller));

    // 먼저 끝을 넉넉히 당겨 둔다.
    await tester.drag(
      find.byKey(const Key('editor-trim-end-handle')),
      const Offset(-80, 0),
    );
    await tester.pump();
    expect(controller.project.selectedClip!.sourceEndMs, lessThan(12000));

    // 다시 끝 쪽으로 밀면, 조금 모자라게 밀어도 영상 끝에 딱 맞는다. 1px이 몇십~
    // 몇백 ms라 손가락으로는 정확히 맞힐 수 없다.
    await tester.drag(
      find.byKey(const Key('editor-trim-end-handle')),
      const Offset(78, 0),
    );
    await tester.pump();

    expect(
      controller.project.selectedClip!.sourceEndMs,
      12000,
      reason: '끝에 달라붙지 않으면 몇백 ms가 남는다',
    );
  });

  testWidgets('손잡이를 여러 번 끌어도 눈금 배율이 그대로다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(trimmableWorkspace(controller));

    // 예전 띠는 자른 뒤 길이를 폭 전체에 다시 펼쳐서, 같은 거리를 끌어도
    // 두 번째부터는 훨씬 적게 잘렸다(손잡이가 손가락에서 달아나는 증상).
    await tester.drag(
      find.byKey(const Key('editor-trim-start-handle')),
      const Offset(40, 0),
    );
    await tester.pump();
    final first = controller.project.selectedClip!.sourceStartMs;

    await tester.drag(
      find.byKey(const Key('editor-trim-start-handle')),
      const Offset(40, 0),
    );
    await tester.pump();
    final second = controller.project.selectedClip!.sourceStartMs - first;

    expect(second, closeTo(first, first * 0.15));
  });

  testWidgets('구간을 정한 뒤 다른 탭으로 가도 그 구간이 남는다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(trimmableWorkspace(controller));
    await tester.drag(
      find.byKey(const Key('editor-trim-start-handle')),
      const Offset(50, 0),
    );
    await tester.pump();
    final trimmedStart = controller.project.selectedClip!.sourceStartMs;
    expect(trimmedStart, greaterThan(0));

    controller.selectTool(EditorTool.text);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(controller.project.selectedClip!.sourceStartMs, trimmedStart);
    // 컷 밖에서는 프로젝트 바를 그리지 않아도 편집 값은 유지된다.
    expect(tester.takeException(), isNull);
  });

  testWidgets('구간 드래그는 되돌리기 이력을 한 칸만 쌓는다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(trimmableWorkspace(controller));
    await tester.drag(
      find.byKey(const Key('editor-trim-start-handle')),
      const Offset(60, 0),
    );
    await tester.pump();
    expect(controller.project.selectedClip!.sourceStartMs, greaterThan(0));

    // 예전에는 프레임마다 이력이 쌓여 되돌리기 한 번이 1ms만 되돌렸다.
    controller.undo();
    expect(controller.project.selectedClip!.sourceStartMs, 0);
    expect(controller.canUndo, isFalse);
  });

  testWidgets('클립 추가·클립 삭제 버튼이 클립 목록을 실제로 바꾼다', (tester) async {
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
        onClipAdd: controller.addClipAtPlayhead,
        onDelete: controller.deleteSelectedClip,
      ),
    );

    controller.setPlayhead(4000);
    await tester.pump();
    await tester.tap(find.text('클립 추가'));
    await tester.pump();
    expect(controller.project.clips, hasLength(2));
    // 새 클립은 재생 위치부터 3초, 바로 골라져 손잡이로 다듬을 수 있다.
    final added = controller.project.selectedClip!;
    expect(added.sourceStartMs, 4000);
    expect(added.sourceEndMs, 7000);

    await tester.tap(find.text('클립 삭제'));
    await tester.pump();
    expect(controller.project.clips, hasLength(1));
  });

  testWidgets('클립이 여러 개면 고르개로 편집할 클립을 바꾼다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..splitAt(5000);
    addTearDown(controller.dispose);
    final first = controller.project.clips.first;

    await tester.pumpWidget(
      workspace(controller, onSeek: controller.setPlayhead),
    );
    expect(find.text('클립 2/2'), findsOneWidget);
    await tester.tap(find.byKey(Key('editor-clip-${first.id}')));
    await tester.pump();

    expect(controller.project.selectedClipId, first.id);
    expect(controller.project.playheadMs, 0);
    expect(find.text('클립 1/2'), findsOneWidget);
    // 클립 구간은 분:초:프레임까지 보여 준다.
    expect(find.text('00:00:00–00:05:00'), findsOneWidget);
    expect(find.text('00:05:00–00:12:00'), findsOneWidget);
  });

  testWidgets('캔버스·텍스트·줌은 화면 안에서 바로 누르는 편집 트레이를 쓴다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    controller.selectTool(EditorTool.ratio);
    await tester.pumpWidget(workspace(controller));
    expect(find.textContaining('검은 띠').hitTestable(), findsOneWidget);
    // 영상 창(검은 띠) 크기를 조절하는 확대 슬라이더가 비율 탭에 있다.
    expect(
      find.byKey(const Key('editor-canvas-scale-slider')).hitTestable(),
      findsOneWidget,
    );

    controller.selectTool(EditorTool.text);
    await tester.pumpAndSettle();
    expect(find.textContaining('자막 ·').hitTestable(), findsOneWidget);
    expect(
      find.byKey(const Key('editor-open-text-sheet')).hitTestable(),
      findsOneWidget,
    );

    controller.selectTool(EditorTool.zoom);
    await tester.pumpAndSettle();
    expect(find.textContaining('줌 ·').hitTestable(), findsOneWidget);
    expect(
      find.byKey(const Key('editor-add-zoom')).hitTestable(),
      findsOneWidget,
    );
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
      workspace(controller, onClipAdd: controller.addClipAtPlayhead),
    );

    expect(controller.project.selectedClip, isNotNull);
    await tester.tap(find.text('클립 추가'));
    await tester.pump();
    expect(controller.project.clips, hasLength(2));
  });

  testWidgets('효과 탭에서 색감은 그 자리에서 바로 적용된다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // 색감은 얼굴 추적과 상관이 없고, AR 탭 미리보기(SurfaceView) 위에는 Flutter
    // 색 필터가 닿지 않는다. 그래서 제 자리인 '효과' 탭으로 옮겼다.
    final controller = newController()..selectTool(EditorTool.effect);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      workspace(controller, onLookSelected: controller.setLook),
    );

    // 화면을 벗어나지 않고 누른 자리에서 바로 색감이 바뀐다.
    await tester.tap(find.byKey(const Key('editor-look-mono')));
    await tester.pump();
    expect(controller.project.look, EditorLook.mono);

    await tester.tap(find.byKey(const Key('editor-clear-look')));
    await tester.pump();
    expect(controller.project.look, EditorLook.none);
  });

  testWidgets('꾸미기 스티커가 스티커 탭 항목으로 들어와 있다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.sticker);
    addTearDown(controller.dispose);
    final picked = <String>[];

    await tester.pumpWidget(
      workspace(controller, onStickerSelected: picked.add),
    );
    await tester.pump(const Duration(milliseconds: 400));

    // 목록 자체에 꾸미기 그림들이 다 들어와 있는지부터 본다. 가로 목록은 보이는
    // 것만 만들기 때문에 화면에서 다 찾을 수는 없다.
    expect(EditorArEffect.stickerValues, contains('👑'));
    expect(EditorArEffect.stickerValues, contains('🕶️'));

    // 왕관을 스티커 탭에서 눌러 놓을 수 있어야 한다.
    final crown = find.byKey(const Key('editor-sticker-👑'));
    await tester.scrollUntilVisible(
      crown,
      80,
      scrollable: find.descendant(
        of: find.byType(SelectedToolPanel),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.ensureVisible(crown);
    await tester.pumpAndSettle();
    await tester.tap(crown);
    await tester.pump();

    expect(picked, contains('👑'));
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

  testWidgets('컷 편집에는 정한 구간만 돌려 보는 단추가 있다', (tester) async {
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);
    var played = 0;

    await tester.pumpWidget(workspace(controller, onPlayRange: () => played++));
    await tester.tap(find.byKey(const Key('editor-play-range')));
    await tester.pump();

    expect(played, 1);
    expect(
      tester.widget<TextButton>(_action('구간 재생')).onPressed,
      isNotNull,
      reason: '클립이 있으면 언제나 돌려 볼 수 있어야 한다',
    );

    // 돌려 보는 중에는 같은 자리가 정지 단추가 된다.
    await tester.pumpWidget(workspace(controller, rangePreviewing: true));
    expect(find.text('정지'), findsOneWidget);
    expect(find.text('구간 재생'), findsNothing);
  });

  testWidgets('좁은 화면에서도 컷 편집 단추 네 개가 넘치지 않는다', (tester) async {
    tester.view
      ..physicalSize = const Size(360, 660)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(workspace(controller));

    for (final label in const ['구간 재생', '클립 추가', '클립 삭제']) {
      expect(find.text(label), findsOneWidget, reason: '$label 단추가 없다');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('AI 추천 컷과 줌 구간을 타임라인과 줌 패널에 표시한다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);
    controller.applyRecommendation(
      const EditRecommendation(
        cutStartMs: 2000,
        cutEndMs: 10000,
        durationPreset: 'medium',
        zoomSegments: [
          {
            'startMs': 4000,
            'endMs': 6500,
            'scale': 1.5,
            'focusX': 0.4,
            'focusY': 0.6,
          },
        ],
      ),
    );

    await tester.pumpWidget(
      workspace(controller, onZoomChanged: controller.updateZoom),
    );
    expect(
      find.byKey(const Key('editor-zoom-marker-auto-zoom-0')),
      findsOneWidget,
    );

    controller.selectTool(EditorTool.zoom);
    await tester.pumpAndSettle();
    // AI 추천 장면이 카드로 나온다. 카드 썸네일에 배율·초점이 그대로 걸린다.
    expect(
      find.byKey(const Key('editor-zoom-scene-auto-zoom-0')),
      findsOneWidget,
    );
    // 배율은 슬라이더로, 구간은 컷과 같은 프레임 타임라인 손잡이로 정한다.
    expect(find.byKey(const Key('editor-zoom-scale-slider')), findsOneWidget);
    expect(find.byKey(const Key('editor-zoom-range-bar')), findsOneWidget);
  });

  testWidgets('추천 적용 뒤에도 컷 손잡이로 구간을 더 좁힐 수 있다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);
    controller.applyRecommendation(
      const EditRecommendation(
        cutStartMs: 2000,
        cutEndMs: 10000,
        durationPreset: 'medium',
        zoomSegments: [],
      ),
    );
    await tester.pumpWidget(trimmableWorkspace(controller));
    final before = controller.project.selectedClip!.sourceStartMs;

    await tester.drag(
      find.byKey(const Key('editor-trim-start-handle')),
      const Offset(45, 0),
    );
    await tester.pump();

    expect(controller.project.selectedClip!.sourceStartMs, greaterThan(before));
  });

  testWidgets('길이 프리셋은 숫자 줄 없이 타임라인 안에서 선택한다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);
    String? selected;
    const recommendations = {
      'short': EditRecommendation(
        cutStartMs: 1000,
        cutEndMs: 5000,
        durationPreset: 'short',
        zoomSegments: [],
      ),
      'medium': EditRecommendation(
        cutStartMs: 0,
        cutEndMs: 9000,
        durationPreset: 'medium',
        zoomSegments: [],
      ),
      'long': EditRecommendation(
        cutStartMs: 0,
        cutEndMs: 12000,
        durationPreset: 'long',
        zoomSegments: [],
      ),
    };

    await tester.pumpWidget(
      workspace(
        controller,
        presetRecommendations: recommendations,
        onRecommendationSelected: (value) => selected = value,
      ),
    );
    expect(find.text('00:01–00:05'), findsNothing);
    expect(find.text('00:00–00:09'), findsNothing);
    expect(find.text('00:00–00:12'), findsNothing);
    expect(find.text('짧게'), findsOneWidget);
    expect(find.text('중간'), findsOneWidget);
    expect(find.text('길게'), findsOneWidget);
    await tester.tap(find.byKey(const Key('editor-preset-long')));
    expect(selected, 'long');
  });

  testWidgets('타임라인 버튼으로 30fps 기준 한 프레임씩 이동한다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      workspace(controller, onSeek: controller.setPlayhead),
    );
    await tester.tap(find.byKey(const Key('editor-frame-forward')));
    await tester.pump();
    expect(controller.project.playheadMs, 33);
    await tester.tap(find.byKey(const Key('editor-frame-forward')));
    await tester.pump();
    expect(controller.project.playheadMs, 67);
    await tester.tap(find.byKey(const Key('editor-frame-back')));
    await tester.pump();
    expect(controller.project.playheadMs, 33);
  });

  testWidgets('컷 밖에서는 프로젝트 개요 바를 표시하지 않는다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);
    controller
      ..setPlayhead(6000)
      ..splitAt(6000)
      ..setPlayhead(1000)
      ..addZoomAtPlayhead()
      ..addTextLayer(text: '표시')
      ..selectTool(EditorTool.zoom);

    await tester.pumpWidget(workspace(controller));
    expect(find.byType(EditorTimelineSection), findsNothing);
  });

  testWidgets('컷 타임라인은 컷 탭에만 있고, 타임코드는 어느 탭에서나 보인다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(workspace(controller));
    expect(find.byKey(const Key('editor-timeline-strip')), findsOneWidget);
    expect(find.byKey(const Key('editor-frame-timecode')), findsOneWidget);
    expect(find.byKey(const Key('editor-timeline-zoom-in')), findsOneWidget);

    // 줌이 하나도 없으면 줌 탭에는 아무 타임라인도 없다.
    controller.selectTool(EditorTool.zoom);
    await tester.pump();
    expect(find.byType(EditorTimelineSection), findsNothing);
    expect(find.byKey(const Key('editor-timeline-strip')), findsNothing);
    // 재생 줄(타임코드·1프레임 이동)은 미리보기 아래 한 곳에 늘 있다.
    expect(find.byKey(const Key('editor-frame-timecode')), findsOneWidget);
    expect(find.byKey(const Key('editor-transport-play')), findsOneWidget);

    // 줌을 하나 만들면 컷과 같은 프레임 타임라인이 붙는다.
    controller.addZoomAtPlayhead();
    await tester.pump();
    expect(find.byKey(const Key('editor-zoom-range-bar')), findsOneWidget);
    expect(find.byKey(const Key('editor-timeline-strip')), findsOneWidget);
  });

  testWidgets('클립을 고르면 그 클립에 귀속된 줌만 보인다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..splitAt(6000);
    addTearDown(controller.dispose);
    final clipA = controller.project.clips.first;
    final clipB = controller.project.clips.last;
    // A 클립(0~6초)의 1초 지점에 줌을 하나 만든다.
    controller
      ..setPlayhead(1000)
      ..addZoomAtPlayhead()
      ..selectTool(EditorTool.zoom);
    final zoomId = controller.project.zoomSegments.single.id;

    await tester.pumpWidget(workspace(controller));
    expect(find.byKey(Key('editor-zoom-scene-$zoomId')), findsOneWidget);

    // B 클립을 고르면 A의 줌 카드는 사라지고 빈 안내가 나온다.
    controller.selectClip(clipB.id);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(Key('editor-zoom-scene-$zoomId')), findsNothing);
    expect(find.textContaining('이 클립에는 줌이 없어요'), findsOneWidget);

    // 다시 A를 고르면 돌아온다.
    controller.selectClip(clipA.id);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(Key('editor-zoom-scene-$zoomId')), findsOneWidget);
  });

  testWidgets('기존 텍스트를 목록에서 다시 수정할 수 있다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);
    controller.addTextLayer(text: '다시 고칠 문구');
    controller.selectTool(EditorTool.text);
    String? editedId;

    await tester.pumpWidget(
      workspace(controller, onTextEdit: (id) => editedId = id),
    );
    // 칩 본문은 "그 자막으로 이동"이고, 내용 수정은 연필 아이콘이다.
    final layerId = controller.project.textLayers.single.id;
    await tester.tap(find.byKey(Key('editor-edit-text-$layerId')));
    expect(editedId, layerId);
  });
}

Finder _action(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextButton));

Finder _saveButton() => find.byKey(const Key('editor-save'));
