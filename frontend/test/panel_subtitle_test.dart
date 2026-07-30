/// 2x2 그림 위에 자막을 얹는 위젯.
/// 칸 대응이 틀리면 3컷 대사가 1컷에 붙는다 — 눈으로만 보면 놓치기 쉬워 고정한다.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/comic/comic_script.dart';
import 'package:william_james_app/features/comic/panel_subtitle.dart';

/// 위젯 테스트에서 쓸 최소 PNG (1x1 흰 점).
Future<Uint8List> onePixelPng() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 1, 1),
    Paint()..color = Colors.white,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(1, 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

List<ComicCut> cuts({String? third}) => [
  ComicCut(beat: '빌드업', scene: 's0', dialogue: '그거 만지지 마'),
  ComicCut(beat: '전개', scene: 's1', dialogue: '안 만졌는데요'),
  ComicCut(beat: '절정', scene: 's2', dialogue: third),
  ComicCut(beat: '여운', scene: 's3', dialogue: '안 만졌다면서'),
];

void main() {
  // testWidgets는 가짜 시계(FakeAsync) 위에서 돈다 — picture.toImage()의 실제
  // 이미지 디코딩은 진짜 이벤트 루프가 필요해 그 안에서는 절대 끝나지 않는다.
  // setUpAll은 진짜 이벤트 루프에서 돌기 때문에 여기서 한 번만 만들어 재사용한다.
  late Uint8List png;
  setUpAll(() async {
    png = await onePixelPng();
  });

  group('subtitleAlignment', () {
    test('읽는 순서대로 네 칸에 배치한다', () {
      expect(subtitleAlignment(0).x, lessThan(0), reason: '0컷은 왼쪽');
      expect(subtitleAlignment(0).y, lessThan(0), reason: '0컷은 위');
      expect(subtitleAlignment(1).x, greaterThan(0), reason: '1컷은 오른쪽');
      expect(subtitleAlignment(1).y, lessThan(0), reason: '1컷은 위');
      expect(subtitleAlignment(2).x, lessThan(0), reason: '2컷은 왼쪽');
      expect(subtitleAlignment(2).y, greaterThan(0), reason: '2컷은 아래');
      expect(subtitleAlignment(3).x, greaterThan(0), reason: '3컷은 오른쪽');
      expect(subtitleAlignment(3).y, greaterThan(0), reason: '3컷은 아래');
    });
  });

  testWidgets('대사 있는 컷만 자막을 그린다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ComicCanvas(image: png, cuts: cuts())),
    );
    await tester.pump();

    expect(find.text('- 그거 만지지 마'), findsOneWidget);
    expect(find.text('- 안 만졌는데요'), findsOneWidget);
    expect(find.text('- 안 만졌다면서'), findsOneWidget);
    // 3컷(index 2)은 대사가 없다
    expect(find.textContaining('- '), findsNWidgets(3));
  });

  testWidgets('대사에 - 접두어를 붙인다 — 영화 자막 관례다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ComicCanvas(
          image: png,
          cuts: cuts(third: '세 번째 대사'),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('- 세 번째 대사'), findsOneWidget);
    expect(find.text('세 번째 대사'), findsNothing, reason: '접두어가 붙어야 한다');
  });
}
