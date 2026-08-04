# 서버 STT(Gemini) 전환 구현 계획 — 최소 변경판

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 자막 전사를 온디바이스 whisper에서 서버(Gemini)로 갈아끼운다. **기존 코드는 최소한만 건드린다** — 새 파일 2개를 더하고, 기존 파일에서는 세 줄만 고친다.

**Architecture:** 원본 영상은 IoT 기기가 서버에 올린 것이라 **서버에 이미 있다.** 폰은 videoId만 보내고, 서버가 저장된 원본에서 오디오·대표 프레임을 뽑아 Gemini로 전사한다(API-54). 앱 쪽 이음매는 `TranscriptStore`가 전사 함수를 주입받는 지점 하나다 — 거기만 바꾸면 자막 편집 UI·캐시·Media3 굽기·4컷 만화가 전부 그대로 동작한다.

**Tech Stack:** Flutter/Dart, 기존 `ApiClient`(Dio). 서버는 별도 브랜치(`feat/backend/*`).

## 배경 — 왜 바꾸나

- 팀 판단: 온디바이스 STT 품질이 부족하다. 실측(`자료/docs`의 06 STT 모델 가이드): 배포 형태 q5_1의 **CER 11.3%**, 2분 영상 전사에 **168초**.
- 사용자 결정(2026-08-02): 자막도 서버로 / Gemini에는 오디오+대표 프레임 / 만화는 두 단계 유지 / 발표용이라 사생활 규칙은 배제 / **기존 코드가 크게 바뀌지 않는 방향**.

## 이번에 하지 않는 것 (사용자가 명시적으로 고른 것)

세 가지를 일부러 남긴다. 지금 이걸 모르고 "왜 안 지웠지?" 하고 손대면 이 계획의 목적이 깨진다.

| 남기는 것 | 이유 | 남는 대가 |
|---|---|---|
| **whisper 일가 전부** — 모델 에셋 181MiB, `whisper_ggml_plus` 의존성, `whisper_transcriber.dart`·`whisper_model.dart`·`android_audio.dart`·`pcm_wav.dart`·`speech_analysis.dart`, `SttChannel.kt`·`AudioDecoder.kt`, `stt_test.dart`·`whisper_model_test.dart` | 발표 뒤에 정리하기로 했다 | APK 181MiB 그대로. `jni`의 CMake 빌드가 남아 **한글 경로(`Desktop\실습\...`)에서 빌드 실패도 그대로**. 아무도 부르지 않는 코드가 남는다 |
| **만화의 `ComicNeedsTranscript`** ("대사를 먼저 알아들어야 해요") | 방금 검토를 통과한 만화 코드·테스트를 다시 건드리지 않는다 | 만화를 만들려면 자막 화면을 **한 번 열어 캐시를 만들어야** 한다 |
| **플래그 이름 `COMIC_SERVER`** | 개명하면 만화 코드·테스트·README·설계문서·`자료/docs`를 전부 고쳐야 한다 | 이름이 만화 전용처럼 보이지만 자막 전사도 이 스위치로 켜진다 |

`transcribeVideo`(whisper 경로)는 **컴파일되는 채로 남되 아무도 배선하지 않는다.** Dart는 안 쓰는 최상위 public 함수를 경고하지 않으므로 analyze는 깨끗하다.

## Global Constraints

