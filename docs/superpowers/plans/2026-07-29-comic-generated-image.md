# 4컷 만화 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 전사문을 서버에 보내 4컷 구성과 만화 그림을 받고, 대사를 영화 자막처럼 얹어 갤러리에 저장한다.

**Architecture:** `features/comic/`이 전사문 읽기(→ `features/stt`), 서버 호출, 상태, 화면을 담당한다. 서버 통로는 별도 브랜치(`feat/backend/*`)에서 만들므로, 기본값은 **가짜 게이트웨이**다 — 서버 없이 화면 전부를 만들고 검증한다.

**Tech Stack:** Flutter/Dart, `dart:ui`(가짜 그림 생성·화면 캡처), `share_plus`(갤러리 저장), 기존 `ApiClient`(Dio)

**설계 문서:** [docs/superpowers/specs/2026-07-29-comic-generated-image-design.md](../specs/2026-07-29-comic-generated-image-design.md)

## Global Constraints

- **작업트리** `C:\Users\SSAFY\dev\stt-captions`, **브랜치** `feat/frontend/comic` (base `develop/frontend`). ASCII 경로여야 Gradle이 빌드한다.
- **전사문(글)만 서버로 보낸다.** 영상·오디오·프레임은 기기를 떠나지 않는다.
- **이미지 생성 키를 앱에 넣지 않는다.** 앱은 우리 서버만 부른다. `ApiClient`가 이미 인증 토큰을 붙인다.
- **전사는 다시 하지 않는다.** `features/stt`의 `transcriptStore`가 캐시한 것을 읽는다.
- **새 pub 의존성을 추가하지 않는다.** 이미 있는 `share_plus`, `path_provider`, `dio`만 쓴다.
- **실패는 항상 강등한다.** 어느 단계가 막혀도 앞 단계 결과(고친 대사 등)를 잃지 않고 재시도할 수 있어야 한다.
- **진입 버튼은 `ui/content_video_detail_screen.dart`에 넣는다.** 같은 폴더의 `video_detail_screen.dart`에 있는 `_LegacyVideoDetailScreen`은 **아무도 부르지 않는 죽은 코드**다 — 거기 넣으면 빌드는 되고 화면에 안 보인다.
- **테스트에서 실제 파일을 만들 때는 반드시 `Directory.systemTemp.createTemp()`를 쓴다.** 절대 경로를 하드코딩하면 윈도우에서는 통과하고 리눅스 CI에서만 권한 오류로 죽는다(자막 작업에서 실제로 겪었다).
- `flutter analyze`는 CI가 돌린다. 로컬 검증은 `dart analyze`와 `flutter test`로 한다.
- 커밋 메시지는 한국어로 쓰고 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`를 붙인다. **`develop/frontend`에 직접 push하지 않는다.**
- **테스트 통과 기준:** 기존 95개 + 새로 추가한 것 전부 통과.

## 파일 구조

| 파일 | 책임 |
|---|---|
| `features/comic/comic_script.dart` | `ComicCut` 자료형, JSON 변환, 응답 검증(4개인지) |
| `features/comic/comic_gateway.dart` | 서버 통로 — 인터페이스 + `HttpComicGateway` + `FakeComicGateway` |
| `features/comic/comic_controller.dart` | 상태 전이 (전사문 → 구성 → 이미지), 대사 수정 |
| `features/comic/panel_subtitle.dart` | 2x2 그림 위에 자막을 얹는 위젯 |
| `features/comic/comic_screen.dart` | 화면 — 목록·버튼·저장 |
| `core/api_client.dart` | 메서드 2개 추가 (기존 42개와 같은 관례) |
| `ui/content_video_detail_screen.dart` | 진입 버튼 1개 |

---

### Task 1: ComicCut 자료형과 응답 검증

서버 응답을 자료형으로 옮기고 **컷이 정확히 4개인지** 검증한다. 4개가 아니면 계약 위반이므로 오류로 다룬다 — 그러지 않으면 자막을 얹을 칸이 안 맞는다.

**Files:**
- Create: `frontend/lib/features/comic/comic_script.dart`
- Test: `frontend/test/comic_script_test.dart`

**Interfaces:**
- Consumes: `CaptionLine` (`features/stt/caption_line.dart` — `{int startMs, int endMs, String text}`)
- Produces:
  - `class ComicCut { ComicCut({required String beat, required String scene, String? dialogue}); final String beat; final String scene; String? dialogue; }`
  - `const comicCutCount = 4`
  - `List<ComicCut> parseComicCuts(Map<String, dynamic> body)` — 4개가 아니면 `FormatException`
  - `List<Map<String, Object?>> cutsToJson(List<ComicCut> cuts)`
  - `List<Map<String, Object>> linesToJson(List<CaptionLine> lines)` — `{startMs, text}`만 보낸다

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`frontend/test/comic_script_test.dart`:

```dart
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
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/comic_script_test.dart
```

기대: 컴파일 실패 — `comic_script.dart`가 없다.

- [ ] **Step 3: 구현한다**

`frontend/lib/features/comic/comic_script.dart`:

```dart
/// 서버와 주고받는 4컷 구성.
///
/// **왜 4개를 강제하나**: 그림이 2x2 격자 한 장이고 자막을 각 칸에 얹는다. 컷 수가
/// 다르면 얹을 칸이 안 맞는다. 서버 계약 위반이므로 조용히 넘기지 않고 던진다.
library;

import '../stt/caption_line.dart';

/// 만화는 항상 네 컷이다.
const comicCutCount = 4;

class ComicCut {
  ComicCut({required this.beat, required this.scene, this.dialogue});

  /// 기·승·전·결 중 어디인지. 사용자에게 보여준다.
  final String beat;

  /// 이미지 프롬프트에 들어갈 장면 묘사. 사용자에게도 보여준다.
  final String scene;

  /// 그 컷에서 들린 대사. 없는 컷도 있다(상황만 있는 컷).
  /// 사용자가 고칠 수 있다.
  String? dialogue;
}

