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
  Canvas(
    recorder,
  ).drawRect(const Rect.fromLTWH(0, 0, 1, 1), Paint()..color = Colors.white);
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

  group('panelAlignment', () {
    test('읽는 순서대로 네 칸에 배치한다', () {
      expect(panelAlignment(0), Alignment.topLeft, reason: '0컷은 왼쪽 위');
      expect(panelAlignment(1), Alignment.topRight, reason: '1컷은 오른쪽 위');
      expect(panelAlignment(2), Alignment.bottomLeft, reason: '2컷은 왼쪽 아래');
      expect(panelAlignment(3), Alignment.bottomRight, reason: '3컷은 오른쪽 아래');
    });
  });

  /// 부호만 보던 예전 검사는 이것을 놓쳤다 — Align이 `부모 − 자식` 범위로 자식을
  /// 움직이기 때문에 좌표 부호가 맞아도 띠가 가운데를 넘어 겹칠 수 있다.
  testWidgets('자막 띠는 자기 칸을 벗어나지 않는다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: ComicCanvas(
              image: png,
              cuts: cuts(third: '세 번째 대사'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final canvas = tester.getRect(find.byType(ComicCanvas));
    Rect panel(int index) => Rect.fromLTWH(
      canvas.left + (index % 2) * canvas.width / 2,
      canvas.top + (index ~/ 2) * canvas.height / 2,
      canvas.width / 2,
      canvas.height / 2,
    );
    final lines = ['그거 만지지 마', '안 만졌는데요', '세 번째 대사', '안 만졌다면서'];
    Rect band(int index) => tester.getRect(find.text('- ${lines[index]}'));

    for (var index = 0; index < 4; index++) {
      final own = panel(index);
      expect(
        band(index).left,
        greaterThanOrEqualTo(own.left),
        reason: '$index컷',
      );
      expect(
        band(index).right,
        lessThanOrEqualTo(own.right),
        reason: '$index컷',
      );
      expect(band(index).top, greaterThanOrEqualTo(own.top), reason: '$index컷');
      expect(
        band(index).bottom,
        lessThanOrEqualTo(own.bottom),
        reason: '$index컷',
      );
    }

    expect(band(0).right, lessThan(band(1).left), reason: '위 두 띠가 겹치면 안 된다');
    expect(band(2).right, lessThan(band(3).left), reason: '아래 두 띠가 겹치면 안 된다');
  });

  testWidgets('대사 있는 컷만 자막을 그린다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ComicCanvas(image: png, cuts: cuts()),
      ),
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