- **작업트리** `C:\Users\SSAFY\dev\stt-captions`, **브랜치** `feat/frontend/comic` 이어서 작업한다(만화 커밋 14개 위, 아직 push 안 함). 자막과 만화가 같은 전사 재료를 쓰므로 한 MR로 낸다.
- **폰은 videoId만 보낸다.** 영상·오디오·프레임을 업로드하지 않는다 — 원본은 서버에 이미 있다. 추출과 Gemini 호출은 서버 몫이다.
- **Gemini 키는 서버에만 둔다.** 앱은 우리 서버(`ApiClient`)만 부른다.
- **새 pub 의존성을 추가하지 않는다.**
- **서버 통로가 없는 동안 가짜가 기본값이다.** 스위치는 기존 `--dart-define=COMIC_SERVER=true`. `bool.fromEnvironment`는 `true`/`false` 리터럴만 알아듣는다 — `1`·`yes`·`TRUE`는 조용히 false가 된다.
- **기존 파일은 최소한만 고친다.** 이 계획이 기존 코드에서 바꾸는 줄은 **`transcript_store.dart` 2줄 + `local_edit_screen.dart` 3줄 삭제**가 전부다. 그 밖의 리팩터링·이름 정리·불필요한 정돈을 하지 않는다.
- **테스트에서 실제 파일을 만들면 `Directory.systemTemp.createTemp()`.** 절대 경로 하드코딩은 리눅스 CI에서만 죽는다(이 저장소에서 실제로 겪었다).
- **`testWidgets`는 가짜 시계 위에서 돈다** — 진짜 파일 입출력·이미지 디코딩이 그 안에서 끝나지 않는다(이 브랜치에서 40분을 잃었다).
- 커밋은 한국어 + `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`. **push·`develop/frontend`·`master` 직접 커밋 금지.**
- **작업트리의 무관한 변경을 절대 스테이지하지 않는다**: `frontend/android/app/build.gradle.kts`(수정됨), `frontend/android/app/src/debug/res/`(미추적). 커밋은 항상 명시 경로로.
- 검증은 `dart analyze lib test`(무경고) + `flutter test`(전부 통과). **현재 기준선 144개.**
- 실행은 PowerShell 도구 + `timeout: 600000`. 단일 파일 반복 시 `--timeout 45s`. `run_in_background`·폴링 금지.

## 파일 구조

| 파일 | 처리 | 책임 |
|---|---|---|
| `frontend/lib/features/stt/transcript_api.dart` | **새로** | 서버/가짜 전사 통로, 플래그, 응답 → `CaptionLine` |
| `frontend/test/transcript_api_test.dart` | **새로** | 위 계약 |
| `frontend/lib/core/api_client.dart` | 메서드 1개 추가 | `createTranscript(videoId)` |
| `frontend/lib/features/stt/transcript_store.dart` | **2줄 수정** | 전역 배선 + `_run`의 인자 |
| `frontend/lib/ui/local_edit_screen.dart` | **3줄 삭제** | whisper 전용 예상시간 |
| `자료/docs` 양쪽 트리 | 수정 | API-54, FN-A39 재정의, REQ-F-27 |

기존 `VideoTranscriber` typedef(`transcript_store.dart:22`)는 **그대로 둔다.** 시그니처가 `Future<List<CaptionLine>> Function(String)`이라 인자에 videoId를 넘겨도 타입이 맞고, 테스트가 쓰는 `(_) async => ...` 스텁도 그대로 통한다.

---

### Task 1: 서버 전사 통로 — 새 파일만 더한다

기존 파일은 `api_client.dart`에 메서드 하나 더하는 것뿐이다. 이 태스크가 끝난 시점에는 **아무도 새 코드를 부르지 않는다** — 배선은 Task 2에서 한다. 그래서 이 태스크만으로는 앱 동작이 하나도 바뀌지 않고, 테스트로만 검증된다.

**Files:**
- Create: `frontend/lib/features/stt/transcript_api.dart`
- Create: `frontend/test/transcript_api_test.dart`
- Modify: `frontend/lib/core/api_client.dart` (메서드 1개 추가)

**Interfaces:**
- Consumes:
  - `CaptionLine({required int startMs, required int endMs, required String text})` — `features/stt/caption_line.dart`. `text`만 mutable.
  - `List<CaptionLine> splitIntoLines(List<CaptionLine> lines, {int maxChars = captionMaxChars})` — 같은 파일. `captionMaxChars`는 20.
  - `ApiClient._post(String path, {Object? data})` — private이지만 같은 클래스 안에서 부른다. `data`는 생략 가능(확인 완료).
- Produces (Task 2가 쓴다):
  - `VideoTranscriber defaultTranscriber(ApiClient api)` — 플래그로 서버/가짜 선택. 반환 타입은 `transcript_store.dart`의 기존 typedef `Future<List<CaptionLine>> Function(String)`.
  - `VideoTranscriber serverTranscriber(ApiClient api)`
  - `Future<List<CaptionLine>> fakeTranscriber(String videoId)`
  - `ApiClient.createTranscript(String videoId) → Future<Map<String, dynamic>>`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`frontend/test/transcript_api_test.dart`:

```dart
/// 서버 전사 통로 계약 — 응답 모양과 줄 나눔.
/// 줄 나눔(20자)은 화면 표시 규칙이라 앱이 갖는다. 서버는 문장 단위로만 주면 된다.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/api_client.dart';
import 'package:william_james_app/features/stt/transcript_api.dart';

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
}
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```
Set-Location C:\Users\SSAFY\dev\stt-captions\frontend; flutter test test/transcript_api_test.dart --timeout 45s 2>&1 | Select-Object -Last 15
```

기대: 컴파일 실패 — `transcript_api.dart`가 없다.

- [ ] **Step 3: ApiClient에 메서드를 더한다**

`frontend/lib/core/api_client.dart`에서 `createComicScript` **바로 앞**에 넣는다(만화 메서드들과 나란히):

```dart
  /// 서버가 원본(이미 서버에 있다)을 Gemini로 전사한 자막을 돌려준다.
  /// 폰은 아무것도 올리지 않는다 — 경로의 videoId가 전부다.
  Future<Map<String, dynamic>> createTranscript(String videoId) =>
      _post('/api/videos/$videoId/transcript');
```

- [ ] **Step 4: 통로를 구현한다**

`frontend/lib/features/stt/transcript_api.dart`:

```dart
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
```

- [ ] **Step 5: 테스트가 통과하는 것을 확인한다**

```
Set-Location C:\Users\SSAFY\dev\stt-captions\frontend; flutter test test/transcript_api_test.dart 2>&1 | Select-Object -Last 10
```

기대: 6개 통과.

- [ ] **Step 6: 전체를 돌려 기존 것이 안 깨졌는지 본다**

```
Set-Location C:\Users\SSAFY\dev\stt-captions\frontend; dart analyze lib test 2>&1 | Select-Object -Last 10
Set-Location C:\Users\SSAFY\dev\stt-captions\frontend; flutter test 2>&1 | Select-Object -Last 8
```

기대: 무경고, **150개 통과**(기준선 144 + 새 6).

- [ ] **Step 7: 커밋**

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/features/stt/transcript_api.dart frontend/test/transcript_api_test.dart frontend/lib/core/api_client.dart
git -C C:\Users\SSAFY\dev\stt-captions commit -m "feat: 서버 전사 통로 — 폰은 videoId만 보낸다

원본은 IoT 기기가 서버에 올린 것이라 서버에 이미 있다. 오디오·대표 프레임
추출과 Gemini 호출은 서버 몫(API-54)이고, 줄 나눔(20자)은 화면 규칙이라
앱이 갖는다.

아직 아무도 부르지 않는다 — 배선은 다음 커밋에서 한다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: 배선 교체 — 기존 코드에서 고치는 줄은 다섯 줄

여기서 실제로 동작이 바뀐다. **`transcript_store.dart` 2줄 + `local_edit_screen.dart` 3줄 삭제**가 전부다. `ensure()`·`CaptionController.start()`·`CaptionAutoSection`의 시그니처는 **바꾸지 않는다** — 호출부와 기존 테스트를 건드리지 않기 위해서다.

**Files:**
- Modify: `frontend/lib/features/stt/transcript_store.dart` (import 2줄 추가, 본문 2줄 수정, 주석)
- Modify: `frontend/lib/ui/local_edit_screen.dart:279-283` (3줄 삭제)

**Interfaces:**
- Consumes: `defaultTranscriber(ApiClient)`(Task 1)
- Produces: 없음 (배선만). 공개 시그니처는 하나도 바뀌지 않는다.

- [ ] **Step 1: 전역 배선을 바꾼다**

`frontend/lib/features/stt/transcript_store.dart`의 import에 두 줄을 **더한다**(기존 import는 하나도 지우지 않는다 — `transcribeVideo`가 아직 쓴다):

```dart
import '../../core/api_client.dart';
import 'transcript_api.dart';
```

그리고 전역 저장소를 **앱 시작 시점에 배선**한다. 라이브러리 초기화 시점에는 클라이언트를 만들지 않는다:

```dart
TranscriptStore transcriptStore = TranscriptStore(
  transcriber: _unwiredTranscriber,   // 배선 전에 부르면 StateError로 크게 실패
  root: captionsDirectory,            // 폴더 만드는 곳은 한 군데뿐
);