/// 서버 응답을 자료형으로 옮긴다. 계약을 어기면 [FormatException]을 던진다.
List<ComicCut> parseComicCuts(Map<String, dynamic> body) {
  final raw = body['cuts'];
  if (raw is! List || raw.length != comicCutCount) {
    throw FormatException(
      '만화는 $comicCutCount컷이어야 합니다 (받은 것: ${raw is List ? raw.length : raw}).',
    );
  }
  return [
    for (final entry in raw)
      ComicCut(
        beat: _required(entry, 'beat'),
        scene: _required(entry, 'scene'),
        dialogue: _dialogue(entry),
      ),
  ];
}

String _required(Object? entry, String key) {
  final value = (entry as Map?)?[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('컷에 $key가 없습니다: $entry');
  }
  return value.trim();
}

/// 빈 문자열은 null로 본다 — 빈 자막 띠를 그리지 않기 위해서다.
String? _dialogue(Object? entry) {
  final value = (entry as Map?)?['dialogue'];
  if (value is! String) return null;
  final text = value.trim();
  return text.isEmpty ? null : text;
}

List<Map<String, Object?>> cutsToJson(List<ComicCut> cuts) => [
  for (final cut in cuts)
    {'beat': cut.beat, 'scene': cut.scene, 'dialogue': cut.dialogue},
];

/// 서버에 보낼 전사문. **끝 시각은 보내지 않는다** — 구성에 쓰이지 않는다.
List<Map<String, Object>> linesToJson(List<CaptionLine> lines) => [
  for (final line in lines)
    if (line.text.trim().isNotEmpty)
      {'startMs': line.startMs, 'text': line.text.trim()},
];
```

- [ ] **Step 4: 테스트가 통과하는 것을 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/comic_script_test.dart
```

기대: 9개 통과.

- [ ] **Step 5: 커밋**

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/features/comic/comic_script.dart frontend/test/comic_script_test.dart
git -C C:\Users\SSAFY\dev\stt-captions commit -m "feat: 4컷 구성 자료형과 응답 검증 (ComicCut)

컷이 4개가 아니면 던진다 — 그림이 2x2 격자라 자막을 얹을 칸이 안 맞는다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: 서버 통로 (가짜가 기본값)

앱이 서버를 부르는 자리를 만든다. **서버가 아직 없으므로 가짜가 기본값이다** — 고정 구성과 4칸으로 나뉜 그림을 돌려주므로 화면 전부를 만들고 검증할 수 있다.

`ApiClient`에 메서드 두 개를 더한다. 기존 42개와 같은 관례를 따르고, 테스트는 기존
`_AccountApiClient`처럼 `ApiClient`를 상속해 갈아끼운다.

**Files:**
- Create: `frontend/lib/features/comic/comic_gateway.dart`
- Modify: `frontend/lib/core/api_client.dart` (메서드 2개 추가)
- Test: `frontend/test/comic_gateway_test.dart`

**Interfaces:**
- Consumes: `ComicCut` / `parseComicCuts` / `cutsToJson` / `linesToJson` (Task 1), `CaptionLine`
- Produces:
  - `abstract interface class ComicGateway` — `Future<List<ComicCut>> script(String videoId, List<CaptionLine> lines)`, `Future<Uint8List> image(String videoId, List<ComicCut> cuts, {String style})`
  - `class HttpComicGateway implements ComicGateway { HttpComicGateway(this.api); final ApiClient api; }`
  - `class FakeComicGateway implements ComicGateway`
  - `const comicServerReady = bool.fromEnvironment('COMIC_SERVER')`
  - `ComicGateway defaultComicGateway(ApiClient api)` — 플래그에 따라 고른다
  - `ApiClient.createComicScript(String videoId, List<Map<String, Object>> lines) → Future<Map<String, dynamic>>`
  - `ApiClient.createComicImage(String videoId, {required List<Map<String, Object?>> cuts, required String style}) → Future<Map<String, dynamic>>`

> 설계 문서에는 `COMIC_GATEWAY`를 문자열로 적었지만 **주소가 필요 없다** — 우리 서버는
> `API_BASE_URL`과 같은 곳이고 `ApiClient`가 인증까지 붙인다. 그래서 켜고 끄는
> 플래그(`COMIC_SERVER`) 하나로 바꿨다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`frontend/test/comic_gateway_test.dart`:

```dart
/// 서버 통로 계약.
/// 서버가 아직 없으므로 기본값은 가짜다. 진짜 통로는 요청 본문 모양만 고정한다 —
/// 키 이름이 바뀌면 서버가 조용히 못 알아듣는다.
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
    return {'image': base64Encode(Uint8List.fromList([1, 2, 3, 4]))};
  }
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

  test('COMIC_SERVER를 주지 않으면 가짜를 쓴다 — 서버 없이 화면을 만든다', () {
    expect(comicServerReady, isFalse);
    expect(defaultComicGateway(ApiClient()), isA<FakeComicGateway>());
  });
}

class _NoImageApi extends _RecordingApi {
  @override
  Future<Map<String, dynamic>> createComicImage(
    String videoId, {
    required List<Map<String, Object?>> cuts,
    required String style,
  }) async => <String, dynamic>{};
}
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/comic_gateway_test.dart
```

기대: 컴파일 실패 — `comic_gateway.dart`가 없다.

- [ ] **Step 3: ApiClient에 메서드 두 개를 더한다**

`frontend/lib/core/api_client.dart`의 다른 공개 메서드들 사이에 넣는다 (`_post`가 정의된
private 구역 **앞**):

```dart
  /// 전사문으로 4컷 구성을 받는다. 서버가 키를 들고 LLM을 대신 부른다.
  ///
  /// **글만 보낸다** — 영상·오디오·프레임은 보내지 않는다.
  Future<Map<String, dynamic>> createComicScript(
    String videoId,
    List<Map<String, Object>> lines,
  ) => _post('/api/videos/$videoId/comic/script', data: {'lines': lines});

  /// 4컷 구성으로 만화 그림 한 장(2x2 격자)을 받는다. 응답은 base64 PNG다.
  Future<Map<String, dynamic>> createComicImage(
    String videoId, {
    required List<Map<String, Object?>> cuts,
    required String style,
  }) => _post(
    '/api/videos/$videoId/comic/image',
    data: {'cuts': cuts, 'style': style},
  );
```

