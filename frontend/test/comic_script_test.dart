/// 서버와 주고받는 4컷 자료형.
/// 컷이 4개가 아니면 자막을 얹을 칸이 안 맞으므로 반드시 오류가 되어야 한다.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/comic/comic_script.dart';
import 'package:william_james_app/features/stt/caption_line.dart';

Map<String, dynamic> body(int count) => {
  'cuts': [
    for (var i = 0; i < count; i++)
      {'beat': '컷$i', 'scene': '장면$i', 'dialogue': i == 2 ? null : '대사$i'},
  ],
};

void main() {
  group('parseComicCuts', () {
    test('네 컷을 자료형으로 옮긴다', () {
      final cuts = parseComicCuts(body(4));

      expect(cuts, hasLength(4));
      expect(cuts[0].beat, '컷0');
      expect(cuts[0].scene, '장면0');
      expect(cuts[0].dialogue, '대사0');
    });

    test('대사가 없는 컷은 null로 둔다', () {
      expect(parseComicCuts(body(4))[2].dialogue, isNull);
    });

    test('컷이 네 개가 아니면 던진다 — 자막 칸이 안 맞는다', () {
      expect(() => parseComicCuts(body(3)), throwsFormatException);
      expect(() => parseComicCuts(body(5)), throwsFormatException);
    });

    test('cuts가 없으면 던진다', () {
      expect(() => parseComicCuts(const {}), throwsFormatException);
    });

    test('필수 항목이 빠지면 던진다', () {
      expect(
        () => parseComicCuts({
          'cuts': [
            for (var i = 0; i < 4; i++) {'scene': '장면$i'},
          ],
        }),
        throwsFormatException,
      );
    });

    test('빈 대사는 null로 본다 — 빈 자막 띠를 그리지 않는다', () {
      final cuts = parseComicCuts({
        'cuts': [
          for (var i = 0; i < 4; i++)
            {'beat': 'b', 'scene': 's', 'dialogue': '   '},
        ],
      });
      expect(cuts.every((cut) => cut.dialogue == null), isTrue);
    });
  });

  test('cutsToJson은 받은 그대로 되돌린다', () {
    final cuts = parseComicCuts(body(4));
    cuts[0].dialogue = '고친 대사';

    final json = cutsToJson(cuts);
    expect(json, hasLength(4));
    expect(json[0]['dialogue'], '고친 대사');
    expect(json[2]['dialogue'], isNull);
    expect(json[0]['scene'], '장면0');
  });

  test('linesToJson은 시작 시각과 글만 보낸다 — 끝 시각은 서버에 필요 없다', () {
    final json = linesToJson([
      CaptionLine(startMs: 1500, endMs: 3000, text: '  그거 만지지 마  '),
    ]);

    expect(json, hasLength(1));
    expect(json.single, {'startMs': 1500, 'text': '그거 만지지 마'});
  });

  test('linesToJson은 빈 줄을 버린다', () {
    final json = linesToJson([
      CaptionLine(startMs: 0, endMs: 1000, text: '   '),
      CaptionLine(startMs: 2000, endMs: 3000, text: '있는 줄'),
    ]);
    expect(json, hasLength(1));
  });
}
