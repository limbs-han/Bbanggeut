/// 만화 크게 보기.
///
/// 두 가지가 깨져 있었다. "크게 보기"가 편집 화면을 열어 아무도 만화를 크게 볼
/// 수 없었고, 그림에는 말풍선이 없는데(그림 프롬프트가 막는다) 앱이 대사를
/// 얹지 않아 만화에 글이 하나도 보이지 않았다.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/comic/comic_script.dart';
import 'package:william_james_app/features/comic/comic_viewer.dart';

/// 1x1 투명 PNG. 그림 자리를 실제로 그려 보려면 디코딩되는 바이트가 필요하다.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

List<ComicCut> _cuts() => [
  ComicCut(beat: '기', scene: '거실', dialogue: '아빠 왔다!'),
  ComicCut(beat: '승', scene: '식탁', dialogue: '  오늘 뭐 먹어?  '),
  // 상황만 있는 컷 — 대사 칸에 나오지 않아야 한다.
  ComicCut(beat: '전', scene: '정전', dialogue: '   '),
  ComicCut(beat: '결', scene: '웃음', dialogue: '다 같이 웃었다'),
];

void main() {
  Future<void> pump(
    WidgetTester tester, {
    Uint8List? image,
    List<ComicCut>? cuts,
    VoidCallback? onEdit,
  }) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ComicViewerScreen(
          title: '우리집 만화',
          image: image,
          cuts: cuts,
          onEdit: onEdit,
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('그림과 대사를 함께 보여 준다', (tester) async {
    await pump(tester, image: _png, cuts: _cuts());

    expect(find.text('우리집 만화'), findsOneWidget);
    expect(find.byKey(const Key('comic-viewer-image')), findsOneWidget);
    expect(find.text('아빠 왔다!'), findsOneWidget);
    // 앞뒤 공백은 다듬어 보여 준다.
    expect(find.text('오늘 뭐 먹어?'), findsOneWidget);
    expect(find.text('다 같이 웃었다'), findsOneWidget);
  });

  testWidgets('대사가 없는 컷은 번호를 차지하지 않는다', (tester) async {
    await pump(tester, image: _png, cuts: _cuts());

    // 1·2·4컷만 대사가 있다 — 3컷은 빈 대사라 줄이 없다.
    expect(find.byKey(const Key('comic-viewer-line-1')), findsOneWidget);
    expect(find.byKey(const Key('comic-viewer-line-2')), findsOneWidget);
    expect(find.byKey(const Key('comic-viewer-line-3')), findsNothing);
    expect(find.byKey(const Key('comic-viewer-line-4')), findsOneWidget);
  });

  testWidgets('구성이 없으면 대사 칸을 접고 그림만 보여 준다', (tester) async {
    await pump(tester, image: _png);

    expect(find.text('대사'), findsNothing);
    expect(find.byKey(const Key('comic-viewer-image')), findsOneWidget);
  });

  testWidgets('그림을 못 받았으면 안내를 보여 준다', (tester) async {
    await pump(tester, cuts: _cuts());

    expect(find.text('만화를 불러오지 못했어요'), findsOneWidget);
    // 그림이 없어도 대사는 읽을 수 있다.
    expect(find.text('아빠 왔다!'), findsOneWidget);
  });

  testWidgets('대사 고치기는 넘겨받은 길이 있을 때만 나온다', (tester) async {
    await pump(tester, image: _png, cuts: _cuts());
    expect(find.byKey(const Key('comic-viewer-edit')), findsNothing);

    var tapped = 0;
    await pump(tester, image: _png, cuts: _cuts(), onEdit: () => tapped++);
    await tester.tap(find.byKey(const Key('comic-viewer-edit')));
    await tester.pump();

    expect(tapped, 1);
  });
}
