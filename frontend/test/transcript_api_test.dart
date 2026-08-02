/// 서버 전사 통로 계약 — 응답 모양과 줄 나눔.
/// 줄 나눔(20자)은 화면 표시 규칙이라 앱이 갖는다. 서버는 문장 단위로만 주면 된다.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/features/stt/transcript_api.dart';
import 'package:william_james_app/features/stt/transcript_store.dart';

/// 보내는 것을 붙잡아 두는 ApiClient — 기존 comic_gateway_test와 같은 방식.
class _RecordingApi extends ApiClient {
  String? videoId;
  Map<String, dynamic> response = const {'lines': <Object>[]};

  @override
  Future<Map<String, dynamic>> createTranscript(String id) async {
    videoId = id;
    return response;
  }
}

void main() {
  test('videoId만 보내고 시각 붙은 줄을 받는다', () async {
    final api = _RecordingApi()
      ..response = {
        'lines': [
          {'startMs': 1000, 'endMs': 2500, 'text': ' 그거 만지지 마 '},
        ],
      };

    final lines = await serverTranscriber(api)('v1');

    expect(api.videoId, 'v1');
    expect(lines.single.text, '그거 만지지 마');
    expect(lines.single.startMs, 1000);
    expect(lines.single.endMs, 2500);
  });

  test('긴 문장은 화면 규칙(20자)에 맞춰 나눈다', () async {
    final api = _RecordingApi()
      ..response = {
        'lines': [
          {
            'startMs': 0,
            'endMs': 8000,
            'text': '아 진짜 오늘 날씨가 너무 좋아서 우리 다 같이 공원에 나가서 놀았잖아',
          },
        ],
      };

    final lines = await serverTranscriber(api)('v1');

    expect(lines.length, greaterThan(1));
    expect(lines.every((line) => line.text.length <= 20), isTrue);
    expect(lines.first.startMs, 0, reason: '시작 시각은 보존한다');
    expect(lines.last.endMs, 8000, reason: '끝 시각은 보존한다');
  });

  test('lines가 없으면 던진다 — 계약 위반을 조용히 넘기지 않는다', () async {
    final api = _RecordingApi()..response = const {'error': '없음'};
    await expectLater(serverTranscriber(api)('v1'), throwsFormatException);
  });

  test('빈 글 줄은 버린다 — 빈 자막을 영상에 굽지 않는다', () async {
    final api = _RecordingApi()
      ..response = {
        'lines': [
          {'startMs': 0, 'endMs': 500, 'text': '   '},
          {'startMs': 600, 'endMs': 1200, 'text': '있는 줄'},
        ],
      };

    final lines = await serverTranscriber(api)('v1');
    expect(lines, hasLength(1));
    expect(lines.single.text, '있는 줄');
  });

  test('발화가 없으면 빈 목록을 돌려준다 — 던지지 않는다', () async {
    final api = _RecordingApi()..response = const {'lines': <Object>[]};
    expect(await serverTranscriber(api)('v1'), isEmpty);
  });

  test('COMIC_SERVER를 주지 않으면 가짜를 쓴다 — 서버 없이 흐름을 걸어 본다', () async {
    expect(transcriptServerReady, isFalse);
    final lines = await defaultTranscriber(ApiClient())('v1');
    expect(lines, isNotEmpty);
  });

  test('줄 하나가 계약과 다르면 FormatException으로 던진다 — TypeError는 진단이 안 된다', () async {
    final api = _RecordingApi()
      ..response = {
        'lines': [
          {'startMs': '1000', 'endMs': 2500, 'text': '그거 만지지 마'},
        ],
      };
    await expectLater(serverTranscriber(api)('v1'), throwsFormatException);
  });

  group('wireTranscriptStore', () {
    late TranscriptStore original;

    setUp(() => original = transcriptStore);
    tearDown(() => transcriptStore = original);

    test('전역 저장소가 넘겨받은 ApiClient 하나로 전사한다 — 자기 것을 새로 만들지 않는다', () async {
      // 앱의 클라이언트를 그대로 써야 한다. 안에서 ApiClient()를 새로 만들면
      // 이 api에는 아무것도 닿지 않아 videoId가 null로 남는다.
      final api = _RecordingApi()
        ..response = {
          'lines': [
            {'startMs': 0, 'endMs': 1000, 'text': '들린 말'},
          ],
        };

      // 기본 빌드는 COMIC_SERVER가 꺼져 있어 defaultTranscriber가 가짜를 고른다.
      // 서버 통로를 직접 지정해야 "어느 클라이언트로 갔는가"가 보인다.
      wireTranscriptStore(api, transcriberFor: serverTranscriber);
      final lines = await transcriptStore.transcriber('v-wired');

      expect(api.videoId, 'v-wired');
      expect(lines.single.text, '들린 말');
    });
  });
}