- [ ] **Step 4: 게이트웨이를 구현한다**

`frontend/lib/features/comic/comic_gateway.dart`:

```dart
/// 만화를 만드는 서버 통로.
///
/// **왜 서버를 경유하나**: 이미지 생성 API 키를 앱에 넣으면 APK를 뜯어 가져갈 수
/// 있다. 그러면 남의 계정으로 아무나 이미지를 생성한다. 키는 서버에만 둔다.
///
/// 서버 통로는 별도 브랜치(feat/backend/*)에서 만든다. 그때까지 기본값은
/// [FakeComicGateway]다 — 서버 없이 화면 전부를 만들고 검증할 수 있다.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../stt/caption_line.dart';
import 'comic_script.dart';

/// 서버 통로가 준비되면 `--dart-define=COMIC_SERVER=true`로 켠다.
const comicServerReady = bool.fromEnvironment('COMIC_SERVER');

/// 기본 화풍. 화면에 고르는 UI를 두지 않는다(설계의 "하지 않는 것").
const comicDefaultStyle = 'webtoon';

abstract interface class ComicGateway {
  /// 전사문 → 4컷 구성.
  Future<List<ComicCut>> script(String videoId, List<CaptionLine> lines);

  /// 4컷 구성 → 만화 그림 한 장(PNG 바이트). 2x2 격자다.
  Future<Uint8List> image(
    String videoId,
    List<ComicCut> cuts, {
    String style,
  });
}

ComicGateway defaultComicGateway(ApiClient api) =>
    comicServerReady ? HttpComicGateway(api) : FakeComicGateway();

class HttpComicGateway implements ComicGateway {
  HttpComicGateway(this.api);

  final ApiClient api;

  @override
  Future<List<ComicCut>> script(
    String videoId,
    List<CaptionLine> lines,
  ) async =>
      parseComicCuts(await api.createComicScript(videoId, linesToJson(lines)));

  @override
  Future<Uint8List> image(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async {
    final body = await api.createComicImage(
      videoId,
      cuts: cutsToJson(cuts),
      style: style,
    );
    final encoded = body['image'];
    if (encoded is! String || encoded.isEmpty) {
      throw FormatException('응답에 그림이 없습니다: ${body.keys.toList()}');
    }
    return base64Decode(encoded);
  }
}

/// 서버가 없을 때 쓰는 가짜. 화면과 흐름을 그대로 검증할 수 있게 만든다.
class FakeComicGateway implements ComicGateway {
  @override
  Future<List<ComicCut>> script(
    String videoId,
    List<CaptionLine> lines,
  ) async => [
    ComicCut(
      beat: '빌드업',
      scene: '아이가 탁자 위 물건에 손을 뻗고, 엄마가 말리는 순간',
      dialogue: '그거 만지지 마',
    ),
    ComicCut(
      beat: '전개',
      scene: '아이가 손을 뒤로 감추며 아니라고 하는 순간',
      dialogue: '안 만졌는데요',
    ),
    ComicCut(
      beat: '절정',
      scene: '탁자 위 물건이 바닥에 흩어져 있고 세 사람이 눈을 크게 뜨고 보는 순간',
    ),
    ComicCut(
      beat: '여운',
      scene: '온 가족이 마주 보며 크게 웃는 순간',
      dialogue: '안 만졌다면서',
    ),
  ];

  /// 2x2로 나뉜 색 블록. 자막을 얹을 칸이 보이면 화면 작업에 충분하다.
  @override
  Future<Uint8List> image(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async {
    const side = 512.0;
    const colors = [
      Color(0xFFBBDEFB),
      Color(0xFFC8E6C9),
      Color(0xFFFFE0B2),
      Color(0xFFF8BBD0),
    ];

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawRect(
        const Rect.fromLTWH(0, 0, side, side),
        Paint()..color = Colors.white,
      );
    for (var i = 0; i < colors.length; i++) {
      final left = (i % 2) * side / 2;
      final top = (i ~/ 2) * side / 2;
      canvas.drawRect(
        Rect.fromLTWH(left + 6, top + 6, side / 2 - 12, side / 2 - 12),
        Paint()..color = colors[i],
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(side.toInt(), side.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) throw StateError('가짜 그림을 만들지 못했습니다.');
    return data.buffer.asUint8List();
  }
}
```

- [ ] **Step 5: 테스트가 통과하는 것을 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/comic_gateway_test.dart
```

기대: 6개 통과. `dart:ui`로 그림을 만드는 부분은 `flutter_test`가 래스터라이저를
갖고 있어 동작한다.

- [ ] **Step 6: 커밋**

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/features/comic/comic_gateway.dart frontend/lib/core/api_client.dart frontend/test/comic_gateway_test.dart
git -C C:\Users\SSAFY\dev\stt-captions commit -m "feat: 만화 서버 통로 — 가짜가 기본값

이미지 생성 키를 앱에 넣으면 APK에서 빼낼 수 있으므로 우리 서버를 경유한다.
서버 통로는 feat/backend 브랜치에서 만들므로 그때까지 FakeComicGateway가
기본값이다 — 서버 없이 화면 전부를 만들고 검증한다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: 상태 컨트롤러

전사문 읽기부터 그림 받기까지의 상태를 한 클래스가 들고 있는다. 화면은 이걸 만들고
부르기만 한다.

**핵심 규칙**: 이미지 요청이 실패해도 **구성과 사용자가 고친 대사를 잃지 않는다.**
다시 시도할 때 고친 것이 그대로 넘어가야 한다.

**Files:**
- Create: `frontend/lib/features/comic/comic_controller.dart`
- Test: `frontend/test/comic_controller_test.dart`

**Interfaces:**
- Consumes: `ComicGateway` (Task 2), `ComicCut` (Task 1), `transcriptStore` / `CaptionLine` (`features/stt`)
- Produces:
  - `sealed class ComicState` — `ComicNeedsTranscript()` / `ComicLoadingScript()` / `ComicScriptReady(List<ComicCut> cuts)` / `ComicLoadingImage(List<ComicCut> cuts)` / `ComicReady(List<ComicCut> cuts, Uint8List image)` / `ComicFailed(String reason, List<ComicCut>? cuts)`
  - `class ComicController extends ChangeNotifier { ComicController({required ComicGateway gateway, required String videoId, TranscriptStore? store}); }`
  - `Future<void> start()` — 전사문을 읽고 구성을 받는다
  - `void editDialogue(int index, String? text)`
  - `Future<void> makeImage()`
  - `ComicState get state`
  - `List<ComicCut> get cuts` — 없으면 빈 목록

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`frontend/test/comic_controller_test.dart`:

```dart
/// 만화 상태 전이.
/// 이미지 요청이 실패해도 고친 대사를 잃지 않아야 한다 — 다시 만들 때 그대로 써야
/// 하고, 잃으면 사용자가 처음부터 다시 고쳐야 한다.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/comic/comic_controller.dart';
import 'package:william_james_app/features/comic/comic_gateway.dart';
import 'package:william_james_app/features/comic/comic_script.dart';
import 'package:william_james_app/features/stt/caption_line.dart';
import 'package:william_james_app/features/stt/transcript_store.dart';

