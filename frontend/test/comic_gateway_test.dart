/// 서버 통로 계약. 서버가 아직 없으므로 기본값은 가짜다.
///
/// **여기서 고정되는 것**: `linesToJson`·`cutsToJson`이 각 항목에 담는 값(startMs와
/// text만, endMs 없음 / 고친 dialogue), 기본 화풍 `webtoon`, 응답 `image`의 base64
/// 복호화와 없을 때의 예외.
///
/// **고정되지 않는 것**: `_RecordingApi`가 [ApiClient]의 메서드를 갈아끼우므로 URL
/// 경로와 감싸는 키(`lines`/`cuts`/`style`)는 이 파일이 검사하지 않는다. 그것을 바꿔도
/// 테스트는 통과한다. 저장소에 Dio를 태우는 테스트가 없어 망 하네스를 새로 짜지
/// 않았다 — 전선 계약(경로·키·에러 모양)의 원천은 `자료/docs`의 API 명세서
/// **API-71·API-72**이고, 그쪽과 어긋나면 서버가 조용히 못 알아듣는다.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/features/comic/comic_gateway.dart';
import 'package:william_james_app/features/comic/comic_script.dart';
import 'package:william_james_app/features/stt/caption_line.dart';

/// 보내는 것을 붙잡아 두는 ApiClient. 기존 _AccountApiClient와 같은 방식이다.
class _RecordingApi extends ApiClient {
  String? scriptVideoId;
  List<Map<String, Object>>? sentLines;
  String? imageVideoId;
  List<Map<String, Object?>>? sentCuts;
  String? sentStyle;

  @override
  Future<Map<String, dynamic>> createComicScript(
    String videoId,
    List<Map<String, Object>> lines,
  ) async {
    scriptVideoId = videoId;
    sentLines = lines;
    return {
      'cuts': [
        for (var i = 0; i < 4; i++)
          {'beat': '컷$i', 'scene': '장면$i', 'dialogue': '대사$i'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> createComicImage(
    String videoId, {
    required List<Map<String, Object?>> cuts,
    required String style,
  }) async {
    imageVideoId = videoId;
    sentCuts = cuts;
    sentStyle = style;
    return {
      'image': base64Encode(Uint8List.fromList([1, 2, 3, 4])),
    };
  }
}

class _NoImageApi extends _RecordingApi {
  @override
  Future<Map<String, dynamic>> createComicImage(
    String videoId, {
    required List<Map<String, Object?>> cuts,
    required String style,
  }) async => <String, dynamic>{};
}

void main() {
  group('HttpComicGateway', () {
    test('전사문을 startMs와 text만 담아 보낸다', () async {
      final api = _RecordingApi();

      final cuts = await HttpComicGateway(api).script('v1', [
        CaptionLine(startMs: 1500, endMs: 3000, text: '그거 만지지 마'),
      ]);

      expect(api.scriptVideoId, 'v1');
      expect(api.sentLines, [
        {'startMs': 1500, 'text': '그거 만지지 마'},
      ]);
      expect(cuts, hasLength(4));
    });

    test('그림 요청에 고친 구성과 화풍을 보낸다', () async {
      final api = _RecordingApi();
      final cuts = await HttpComicGateway(api).script('v1', const []);
      cuts[0].dialogue = '고친 대사';

      final bytes = await HttpComicGateway(api).image('v1', cuts);

      expect(api.imageVideoId, 'v1');
      expect(api.sentCuts!.first['dialogue'], '고친 대사');
      expect(api.sentStyle, 'webtoon');
      expect(bytes, [1, 2, 3, 4]);
    });

    test('이미지가 없으면 던진다', () async {
      final api = _NoImageApi();
      final cuts = await HttpComicGateway(api).script('v1', const []);

      await expectLater(
        HttpComicGateway(api).image('v1', cuts),
        throwsFormatException,
      );
    });
  });

  group('FakeComicGateway', () {
    test('네 컷을 돌려준다', () async {
      final cuts = await FakeComicGateway().script('v1', const []);
      expect(cuts, hasLength(comicCutCount));
      expect(cuts.map((c) => c.scene).every((s) => s.isNotEmpty), isTrue);
    });

    test('PNG 바이트를 돌려준다', () async {
      final cuts = await FakeComicGateway().script('v1', const []);
      final bytes = await FakeComicGateway().image('v1', cuts);

      expect(bytes.length, greaterThan(100), reason: '그림이 들어 있어야 한다');
      // PNG 서명 8바이트
      expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    });
  });

  /// 인자를 붙이는 걸 잊으면 오류가 아니라 가짜 만화가 그대로 출고된다. 그래서
  /// 기본을 실서버로 두고, 견본은 `COMIC_SERVER=false`로 명시해서 켠다.
  test('인자를 주지 않으면 실서버 통로를 쓴다', () {
    expect(comicServerReady, isTrue);
    expect(defaultComicGateway(ApiClient()), isA<HttpComicGateway>());
  });
}