void wireTranscriptStore(ApiClient api) {
  transcriptStore = TranscriptStore(
    transcriber: defaultTranscriber(api),
    root: captionsDirectory,
  );
}
```

`app.dart`의 `initState`에서 `AppController`를 만든 직후 `wireTranscriptStore(controller.api)`를 부른다.

> **[2026-08-02 정정] 이 계획의 원래 문장 — "`ApiClient`를 새로 만들어도 로그인 상태는 그대로 쓴다. 토큰을 secure storage에서 읽는 인터셉터가 생성자에 있다" — 은 틀렸다.** 인터셉터는 `_memoryAccessToken ?? await _storage.read(...)` 순으로 읽는데, "로그인 유지"를 끄고(`persistSession: false`) 로그인하면 `_saveSession`이 저장소 키를 **지운다**(`api_client.dart:464-475`). 그러면 두 번째 클라이언트에는 메모리 토큰도 저장소 토큰도 없어 `Authorization` 헤더가 붙지 않고, 401 뒤 갱신도 갱신 토큰이 없어 실패한다 — 그 사용자는 자막을 아예 쓰지 못한다. 유지를 켜 두더라도 먼저 갱신한 쪽이 토큰을 회전시키면 다른 쪽은 낡은 `_memoryAccessToken`을 우선 쓰다 갱신에 실패하고 `catch (_) { await clearSession(); }`로 가 **사용자를 편집 도중 로그아웃**시킨다(`api_client.dart:502-519`). 단일 실행 가드 `_refreshFuture`도 인스턴스마다 따로라 서로를 막지 못한다. **앱의 `ApiClient`는 `AppController.api` 하나뿐이어야 한다.**

- [ ] **Step 2: `_run`이 넘기는 인자를 바꾼다**

같은 파일 `_run` 안에서 `final fresh = await transcriber(videoPath);`를 아래로 바꾼다:

```dart
      // 서버 전사는 videoId로 부른다 — 원본이 서버에 이미 있어 경로가 필요 없다.
      // videoPath 매개변수는 남겨 둔다: 호출부(caption_controller → ensure)를
      // 건드리지 않기 위해서고, 온디바이스 경로(transcribeVideo)가 코드에 남아
      // 있어 되돌릴 때 다시 쓴다.
      final fresh = await transcriber(videoId);