/// 파일을 만들지 않는 저장소 (stt 테스트와 같은 이유 — 실제 입출력은 거기서 검증).
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

class _StubGateway implements ComicGateway {
  _StubGateway({this.scriptError, this.imageError});

  final Object? scriptError;
  final Object? imageError;
  List<ComicCut>? receivedCuts;

  @override
  Future<List<ComicCut>> script(String videoId, List<CaptionLine> lines) async {
    if (scriptError != null) throw scriptError!;
    return [
      for (var i = 0; i < 4; i++)
        ComicCut(beat: '컷$i', scene: '장면$i', dialogue: '대사$i'),
    ];
  }

  @override
  Future<Uint8List> image(
    String videoId,
    List<ComicCut> cuts, {
    String style = comicDefaultStyle,
  }) async {
    receivedCuts = cuts;
    if (imageError != null) throw imageError!;
    return Uint8List.fromList([9, 9, 9]);
  }
}

List<CaptionLine> _lines() => [
  CaptionLine(startMs: 1000, endMs: 3000, text: '그거 만지지 마'),
];

void main() {
  ComicController controller({
    List<CaptionLine>? saved,
    _StubGateway? gateway,
  }) => ComicController(
    gateway: gateway ?? _StubGateway(),
    videoId: 'v1',
    store: _MemoryStore(saved),
  );

  test('전사문이 없으면 만들 수 없다고 알린다', () async {
    final subject = controller();
    await subject.start();

    expect(subject.state, isA<ComicNeedsTranscript>());
    expect(subject.cuts, isEmpty);
  });

  test('전사문이 있으면 구성을 받아 온다', () async {
    final subject = controller(saved: _lines());
    var notified = 0;
    subject.addListener(() => notified++);

    await subject.start();

    expect(subject.state, isA<ComicScriptReady>());
    expect(subject.cuts, hasLength(4));
    expect(notified, greaterThan(0));
  });

  test('구성 요청이 실패하면 사유를 남긴다', () async {
    final subject = controller(
      saved: _lines(),
      gateway: _StubGateway(scriptError: StateError('서버 없음')),
    );
    await subject.start();

    expect(subject.state, isA<ComicFailed>());
    expect((subject.state as ComicFailed).reason, contains('서버 없음'));
  });

  test('대사를 고치면 구성에 반영된다', () async {
    final subject = controller(saved: _lines());
    await subject.start();

    subject.editDialogue(0, '고친 대사');

    expect(subject.cuts[0].dialogue, '고친 대사');
  });

  test('대사를 지우면 null이 된다 — 자막 띠를 그리지 않는다', () async {
    final subject = controller(saved: _lines());
    await subject.start();

    subject.editDialogue(0, '   ');

    expect(subject.cuts[0].dialogue, isNull);
  });

  test('없는 컷을 고치라고 해도 죽지 않는다', () async {
    final subject = controller(saved: _lines());
    await subject.start();

    subject.editDialogue(9, '아무거나');

    expect(subject.cuts, hasLength(4));
  });

  test('그림을 받으면 완료가 된다', () async {
    final subject = controller(saved: _lines());
    await subject.start();
    await subject.makeImage();

    expect(subject.state, isA<ComicReady>());
    expect((subject.state as ComicReady).image, [9, 9, 9]);
  });

  test('그림 요청은 고친 대사를 그대로 보낸다', () async {
    final gateway = _StubGateway();
    final subject = controller(saved: _lines(), gateway: gateway);
    await subject.start();
    subject.editDialogue(0, '고친 대사');

    await subject.makeImage();

    expect(gateway.receivedCuts![0].dialogue, '고친 대사');
  });

  test('그림 요청이 실패해도 고친 대사를 잃지 않는다', () async {
    final subject = controller(
      saved: _lines(),
      gateway: _StubGateway(imageError: StateError('생성 실패')),
    );
    await subject.start();
    subject.editDialogue(0, '고친 대사');

    await subject.makeImage();

    expect(subject.state, isA<ComicFailed>());
    expect(subject.cuts[0].dialogue, '고친 대사', reason: '다시 만들 때 써야 한다');
  });

  test('구성 없이 그림을 만들라고 하면 아무 일도 하지 않는다', () async {
    final gateway = _StubGateway();
    final subject = controller(gateway: gateway);
    await subject.start();

    await subject.makeImage();

    expect(gateway.receivedCuts, isNull);
  });
}
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/comic_controller_test.dart
```

기대: 컴파일 실패 — `comic_controller.dart`가 없다.

- [ ] **Step 3: 구현한다**

`frontend/lib/features/comic/comic_controller.dart`:

```dart
/// 만화 만들기 상태 — 전사문 → 구성 → 그림.
///
/// 화면은 이 클래스를 만들고 부르기만 한다. 상태 전이가 여기 모여 있어서 화면을
/// 띄우지 않고 전부 검증할 수 있다.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../stt/caption_line.dart';
import '../stt/transcript_store.dart' as stt;
import 'comic_gateway.dart';
import 'comic_script.dart';

sealed class ComicState {
  const ComicState();
}

