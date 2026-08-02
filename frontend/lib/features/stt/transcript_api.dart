/// 자막 글이 서버에서 온다 — 온디바이스 whisper를 대체하는 통로.
///
/// **왜 서버인가**: 온디바이스 whisper(배포 형태 q5_1)는 실측 CER 11.3%, 2분
/// 영상에 168초였다(자료/docs의 06 STT 모델 가이드에 측정 기록). 자막 재료로
/// 부족해 서버(Gemini)로 옮겼다.
///
/// **폰은 videoId만 보낸다.** 원본 영상은 IoT 기기가 서버에 올린 것이라 서버에
/// 이미 있다. 오디오·대표 프레임 추출과 Gemini 호출은 서버 몫이다(API-54).
///
/// whisper 경로(`transcript_store.dart`의 `transcribeVideo`)는 아직 코드에
/// 남아 있지만 아무도 배선하지 않는다. 발표 뒤에 정리한다.
library;

import '../../core/api_client.dart';
import 'caption_line.dart';
import 'transcript_store.dart' show VideoTranscriber;

/// 서버 AI 통로가 준비됐는지. 만화(FN-A40)와 **같은 스위치**를 쓴다 —
/// `--dart-define=COMIC_SERVER=true`.
///
/// ponytail: `comic_gateway.dart`의 `comicServerReady`와 같은 값을 따로 읽는다.
/// 그 상수를 import하면 `stt → comic → stt` 순환이 생기고(comic_gateway가
/// `stt/caption_line.dart`를 쓴다), 공용 상수로 옮기면 만화 파일을 고쳐야 한다.
/// 읽는 곳이 셋째로 늘어나면 `core/`로 올린다.
const transcriptServerReady = bool.fromEnvironment('COMIC_SERVER');

/// 서버 통로가 준비되기 전에는 가짜가 기본값 — 만화와 같은 규칙.
VideoTranscriber defaultTranscriber(ApiClient api) =>
    transcriptServerReady ? serverTranscriber(api) : fakeTranscriber;

/// 서버가 전사한 줄을 받아 화면 규칙(한 줄 20자)에 맞춰 다시 나눈다.
///
/// 줄 나눔을 앱이 하는 이유: 한 줄에 몇 자가 들어가는지는 화면 사정이고,
/// 서버가 그걸 알 필요가 없다. 서버는 문장 단위로만 주면 된다.
VideoTranscriber serverTranscriber(ApiClient api) => (String videoId) async {
  final body = await api.createTranscript(videoId);
  final raw = body['lines'];
  if (raw is! List) {
    throw FormatException('응답에 lines가 없습니다: ${body.keys.toList()}');
  }
  final lines = <CaptionLine>[
    for (final entry in raw)
      if (((entry as Map)['text'] as String).trim().isNotEmpty)
        CaptionLine(
          startMs: entry['startMs'] as int,
          endMs: entry['endMs'] as int,
          text: (entry['text'] as String).trim(),
        ),
  ];
  return splitIntoLines(lines);
};

/// 서버가 없을 때 쓰는 가짜. `FakeComicGateway`와 같은 이야기라서 실기기에서
/// 자막과 만화가 한 흐름으로 보인다.
Future<List<CaptionLine>> fakeTranscriber(String videoId) async => [
  CaptionLine(startMs: 1200, endMs: 3200, text: '그거 만지지 마'),
  CaptionLine(startMs: 4100, endMs: 5900, text: '안 만졌는데요'),
  CaptionLine(startMs: 9800, endMs: 11600, text: '안 만졌다면서'),
];
