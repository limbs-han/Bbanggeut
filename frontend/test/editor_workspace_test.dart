import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/editor/editor_ar_effects.dart';
import 'package:william_james_app/editor/editor_project.dart';
import 'package:william_james_app/editor/editor_project_controller.dart';
import 'package:william_james_app/editor/editor_tokens.dart';
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
    VoidCallback? onText,
    bool directCaptionAddMode = false,
    VoidCallback? onDirectCaptionAddMode,
    ValueChanged<String>? onEditCaption,
    ValueChanged<String>? onDeleteCaption,
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
        onText: onText ?? () {},
        directCaptionAddMode: directCaptionAddMode,
        onDirectCaptionAddMode: onDirectCaptionAddMode,
        onEditCaption: onEditCaption,
        onDeleteCaption: onDeleteCaption,
        onVolumeChanged: (_) {},
        onMutedChanged: (_) {},
        onStickerSelected: onStickerSelected ?? (_) {},
        onFaceStickerSelected: (_) {},
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
      for (final label in const ['컷 편집', '비율', '줌', '자막', '오디오', '스티커', '효과']) {
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

  // 자막 판은 눈금 판과 카드 줄을 함께 세운다. 세로가 짧은 기기에서 그 둘이
  // 미리보기를 파고들지 않는지, 겹친 자막까지 넣고 크기마다 확인한다.
  for (final size in const [
    Size(360, 660),
    Size(360, 740),
    galaxyS24Plus,
    Size(412, 915),
  ]) {
    testWidgets(
      '${size.width.toInt()}×${size.height.toInt()}에서 자막 판과 카드 줄이 넘치지 않는다',
      (tester) async {
        tester.view
          ..physicalSize = size
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final controller = newController()..selectTool(EditorTool.text);
        addTearDown(controller.dispose);
        controller.applyTranscriptCaptions([
          (startMs: 1000, endMs: 7000, text: '안녕'),
          (startMs: 2000, endMs: 6000, text: '아 진짜 신기해'),
          (startMs: 3000, endMs: 6000, text: '지금 뭐 해?'),
          (startMs: 3500, endMs: 6500, text: '여기 봐봐'),
          (startMs: 4000, endMs: 7000, text: '웃어봐'),
        ]);
        controller.addTextLayer(
          text: '아주 긴 자막 문장이 들어와도 카드가 넘치지 않아야 해요',
          startMs: 8000,
          endMs: 11000,
        );

        await tester.pumpWidget(
          workspace(controller, onSeek: controller.setPlayhead),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: '자막 판이 넘쳤다');
        expect(find.byKey(const Key('editor-caption-cards')), findsOneWidget);
        // 미리보기는 어느 크기에서도 최소 높이(화면의 32%)를 지킨다.
        expect(
          tester.getSize(find.byType(VideoPreviewWorkspace)).height,
          greaterThanOrEqualTo(size.height * 0.32),
        );

        // 배율을 끝까지 올려도, 카드 줄을 끝까지 넘겨도 그대로다.
        for (var tap = 0; tap < 5; tap++) {
          await tester.tap(find.byKey(const Key('editor-caption-zoom-in')));
          await tester.pump();
        }
        await tester.pumpAndSettle();
        await tester.drag(
          find.byKey(const Key('editor-caption-cards')),
          const Offset(-800, 0),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '배율·카드 줄에서 넘쳤다');
      },
    );
  }

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

  testWidgets('하단 네비는 도구 일곱 개가 너비를 똑같이 나눠 쓴다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(workspace(controller));

    const navTools = [
      EditorTool.cut,
      EditorTool.ratio,
      EditorTool.zoom,
      EditorTool.text,
      EditorTool.sticker,
      EditorTool.audio,
      EditorTool.effect,
    ];
    for (final tool in navTools) {
      expect(
        find.byKey(Key('editor-nav-${tool.name}')),
        findsOneWidget,
        reason: '${tool.name} 탭이 없다',
      );
    }
    // 구분선은 걷어냈다 — 한 줄이 두 덩이로 읽히면 아래 줄이 위 타임라인보다
    // 먼저 눈에 들어온다.
    expect(find.byKey(const Key('editor-nav-divider')), findsNothing);
    final widths = {
      for (final tool in navTools)
        tester.getSize(find.byKey(Key('editor-nav-${tool.name}'))).width,
    };
    expect(widths.length, 1, reason: '탭 폭이 서로 다르다');
    // AI 자막은 자막 탭의 버튼으로, AR은 스티커 탭의 줄로 들어갔다.
    expect(find.byKey(const Key('editor-nav-aiCaption')), findsNothing);
    expect(find.byKey(const Key('editor-nav-ar')), findsNothing);
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
    expect(
      find.byKey(const Key('editor-open-ai-caption')).hitTestable(),
      findsOneWidget,
    );
    expect(find.text('직접 자막').hitTestable(), findsOneWidget);
    expect(find.text('자동 자막').hitTestable(), findsOneWidget);

    controller.selectTool(EditorTool.zoom);
    await tester.pumpAndSettle();
    expect(find.textContaining('줌 ·').hitTestable(), findsOneWidget);
    expect(
      find.byKey(const Key('editor-add-zoom')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('직접 자막을 고르면 타임라인과 현재 위치 추가 카드가 먼저 열린다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()
      ..selectTool(EditorTool.text)
      ..setPlayhead(3800);
    addTearDown(controller.dispose);
    var modeRequested = false;
    var sheetRequested = false;

    await tester.pumpWidget(
      workspace(
        controller,
        onText: () => sheetRequested = true,
        onDirectCaptionAddMode: () => modeRequested = true,
      ),
    );
    await tester.tap(
      find.byKey(const Key('editor-open-text-sheet')).hitTestable(),
    );
    expect(modeRequested, isTrue);
    expect(sheetRequested, isFalse);

    await tester.pumpWidget(
      workspace(
        controller,
        directCaptionAddMode: true,
        onText: () => sheetRequested = true,
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('editor-caption-track-timeline')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('editor-direct-caption-add-card')),
      findsOneWidget,
    );
    expect(find.text('이 위치에 자막 추가'), findsOneWidget);
    // 추가 카드가 줄 칸을 차지하는 동안에는 자막 줄이 서지 않는다.
    expect(find.byKey(const Key('editor-caption-rows')), findsNothing);

    await tester.tap(
      find
          .byKey(const Key('editor-direct-caption-add-at-playhead'))
          .hitTestable(),
    );
    expect(sheetRequested, isTrue);
  });

  testWidgets('자막 탭 영상 레인에도 클립 컷 구간 손잡이가 있다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    controller.applyTranscriptCaptions([
      (startMs: 1000, endMs: 2000, text: '아니 이거 말고'),
    ]);
    int? changedStart;
    bool? changedStartHandle;
    var committed = 0;

    await tester.pumpWidget(
      workspace(
        controller,
        onTrimChanged: (startMs, _, startHandle) {
          changedStart = startMs;
          changedStartHandle = startHandle;
        },
        onTrimCommitted: () => committed++,
      ),
    );
    await tester.pumpAndSettle();

    final startHandle = find.byKey(
      const Key('editor-caption-clip-start-handle'),
    );
    expect(startHandle, findsOneWidget);
    expect(
      find.byKey(const Key('editor-caption-clip-end-handle')),
      findsOneWidget,
    );
    // 자막 손잡이와 겹치지 않는다 — 프레임 띠와 자막 줄이 서로 다른 칸이다.
    final layerId = controller.project.textLayers.single.id;
    expect(
      tester.getCenter(startHandle).dy,
      isNot(
        tester
            .getCenter(find.byKey(Key('editor-caption-start-handle-$layerId')))
            .dy,
      ),
    );

    await tester.drag(startHandle, const Offset(40, 0));
    await tester.pump();

    expect(changedStartHandle, isTrue);
    expect(changedStart, greaterThan(0));
    expect(committed, 1);
    expect(tester.takeException(), isNull);
  });

  // 자막 탭 → AI 자막 → 직접 추가 순서로 들어가면, 예전에는 추가 카드와
  // 고른 자막의 '표시 시간' 줄이 함께 서서 패널이 60px 넘쳤다.
  testWidgets('자막이 이미 있으면 직접 추가는 카드를 건너뛰고 입력 시트로 간다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    controller.applyTranscriptCaptions([
      (startMs: 1000, endMs: 2000, text: '아니 이거 말고'),
    ]);
    expect(controller.project.selectedLayerId, isNotNull);
    var modeRequested = false;
    var sheetRequested = false;

    await tester.pumpWidget(
      workspace(
        controller,
        onText: () => sheetRequested = true,
        onDirectCaptionAddMode: () => modeRequested = true,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('editor-open-text-sheet')).hitTestable(),
    );

    expect(sheetRequested, isTrue);
    expect(modeRequested, isFalse);
    expect(
      find.byKey(const Key('editor-direct-caption-add-card')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('추가 카드가 떠 있으면 고른 자막의 표시 시간 줄은 접힌다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    controller.applyTranscriptCaptions([
      (startMs: 1000, endMs: 2000, text: '아니 이거 말고'),
    ]);

    await tester.pumpWidget(workspace(controller, directCaptionAddMode: true));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('editor-direct-caption-add-card')),
      findsOneWidget,
    );
    expect(find.textContaining('표시 시간'), findsNothing);
    expect(tester.takeException(), isNull);
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

  testWidgets('모든 편집 탭의 공통 위치에서 실행 취소와 다시 실행을 한다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);
    controller.addTextLayer(text: '되돌릴 자막');

    await tester.pumpWidget(workspace(controller));
    expect(find.byKey(const Key('editor-undo')), findsOneWidget);
    expect(find.byKey(const Key('editor-redo')), findsOneWidget);

    await tester.tap(find.byKey(const Key('editor-undo')));
    await tester.pump();
    expect(controller.project.textLayers, isEmpty);

    await tester.tap(find.byKey(const Key('editor-redo')));
    await tester.pump();
    expect(controller.project.textLayers.single.text, '되돌릴 자막');
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

  // 고치기·지우기는 영상 위 글자 상자로 옮겼다. 자막 막대에는 길이 손잡이만
  // 남는다 — 좁은 막대에 아이콘 넷이 들어가면 길이를 잡을 자리가 없다.
  testWidgets('자막 막대에는 연필도 휴지통도 없다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);
    controller.addTextLayer(text: '다시 고칠 문구', startMs: 1000, endMs: 6000);
    controller.selectTool(EditorTool.text);

    await tester.pumpWidget(workspace(controller));
    await tester.pumpAndSettle();

    final layerId = controller.project.textLayers.single.id;
    expect(controller.project.selectedLayerId, layerId);
    expect(find.byKey(Key('editor-caption-segment-$layerId')), findsOneWidget);
    expect(find.byKey(Key('editor-edit-text-$layerId')), findsNothing);
    expect(find.byKey(Key('editor-caption-remove-$layerId')), findsNothing);
    // 대신 길이 손잡이는 그대로 있다.
    expect(
      find.byKey(Key('editor-caption-start-handle-$layerId')),
      findsOneWidget,
    );
    expect(
      find.byKey(Key('editor-caption-end-handle-$layerId')),
      findsOneWidget,
    );
  });

  testWidgets('겹치지 않는 자막은 한 줄을 나눠 쓰고, 순번마다 색이 갈린다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController();
    addTearDown(controller.dispose);

    controller.addTextLayer(text: '직접 넣은 자막', startMs: 1000, endMs: 4000);
    final directId = controller.project.textLayers.single.id;
    controller.applyTranscriptCaptions([
      (startMs: 5000, endMs: 8000, text: '자동으로 만든 자막'),
    ]);
    final aiId = controller.project.textLayers
        .firstWhere((layer) => layer.id.startsWith('ai-caption-'))
        .id;
    controller
      ..selectTool(EditorTool.text)
      ..selectLayer(directId);

    await tester.pumpWidget(
      workspace(controller, onSeek: controller.setPlayhead),
    );

    final directSegment = find.byKey(Key('editor-caption-segment-$directId'));
    final aiSegment = find.byKey(Key('editor-caption-segment-$aiId'));
    expect(directSegment, findsOneWidget);
    expect(aiSegment, findsOneWidget);
    // 앞뒤로 떨어져 있으니 한 줄을 나눠 쓴다 — 자막마다 줄을 하나씩 주면
    // 안 겹치는 자막 스무 개가 스무 줄이 된다.
    expect(tester.getCenter(directSegment).dy, tester.getCenter(aiSegment).dy);
    // 길이 손잡이는 **고른 줄에만** 붙는다.
    expect(
      find.byKey(Key('editor-caption-start-handle-$directId')),
      findsOneWidget,
    );
    expect(
      find.byKey(Key('editor-caption-end-handle-$directId')),
      findsOneWidget,
    );
    expect(find.byKey(Key('editor-caption-start-handle-$aiId')), findsNothing);
    // 얇은 막대라 제 색을 거의 그대로 쓴다. 색은 순번에서 나오므로 이웃한
    // 둘은 늘 다르다. 고른 것만 온전한 원색이다.
    final directFill = _barFillColor(tester, directSegment);
    final aiFill = _barFillColor(tester, aiSegment);
    expect(directFill.withValues(alpha: 1), EditorCaptionTokens.colorAt(0));
    expect(aiFill.withValues(alpha: 1), isNot(directFill.withValues(alpha: 1)));
    expect(directFill.a, 1);
    expect(aiFill.a, lessThan(1));

    final playheadBefore = controller.project.playheadMs;
    await tester.drag(
      find.byKey(const Key('editor-caption-playhead-handle')),
      const Offset(42, 0),
    );
    await tester.pump();
    expect(controller.project.playheadMs, greaterThan(playheadBefore));

    // 봉에서 멀찍이 끈다 — 가까이 두면 자석이 봉에 붙여 버려, 손잡이가
    // 움직였는지 자석이 잡았는지를 이 검사로는 가릴 수 없다.
    final before = controller.project.textLayers.firstWhere(
      (layer) => layer.id == directId,
    );
    await tester.drag(
      find.byKey(Key('editor-caption-start-handle-$directId')),
      const Offset(70, 0),
    );
    await tester.pump();
    final after = controller.project.textLayers.firstWhere(
      (layer) => layer.id == directId,
    );
    expect(after.startMs, greaterThan(before.startMs));
    expect(after.endMs, before.endMs);

    // 다른 줄을 누르면 그 줄이 고른 줄이 되고, 손잡이가 그리로 옮겨 간다.
    await tester.tap(aiSegment);
    await tester.pump();
    expect(controller.project.selectedLayerId, aiId);
    // 고른 자리가 옮겨 간다 — 둘째 줄이 진해지고 첫 줄은 다시 옅어진다.
    expect(
      _barFillColor(tester, aiSegment).withValues(alpha: 1),
      aiFill.withValues(alpha: 1),
    );
    expect(_barFillColor(tester, aiSegment).a, greaterThan(aiFill.a));
    expect(_barFillColor(tester, directSegment).a, lessThan(directFill.a));
    expect(
      find.byKey(Key('editor-caption-start-handle-$aiId')),
      findsOneWidget,
    );
    expect(
      find.byKey(Key('editor-caption-start-handle-$directId')),
      findsNothing,
    );
  });

  testWidgets('자막이 없으면 만드는 두 갈래만, 하나 생기면 자막 판이 그 자리를 넘겨받는다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);

    await tester.pumpWidget(workspace(controller));
    await tester.pumpAndSettle();

    // 아직 손댈 자막이 없다 — 눈금도 줄 칸도 띄우지 않는다.
    expect(find.textContaining('자막 ·').hitTestable(), findsOneWidget);
    expect(
      find.byKey(const Key('editor-caption-track-timeline')),
      findsNothing,
    );

    controller.addTextLayer(text: '안녕', startMs: 1000, endMs: 4000);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 하나 생기면 자막 판이 서고, 만드는 두 갈래는 큰 카드에서 자막 카드 줄
    // 머리의 단추 둘로 줄어든다 — 같은 자리에 계속 있으니 찾아 헤맬 일이 없다.
    expect(
      find.byKey(const Key('editor-caption-track-timeline')),
      findsOneWidget,
    );
    expect(find.text('프레임 타임라인').hitTestable(), findsOneWidget);
    expect(find.text('자막 · 이 클립의 자막').hitTestable(), findsOneWidget);
    expect(find.text('직접 자막'), findsNothing);
    expect(
      find.byKey(const Key('editor-open-text-sheet')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('editor-open-ai-caption')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('최소 폭을 넘는 자막은 막대 폭이 곧 길이다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    controller
      ..addTextLayer(text: '짧은 자막', startMs: 1000, endMs: 6000)
      ..addTextLayer(text: '긴 자막', startMs: 1500, endMs: 11500);
    final shortId = controller.project.textLayers.first.id;
    final longId = controller.project.textLayers.last.id;

    await tester.pumpWidget(workspace(controller));
    await tester.pumpAndSettle();

    final shortBar = find.byKey(Key('editor-caption-segment-$shortId'));
    final longBar = find.byKey(Key('editor-caption-segment-$longId'));
    // 5초짜리와 10초짜리가 같은 폭으로 보이면 안 된다.
    expect(
      tester.getRect(longBar).width,
      greaterThan(tester.getRect(shortBar).width * 1.7),
    );
    // **그려지는 막대**도 같은 폭이다. 손가락 자리만 넓고 색 막대는 폭 0으로
    // 접혀 점처럼 보인 적이 있어, 칠해지는 네모를 직접 재 둔다.
    final shortPaint = _barRect(tester, shortBar);
    final longPaint = _barRect(tester, longBar);
    expect(shortPaint.width, moreOrLessEquals(tester.getRect(shortBar).width));
    expect(longPaint.width, greaterThan(shortPaint.width * 1.7));
    // 그리고 가로로 눕는다 — 폭이 두께보다 훨씬 크다.
    expect(shortPaint.width, greaterThan(shortPaint.height * 2));
    expect(shortPaint.height, moreOrLessEquals(4, epsilon: 0.01));
    // 글자는 막대가 아니라 아래 자막 카드가 말한다 — 막대는 길이와 색만
    // 말하므로 짧은 자막이 글자 때문에 부풀지 않는다.
    expect(
      find.descendant(of: shortBar, matching: find.text('짧은 자막')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(Key('editor-caption-card-$shortId')),
        matching: find.text('짧은 자막'),
      ),
      findsOneWidget,
    );

    controller.selectLayer(shortId);
    await tester.pump();
    final before = tester.getRect(shortBar).width;
    await tester.drag(
      find.byKey(Key('editor-caption-end-handle-$shortId')),
      const Offset(60, 0),
    );
    await tester.pump();

    // 손잡이를 끌면 자막 길이와 막대 폭이 함께 는다.
    expect(
      controller.project.textLayers
          .firstWhere((layer) => layer.id == shortId)
          .endMs,
      greaterThan(6500),
    );
    expect(tester.getRect(shortBar).width, greaterThan(before + 20));
    expect(tester.takeException(), isNull);
  });

  testWidgets('자막 손잡이는 재생 봉과 이웃 자막 끝에 달라붙는다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    controller
      ..addTextLayer(text: '앞 자막', startMs: 1000, endMs: 4000)
      ..addTextLayer(text: '뒤 자막', startMs: 8000, endMs: 10000)
      ..setPlayhead(6000);
    final movingId = controller.project.textLayers.first.id;
    // 손잡이는 고른 줄에만 붙는다 — 끌기 전에 먼저 고른다.
    controller.selectLayer(movingId);

    await tester.pumpWidget(workspace(controller));
    await tester.pumpAndSettle();

    // 손가락은 6005ms쯤에서 멈추지만 자석이 재생 봉(6000ms)에 딱 붙인다.
    final endHandle = find.byKey(Key('editor-caption-end-handle-$movingId'));
    await tester.drag(endHandle, const Offset(80, 0));
    await tester.pump();
    expect(
      controller.project.textLayers.firstWhere((l) => l.id == movingId).endMs,
      6000,
    );

    // 한 번 더 끌면 이번에는 뒤 자막의 시작(8000ms)에 붙는다.
    await tester.drag(endHandle, const Offset(80, 0));
    await tester.pump();
    expect(
      controller.project.textLayers.firstWhere((l) => l.id == movingId).endMs,
      8000,
    );
    expect(tester.takeException(), isNull);
  });

  // 실기기(S24+)에서 자막 판이 깨지지 않는지 몰아서 확인한다. 긴 영상,
  // 아주 짧은 자막, 아주 긴 글, 겹치는 무더기, 배율을 끝까지 올린 상태까지.
  testWidgets('S24+ 자막 판은 어떤 자막 더미에서도 깨지지 않는다', (tester) async {
    tester.view
      ..physicalSize = galaxyS24Plus
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: '/tmp/source.mp4',
        sourceDurationMs: 180000,
        sourceSize: const EditorSourceSize(width: 1920, height: 1080),
      ),
    )..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    controller.applyTranscriptCaptions([
      for (var index = 0; index < 40; index++)
        (
          startMs: index * 4000,
          // 0.2초짜리부터 40초짜리까지 섞고, 뒤로 갈수록 서로 겹친다.
          endMs: index * 4000 + (index.isEven ? 200 : 3000 + index * 900),
          text: index.isEven ? '짧' : '아주 긴 자막 문장이 들어와도 네모가 넘치지 않아야 해요 $index',
        ),
    ]);
    controller.addTextLayer(text: '직접 넣은 자막', startMs: 0, endMs: 180000);

    await tester.pumpWidget(
      workspace(controller, onSeek: controller.setPlayhead),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '1배율에서 넘쳤다');

    // 배율을 끝까지 올린다.
    for (var tap = 0; tap < 6; tap++) {
      await tester.tap(find.byKey(const Key('editor-caption-zoom-in')));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '최대 배율에서 넘쳤다');

    // 자막 카드 줄을 끝까지 넘겼다 되돌린다.
    final cards = find.byKey(const Key('editor-caption-cards'));
    await tester.drag(cards, const Offset(-2000, 0));
    await tester.pump();
    await tester.drag(cards, const Offset(2000, 0));
    await tester.pump();
    expect(tester.takeException(), isNull, reason: '카드 줄을 넘기다 넘쳤다');

    // 미리보기는 여전히 화면의 절반을 넘게 쓴다. 자막 카드 줄이 새로 자리를
    // 잡았지만, 막대가 얇아져 줄 칸이 그만큼 줄었다.
    expect(
      tester.getSize(find.byType(VideoPreviewWorkspace)).height,
      greaterThan(galaxyS24Plus.height * 0.5),
    );
  });

  testWidgets('겹치는 자막은 아래 줄로 밀린다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    controller.applyTranscriptCaptions([
      (startMs: 1000, endMs: 5000, text: '먼저 뜨는 자막'),
      (startMs: 3000, endMs: 7000, text: '겹쳐 뜨는 자막'),
      (startMs: 8000, endMs: 11000, text: '한참 뒤 자막'),
    ]);
    final ids = controller.project.textLayers.map((layer) => layer.id).toList();

    await tester.pumpWidget(workspace(controller));
    await tester.pumpAndSettle();

    Offset centerOf(String id) =>
        tester.getCenter(find.byKey(Key('editor-caption-segment-$id')));
    // 겹치는 둘은 위아래로 갈라서고, 뒤에 떨어져 있는 것은 첫 줄로 돌아온다.
    expect(centerOf(ids[0]).dy, isNot(centerOf(ids[1]).dy));
    expect(centerOf(ids[2]).dy, centerOf(ids[0]).dy);
    expect(tester.takeException(), isNull);
  });

  testWidgets('셋 이상 겹친 자막은 +N 배지로 접히고 배지를 누르면 시트가 펼친다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    // 사진과 같은 상황 — 같은 자리에 자막 다섯이 겹친다.
    controller.applyTranscriptCaptions([
      (startMs: 1000, endMs: 7000, text: '안녕'),
      (startMs: 2000, endMs: 6000, text: '아 진짜 신기해'),
      (startMs: 3000, endMs: 6000, text: '지금 뭐 해?'),
      (startMs: 3500, endMs: 6500, text: '네 번째'),
      (startMs: 4000, endMs: 7000, text: '다섯 번째'),
    ]);
    final ids = controller.project.textLayers.map((layer) => layer.id).toList();

    await tester.pumpWidget(
      workspace(controller, onSeek: controller.setPlayhead),
    );
    await tester.pumpAndSettle();

    final strip = find.byKey(const Key('editor-caption-video-track'));
    final stripBefore = tester.getRect(strip);
    // 막대는 세 줄까지만 그린다. 나머지 둘은 배지 하나로 접힌다.
    expect(find.byKey(Key('editor-caption-segment-${ids[0]}')), findsOneWidget);
    expect(find.byKey(Key('editor-caption-segment-${ids[1]}')), findsOneWidget);
    expect(find.byKey(Key('editor-caption-segment-${ids[2]}')), findsOneWidget);
    expect(find.byKey(Key('editor-caption-segment-${ids[3]}')), findsNothing);
    expect(find.byKey(Key('editor-caption-segment-${ids[4]}')), findsNothing);
    expect(find.text('+2'), findsOneWidget);

    // 배지는 **마지막 줄 아래 빈 칸**에 선다. 줄 위에 얹으면 그 자리의 막대가
    // 숫자를 덮어, 정작 몇 줄이 더 있는지를 읽을 수 없다.
    final badge = find.ancestor(
      of: find.text('+2'),
      matching: find.byType(GestureDetector),
    );
    final badgeRect = tester.getRect(badge.first);
    for (final id in ids) {
      final bar = find.byKey(Key('editor-caption-segment-$id'));
      if (bar.evaluate().isEmpty) continue;
      expect(
        badgeRect.top,
        greaterThanOrEqualTo(tester.getRect(bar).bottom),
        reason: '배지가 막대를 덮는다',
      );
    }
    // 접힌 덩이가 끝나는 자리에 걸친다 — 해당 막대의 오른쪽 아래다.
    expect(
      badgeRect.center.dx,
      moreOrLessEquals(
        tester
            .getRect(find.byKey(Key('editor-caption-segment-${ids[0]}')))
            .right,
        epsilon: 12,
      ),
    );
    // 알갱이는 작아도 겨누기 쉬워야 한다.
    expect(badgeRect.width, greaterThanOrEqualTo(44));
    expect(badgeRect.height, greaterThanOrEqualTo(18));

    // 프레임 띠와 눈금은 제자리다 — "지금 어디"가 흔들리지 않는다.
    expect(tester.getRect(strip), stripBefore);

    await tester.tap(find.text('+2'));
    await tester.pumpAndSettle();

    // 접힌 자막만이 아니라 그 시점에 떠 있는 자막 전부가 시트에 선다.
    expect(find.text('현재 시점 자막 5개'), findsOneWidget);
    expect(find.text('다섯 번째'), findsOneWidget);
    // 시트는 미리보기를 덮지 않는다 — 자막 판 위로 올라오지 않는다.
    final sheet = tester.getRect(
      find.byKey(const Key('editor-caption-overlap-rows')),
    );
    expect(
      sheet.top,
      greaterThan(tester.getRect(find.byType(VideoPreviewWorkspace)).bottom),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('막대와 자막 카드는 서로를 가리킨다', (tester) async {
    tester.view
      ..physicalSize = galaxyS24Plus
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    controller.applyTranscriptCaptions([
      for (var index = 0; index < 8; index++)
        (startMs: index * 1200, endMs: index * 1200 + 900, text: '자막 $index'),
    ]);
    final ids = controller.project.textLayers.map((layer) => layer.id).toList();
    String? editRequested;

    await tester.pumpWidget(
      workspace(
        controller,
        onSeek: controller.setPlayhead,
        onEditCaption: (id) => editRequested = id,
      ),
    );
    await tester.pumpAndSettle();

    // 카드 줄은 자막마다 한 장, 번호와 글이 함께 선다.
    expect(find.byKey(const Key('editor-caption-cards')), findsOneWidget);
    expect(find.text('8개'), findsOneWidget);

    // 두 장이 온전히 서고 셋째가 화면 밖으로 반쯤 잘린다 — "옆으로 더
    // 있다"가 스크롤바 없이 읽혀야 한다.
    final strip = tester.getRect(find.byKey(const Key('editor-caption-cards')));
    final visible = [
      for (var index = 0; index < 8; index++)
        find.byKey(Key('editor-caption-card-${ids[index]}')),
    ].where((card) => card.evaluate().isNotEmpty).toList();
    expect(visible.length, greaterThanOrEqualTo(3));
    expect(tester.getRect(visible[1]).right, lessThanOrEqualTo(strip.right));
    expect(tester.getRect(visible[2]).right, greaterThan(strip.right));

    // 뒤쪽 막대를 누르면 그 카드가 줄 가운데로 흘러온다 — 처음에는 화면
    // 밖이라 그려지지도 않은 카드다.
    final farCard = find.byKey(Key('editor-caption-card-${ids[4]}'));
    expect(farCard, findsNothing);
    await tester.tap(find.byKey(Key('editor-caption-segment-${ids[4]}')));
    await tester.pumpAndSettle();

    expect(controller.project.selectedLayerId, ids[4]);
    expect(farCard, findsOneWidget);
    final viewport = tester.getRect(
      find.byKey(const Key('editor-caption-cards')),
    );
    expect(
      tester.getRect(farCard).center.dx,
      moreOrLessEquals(viewport.center.dx, epsilon: 2),
    );

    // 거꾸로 옆 카드를 누르면 그 막대가 고른 막대가 된다 — 테두리도 그림자도
    // 두르지 않고, 조금 두꺼워지는 것만으로 알린다.
    final thinBefore = _barRect(
      tester,
      find.byKey(Key('editor-caption-segment-${ids[5]}')),
    ).height;
    await tester.tap(find.byKey(Key('editor-caption-card-${ids[5]}')));
    await tester.pumpAndSettle();
    expect(controller.project.selectedLayerId, ids[5]);
    final segment = find.byKey(Key('editor-caption-segment-${ids[5]}'));
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: segment,
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(decoration.border, isNull);
    expect(decoration.boxShadow, isNull);
    expect(_barRect(tester, segment).height, greaterThan(thinBefore));

    // 고른 카드에만 연필이 선다.
    expect(find.byKey(Key('editor-caption-card-edit-${ids[4]}')), findsNothing);
    await tester.tap(find.byKey(Key('editor-caption-card-edit-${ids[5]}')));
    expect(editRequested, ids[5]);

    // 맨 끝 자막은 줄 끝이라 가운데로는 못 오지만, 적어도 보이는 자리까지는
    // 온다.
    await tester.tap(find.byKey(Key('editor-caption-segment-${ids.last}')));
    await tester.pumpAndSettle();
    final lastCard = find.byKey(Key('editor-caption-card-${ids.last}'));
    expect(lastCard, findsOneWidget);
    expect(tester.getRect(lastCard).right, lessThanOrEqualTo(viewport.right));
    expect(tester.takeException(), isNull);
  });

  // 자막 카드에는 새 카드가 서는데 위 타임라인에는 막대가 나타나지 않았다.
  // AI 자막이 이미 세 층을 다 채워 놓은 자리에 얹으면, 시작 시각 순으로만
  // 담던 줄 나누기가 직접 자막을 넷째 층으로 밀어 +N 배지 안으로 접었다.
  testWidgets('직접 추가한 자막은 자막이 빽빽해도 그 자리에서 막대로 선다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    // 같은 자리에 여덟 개가 겹친다 — 보이는 세 층이 이미 꽉 찬 상태다.
    controller.applyTranscriptCaptions([
      for (var index = 0; index < 8; index++)
        (
          startMs: 1000 + index * 200,
          endMs: 6000 + index * 300,
          text: 'AI 자막 $index',
        ),
    ]);

    await tester.pumpWidget(
      workspace(controller, onSeek: controller.setPlayhead),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('+'), findsWidgets, reason: '접힌 층이 없다');

    controller.addTextLayer(text: '직접 넣은 자막', startMs: 2000, endMs: 7000);
    await tester.pumpAndSettle();

    final directId = controller.project.textLayers.last.id;
    final bar = find.byKey(Key('editor-caption-segment-$directId'));
    // 화면을 다시 열지 않아도 그 자리에서 바로 선다. 접힌 층(+N 배지)에
    // 들어가 있으면 이 막대는 아예 그려지지 않는다.
    expect(bar, findsOneWidget, reason: '직접 자막 막대가 타임라인에 없다');
    expect(find.byKey(Key('editor-caption-card-$directId')), findsOneWidget);

    // 시간을 고치면 막대의 자리와 길이가 함께 따라간다.
    final before = _barRect(tester, bar);
    controller.updateTextLayerRangeGesture(directId, 5000, 11500);
    await tester.pump();
    final after = _barRect(tester, bar);
    expect(after.left, greaterThan(before.left));
    expect(after.width, greaterThan(before.width));

    // 지우면 막대와 카드가 함께 사라진다.
    controller.removeLayer(directId);
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    expect(find.byKey(Key('editor-caption-card-$directId')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // 배지가 답하는 물음은 "여기 자막이 몇 개 더 있나"가 아니라 "몇 **줄**이 더
  // 있나"다. 세 줄까지는 막대가 그대로 보이니 셀 것이 없고, 네 번째 줄부터
  // 한 줄에 하나씩 센다.
  for (final (overlapping, badge) in const [(3, null), (4, '+1'), (5, '+2')]) {
    testWidgets('$overlapping줄이 겹치면 배지는 ${badge ?? '서지 않는다'}', (tester) async {
      tester.view
        ..physicalSize = const Size(411, 890)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = newController()..selectTool(EditorTool.text);
      addTearDown(controller.dispose);
      // 같은 자리에 겹쳐 세우면 자막 하나가 줄 하나를 차지한다.
      controller.applyTranscriptCaptions([
        for (var index = 0; index < overlapping; index++)
          (startMs: 1000, endMs: 6000, text: '겹친 자막 $index'),
      ]);

      await tester.pumpWidget(
        workspace(controller, onSeek: controller.setPlayhead),
      );
      await tester.pumpAndSettle();

      if (badge == null) {
        expect(find.textContaining('+'), findsNothing, reason: '안 접혔는데 배지가 섰다');
      } else {
        expect(find.text(badge), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  // 클립을 나눈 뒤 앞 클립을 골라 둔 채 재생 위치만 뒤 클립으로 옮겨 자막을
  // 만들면, 자막은 뒤 클립에 붙는데 자막 판은 앞 클립을 펼치고 있었다 —
  // 막대도 카드도 나타나지 않던 정체다.
  testWidgets('다른 클립의 재생 위치에 만든 자막도 그 자리에서 바로 보인다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = EditorProjectController(
      EditorProject.fromSource(
        sourceVideoPath: '/tmp/source.mp4',
        sourceDurationMs: 120000,
        sourceSize: const EditorSourceSize(width: 1920, height: 1080),
      ),
    )..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    controller.applyTranscriptCaptions([
      for (var index = 0; index < 21; index++)
        (startMs: index * 5000, endMs: index * 5000 + 2000, text: '자막 $index'),
    ]);
    // 클립을 둘로 나누고, 앞 클립을 고른 채 재생 위치만 뒤 클립으로 옮긴다.
    expect(controller.splitAt(60000), isTrue);
    controller.selectClip(controller.project.clips.first.id);
    controller.setPlayhead(80000);

    await tester.pumpWidget(
      workspace(controller, onSeek: controller.setPlayhead),
    );
    await tester.pumpAndSettle();

    controller.addTextLayer(text: '뒤 클립 자막', startMs: 80000, endMs: 83000);
    await tester.pumpAndSettle();

    final layer = controller.project.textLayers.last;
    expect(layer.clipId, controller.project.clips.last.id);
    expect(
      find.byKey(Key('editor-caption-segment-${layer.id}')),
      findsOneWidget,
      reason: '다른 클립에 만든 자막의 막대가 없다',
    );
    expect(
      find.byKey(Key('editor-caption-card-${layer.id}')),
      findsOneWidget,
      reason: '다른 클립에 만든 자막의 카드가 없다',
    );
    expect(tester.takeException(), isNull);
  });

  // 막대는 4dp고 줄 사이는 10dp다. 그 실선을 정확히 겨누라고 하면 열 번에
  // 서너 번은 헛손질이 된다 — 그림은 촘촘한 채로 손끝만 넉넉해야 한다.
  testWidgets('막대를 살짝 빗나가게 눌러도 가장 가까운 자막이 골라진다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    controller
      ..addTextLayer(text: '앞 자막', startMs: 1000, endMs: 3000)
      ..addTextLayer(text: '뒤 자막', startMs: 5000, endMs: 7000);
    final ids = controller.project.textLayers.map((layer) => layer.id).toList();

    await tester.pumpWidget(
      workspace(controller, onSeek: controller.setPlayhead),
    );
    await tester.pumpAndSettle();

    // 겹치지 않으니 한 줄을 나눠 쓴다. 지금 골라진 것은 나중에 넣은 뒤 자막이다.
    expect(controller.project.selectedLayerId, ids[1]);
    final target = find.byKey(Key('editor-caption-segment-${ids[0]}'));
    final bar = tester.getRect(target);

    // 막대에서 8dp 아래 — 막대 밖, 줄과 줄 사이의 빈 자리다.
    await tester.tapAt(Offset(bar.center.dx, bar.center.dy + 8));
    await tester.pump();
    expect(controller.project.selectedLayerId, ids[0], reason: '빗나간 손끝이 버려졌다');

    // 너무 멀면 아무것도 고르지 않는다 — 빈 곳을 눌렀는데 엉뚱한 자막이
    // 골라지면 그게 더 나쁘다.
    controller.selectLayer(ids[1]);
    await tester.pumpAndSettle();
    await tester.tapAt(Offset(bar.center.dx - 60, bar.center.dy));
    await tester.pump();
    expect(controller.project.selectedLayerId, ids[1]);
    expect(tester.takeException(), isNull);
  });

  // 확대해 놓으면 프레임 띠의 가로 끌기는 띠를 옆으로 넘기는 데 쓰인다.
  // 그래서 예전에는 봉을 옮길 길이 "봉 자체를 정확히 집는 것" 하나뿐이었다.
  testWidgets('재생 봉은 눈금 줄 어디서나 끌리고 자막 끝에 달라붙는다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    controller
      ..addTextLayer(text: '자막 하나', startMs: 3000, endMs: 6000)
      ..setPlayhead(0);

    await tester.pumpWidget(
      workspace(controller, onSeek: controller.setPlayhead),
    );
    await tester.pumpAndSettle();

    // 눈금 줄을 끌면 봉이 따라온다. 3000ms 언저리에서 손을 떼면 자석이
    // 자막의 시작에 딱 붙인다.
    final ruler = find.byKey(const Key('editor-caption-ruler-scrub'));
    expect(ruler, findsOneWidget);
    await tester.drag(ruler, const Offset(120, 0));
    await tester.pump();
    expect(controller.project.playheadMs, 3000, reason: '자막 시작에 붙지 않았다');

    // 배율을 올려도 눈금 줄은 그대로 봉을 끄는 자리다. 이때 띠는 화면보다
    // 넓으므로 보이는 자리를 짚어 끈다.
    controller.setPlayhead(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editor-caption-zoom-in')));
    await tester.pumpAndSettle();
    final visible = tester.getRect(ruler);
    await tester.dragFrom(
      Offset(visible.left + 40, visible.center.dy),
      const Offset(40, 0),
    );
    await tester.pump();
    expect(controller.project.playheadMs, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('막대 색은 순번마다 돈다 — 이웃한 자막은 늘 다른 색이다', (tester) async {
    tester.view
      ..physicalSize = const Size(411, 890)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = newController()..selectTool(EditorTool.text);
    addTearDown(controller.dispose);
    controller.applyTranscriptCaptions([
      (startMs: 0, endMs: 900, text: 'AI 하나'),
      (startMs: 1000, endMs: 1900, text: 'AI 둘'),
      (startMs: 2000, endMs: 2900, text: 'AI 셋'),
    ]);
    controller
      ..addTextLayer(text: '직접 하나', startMs: 3000, endMs: 3900)
      ..addTextLayer(text: '직접 둘', startMs: 4000, endMs: 4900);
    final ids = controller.project.textLayers.map((layer) => layer.id).toList();

    await tester.pumpWidget(workspace(controller));
    await tester.pumpAndSettle();

    Color barColorOf(String id) => _barFillColor(
      tester,
      find.byKey(Key('editor-caption-segment-$id')),
    ).withValues(alpha: 1);

    // 만들어진 곳(AI/직접)이 아니라 **순번**이 색을 정한다 — 나란히 선
    // 막대끼리는 늘 다른 색이라, 어디서 하나가 끝나는지가 보인다.
    for (var index = 0; index + 1 < ids.length; index++) {
      expect(
        barColorOf(ids[index]),
        isNot(barColorOf(ids[index + 1])),
        reason: '$index번과 그다음 자막이 같은 색이다',
      );
    }
    // 세 색이 돌아간다 — 셋째 다음은 다시 첫 색이다.
    expect(barColorOf(ids[3]), barColorOf(ids[0]));
    expect(barColorOf(ids[4]), barColorOf(ids[1]));

    // 카드 번호도 막대와 같은 색이다. 카드는 고를 때 줄 가운데로 흘러온다.
    Future<Color> cardNumberOf(String id, int order) async {
      controller.selectLayer(id);
      await tester.pumpAndSettle();
      return _cardNumberColor(tester, id, order);
    }

    expect(await cardNumberOf(ids[3], 4), barColorOf(ids[3]));
    expect(await cardNumberOf(ids[0], 1), barColorOf(ids[0]));
    expect(tester.takeException(), isNull);
  });
}

/// 자막 카드 앞 칸의 번호 색. 막대와 1:1로 같은 색이어야 한다.
Color _cardNumberColor(WidgetTester tester, String layerId, int order) {
  final text = tester.widget<Text>(
    find.descendant(
      of: find.byKey(Key('editor-caption-card-$layerId')),
      matching: find.text('$order'),
    ),
  );
  return text.style!.color!;
}

/// 자막 막대를 채운 색. 제 색(코랄·주황·올리브)을 투명도로 살짝 깐 것이라,
/// 색상은 [Color.withValues]로 불투명하게 되돌려 비교한다.
Color _barFillColor(WidgetTester tester, Finder segment) {
  final decorated = tester.widget<DecoratedBox>(
    find.descendant(of: segment, matching: find.byType(DecoratedBox)).first,
  );
  return (decorated.decoration as BoxDecoration).color!;
}

/// 실제로 **칠해지는** 막대의 네모. 손가락 자리([segment])보다 얇고, 폭은
/// 손가락 자리와 같아야 한다.
Rect _barRect(WidgetTester tester, Finder segment) => tester.getRect(
  find.descendant(of: segment, matching: find.byType(DecoratedBox)).first,
);

Finder _action(String label) =>
    find.ancestor(of: find.text(label), matching: find.byType(TextButton));

Finder _saveButton() => find.byKey(const Key('editor-save'));