/// 자막(전사문)이 없다. 만화를 만들 수 없다.
class ComicNeedsTranscript extends ComicState {
  const ComicNeedsTranscript();
}

class ComicLoadingScript extends ComicState {
  const ComicLoadingScript();
}

class ComicScriptReady extends ComicState {
  const ComicScriptReady(this.cuts);
  final List<ComicCut> cuts;
}

class ComicLoadingImage extends ComicState {
  const ComicLoadingImage(this.cuts);
  final List<ComicCut> cuts;
}

class ComicReady extends ComicState {
  const ComicReady(this.cuts, this.image);
  final List<ComicCut> cuts;
  final Uint8List image;
}

/// 실패했지만 구성이 있으면 함께 들고 있는다 — 고친 대사를 잃지 않기 위해서다.
class ComicFailed extends ComicState {
  const ComicFailed(this.reason, this.cuts);
  final String reason;
  final List<ComicCut>? cuts;
}

class ComicController extends ChangeNotifier {
  ComicController({
    required this.gateway,
    required this.videoId,
    stt.TranscriptStore? store,
  }) : _store = store ?? stt.transcriptStore;

  final ComicGateway gateway;
  final String videoId;
  final stt.TranscriptStore _store;

  ComicState _state = const ComicLoadingScript();
  List<ComicCut> _cuts = <ComicCut>[];

  ComicState get state => _state;

  /// 지금 들고 있는 구성. 없으면 빈 목록.
  List<ComicCut> get cuts => _cuts;

  void _set(ComicState next) {
    _state = next;
    notifyListeners();
  }

  /// 자막에서 만든 전사문을 읽어 구성을 받는다. **전사를 다시 돌리지 않는다.**
  Future<void> start() async {
    _set(const ComicLoadingScript());
    final List<CaptionLine>? lines;
    try {
      lines = await _store.read(videoId);
    } catch (error) {
      _set(ComicFailed('$error', null));
      return;
    }
    if (lines == null || lines.isEmpty) {
      _set(const ComicNeedsTranscript());
      return;
    }

    try {
      _cuts = await gateway.script(videoId, lines);
      _set(ComicScriptReady(_cuts));
    } catch (error) {
      _set(ComicFailed('$error', null));
    }
  }

  /// 빈 글이면 null로 둔다 — 빈 자막 띠를 그리지 않는다.
  void editDialogue(int index, String? text) {
    if (index < 0 || index >= _cuts.length) return;
    final trimmed = text?.trim();
    _cuts[index].dialogue = (trimmed == null || trimmed.isEmpty)
        ? null
        : trimmed;
    notifyListeners();
  }

  /// 실패해도 _cuts를 그대로 둔다 — 사용자가 고친 것을 잃으면 처음부터 다시
  /// 고쳐야 한다.
  Future<void> makeImage() async {
    if (_cuts.isEmpty) return;
    _set(ComicLoadingImage(_cuts));
    try {
      final bytes = await gateway.image(videoId, _cuts);
      _set(ComicReady(_cuts, bytes));
    } catch (error) {
      _set(ComicFailed('$error', _cuts));
    }
  }
}
```

- [ ] **Step 4: 테스트가 통과하는 것을 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/comic_controller_test.dart
```

기대: 11개 통과.

- [ ] **Step 5: 커밋**

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/features/comic/comic_controller.dart frontend/test/comic_controller_test.dart
git -C C:\Users\SSAFY\dev\stt-captions commit -m "feat: 만화 상태 컨트롤러 (전사문 → 구성 → 그림)

그림 요청이 실패해도 사용자가 고친 대사를 잃지 않는다 — 잃으면 처음부터 다시
고쳐야 한다. 테스트로 고정했다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: 2x2 그림 위에 자막 얹기

그림을 네 칸으로 나눠 각 칸 아래쪽에 영화 자막처럼 대사를 얹는다.

**컷과 칸의 대응**은 읽는 순서와 같다 — 0 왼쪽 위, 1 오른쪽 위, 2 왼쪽 아래,
3 오른쪽 아래.

**Files:**
- Create: `frontend/lib/features/comic/panel_subtitle.dart`
- Test: `frontend/test/panel_subtitle_test.dart`

**Interfaces:**
- Consumes: `ComicCut` (Task 1)
- Produces:
  - `class ComicCanvas extends StatelessWidget { const ComicCanvas({required Uint8List image, required List<ComicCut> cuts}); }`
  - `Alignment subtitleAlignment(int cutIndex)` — 그 컷 자막 띠의 위치

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`frontend/test/panel_subtitle_test.dart`:

```dart
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
    final png = await onePixelPng();
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
    final png = await onePixelPng();
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
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/panel_subtitle_test.dart
```

기대: 컴파일 실패 — `panel_subtitle.dart`가 없다.

- [ ] **Step 3: 구현한다**

`frontend/lib/features/comic/panel_subtitle.dart`:

```dart
/// 2x2 만화 그림 위에 대사를 영화 자막처럼 얹는다.
///
/// **왜 말풍선이 아닌가**: 생성 모델에게 말풍선을 그리지 말라고 요청한다. 말풍선
/// 자리가 있으면 모델이 거기에 글자를 넣으려 하고(PC 시험에서 "CRASH"가 박혔다),
/// 앱이 얹는 글자와 스타일도 섞인다.
///
/// **칸 대응은 읽는 순서와 같다** — 0 왼쪽 위, 1 오른쪽 위, 2 왼쪽 아래, 3 오른쪽
/// 아래. 그림이 2x2 격자로 나온다는 전제에 기대고 있다(설계의 천장).
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'comic_script.dart';

/// 자막 띠를 칸 아래쪽에 둔다. y는 -1이 위, 1이 아래다.
const _subtitleY = 0.82;

Alignment subtitleAlignment(int cutIndex) {
  final right = cutIndex % 2 == 1;
  final bottom = cutIndex >= 2;
  return Alignment(
    right ? 0.5 : -0.5,
    bottom ? _subtitleY : _subtitleY - 1,
  );
}

class ComicCanvas extends StatelessWidget {
  const ComicCanvas({super.key, required this.image, required this.cuts});

  final Uint8List image;
  final List<ComicCut> cuts;

  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: 1,
    child: Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(image, fit: BoxFit.contain),
        for (var index = 0; index < cuts.length; index++)
          if (cuts[index].dialogue case final line?)
            Align(
              alignment: subtitleAlignment(index),
              child: FractionallySizedBox(
                widthFactor: 0.44,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.62),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    child: Text(
                      // 영화 자막에서 화자가 바뀜을 나타내는 관례다.
                      '- $line',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        shadows: [Shadow(color: Colors.black, blurRadius: 2)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
      ],
    ),
  );
}
```

