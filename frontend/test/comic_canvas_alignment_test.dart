import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/comic/comic_script.dart';
import 'package:william_james_app/features/comic/panel_subtitle.dart';

/// 자막 띠가 **자기 칸 가운데**에 앉는지 좌표로 확인한다.
///
/// 눈으로는 "옆으로 빗겨난 느낌"까지만 알 수 있고 몇 픽셀이 어긋났는지는
/// 알 수 없다. 칸 중심과 띠 중심을 직접 재서 못박는다.
void main() {
  /// 1x1 투명 PNG. 그림 내용은 배치와 무관하다.
  final png = Uint8List.fromList(const [
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

  const side = 400.0;

  List<ComicCut> cuts() => [
    for (var index = 0; index < comicCutCount; index++)
      ComicCut(
        beat: '기',
        scene: '장면 $index',
        // 길이가 서로 다른 대사를 넣는다 — 폭이 다를 때도 가운데여야 한다.
        dialogue: index.isEven ? '짧다' : '이건 훨씬 더 긴 대사예요 정말로',
      ),
  ];

  testWidgets('자막 띠는 자기 칸의 가로 가운데에 앉는다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: side,
            height: side,
            child: ComicCanvas(image: png, cuts: cuts()),
          ),
        ),
      ),
    );
    await tester.pump();

    final canvas = tester.getRect(find.byType(ComicCanvas));
    final bands = tester.widgetList(find.byType(DecoratedBox)).toList();
    expect(bands, hasLength(comicCutCount), reason: '컷마다 띠 하나');

    for (var index = 0; index < comicCutCount; index++) {
      final band = tester.getRect(find.byType(DecoratedBox).at(index));
      // 칸 중심 — 0·2는 왼쪽 절반, 1·3은 오른쪽 절반이다.
      final panelCenterX = canvas.left +
          (index % 2 == 1 ? canvas.width * 0.75 : canvas.width * 0.25);

      expect(
        band.center.dx,
        moreOrLessEquals(panelCenterX, epsilon: 0.5),
        reason: '$index컷 띠가 칸 가운데에서 '
            '${(band.center.dx - panelCenterX).toStringAsFixed(1)}px 빗겨났다',
      );
    }
  });

  testWidgets('띠는 자기 칸을 넘지 않아 옆 컷 그림을 밟지 않는다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: side,
            height: side,
            child: ComicCanvas(image: png, cuts: cuts()),
          ),
        ),
      ),
    );
    await tester.pump();

    final canvas = tester.getRect(find.byType(ComicCanvas));
    final middleX = canvas.center.dx;

    for (var index = 0; index < comicCutCount; index++) {
      final band = tester.getRect(find.byType(DecoratedBox).at(index));
      if (index % 2 == 1) {
        expect(band.left, greaterThanOrEqualTo(middleX),
            reason: '$index컷 띠가 왼쪽 칸으로 넘어갔다');
      } else {
        expect(band.right, lessThanOrEqualTo(middleX),
            reason: '$index컷 띠가 오른쪽 칸으로 넘어갔다');
      }
    }
  });
}
