/// 만화 화면.
/// 실패해도 고친 대사가 화면에 남아 다시 만들 수 있어야 한다.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/core/models.dart';
import 'package:william_james_app/features/comic/comic_controller.dart';
import 'package:william_james_app/features/comic/comic_gateway.dart';
import 'package:william_james_app/features/comic/comic_screen.dart';
import 'package:william_james_app/features/comic/comic_script.dart';
import 'package:william_james_app/features/stt/caption_line.dart';
import 'package:william_james_app/features/stt/transcript_store.dart';

class _MemoryStore extends TranscriptStore {
  _MemoryStore(this._saved)
    : super(
        transcriber: (_) async => const [],
        root: () async => Directory.systemTemp,
      );

  final List<CaptionLine>? _saved;

  @override
  Future<List<CaptionLine>?> read(String videoId) async => _saved;
}

/// 미리 만들어 둔 PNG를 그대로 돌려준다.
///
/// **왜 여기서 그림을 만들지 않나**: testWidgets는 가짜 시계(FakeAsync) 위에서
/// 돈다. `picture.toImage()`로 진짜 PNG를 만드는 일은 진짜 이벤트 루프가 필요해서
/// 그 안에서는 절대 끝나지 않는다 — 테스트가 무한 대기에 걸린다(Task 4에서 실제로
/// 겪었다). 그래서 그림은 setUpAll에서 한 번 만들어 넣어 준다.
class _StubGateway implements ComicGateway {
  _StubGateway({required this.png, this.scriptError, this.imageError});

  final Uint8List png;
  final Object? scriptError;
  final Object? imageError;

  /// 구성 요청은 돈이 든다 — 되돌아가기가 이것을 다시 부르지 않는지 세어서 본다.
  int scriptCalls = 0;
  int imageCalls = 0;

  @override
  Future<List<ComicCut>> script(
    String videoId,
    List<CaptionLine> lines,
  ) async {
    scriptCalls++;
    if (scriptError != null) throw scriptError!;
    return [
      for (var i = 0; i < 4; i++)
        ComicCut(beat: '컷$i', scene: '장면$i', dialogue: '대사$i'),
    ];
  }

  @override
  Future<Uint8List> image(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async {
    imageCalls++;
    if (imageError != null) throw imageError!;
    return png;
  }
}

final _video = VideoMemory(
  id: 'v1',
  deviceId: 'd1',
  triggerType: 'LAUGH',
  title: '테스트 영상',
  status: 'READY',
  favorite: false,
);

Future<void> pump(
  WidgetTester tester,
  ComicController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ComicScreen(api: ApiClient(), video: _video, controller: controller),
    ),
  );
  await tester.pumpAndSettle();
}

List<CaptionLine> _lines() => [
  CaptionLine(startMs: 1000, endMs: 3000, text: '그거 만지지 마'),
];

/// 0컷 대사를 '고친 대사'로 바꾼다. 온디바이스 인식이 틀려 손으로 고치는 상황이다.
Future<void> _editFirstDialogue(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('comic-cut-0')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('comic-dialogue-field')),
    '고친 대사',
  );
  await tester.tap(find.text('넣기'));
  await tester.pumpAndSettle();
}