- [ ] **Step 4: 테스트가 통과하는 것을 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/panel_subtitle_test.dart
```

기대: 3개 통과.

- [ ] **Step 5: 커밋**

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/features/comic/panel_subtitle.dart frontend/test/panel_subtitle_test.dart
git -C C:\Users\SSAFY\dev\stt-captions commit -m "feat: 2x2 만화 위에 영화 자막처럼 대사를 얹는다

말풍선을 쓰지 않는다 — 모델에게 말풍선을 그리지 말라고 요청하기 때문이다.
말풍선 자리가 있으면 모델이 거기에 글자를 넣는다(시험에서 확인).

칸 대응(0 왼위, 1 오른위, 2 왼아래, 3 오른아래)을 테스트로 고정했다 — 틀리면
3컷 대사가 1컷에 붙는데 눈으로만 보면 놓치기 쉽다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: 만화 화면

앞의 조각들을 붙여 화면을 만든다. 저장은 `RepaintBoundary`로 화면을 떠서 공유 시트로
넘긴다 — 예전 만화 편집기가 쓴 방식이고 새 의존성이 없다.

**Files:**
- Create: `frontend/lib/features/comic/comic_screen.dart`
- Test: `frontend/test/comic_screen_test.dart`

**Interfaces:**
- Consumes: `ComicController` / `ComicState` (Task 3), `ComicCanvas` (Task 4), `defaultComicGateway` (Task 2), `ApiClient`, `VideoMemory`
- Produces: `class ComicScreen extends StatefulWidget { const ComicScreen({required ApiClient api, required VideoMemory video, ComicController? controller}); }`

> `controller`를 주입할 수 있게 둔다 — 위젯 테스트가 가짜 상태를 넣는 통로다
> (`ComicEditorScreen`이 `deps`를 주입받던 것과 같은 관례).

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`frontend/test/comic_screen_test.dart`:

```dart
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