```

- [ ] **Step 3: 남은 두 주석의 거짓을 고친다**

같은 파일에서 사실이 아니게 된 주석 두 곳만 고친다. 파일 머리 `**왜 필요한가**` 문단:

```dart
/// **왜 필요한가**: 전사는 서버의 Gemini 호출이다 — 돈이고 네트워크다. 같은
/// 영상을 열 때마다 또 부르면 안 되니 한 번 받은 결과를 파일로 남긴다.
```

그리고 `_run`의 `catch` 안 주석에서 "오디오 추출이 깨진 것인지" → "서버가 죽은 것인지".

`typedef VideoTranscriber`의 doc와 매개변수 이름(`videoPath`)은 **그대로 둔다** — 고치면 이 파일을 쓰는 곳이 늘어난다. `transcribeVideo` 함수도 손대지 않는다.

- [ ] **Step 4: whisper 전용 예상시간을 뺀다**

`frontend/lib/ui/local_edit_screen.dart` 277~286행에서 주석 2줄과 `estimateSeconds:` 인자 3줄을 지운다:

```dart
              CaptionAutoSection(
                controller: _autoCaptions,
                // 자막 수정도 저장 안 된 변경이다.
                onChanged: () =>
                    setState(() => _editState.markExternalEditApplied()),
```

`CaptionAutoSection`의 `estimateSeconds` 매개변수와 `CaptionController.message({int? estimateSeconds})`는 **그대로 둔다.** 안 넘기면 null이 되어 "대사를 알아듣고 있어요."만 뜬다 — 그게 맞는 문구다. 시그니처를 지우면 위젯과 테스트를 고쳐야 한다.

- [ ] **Step 5: 전체 검증**

```
Set-Location C:\Users\SSAFY\dev\stt-captions\frontend; dart analyze lib test 2>&1 | Select-Object -Last 10
Set-Location C:\Users\SSAFY\dev\stt-captions\frontend; flutter test 2>&1 | Select-Object -Last 8
```

기대: 무경고, **150개 전부 통과**. 기존 테스트는 전사 함수를 `(_) async => ...`로 주입하므로 인자가 videoPath에서 videoId로 바뀐 것에 영향받지 않는다.

`stt_test.dart`와 `whisper_model_test.dart`도 **그대로 통과해야 한다** — whisper 코드를 지우지 않았기 때문이다. 이 둘이 깨지면 지우지 말아야 할 것을 건드린 것이니 되돌린다.

- [ ] **Step 6: 커밋**

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/features/stt/transcript_store.dart frontend/lib/ui/local_edit_screen.dart
git -C C:\Users\SSAFY\dev\stt-captions commit -m "feat: 자막 전사를 서버로 배선한다 — 이음매 한 곳만

TranscriptStore가 전사 함수를 주입받는 지점 하나만 바꿨다. ensure()와
CaptionController.start()의 시그니처, 자막 편집 UI, Media3 굽기, 만화는
그대로다.

예상시간 문구는 whisper 실측(영상 길이의 0.9배) 전용이라 뺐다 — 서버
전사에서는 틀린 숫자를 보여준다.

whisper 코드는 아직 남아 있으나 아무도 배선하지 않는다. 발표 뒤 정리한다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: 문서 — API-54, FN-A39 재정의, REQ-F-27

팀 규칙: `자료/docs`는 코드와 같은 브랜치·MR에서 고친다. FN-A39가 "폰 완결"에서 "폰+서버"로 바뀌므로 손댈 곳이 있다.

**모델을 앱에서 빼지 않았으므로** 모델 에셋·용량(q5_1, 약 181MiB)을 말하는 문장은 **여전히 사실이다 — 고치지 않는다.** 06 STT 모델 가이드도 그대로 둔다(측정 기록이자 발표 근거).

**Files:**
- Modify: `자료/docs/ai에게 입력용 문서/{01-service-overview,02-requirements,03-features,04-api-spec}.md`
- Modify: `자료/docs/사람이 읽을 문서/{01-서비스기획,02-요구사항명세서,03-기능명세서,04-API명세서}.md`

**Interfaces:** 없음 (문서만). 코드가 끝난 뒤에 한다 — 문서는 배포된 사실을 적는 것이다.

- [ ] **Step 1: API-54를 두 명세서에 넣는다**

먼저 API-53 섹션을 읽어 틀을 맞춘다(이 브랜치에서 방금 추가한 것이라 형식이 최신이다):

```bash
grep -n "API-53" "C:\Users\SSAFY\dev\stt-captions\자료\docs\ai에게 입력용 문서\04-api-spec.md"
```

`ai에게 입력용 문서/04-api-spec.md`의 API-53 섹션 **뒤**에 넣는다:

```markdown
### API-54 `POST /api/videos/{videoId}/transcript` **[제안·미구현]**

자동 자막(FN-A39)의 전사. **요청 본문 없음** — 원본이 이미 서버에 있으므로 경로의
videoId가 전부다. 서버가 저장된 원본에서 오디오와 대표 프레임(4~8장)을 뽑아
Gemini에 보내고, 시각 붙은 전사문을 돌려준다. 결과는 서버가 videoId로 캐시한다 —
같은 영상을 다시 불러도 Gemini를 또 부르지 않는다.

응답 200:

```json
{
  "lines": [
    {"startMs": 1200, "endMs": 3200, "text": "그거 만지지 마"}
  ]
}
```

| 항목 | 규칙 |
|---|---|
| `startMs`/`endMs` | 정수 밀리초. **`endMs` 필수** — 자막을 영상에 구울 때 줄이 사라질 시각이다 |
| `text` | 공백이 아닌 문자열. **문장 단위로 주면 된다** — 한 줄 20자 나눔은 앱이 한다 |
| 정렬·겹침 | `startMs` 오름차순, 구간이 겹치지 않아야 한다. 겹치면 앱이 먼저 걸린 줄만 보여준다 |
| 발화 없음 | `{"lines": []}` — 앱이 "대사를 알아듣지 못했어요"로 안내하고 자막 없이 저장하게 둔다 |
| 오류 | API-52·53과 같은 공통 블록(401/403/404/429/502/500). `message`는 사용자에게 **그대로 보인다** |
| 외부 전달 | **오디오와 대표 프레임이 Gemini(구글)로 나간다.** 개인정보 고지 대상 |
```

`사람이 읽을 문서/04-API명세서.md`에도 같은 내용을 그 문서의 산문 틀로 넣는다(API-53 산문 섹션을 읽고 맞춘다).

- [ ] **Step 2: API 개수 문장을 맞춘다**

```bash
grep -rn "API-01~5\|API 5[0-9]개\|53개" "C:\Users\SSAFY\dev\stt-captions\자료\docs"
```

걸리는 줄마다 53 → 54로 올린다. 합산을 적어 둔 검증 문장이 있으면 **다시 계산해서** 고친다(이 브랜치에서 API-52·53을 넣을 때 만든 산술이다 — 숫자만 바꾸지 말고 식이 맞는지 본다).

- [ ] **Step 3: FN-A39를 "폰+서버"로 다시 적는다**

```bash
grep -rn "FN-A39" "C:\Users\SSAFY\dev\stt-captions\자료\docs"
```

나오는 곳을 전부 현재 사실로 고친다. 핵심 행의 교체문 — `ai에게 입력용 문서/03-features.md` 2절 상세 표:

```markdown
| FN-A39 | 자동 자막 | 폰+서버 | 서버가 원본에서 Gemini로 전사한 시각별 자막(API-54)을 받아 줄마다 수정할 수 있게 한다. 결과는 `videoId`로 캐시하고, 저장 시 다른 편집 효과와 한 번에 인코딩한다 | REQ-F-27 / API-54 **[제안·미구현]** | `features/stt/*`, `SubtitleOverlay.kt` |
```

같은 문서 0.2 경로표의 `features/stt/` 행에 `transcript_api`를 더한다(**기존 이름은 지우지 않는다** — whisper 파일이 아직 있다):

```markdown
| `features/stt/`(pcm_wav, speech_analysis, android_audio, whisper_model, whisper_transcriber, transcript_api, caption_line, transcript_store, caption_controller, caption_auto_section) | FN-A39 |
```

6절(MVP ⑤)의 FN-A39 행과 `사람이 읽을 문서/03-기능명세서.md`의 대응 행 두 곳도 같은 취지로 고친다.

`03-기능명세서.md`의 "FN-A39 알아둘 점"에서 **모델 항목은 그대로 두고**(모델은 아직 앱에 들어 있다) 다음 두 줄을 더한다:

```markdown
- **전사는 서버가 한다(API-54).** 폰은 `videoId`만 보내고, 서버가 저장된 원본에서
  오디오와 대표 프레임을 뽑아 Gemini에 전달한다. 온디바이스 모델을 쓰다 옮긴 근거
  (배포 형태 CER 11.3%, 2분 영상 168초)는 06-STT모델가이드에 있다.
- **모델 파일은 아직 앱에 들어 있다.** 온디바이스 전사 코드도 남아 있으나 배선돼
  있지 않다. 발표 뒤에 함께 정리한다 — 지우면 설치 용량이 약 181MiB 줄고, 한글이
  든 경로에서 빌드가 실패하던 문제도 사라진다.
- **서버 통로가 없는 동안은 견본 자막 3줄이 뜬다.** `--dart-define=COMIC_SERVER=true`로 켠다.
```

- [ ] **Step 4: MVP ⑤ 문단과 REQ-F-27을 고친다**

이 브랜치에서 이미 한 번 고친 문단이다. FN-A39까지 서버를 쓰게 됐으니 다시 좁힌다.
`ai에게 입력용 문서/03-features.md`와 `사람이 읽을 문서/03-기능명세서.md`의 MVP ⑤ 표 아래 문단을:

```markdown
폰 완결인 것은 편집(FN-A21)뿐이다 — 원본 다운로드는 API-32를 재사용한다. 자동
자막(FN-A39)과 4컷 만화(FN-A40)는 서버 AI를 쓴다(API-52·53·54). 폰이 보내는 것은
`videoId`뿐이고(원본은 서버에 이미 있다), 서버가 오디오·대표 프레임을 Gemini에
전달한다. Gemini 키와 이미지 생성 키는 서버가 보관한다.
```

그다음 REQ-F-27을 훑는다:

```bash
grep -rn "REQ-F-27\|온디바이스 음성 인식\|기기에서 인식\|외부 전송 없음" "C:\Users\SSAFY\dev\stt-captions\자료\docs"
```

이 브랜치가 앞서 "FN-A21·FN-A39는 외부 전송 없음, FN-A40만 예외"로 고쳐 둔 문장들이 이제 **틀렸다.** FN-A39도 서버를 쓴다. 걸리는 곳을 다음 취지로 다시 적는다:

- 요구사항 본문: "폰에서 자르기·비율·효과·자막을 편집하고, **서버 전사(Gemini, API-54)**로 만든 자동 자막을 줄마다 수정할 수 있다"
- FN 목록: `FN-A21, FN-A39, FN-A40` 유지
- 비고: "편집(FN-A21)은 폰 완결·서버 API 불요. FN-A39·FN-A40은 서버 AI 사용 — 폰은 `videoId`만 보내고 서버가 오디오·대표 프레임을 Gemini에 전달한다"
- 구현 현황(부분 구현) 사유: "서버 통로(API-52·53·54) 미구현"

06 가이드가 스스로를 소개하며 쓰는 "FN-A39(온디바이스 자동 자막)" 같은 **과거 문맥 표현은 남긴다** — 그 문서는 측정 기록이다.

- [ ] **Step 5: 남은 거짓말이 없는지 훑는다**

```bash
grep -rn "온디바이스 자동 자막\|오디오·전사문 외부\|폰 밖으로 나가지" "C:\Users\SSAFY\dev\stt-captions\자료\docs"
```

06 가이드 밖에서 걸리는 것을 현재 사실로 고친다. **모델 용량·파일명(q5_1, 181MiB)을 말하는 문장은 건드리지 않는다 — 여전히 사실이다.**

- [ ] **Step 6: 코드를 건드리지 않았는지 확인하고 커밋**

```
Set-Location C:\Users\SSAFY\dev\stt-captions\frontend; dart analyze lib test 2>&1 | Select-Object -Last 5
Set-Location C:\Users\SSAFY\dev\stt-captions\frontend; flutter test 2>&1 | Select-Object -Last 5
```

기대: 무경고, 150개 통과(문서만 고쳤으니 그대로).

```bash
git -C C:\Users\SSAFY\dev\stt-captions add "자료/docs"
git -C C:\Users\SSAFY\dev\stt-captions commit -m "docs: FN-A39를 서버 전사(Gemini)로 재정의, API-54 추가

온디바이스 STT는 실측(배포 형태 CER 11.3%, 2분 168초)을 근거로 서버로 옮겼다.
측정 기록은 06 STT 모델 가이드에 그대로 둔다.

모델 파일과 온디바이스 코드는 아직 앱에 남아 있다(배선만 끊었다) —
용량·파일명을 말하는 문장은 여전히 사실이라 고치지 않았다.

폰은 videoId만 보낸다. 오디오·대표 프레임이 Gemini로 나간다는 사실을
API-54와 REQ-F-27에 적었다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: 실기기 확인과 MR (사람이 한다)

- [ ] **Step 1: 이 작업트리에서 빌드해 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend
```
```bash
flutter run -d R3CX606KQFX --dart-define=API_BASE_URL=https://i15e201.p.ssafy.io
```

서버가 없으므로 가짜 응답으로 흐름만 본다. 확인할 것:

1. 편집 화면 자막 탭에 견본 자막 3줄("그거 만지지 마" 등)이 **몇 초 안에** 뜬다 — 168초 대기가 사라졌다
2. 진행 중 문구가 "대사를 알아듣고 있어요."다 — **"약 ○○초 걸려요"가 안 뜬다**
3. 자막 줄을 고치고 저장 → 내보낸 영상에 자막이 구워져 있다 (Media3 경로 무손상)
4. 영상 상세 [4컷 만화 만들기] — 자막 화면을 **한 번 연 뒤에는** 구성 목록이 뜬다 (이번에 만화는 안 건드렸으므로 기존 동작 그대로)
5. 만화 화면 위 견본 안내, 대사 수정 → 그림 → 저장까지 기존 흐름 그대로

- [ ] **Step 2: push와 MR** — 팀 공유가 먼저다

팀원에게 미리 말할 것: FN-A39 전사를 서버로 옮긴다는 것, 근거(배포 형태 CER 11.3%, 2분 168초 — 06 가이드), 그리고 **온디바이스 코드와 모델은 이번에 지우지 않았다**는 것.

```bash
git -C C:\Users\SSAFY\dev\stt-captions push -u origin feat/frontend/comic
```

- 대상 `develop/frontend`, 원본 브랜치 삭제 켬, Jenkins CI 초록 확인 후 머지
- MR 본문에 적을 것: ① 4컷 만화(FN-A40) 신규 ② FN-A39 전사를 서버(Gemini, API-54)로 전환 — 근거와 팀 합의 명시 ③ **온디바이스 whisper 코드·모델은 배선만 끊고 남겼다. 발표 뒤 정리 예정이며, 그때 APK 181MiB 감소와 한글 경로 빌드 복구가 따라온다** ④ `COMIC_SERVER` 없이는 자막·만화 모두 가짜 응답(견본 안내 표시) ⑤ 서버 작업은 API-52·53·54 명세 참조

---

## 서버 쪽에 넘길 것 (feat/backend/*)

1. **API-54** `POST /api/videos/{videoId}/transcript` — 저장된 원본에서 오디오(+대표 프레임 4~8장) 추출 → Gemini 전사 → `{lines:[{startMs,endMs,text}]}`. **`endMs` 필수**, `startMs` 오름차순, 구간 안 겹침. videoId로 캐시.
2. **API-52·53** (만화 구성·그림) — 기존 명세 그대로. Gemini 키는 서버에만.
3. 사용자별 호출 제한. 오류 `message`는 사용자에게 그대로 보인다.
4. 오디오·대표 프레임이 Gemini(구글)로 나간다 — 개인정보 고지는 서비스 차원에서 정리.

## 남는 천장

- **whisper 코드·모델 181MiB·`jni` 의존성이 남는다** (이번에 남기기로 한 것). APK 용량과 **한글 경로 빌드 실패가 그대로**다. 발표 뒤 정리 대상.
- **만화는 여전히 자막 화면을 한 번 열어야 만들 수 있다** (`ComicNeedsTranscript` 유지). 서버 전사가 빨라져 이제는 자동으로 기다려도 되지만, 만화 코드를 건드리지 않기로 했다.
- **플래그 이름 `COMIC_SERVER`가 자막까지 켠다.** 이름이 사실보다 좁다. 읽는 곳이 셋째로 늘면 `core/`로 올리면서 개명한다.
- `transcript_store.dart`의 `ensure(videoId, videoPath)`에서 **`videoPath`가 쓰이지 않는다.** 호출부를 안 건드리려고 남긴 것이다.
- **네트워크 없이는 자막이 없다.** 원래도 편집 진입에 원본 다운로드(네트워크)가 필요했으므로(`local_edit_screen.dart:149`) 실질 손실은 없다.
- 전사 품질·속도가 서버와 Gemini에 달렸다 — 앱이 할 수 있는 건 캐시뿐이다.
- 가짜 전사는 항상 같은 3줄이라 실기기 시연에서 영상 내용과 무관하다.
- `CaptionController.edit`은 고친 자막을 **메모리에만** 반영하고 캐시에 쓰지 않는다(기존 이월 사항). 그래서 만화는 사용자가 고치기 전의 원문을 쓴다 — 이번 범위 밖.
