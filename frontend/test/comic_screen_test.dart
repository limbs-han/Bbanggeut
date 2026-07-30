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
  _StubGateway({required this.png, this.imageError});

  final Uint8List png;
  final Object? imageError;

  @override
  Future<List<ComicCut>> script(String videoId, List<CaptionLine> lines) async =>
      [
        for (var i = 0; i < 4; i++)
          ComicCut(beat: '컷$i', scene: '장면$i', dialogue: '대사$i'),
      ];

  @override
  Future<Uint8List> image(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async {
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

void main() {
  // 진짜 PNG는 진짜 이벤트 루프에서만 만들어진다 — _StubGateway의 주석 참조.
  late Uint8List png;
  setUpAll(() async {
    png = await FakeComicGateway().image('v1', const []);
  });

  ComicController build({List<CaptionLine>? saved, Object? imageError}) =>
      ComicController(
        gateway: _StubGateway(png: png, imageError: imageError),
        videoId: 'v1',
        store: _MemoryStore(saved),
      );

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

    await tester.tap(find.byKey(const ValueKey('comic-cut-0')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('comic-dialogue-field')),
      '고친 대사',
    );
    await tester.tap(find.text('넣기'));
    await tester.pumpAndSettle();

    expect(find.text('고친 대사'), findsOneWidget);
    expect(find.text('대사0'), findsNothing);
  });

  testWidgets('그림을 만들면 만화와 자막이 보인다', (tester) async {
    await pump(tester, build(saved: _lines()));

    await tester.tap(find.byKey(const ValueKey('comic-make-image')));
    await tester.pumpAndSettle();

    expect(find.text('- 대사0'), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-save')), findsOneWidget);
  });

  testWidgets('그림이 실패해도 고친 대사가 남고 다시 만들 수 있다', (tester) async {
    await pump(
      tester,
      build(saved: _lines(), imageError: StateError('생성 실패')),
    );

    await tester.tap(find.byKey(const ValueKey('comic-cut-0')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('comic-dialogue-field')),
      '고친 대사',
    );
    await tester.tap(find.text('넣기'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('comic-make-image')));
    await tester.pumpAndSettle();

    expect(find.textContaining('생성 실패'), findsOneWidget);
    expect(find.text('고친 대사'), findsOneWidget);
    expect(find.byKey(const ValueKey('comic-make-image')), findsOneWidget);
  });
}