class _StubGateway implements ComicGateway {
  _StubGateway({this.imageError});

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
    return FakeComicGateway().image(videoId, cuts);
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

ComicController build({
  List<CaptionLine>? saved,
  _StubGateway? gateway,
}) => ComicController(
  gateway: gateway ?? _StubGateway(),
  videoId: 'v1',
  store: _MemoryStore(saved),
);

List<CaptionLine> _lines() => [
  CaptionLine(startMs: 1000, endMs: 3000, text: '그거 만지지 마'),
];

void main() {
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
      build(saved: _lines(), gateway: _StubGateway(imageError: StateError('생성 실패'))),
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
```

- [ ] **Step 2: 테스트가 실패하는 것을 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/comic_screen_test.dart
```

기대: 컴파일 실패 — `comic_screen.dart`가 없다.

- [ ] **Step 3: 구현한다**

`frontend/lib/features/comic/comic_screen.dart`:

```dart
/// 4컷 만화 만들기 화면.
///
/// 전사문(자막 기능이 만든 것)으로 구성을 받고, 대사를 고치고, 그림을 받아
/// 자막을 얹어 갤러리에 저장한다. 로직은 ComicController에 있고 여기는 화면만 본다.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import '../../app/app_theme.dart';
import '../../core/api_client.dart';
import '../../core/models.dart';
import '../../ui/widgets.dart';
import 'comic_controller.dart';
import 'comic_gateway.dart';
import 'comic_script.dart';
import 'panel_subtitle.dart';

class ComicScreen extends StatefulWidget {
  const ComicScreen({
    super.key,
    required this.api,
    required this.video,
    this.controller,
  });

  final ApiClient api;
  final VideoMemory video;

  /// 주입되면 그대로 쓴다. 위젯 테스트가 가짜 상태를 넣는 통로다.
  final ComicController? controller;

  @override
  State<ComicScreen> createState() => _ComicScreenState();
}

class _ComicScreenState extends State<ComicScreen> {
  /// 화면을 PNG로 뜰 때 쓰는 경계.
  final _canvasKey = GlobalKey();

  /// 대사 입력칸은 화면이 소유한다 — 다이얼로그마다 만들어 닫힌 직후 dispose하면
  /// 리빌드가 죽은 컨트롤러를 만져 화면이 빈다(자막 작업에서 겪었다).
  final _dialogueField = TextEditingController();

  late final ComicController _controller =
      widget.controller ??
      ComicController(
        gateway: defaultComicGateway(widget.api),
        videoId: widget.video.id,
      );

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    // 빌드 페이즈 밖에서 시작한다.
    Future.microtask(_controller.start);
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    if (widget.controller == null) _controller.dispose();
    _dialogueField.dispose();
    super.dispose();
  }

  Future<void> _editDialogue(int index) async {
    _dialogueField.text = _controller.cuts[index].dialogue ?? '';
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${index + 1}컷 대사'),
        content: TextField(
          key: const ValueKey('comic-dialogue-field'),
          controller: _dialogueField,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(hintText: '들린 그대로 적어 주세요'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, _dialogueField.text),
            child: const Text('넣기'),
          ),
        ],
      ),
    );
    if (text == null || !mounted) return;
    _controller.editDialogue(index, text);
  }

  /// 화면을 PNG로 떠서 공유 시트로 넘긴다. 거기서 '이미지 저장'으로 갤러리에
  /// 들어간다 — 갤러리 전용 플러그인을 새로 넣지 않는다.
  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final boundary =
          _canvasKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) throw StateError('만화 영역을 찾지 못했어요.');
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('이미지로 바꾸지 못했어요.');

      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}${Platform.pathSeparator}comic_${widget.video.id}.png',
      );
      await file.writeAsBytes(data.buffer.asUint8List());

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: '${widget.video.title} 4컷 만화',
        ),
      );
    } catch (failure) {
      if (mounted) showAppSnack(context, '$failure', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('4컷 만화 만들기')),
    body: SafeArea(child: _body()),
  );

  Widget _body() => switch (_controller.state) {
    ComicNeedsTranscript() => const Center(
      child: Padding(
        padding: EdgeInsets.all(28),
        child: Text(
          '대사를 먼저 알아들어야 만화를 만들 수 있어요.\n'
          '영상 편집 화면에서 자막을 한 번 열어 주세요.',
          textAlign: TextAlign.center,
        ),
      ),
    ),
    ComicLoadingScript() => const _Busy('이야기를 짜고 있어요'),
    ComicLoadingImage() => const _Busy('그림을 그리고 있어요'),
    ComicScriptReady(:final cuts) => _cutList(cuts),
    ComicFailed(:final reason, :final cuts) => _failed(reason, cuts),
    ComicReady(:final cuts, :final image) => _finished(cuts, image),
  };

  Widget _cutList(List<ComicCut> cuts, {String? error}) => Column(
    children: [
      if (error != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(error, style: const TextStyle(color: AppColors.coral)),
        ),
      Expanded(
        child: ListView.builder(
          itemCount: cuts.length,
          itemBuilder: (_, index) => ListTile(
            key: ValueKey('comic-cut-$index'),
            leading: Text('${index + 1}컷'),
            title: Text(cuts[index].dialogue ?? '(대사 없음)'),
            subtitle: Text(cuts[index].scene),
            trailing: const Icon(Icons.edit_rounded, size: 18),
            onTap: () => _editDialogue(index),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('comic-make-image'),
            onPressed: _controller.makeImage,
            icon: const Icon(Icons.auto_awesome_rounded),
            label: Text(error == null ? '그림 만들기' : '다시 만들기'),
          ),
        ),
      ),
    ],
  );

  /// 구성이 남아 있으면 목록을 그대로 보여준다 — 고친 대사를 잃지 않는다.
  Widget _failed(String reason, List<ComicCut>? cuts) => cuts == null
      ? Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: EmptyState(
              icon: Icons.cloud_off_rounded,
              title: '만화를 만들지 못했어요',
              message: reason,
              action: FilledButton.icon(
                onPressed: _controller.start,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('다시 시도'),
              ),
            ),
          ),
        )
      : _cutList(cuts, error: reason);

  Widget _finished(List<ComicCut> cuts, Uint8List image) => Column(
    children: [
      Expanded(
        child: Center(
          child: RepaintBoundary(
            key: _canvasKey,
            child: ComicCanvas(image: image, cuts: cuts),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('comic-save'),
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.ios_share_rounded),
            label: Text(_saving ? '저장하는 중이에요' : '만화 저장하기'),
          ),
        ),
      ),
    ],
  );
}

class _Busy extends StatelessWidget {
  const _Busy(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(message),
      ],
    ),
  );
}
```

- [ ] **Step 4: 테스트가 통과하는 것을 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/comic_screen_test.dart
```

기대: 5개 통과.

쓰는 공용 위젯의 서명은 확인해 뒀다:

```dart
void showAppSnack(BuildContext context, String message, {bool error = false})
class EmptyState({required IconData icon, required String title,
                  required String message, Widget? action})
const VideoMemory({required id, deviceId, triggerType, title, status, favorite})
```

- [ ] **Step 5: 커밋**

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/features/comic/comic_screen.dart frontend/test/comic_screen_test.dart
git -C C:\Users\SSAFY\dev\stt-captions commit -m "feat: 4컷 만화 화면

전사문 → 구성 → 대사 수정 → 그림 → 자막 → 저장. 저장은 RepaintBoundary로 화면을
떠서 공유 시트로 넘긴다(새 의존성 없음).

그림 요청이 실패하면 구성 목록을 그대로 보여준다 — 고친 대사를 잃지 않는다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: 진입 버튼과 문서

영상 상세에 버튼을 넣고, 규칙대로 `자료/docs`를 갱신한다.

**Files:**
- Modify: `frontend/lib/ui/content_video_detail_screen.dart`
- Modify: `자료/docs/사람이 읽을 문서/03-기능명세서.md`
- Modify: `자료/docs/ai에게 입력용 문서/03-features.md`

**Interfaces:**
- Consumes: `ComicScreen` (Task 5)
- Produces: 없음 (마지막 배선)

- [ ] **Step 1: 버튼을 넣는다**

`frontend/lib/ui/content_video_detail_screen.dart`의 import에 추가한다:

```dart
import '../features/comic/comic_screen.dart';
```

`_openEditor` 메서드 뒤에 추가한다:

```dart
  Future<void> _openComic() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ComicScreen(api: widget.controller.api, video: _video),
      ),
    );
  }
```

`영상 편집하기` 버튼 뒤에 넣는다:

```dart
                  const SizedBox(height: 10),
                  // 처리가 끝나기 전에는 전사문이 없어 만화를 만들 수 없다.
                  OutlinedButton.icon(
                    key: const ValueKey('open-comic'),
                    onPressed: _video.status == 'READY' ? _openComic : null,
                    icon: const Icon(Icons.auto_stories_rounded),
                    label: const Text('4컷 만화 만들기'),
                  ),
```

> `ui/video_detail_screen.dart`에 넣지 않도록 주의한다 — 거기 `_LegacyVideoDetailScreen`은
> 아무도 부르지 않는 죽은 코드다.

- [ ] **Step 2: 화면이 실제로 도달하는 자리인지 먼저 확인한다**

```bash
grep -rn "ComicScreen(" C:\Users\SSAFY\dev\stt-captions\frontend\lib
```

`content_video_detail_screen.dart`에서 **만드는 곳**이 나와야 한다. 괄호까지 붙여
찾는 이유는 "이름이 나오는 곳"과 "실제로 만드는 곳"을 구분하기 위해서다.

**왜 이걸 먼저 하나**: `dart analyze`도 위젯 테스트도 이 실수를 못 잡는다. 위젯
테스트는 화면을 직접 만들어 검사하므로 죽은 코드에 넣어도 통과한다. 앱을 띄워
눈으로 보는 것 외에는 방법이 없고, 빌드에 몇 분이 걸린다. 이 한 줄이 그 시간을
아낀다.

- [ ] **Step 3: 정적 검사와 전체 테스트**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && dart analyze lib test && flutter test
```