void main() {
  // 진짜 PNG는 진짜 이벤트 루프에서만 만들어진다 — _StubGateway의 주석 참조.
  late Uint8List png;
  setUpAll(() async {
    png = await FakeComicGateway().image('v1', const []);
  });

  late _StubGateway gateway;

  ComicController build({
    List<CaptionLine>? saved,
    Object? scriptError,
    Object? imageError,
  }) {
    gateway = _StubGateway(
      png: png,
      scriptError: scriptError,
      imageError: imageError,
    );
    return ComicController(
      gateway: gateway,
      videoId: 'v1',
      store: _MemoryStore(saved),
    );
  }

  testWidgets('전사문이 없으면 안내를 보여준다', (tester) async {
    await pump(tester, build());

    expect(find.textContaining('대사를 먼저'), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-make-image')), findsNothing);
  });

  testWidgets('구성을 받으면 네 컷을 보여준다', (tester) async {
    await pump(tester, build(saved: _lines()));

    expect(find.text('대사0'), findsOneWidget);
    expect(find.text('장면0'), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-make-image')), findsOneWidget);
  });

  testWidgets('대사를 눌러 고치면 목록에 반영된다', (tester) async {
    await pump(tester, build(saved: _lines()));

    await _editFirstDialogue(tester);

    expect(find.text('고친 대사'), findsOneWidget);
    expect(find.text('대사0'), findsNothing);
  });

  testWidgets('그림을 만들면 만화와 자막이 보인다', (tester) async {
    await pump(tester, build(saved: _lines()));

    await tester.tap(find.byKey(const ValueKey('comic-make-image')));
    await tester.pumpAndSettle();

    expect(find.text('- 대사0'), findsOneWidget);
    // 저장은 갤러리 직행, 공유는 별도 버튼이다 — "저장하기"를 눌렀는데
    // 공유 시트가 열리던 혼란을 두 버튼으로 갈랐다.
    expect(find.byKey(const ValueKey('comic-save')), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-share')), findsOneWidget);
  });

  testWidgets('그림이 실패해도 고친 대사가 남고 다시 만들 수 있다', (tester) async {
    await pump(
      tester,
      build(saved: _lines(), imageError: StateError('생성 실패')),
    );

    await _editFirstDialogue(tester);

    await tester.tap(find.byKey(const ValueKey('comic-make-image')));
    await tester.pumpAndSettle();

    expect(find.textContaining('생성 실패'), findsOneWidget);
    expect(find.text('고친 대사'), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-make-image')), findsOneWidget);
  });

  /// 완성 화면에서 되돌아갈 길이 없으면 뒤로 나가야 하고, 그러면 고친 대사가 전부
  /// 날아간다. 글자가 섞이거나 격자가 어긋나는 것은 막을 수 없으니 정상 경로다.
  testWidgets('완성 뒤 다시 만들기는 고친 대사로 그림만 다시 받는다', (tester) async {
    final controller = build(saved: _lines());
    await pump(tester, controller);
    await _editFirstDialogue(tester);
    await tester.tap(find.byKey(const ValueKey('comic-make-image')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('comic-remake')));
    await tester.pumpAndSettle();

    expect(gateway.imageCalls, 2, reason: '그림을 다시 요청해야 한다');
    expect(gateway.scriptCalls, 1, reason: '구성은 다시 받지 않는다 — 돈이 든다');
    expect(find.text('- 고친 대사'), findsOneWidget);
  });

  testWidgets('완성 뒤 대사 고치기는 구성을 다시 받지 않고 목록으로 돌아간다', (tester) async {
    final controller = build(saved: _lines());
    await pump(tester, controller);
    await _editFirstDialogue(tester);
    await tester.tap(find.byKey(const ValueKey('comic-make-image')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('comic-edit-cuts')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('comic-cut-0')), findsOneWidget);
    expect(find.text('고친 대사'), findsOneWidget, reason: '고친 대사가 그대로 있어야 한다');
    expect(gateway.scriptCalls, 1, reason: '구성을 다시 받으면 고친 대사가 원문으로 덮인다');
  });

  /// 가짜 통로의 고정 대사를 자기 가족의 말로 오해하면 안 된다. `comicServerReady`는
  /// 컴파일 시점 상수여서 테스트에서는 항상 꺼져 있다 — 켜졌을 때 사라지는 것까지
  /// 같은 식으로 묶어 둔다.
  testWidgets('서버 통로가 없으면 견본이라고 알린다', (tester) async {
    await pump(tester, build(saved: _lines()));

    expect(
      find.byKey(const ValueKey('comic-sample-notice')),
      comicServerReady ? findsNothing : findsOneWidget,
    );
  });

  /// 첫 시도부터 구성이 실패하면 고칠 대사조차 없다 — 목록 대신 다시 시도만 보여준다.
  testWidgets('구성부터 실패하면 목록 없이 다시 시도를 보여준다', (tester) async {
    await pump(
      tester,
      build(saved: _lines(), scriptError: StateError('구성 실패')),
    );

    expect(find.textContaining('구성 실패'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-cut-0')), findsNothing);
    expect(find.byKey(const ValueKey('comic-make-image')), findsNothing);
  });
}