기대: analyze 무경고, 기존 95개 + 새로 만든 34개 전부 통과.

- [ ] **Step 4: 기능명세서에 FN-A40을 넣는다**

`자료/docs/사람이 읽을 문서/03-기능명세서.md`의 **MVP ⑤ 영상 편집** 관련 기능 표에
FN-A39 다음 줄로 추가한다 (앱 max가 FN-A39이므로 새 번호는 FN-A40):

```markdown
| FN-A40 | 4컷 만화 만들기 | 폰+서버 | 자막이 만든 전사문을 서버에 보내 4컷 구성을 받고, 사용자가 대사를 고친 뒤 만화 그림 한 장(2x2 격자)을 받는다. 대사는 영화 자막처럼 각 컷에 앱이 얹고, 완성작은 갤러리에 저장한다 | REQ-F-27 / `POST /api/videos/{id}/comic/script`, `POST /api/videos/{id}/comic/image` |
```

같은 절에 알아둘 점을 덧붙인다:

```markdown
#### FN-A40 알아둘 점

- **전사문(글)만 서버로 보낸다.** 영상·오디오·프레임은 기기를 떠나지 않는다.
- **이미지 생성 키는 서버가 들고 있다.** 앱에 넣으면 APK를 뜯어 가져갈 수 있다.
  서버 통로는 별도 작업이며, 없는 동안 앱은 가짜 응답으로 화면만 동작한다.
- **API를 두 단계로 나눴다.** 구성을 먼저 받아 사용자가 고친 뒤에 그림을 만든다 —
  이미지 생성은 호출마다 돈이 들어서 엉뚱한 구성에 쓰지 않으려는 것이다.
- **그림에 글자도 말풍선도 넣지 않는다.** 대사는 앱이 얹는다. 말풍선 자리가 있으면
  생성 모델이 거기에 글자를 넣는다.
- 만화는 서버나 앱에 보관하지 않는다. 갤러리 저장으로 끝낸다.
- 컷 하나만 다시 그릴 수 없다 — 격자 한 장으로 받기 때문이다.
```

- [ ] **Step 5: 영문판에도 같은 항목을 넣는다**

`자료/docs/ai에게 입력용 문서/03-features.md`의 FN 표에 FN-A39 다음 줄로:

```markdown
| FN-A40 | 4컷 만화 만들기 | `POST /api/videos/{id}/comic/script`, `POST /api/videos/{id}/comic/image` | `features/comic/*`, `ui/content_video_detail_screen.dart`, `core/api_client.dart` | 전사문(글)만 서버로 보냄. 키는 서버 보관. COMIC_SERVER가 없으면 FakeComicGateway |
```

앱 경로 표에도 추가한다:

```markdown
| `features/comic/`(comic_script, comic_gateway, comic_controller, panel_subtitle, comic_screen) | FN-A40 |
```

- [ ] **Step 6: 커밋**

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/ui/content_video_detail_screen.dart "자료/docs"
git -C C:\Users\SSAFY\dev\stt-captions commit -m "feat: 영상 상세에 4컷 만화 버튼, 기능명세서에 FN-A40

버튼은 content_video_detail_screen에 넣는다 — video_detail_screen의
_LegacyVideoDetailScreen은 아무도 부르지 않는 죽은 코드다.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

- [ ] **Step 7: 실기기로 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter run --dart-define=API_BASE_URL=https://i15e201.p.ssafy.io
```

확인할 것 (서버가 없으므로 가짜 응답으로 흐름만 본다):

1. 영상 상세에 **[4컷 만화 만들기]** 버튼이 보인다. 처리 중인 영상에서는 눌리지 않는다
2. 자막을 한 번도 안 만든 영상에서 열면 "대사를 먼저 알아들어야 해요"가 뜬다
3. 자막을 만든 영상에서 열면 4컷 목록(대사·장면)이 뜬다
4. 컷을 눌러 대사를 고치면 목록에 반영된다
5. [그림 만들기]를 누르면 4칸 색 블록 그림이 뜨고 **대사 있는 컷에만** 자막이 얹힌다
6. 자막 위치가 컷과 맞는다 — 1컷 대사가 왼쪽 위, 4컷 대사가 오른쪽 아래
7. [만화 저장하기] → 공유 시트가 열리고 '이미지 저장'으로 갤러리에 들어간다
8. 저장된 PNG에 **자막이 함께** 들어 있다

---

## 서버 쪽에 넘길 것

이 계획은 앱만 다룬다. 서버 통로는 `feat/backend/*` 브랜치에서 만들며, 설계 문서의
**"서버가 지켜야 할 것"** 절을 그대로 옮겨 적으면 된다. 요약하면:

1. 키는 서버에만 둔다
2. 사용자별 호출 횟수를 제한한다
3. 이미지 프롬프트에 글자·말풍선 금지, 인물 일관성, 카메라 UI 금지를 넣는다
4. 장면 묘사에 소리를 언급하지 않는다 — 쓰면 모델이 의성어를 그린다

서버가 준비되면 앱은 `--dart-define=COMIC_SERVER=true`로 켠다.

## 남는 천장

- **격자 정렬을 믿고 자막을 얹는다.** 모델이 2x2를 정확히 그린다는 보장이 없다.
  어긋나면 자막 위치가 틀어지고, 사용자가 다시 만드는 것 외에 대응이 없다
- **그림에 글자가 섞여 나오는 것을 완전히 막을 수 없다.** 프롬프트로 줄일 뿐이다
- 화풍 고르기 UI 없음(요청에는 `style`이 있지만 `webtoon` 고정)
- 만화를 다시 열어 보는 기능 없음 — 갤러리 저장으로 끝낸다
- 컷 하나만 다시 그리기 없음 — 격자 한 장이라 부분 재생성이 안 된다
- 전사문이 부실하면 구성 품질도 그만큼이다 (자막 실측: 2분 영상에 143자)
