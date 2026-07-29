# STT 자동 자막 — 남은 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**브랜치:** `feat/frontend/STT` (base `origin/feat/frontend-app-device`)
**작업트리:** `C:\Users\SSAFY\dev\stt-captions`

**Goal:** 폰에서 전사한 자막을 편집 화면에서 고치고, 저장할 때 영상에 함께 굽는다.

**Architecture:** `features/stt/`가 전사·캐시·자막 편집 UI를 전부 들고 있고, 상대 파일(`local_edit_screen.dart`, `video_exporter.dart`, `MainActivity.kt`)에는 호출 한·두 줄만 들어간다. 자막은 기존 `exportWithTrim` 한 패스에서 Media3 `OverlayEffect`로 함께 구워진다.

## 이미 끝난 것

이 브랜치에 다음이 들어와 있고 테스트 30개가 통과한다 (`frontend/test/stt_test.dart`).

| 파일 | 하는 일 |
|---|---|
| `features/stt/pcm_wav.dart` | 16비트 PCM WAV 파싱 |
| `features/stt/speech_analysis.dart` | 발화 구간 검출(RMS + 스펙트럼 평탄도), 리샘플·슬라이스·인코딩 |
| `features/stt/android_audio.dart` | 영상 → 16kHz 모노 WAV (MediaCodec) |
| `features/stt/whisper_transcriber.dart` | whisper.cpp 전사, 발화 구간만 이어붙여 처리량 절감 |
| `features/stt/caption_line.dart` | `CaptionLine`, `captionAt`, `captionsForExport` |
| `features/stt/transcript_store.dart` | videoId 캐시 + 백그라운드 작업 |
| `android/.../SttChannel.kt`, `AudioDecoder.kt` | 네이티브 오디오 추출 |
| `docs/whisper-model.md` | 모델을 만들고 기기에 넣는 절차 — **모델 파일은 저장소에 없다** |

상대 파일 접촉은 지금까지 **두 줄**이다 — `MainActivity.kt`에 `SttChannel.register(flutterEngine)` 한 줄, `pubspec.yaml`에 `whisper_ggml_plus` 한 줄.

## Global Constraints

- **영상 가공은 폰에서만 한다.** 오디오도 전사문도 외부 서버로 보내지 않는다.
- **상대 파일은 한·두 줄만 건드린다.** 새 로직은 전부 `features/stt/` 안의 새 파일에 넣는다. 나중에 `feat/frontend-app-device`에 합칠 때 충돌 지점을 줄이기 위한 규칙이다.
- **`core/`는 손대지 않는다.** `CaptionLine`이 `video_edit_state.dart`가 아니라 `features/stt/`에 있는 이유다.
- **새 pub 의존성을 추가하지 않는다.** `whisper_ggml_plus`는 이미 넣었다. 나머지는 이미 있는 `media3-effect:1.9.2` / `media3-transformer:1.9.2`만 쓴다.
- **실패는 항상 강등한다.** 전사가 실패해도 사용자는 자르기·저장을 그대로 할 수 있어야 한다. 어느 단계도 화면을 막지 않는다.
- ASCII 경로여야 Gradle이 빌드한다. `flutter analyze`는 이 환경에서 죽으므로 `dart analyze`를 쓴다.
- 커밋 메시지는 한국어로 쓰고 `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`를 붙인다. **푸시하지 않는다.**
- **테스트 통과 기준:** `widget_test.dart: 로컬 Banuba 토큰 설정을 자동으로 불러온다` 1개는 원래 실패한다 (gitignore된 `assets/config/banuba.local.json`이 없어서). **이 1개 외에 전부 통과해야 한다.**

---

### Task 1: Banuba 자막 시험 키 기본값 제거

`_captionsApiKey`에 시험용 키가 기본값으로 박혀 있다. 누가 `enableAiCaptions: true`로 바꾸기만 하면 오디오가 `internal.transcribe.banuba.net`으로 나간다 — 우리가 온디바이스로 만든 이유가 무너진다.

**Files:**
- Modify: `frontend/lib/core/banuba_video_editor.dart` (자막 상수 4개)
- Test: `frontend/test/banuba_captions_gate_test.dart` (create)

**Interfaces:**
- Consumes: 없음
- Produces: `BanubaVideoEditor.isAiCaptionsConfigured` — dart-define이 없으면 항상 `false`

- [ ] **Step 1: 실패하는 테스트를 쓴다**

```dart
/// Banuba 자동 자막은 오디오를 Banuba 서버로 올린다. 온디바이스 원칙에 어긋나므로
/// dart-define 없이는 절대 켜지지 않아야 한다.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/banuba_video_editor.dart';

void main() {
  test('dart-define이 없으면 AI 자막 설정이 갖춰지지 않은 것으로 본다', () {
    expect(BanubaVideoEditor().isAiCaptionsConfigured, isFalse);
  });

  test('AI 자막을 켜달라고 하면 거절한다', () async {
    await expectLater(
      BanubaVideoEditor().edit(
        sourcePaths: const ['/does/not/matter.mp4'],
        outputName: 'x',
        enableAiCaptions: true,
      ),
      throwsA(isA<BanubaEditorException>()),
    );
  });
}
```

- [ ] **Step 2: 실패를 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/banuba_captions_gate_test.dart
```

기대: 첫 테스트가 `Expected: false / Actual: true`로 실패.

- [ ] **Step 3: 기본값을 없앤다**

`frontend/lib/core/banuba_video_editor.dart`의 자막 상수 네 개를 바꾼다:

```dart
  // 기본값을 두지 않는다. Banuba 자동 자막은 오디오를 자기 서버로 올리므로
  // 온디바이스 원칙에 어긋난다. 값이 없으면 isAiCaptionsConfigured가 거짓이 되어
  // 실수로 켜지지 않는다. 자막은 features/stt가 직접 만들고 굽는다.
  static const _captionsApiKey = String.fromEnvironment('BANUBA_CAPTIONS_API_KEY');
  static const _captionsApiV2Key = String.fromEnvironment(
    'BANUBA_CAPTIONS_API_V2_KEY',
  );
  static const _captionsUploadUrl = String.fromEnvironment(
    'BANUBA_CAPTIONS_UPLOAD_URL',
  );
  static const _captionsTranscribeUrl = String.fromEnvironment(
    'BANUBA_CAPTIONS_TRANSCRIBE_URL',
  );
```

- [ ] **Step 4: 통과를 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/banuba_captions_gate_test.dart
```

기대: 2개 통과.

- [ ] **Step 5: 커밋**

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/core/banuba_video_editor.dart frontend/test/banuba_captions_gate_test.dart
git -C C:\Users\SSAFY\dev\stt-captions commit -m "fix: Banuba 자막 시험 키 기본값 제거 — 실수로 켜면 오디오가 외부로 나간다

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: CaptionController — 자막 상태를 한 곳에

전사 시작, 결과 보관, 사용자 수정, 내보내기 변환을 한 클래스가 들고 있는다. 화면은 이걸 만들고 부르기만 한다 — 그래야 상대 파일에 로직이 안 들어간다.

**Files:**
- Create: `frontend/lib/features/stt/caption_controller.dart`
- Test: `frontend/test/caption_controller_test.dart`

**Interfaces:**
- Consumes: `transcriptStore.ensure` / `TranscriptJobState` / `CaptionLine` / `captionAt` / `captionsForExport` (모두 이미 있음)
- Produces:
  - `CaptionController({TranscriptStore? store}) extends ChangeNotifier`
  - `void start(String videoId, String videoPath)` — 전사를 시작한다. 두 번 불러도 한 번만 돈다
  - `List<CaptionLine> get lines`
  - `TranscriptJobState? get status`
  - `bool get hasUserEdits` — 화면이 `hasUnsavedChanges`에 반영한다
  - `void edit(int index, String text)`
  - `String? textAt(int positionMs)`
  - `List<Map<String, Object>> forExport({required int startMs, required int endMs})`
  - `String message({int? estimateSeconds})` — 패널 맨 위 한 줄

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`frontend/test/caption_controller_test.dart`:

```dart
/// CaptionController 회귀 테스트.
/// 화면은 이 클래스를 부르기만 한다. 상태 전이와 안내 문구가 여기서 다 결정되므로
/// 화면을 띄우지 않고 전부 검증할 수 있다.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/stt/caption_controller.dart';
import 'package:william_james_app/features/stt/caption_line.dart';
import 'package:william_james_app/features/stt/transcript_store.dart';

List<CaptionLine> _lines() => [
  CaptionLine(startMs: 1000, endMs: 3000, text: '그거 만지지 마'),
  CaptionLine(startMs: 5000, endMs: 7000, text: '안 만졌는데요'),
];

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('caption-controller-');
  });

  tearDown(() async {
    if (temporary.existsSync()) await temporary.delete(recursive: true);
  });

  TranscriptStore storeWith(VideoTranscriber transcriber) => TranscriptStore(
    transcriber: transcriber,
    root: () async => temporary,
  );

  CaptionController controllerWith(VideoTranscriber transcriber) =>
      CaptionController(store: storeWith(transcriber));

  test('시작 전에는 상태가 없고 줄도 없다', () {
    final subject = controllerWith((_) async => _lines());
    expect(subject.status, isNull);
    expect(subject.lines, isEmpty);
    expect(subject.message(), contains('준비'));
  });

  test('전사가 끝나면 줄이 들어오고 알림이 간다', () async {
    final store = storeWith((_) async => _lines());
    final subject = CaptionController(store: store);
    var notified = 0;
    subject.addListener(() => notified++);

    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    expect(subject.lines, hasLength(2));
    expect(subject.status, isA<TranscriptReady>());
    expect(notified, greaterThan(0));
    expect(subject.message(), contains('2줄'));
  });

  test('두 번 시작해도 전사는 한 번만 돈다', () async {
    var calls = 0;
    final store = storeWith((_) async {
      calls++;
      return _lines();
    });
    final subject = CaptionController(store: store);

    subject.start('v1', '/video/v1.mp4');
    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    expect(calls, 1);
  });

  test('전사가 실패해도 줄은 비고 상태만 실패가 된다', () async {
    final store = storeWith((_) async => throw StateError('모델 없음'));
    final subject = CaptionController(store: store);

    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    expect(subject.lines, isEmpty);
    expect(subject.status, isA<TranscriptFailed>());
    expect(subject.message(), contains('알아듣지 못했'));
  });

  test('도는 중이면 예상 시간을 알려준다', () async {
    final store = storeWith((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return _lines();
    });
    final subject = CaptionController(store: store);

    subject.start('v1', '/video/v1.mp4');

    expect(subject.message(estimateSeconds: 108), contains('108초'));
    expect(subject.message(), isNot(contains('초')));
    await store.pending;
  });

  test('사용자가 고치면 hasUserEdits가 켜지고 알림이 간다', () async {
    final store = storeWith((_) async => _lines());
    final subject = CaptionController(store: store);
    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    expect(subject.hasUserEdits, isFalse);
    var notified = 0;
    subject.addListener(() => notified++);

    subject.edit(0, '그거 만지면 안 돼');

    expect(subject.lines[0].text, '그거 만지면 안 돼');
    expect(subject.hasUserEdits, isTrue);
    expect(notified, 1);
  });

  test('없는 번호를 고치라고 해도 죽지 않고 수정으로 세지 않는다', () async {
    final store = storeWith((_) async => _lines());
    final subject = CaptionController(store: store);
    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    subject.edit(9, '아무거나');

    expect(subject.lines, hasLength(2));
    expect(subject.hasUserEdits, isFalse);
  });

  test('textAt과 forExport는 현재 줄을 그대로 쓴다', () async {
    final store = storeWith((_) async => _lines());
    final subject = CaptionController(store: store);
    subject.start('v1', '/video/v1.mp4');
    await store.pending;

    expect(subject.textAt(2000), '그거 만지지 마');
    final exported = subject.forExport(startMs: 4000, endMs: 10000);
    expect(exported, hasLength(1));
    expect(exported.single['startMs'], 1000);
  });
}
```

- [ ] **Step 2: 실패를 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/caption_controller_test.dart
```

기대: 컴파일 실패 — `caption_controller.dart`가 없다.

- [ ] **Step 3: 구현한다**

`frontend/lib/features/stt/caption_controller.dart`:

```dart
/// 자막 상태를 한 곳에 모은다 — 전사 시작, 보관, 수정, 내보내기 변환.
///
/// **왜 컨트롤러인가**: 편집 화면(`local_edit_screen.dart`)은 다른 사람이 계속
/// 고치는 파일이다. 자막 로직을 그 안에 넣으면 나중에 합칠 때 충돌한다. 화면은
/// 이 클래스를 만들고 부르기만 하게 둔다.
library;

import 'package:flutter/foundation.dart';

import 'caption_line.dart';
import 'transcript_store.dart';

class CaptionController extends ChangeNotifier {
  CaptionController({TranscriptStore? store})
    : _store = store ?? transcriptStore;

  final TranscriptStore _store;

  ValueListenable<TranscriptJobState>? _job;
  List<CaptionLine> _lines = <CaptionLine>[];
  bool _hasUserEdits = false;

  List<CaptionLine> get lines => _lines;

  TranscriptJobState? get status => _job?.value;

  /// 사용자가 자막을 고쳤는가. 화면이 이 값을 편집 상태의
  /// `hasUnsavedChanges`에 반영한다 — 전사 결과가 들어온 것만으로는 켜지지
  /// 않아야 한다(화면을 열자마자 폐기 경고가 뜨면 안 된다).
  bool get hasUserEdits => _hasUserEdits;

  /// 전사를 시작한다. 캐시가 있으면 즉시 끝난다. 두 번 불러도 한 번만 돈다.
  void start(String videoId, String videoPath) {
    if (_job != null) return;
    _job = _store.ensure(videoId, videoPath)..addListener(_onJobChanged);
    _onJobChanged();
  }

  void _onJobChanged() {
    final state = _job?.value;
    if (state is TranscriptReady) _lines = state.lines;
    notifyListeners();
  }

  void edit(int index, String text) {
    if (index < 0 || index >= _lines.length) return;
    _lines[index].text = text;
    _hasUserEdits = true;
    notifyListeners();
  }

  String? textAt(int positionMs) => captionAt(_lines, positionMs);

  List<Map<String, Object>> forExport({
    required int startMs,
    required int endMs,
  }) => captionsForExport(_lines, startMs: startMs, endMs: endMs);

  /// 패널 맨 위 한 줄. 실패해도 자르기·저장은 되어야 하므로 그렇게 안내한다.
  String message({int? estimateSeconds}) {
    final state = status;
    if (state is TranscriptFailed) {
      return '대사를 알아듣지 못했어요. 자막 없이 저장할 수 있어요.';
    }
    if (state is TranscriptRunning) {
      return estimateSeconds == null
          ? '대사를 알아듣고 있어요.'
          : '대사를 알아듣고 있어요. 약 $estimateSeconds초 걸려요.';
    }
    if (state == null) return '자막을 준비하고 있어요.';
    if (_lines.isEmpty) {
      return '대사를 알아듣지 못했어요. 자막 없이 저장할 수 있어요.';
    }
    return '자막 ${_lines.length}줄이에요. 눌러서 고칠 수 있어요.';
  }

  @override
  void dispose() {
    _job?.removeListener(_onJobChanged);
    super.dispose();
  }
}
```

- [ ] **Step 4: 통과를 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/caption_controller_test.dart
```

기대: 8개 통과.

- [ ] **Step 5: 커밋**

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/features/stt/caption_controller.dart frontend/test/caption_controller_test.dart
git -C C:\Users\SSAFY\dev\stt-captions commit -m "feat: 자막 상태를 CaptionController 한 곳에 모은다

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: 자막 시트에 넣을 자동 자막 섹션

상대는 자막을 **하단 시트**(`_showCaptionEditor`)로 만들었다 — 입력칸 하나, 색 4개, [자막 적용] 버튼. 그 시트의 `Column` children에 **우리 섹션 하나만 끼운다.** 목록과 수정 다이얼로그를 섹션이 스스로 들고 있어야 상대 파일에 로직이 안 들어간다.

**Files:**
- Create: `frontend/lib/features/stt/caption_auto_section.dart`
- Test: `frontend/test/caption_auto_section_test.dart`

**Interfaces:**
- Consumes: `CaptionController` (Task 2)
- Produces:
  - `CaptionAutoSection({required CaptionController controller, int? estimateSeconds, VoidCallback? onChanged})` — 시트 안에 들어가는 `Column` 조각
  - `String? autoCaptionAt(CaptionController controller, int positionMs)` — 미리보기가 쓸 한 줄

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`frontend/test/caption_auto_section_test.dart`:

```dart
/// 자동 자막 섹션 위젯 테스트.
/// 수정 다이얼로그를 섹션이 직접 들고 있으므로 편집 화면 없이 여기서 검증된다.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/features/stt/caption_auto_section.dart';
import 'package:william_james_app/features/stt/caption_controller.dart';
import 'package:william_james_app/features/stt/caption_line.dart';
import 'package:william_james_app/features/stt/transcript_store.dart';

void main() {
  late Directory temporary;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('caption-section-');
  });

  tearDown(() async {
    if (temporary.existsSync()) await temporary.delete(recursive: true);
  });

  Future<CaptionController> readyWith(List<CaptionLine> lines) async {
    final store = TranscriptStore(
      transcriber: (_) async => lines,
      root: () async => temporary,
    );
    final controller = CaptionController(store: store);
    controller.start('v1', '/video/v1.mp4');
    await store.pending;
    return controller;
  }

  Future<CaptionController> ready() => readyWith([
    CaptionLine(startMs: 1000, endMs: 3000, text: '그거 만지지 마'),
    CaptionLine(startMs: 5000, endMs: 7000, text: '안 만졌는데요'),
  ]);

  Future<void> pumpSection(
    WidgetTester tester,
    CaptionController controller, {
    VoidCallback? onChanged,
    int? estimateSeconds,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              CaptionAutoSection(
                controller: controller,
                onChanged: onChanged,
                estimateSeconds: estimateSeconds,
              ),
            ],
          ),
        ),
      ),
    ),
  );

  testWidgets('줄마다 한 행씩 보여준다', (tester) async {
    await pumpSection(tester, await ready());
    await tester.pump();

    expect(find.text('그거 만지지 마'), findsOneWidget);
    expect(find.text('안 만졌는데요'), findsOneWidget);
  });

  testWidgets('행을 눌러 고치면 목록에 반영되고 onChanged가 불린다', (tester) async {
    var changed = 0;
    await pumpSection(tester, await ready(), onChanged: () => changed++);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('auto-caption-row-0')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('auto-caption-field')),
      '그거 만지면 안 돼',
    );
    await tester.tap(find.text('넣기'));
    await tester.pumpAndSettle();

    expect(find.text('그거 만지면 안 돼'), findsOneWidget);
    expect(find.text('그거 만지지 마'), findsNothing);
    expect(changed, 1);
  });

  testWidgets('취소하면 아무것도 바뀌지 않는다', (tester) async {
    var changed = 0;
    await pumpSection(tester, await ready(), onChanged: () => changed++);
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('auto-caption-row-0')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    expect(find.text('그거 만지지 마'), findsOneWidget);
    expect(changed, 0);
  });

  testWidgets('줄이 없으면 목록 없이 안내만 보여준다', (tester) async {
    await pumpSection(tester, await readyWith(const []));
    await tester.pump();

    expect(find.textContaining('알아듣지 못했'), findsOneWidget);
    expect(find.byKey(const ValueKey('auto-caption-row-0')), findsNothing);
  });

  testWidgets('도는 중이면 예상 시간을 보여준다', (tester) async {
    final store = TranscriptStore(
      transcriber: (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 80));
        return const <CaptionLine>[];
      },
      root: () async => temporary,
    );
    final controller = CaptionController(store: store);
    controller.start('v1', '/video/v1.mp4');

    await pumpSection(tester, controller, estimateSeconds: 108);
    await tester.pump();

    expect(find.textContaining('108초'), findsOneWidget);
    await store.pending;
  });

  test('autoCaptionAt은 그 시각의 줄만 돌려준다', () async {
    final controller = await ready();
    expect(autoCaptionAt(controller, 2000), '그거 만지지 마');
    expect(autoCaptionAt(controller, 4000), isNull);
  });
}
```

- [ ] **Step 2: 실패를 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/caption_auto_section_test.dart
```

기대: 컴파일 실패 — `caption_auto_section.dart`가 없다.

- [ ] **Step 3: 구현한다**

`frontend/lib/features/stt/caption_auto_section.dart`:

```dart
/// 자막 시트에 끼우는 자동 자막 섹션.
///
/// **왜 섹션인가**: 상대가 만든 자막 하단 시트(`_showCaptionEditor`)에는 직접
/// 타이핑하는 입력칸과 색 선택이 이미 있다. 그 아래에 이 섹션 하나만 끼우면
/// "직접 쓰는 자막"과 "알아서 만들어지는 자막"이 한 화면에서 이어진다.
/// 수정 다이얼로그를 섹션이 직접 들고 있어서 상대 파일에는 위젯 호출만 남는다.
library;

import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import 'caption_controller.dart';

/// 미리보기가 쓸 한 줄. 상대 미리보기 위젯에 넘길 값을 만든다.
String? autoCaptionAt(CaptionController controller, int positionMs) =>
    controller.textAt(positionMs);

class CaptionAutoSection extends StatefulWidget {
  const CaptionAutoSection({
    super.key,
    required this.controller,
    this.estimateSeconds,
    this.onChanged,
  });

  final CaptionController controller;

  /// 전사가 도는 중일 때 보여줄 예상 시간. 모르면 null.
  final int? estimateSeconds;

  /// 사용자가 자막을 고쳤을 때. 화면이 "저장 안 된 변경"으로 표시한다.
  final VoidCallback? onChanged;

  @override
  State<CaptionAutoSection> createState() => _CaptionAutoSectionState();
}

class _CaptionAutoSectionState extends State<CaptionAutoSection> {
  /// 입력칸 컨트롤러는 이 위젯이 소유한다 — 다이얼로그마다 만들어 닫힌 직후
  /// dispose하면 리빌드가 죽은 컨트롤러를 만져 화면이 빈다.
  final _field = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _field.dispose();
    super.dispose();
  }

  Future<void> _edit(int index) async {
    _field.text = widget.controller.lines[index].text;
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${index + 1}번째 자막'),
        content: TextField(
          key: const ValueKey('auto-caption-field'),
          controller: _field,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '들린 그대로 적어 주세요'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, _field.text.trim()),
            child: const Text('넣기'),
          ),
        ],
      ),
    );
    if (text == null || text.isEmpty) return;
    widget.controller.edit(index, text);
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.controller.lines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 24),
        Row(
          children: [
            const Icon(Icons.auto_awesome_rounded, size: 16),
            const SizedBox(width: 6),
            Text(
              '들린 대사로 자동 자막',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          widget.controller.message(estimateSeconds: widget.estimateSeconds),
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
        if (lines.isNotEmpty) ...[
          const SizedBox(height: 8),
          // 시트가 화면을 다 먹지 않게 높이를 묶는다.
          SizedBox(
            height: 148,
            child: ListView.builder(
              itemCount: lines.length,
              itemBuilder: (_, index) => InkWell(
                key: ValueKey('auto-caption-row-$index'),
                onTap: () => _edit(index),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 52,
                        child: Text(
                          _clock(lines[index].startMs),
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      Expanded(child: Text(lines[index].text)),
                      const Icon(Icons.edit_rounded, size: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _clock(int milliseconds) {
    final value = Duration(milliseconds: milliseconds);
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
```

- [ ] **Step 4: 통과를 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/caption_auto_section_test.dart
```

기대: 6개 통과.

- [ ] **Step 5: 커밋**

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/features/stt/caption_auto_section.dart frontend/test/caption_auto_section_test.dart
git -C C:\Users\SSAFY\dev\stt-captions commit -m "feat: 자막 시트에 넣을 자동 자막 섹션

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: 편집 화면에 훅을 끼운다

여기가 상대 파일을 건드리는 지점이다. 로직은 Task 2·3에 있으므로 호출만 넣는다.

**Files:**
- Modify: `frontend/lib/ui/local_edit_screen.dart` (일곱 지점)
- Test: 없음 (로직이 없다). Task 5의 실기기 확인으로 검증한다

**Interfaces:**
- Consumes: `CaptionController` (Task 2), `CaptionAutoSection` / `autoCaptionAt` (Task 3)
- Produces: 없음

- [ ] **Step 1: import와 필드 (3줄)**

import 두 줄:

```dart
import '../features/stt/caption_auto_section.dart';
import '../features/stt/caption_controller.dart';
```

`_LocalEditScreenState`의 `Color _captionColor = AppColors.cream;` 아래 한 줄:

```dart
  final _autoCaptions = CaptionController();
```

- [ ] **Step 2: 다운로드 직후 전사를 시작한다 (2줄)**

`_prepare()`의 `setState` 블록 안, 미리보기를 넣은 뒤에:

```dart
        // 영상이 기기에 내려온 직후 한 번. 캐시가 있으면 즉시 끝난다.
        _autoCaptions.start(widget.video.id, sourcePath);
```

- [ ] **Step 3: dispose에 한 줄**

`dispose()`의 `super.dispose()` 앞:

```dart
    _autoCaptions.dispose();
```

- [ ] **Step 4: 자막 시트에 섹션을 끼운다 (6줄)**

`_showCaptionEditor()`의 `Column` children에서 `_SheetApplyButton` **앞에** 넣는다:

```dart
              CaptionAutoSection(
                controller: _autoCaptions,
                // whisper는 진행률을 주지 않는다. 영상 길이에 실측 비율을 곱해
                // 대략만 알려준다 (갤럭시 S24에서 약 0.9배).
                estimateSeconds: _editState.durationMs > 0
                    ? (_editState.durationMs / 1000 * 0.9).round()
                    : null,
                // 자막 수정도 저장 안 된 변경이다.
                onChanged: () =>
                    setState(() => _editState.markExternalEditApplied()),
              ),
```

> 시트는 `StatefulBuilder` 안이라 `setSheetState`가 있지만, 섹션은 자기 컨트롤러를
> 듣고 스스로 다시 그린다. 여기서 `setSheetState`를 부를 필요가 없다.

- [ ] **Step 5: 미리보기에 자동 자막을 넘긴다 (5줄)**

상대 미리보기 위젯은 `captionText`/`captionColor`를 받아 화면 아래에 그린다. 자동 자막을 같은 스타일로 보여주려면 파라미터 하나를 더한다.

미리보기 위젯의 생성자와 필드에:

```dart
    this.autoCaptionText,
```
```dart
  final String? autoCaptionText;
```

`if (captionText.isNotEmpty)` 블록 **뒤에** 같은 모양으로 하나 더 넣는다. 손 자막이 없을 때만 그린다 — 둘이 겹치면 읽을 수 없다:

```dart
                    if (captionText.isEmpty &&
                        (autoCaptionText?.isNotEmpty ?? false))
                      Align(
                        alignment: const Alignment(0, 0.74),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 16),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            autoCaptionText!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: captionColor,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              shadows: const [
                                Shadow(color: Colors.black, blurRadius: 3),
                              ],
                            ),
                          ),
                        ),
                      ),
```

호출부(미리보기를 만드는 곳, `captionText: _captionText,` 옆)에 한 줄:

```dart
                      autoCaptionText: autoCaptionAt(
                        _autoCaptions,
                        (_preview?.value.position.inMilliseconds) ?? 0,
                      ),
```

- [ ] **Step 6: 저장할 때 자막을 넘긴다 (5줄)**

`_saveEdit()`의 `exportEditedVideo` 호출에서 `captionText:` 옆에:

```dart
        // 자른 구간 밖은 버리고 시각을 클립 기준으로 옮긴다. 전사가 실패했으면
        // 빈 목록이 되어 종전과 똑같이 저장된다.
        captions: _autoCaptions.forExport(
          startMs: _editState.startMs,
          endMs: _editState.endMs,
        ),
```

> 이 인자는 Task 5에서 만든다. 이 줄만 마지막에 넣는다.

- [ ] **Step 7: 정적 검사**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && dart analyze lib
```

기대: Step 6의 `captions:` 인자만 오류로 남는다 (Task 5에서 만든다). 그 외 무경고.

- [ ] **Step 8: 커밋** (Task 5와 함께 커밋해도 된다)

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/ui/local_edit_screen.dart
git -C C:\Users\SSAFY\dev\stt-captions commit -m "feat: 자막 시트에 자동 자막 섹션 연결, 미리보기에 겹쳐 보여준다

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: 내보내기에 시각 자막을 얹는다

상대가 이미 오버레이 목록을 만들어 뒀다:

```kotlin
val overlays = mutableListOf<TextureOverlay>()
if (captionText.isNotBlank()) { overlays.add(...) }   // 손 자막
if (arSticker.isNotBlank())   { overlays.add(...) }   // AR 스티커
if (overlays.isNotEmpty()) { videoEffects.add(OverlayEffect(overlays)) }
```

**우리는 `overlays.add(...)`를 한 번 더 하면 된다.** 인코딩은 그대로 한 번이다.

**빠른 경로를 막아야 한다.** "자르기가 없으면 파일을 그대로 복사한다"는 분기가 있으면 자막이 있을 때 그리로 가면 안 된다. 상대 코드에 그 분기가 남아 있는지 확인하고, 있으면 조건을 더한다.

**Files:**
- Modify: `frontend/lib/core/video_exporter.dart` (인자 1줄 + 맵 1줄)
- Create: `frontend/android/app/src/main/kotlin/com/williamjames/william_james_app/SubtitleOverlay.kt`
- Modify: `frontend/android/app/src/main/kotlin/com/williamjames/william_james_app/MainActivity.kt` (네 지점, 각 1~3줄)
- Test: `frontend/test/video_exporter_captions_test.dart` (create)

**Interfaces:**
- Consumes: `CaptionController.forExport` (Task 2)
- Produces:
  - `VideoEditorExporter.exportEditedVideo({..., List<Map<String, Object>> captions = const []})`
  - Kotlin `exportWithTrim` args에 `segments: List<Map>` — 각 항목 `{startMs: Int, endMs: Int, text: String}`
  - Kotlin `SubtitleOverlay.of(rawSegments, color): TextureOverlay?` — 쓸 자막이 없으면 null

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`frontend/test/video_exporter_captions_test.dart`:

```dart
/// 내보내기가 네이티브에 넘기는 자막 인자 모양을 고정한다.
/// Kotlin이 startMs/endMs/text 키를 그대로 읽으므로 이름이 바뀌면 조용히 자막이
/// 빠진 영상이 나온다.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:william_james_app/core/video_exporter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.williamjames/video_canvas');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'exportWithTrim' ? '/out/edited.mp4' : null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('자동 자막을 주면 segments로 넘긴다', () async {
    await VideoEditorExporter().exportEditedVideo(
      inputPath: '/in/event.mp4',
      outputPath: '/out/edited.mp4',
      startMs: 0,
      endMs: 10000,
      aspectRatio: 16 / 9,
      captions: const [
        {'startMs': 1000, 'endMs': 3000, 'text': '그거 만지지 마'},
      ],
    );

    final args = calls.single.arguments as Map;
    final first = (args['segments'] as List).single as Map;
    expect(first['startMs'], 1000);
    expect(first['endMs'], 3000);
    expect(first['text'], '그거 만지지 마');
  });

  test('자동 자막이 없으면 빈 목록을 넘긴다 — 손 자막 경로가 종전대로 동작한다', () async {
    await VideoEditorExporter().exportEditedVideo(
      inputPath: '/in/event.mp4',
      outputPath: '/out/edited.mp4',
      startMs: 0,
      endMs: 0,
      aspectRatio: 16 / 9,
      captionText: '손으로 쓴 자막',
    );

    final args = calls.single.arguments as Map;
    expect(args['segments'], isEmpty);
    expect(args['captionText'], '손으로 쓴 자막');
  });
}
```

- [ ] **Step 2: 실패를 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/video_exporter_captions_test.dart
```

기대: 컴파일 실패 — `captions` 인자가 없다.

- [ ] **Step 3: Dart 쪽에 인자를 더한다**

`frontend/lib/core/video_exporter.dart`의 `exportEditedVideo` 서명에서 `String captionText = '',` 옆에:

```dart
    // 이미 클립 기준으로 옮겨진 목록을 받는다 (caption_line.dart의
    // captionsForExport 참조). 기본값을 둬서 기존 호출부가 그대로 동작한다.
    List<Map<String, Object>> captions = const [],
```

같은 메서드의 `invokeMethod` 인자 맵에서 `'captionText': captionText,` 옆에:

```dart
      'segments': captions,
```

- [ ] **Step 4: 통과를 확인한다**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter test test/video_exporter_captions_test.dart
```

기대: 2개 통과.

- [ ] **Step 5: 오버레이를 우리 Kotlin 파일에 만든다**

`frontend/android/app/src/main/kotlin/com/williamjames/william_james_app/SubtitleOverlay.kt`:

```kotlin
package com.williamjames.william_james_app

import android.graphics.Typeface
import android.text.Spannable
import android.text.SpannableString
import android.text.style.AbsoluteSizeSpan
import android.text.style.BackgroundColorSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.OverlaySettings
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TextOverlay
import androidx.media3.effect.TextureOverlay

/**
 * 시각마다 글이 바뀌는 자동 자막 오버레이.
 *
 * MainActivity에 코드를 늘리지 않으려고 여기에 모았다 — 저쪽에는 [of] 호출과
 * `overlays.add` 한 줄만 들어간다.
 *
 * 스타일과 자리는 손 자막(captionText)과 같게 맞췄다. 사용자가 보기에 자막이
 * 두 종류로 보이면 안 된다.
 *
 * 넘어오는 시각은 이미 잘린 클립 기준이다 (Dart의 captionsForExport가 옮겨
 * 준다). 시작 포함·끝 제외로 판정한다 — Dart의 captionAt과 같은 규칙이라야
 * 미리보기와 저장된 영상이 일치한다.
 */
@UnstableApi
object SubtitleOverlay {
    /** 쓸 만한 자막이 없으면 null — 호출부가 아무것도 추가하지 않는다. */
    fun of(rawSegments: List<Map<String, Any?>>, color: Int): TextureOverlay? {
        val cues = rawSegments.mapNotNull { entry ->
            val text = entry["text"] as? String ?: return@mapNotNull null
            val from = (entry["startMs"] as? Number)?.toLong() ?: return@mapNotNull null
            val to = (entry["endMs"] as? Number)?.toLong() ?: return@mapNotNull null
            if (text.isBlank() || to <= from) null
            else Cue(from * 1000, to * 1000, text)
        }
        if (cues.isEmpty()) return null
        return TimedText(cues, color)
    }

    private data class Cue(val startUs: Long, val endUs: Long, val text: String)

    private class TimedText(
        private val cues: List<Cue>,
        private val color: Int,
    ) : TextOverlay() {
        // 손 자막과 같은 자리 (MainActivity의 -0.72f).
        private val settings = StaticOverlaySettings.Builder()
            .setBackgroundFrameAnchor(0f, -0.72f)
            .build()

        override fun getText(presentationTimeUs: Long): SpannableString {
            val hit = cues.firstOrNull {
                presentationTimeUs >= it.startUs && presentationTimeUs < it.endUs
            }
            val span = SpannableString(hit?.text ?: "")
            if (span.isNotEmpty()) {
                // 손 자막과 같은 스타일 (색·배경·크기 54·굵게).
                span.setSpan(
                    ForegroundColorSpan(color),
                    0,
                    span.length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
                span.setSpan(
                    BackgroundColorSpan(0x99000000.toInt()),
                    0,
                    span.length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
                span.setSpan(
                    AbsoluteSizeSpan(54),
                    0,
                    span.length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
                span.setSpan(
                    StyleSpan(Typeface.BOLD),
                    0,
                    span.length,
                    Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
            }
            return span
        }

        override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings =
            settings
    }
}
```

- [ ] **Step 6: MainActivity에 네 지점만 고친다**

`"exportWithTrim"` 분기에서 `segments`를 읽는다 (`captionText`를 읽는 줄 옆, 두 줄):

```kotlin
                val segments = call.argument<List<Map<String, Any?>>>("segments")
                    ?: emptyList()
```

같은 분기의 `exportTrimmedVideo(...)` 호출 인자에 `segments`를 `result` 앞에 끼운다 (한 줄).

`exportTrimmedVideo`의 서명에 한 줄 (`arSticker: String,` 옆):

```kotlin
        rawSegments: List<Map<String, Any?>>,
```

오버레이 목록에 한 줄 — `if (arSticker.isNotBlank()) { ... }` 블록 **뒤**, `if (overlays.isNotEmpty())` **앞**:

```kotlin
        // 자동 자막. 손 자막이 없을 때만 얹는다 — 둘이 같은 자리라 겹치면 읽을 수 없다.
        if (captionText.isBlank()) {
            SubtitleOverlay.of(rawSegments, captionColor)?.let(overlays::add)
        }
```

- [ ] **Step 7: 빠른 경로를 확인한다**

`exportTrimmedVideo` 안에 "자르기가 없으면 그대로 복사"하는 분기가 남아 있는지 본다:

```bash
cd C:\Users\SSAFY\dev\stt-captions && grep -n "copyTo" frontend/android/app/src/main/kotlin/com/williamjames/william_james_app/MainActivity.kt
```

나오면 그 `if` 조건에 `&& overlays.isEmpty()`에 해당하는 조건을 더한다 — 자막이 있으면 복사로 빠질 수 없다. 안 나오면 상대가 이미 없앤 것이므로 넘어간다.

- [ ] **Step 8: 빌드와 전체 테스트**

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && dart analyze lib test && flutter test && flutter build apk --debug
```

기대: analyze 무경고, 테스트는 `widget_test.dart: 로컬 Banuba 토큰` 1개만 실패, APK 빌드 성공.

- [ ] **Step 9: 실기기로 확인한다**

모델이 에셋에 들어 있으므로 추가 인자가 필요 없다:

```bash
cd C:\Users\SSAFY\dev\stt-captions\frontend && flutter run --dart-define=API_BASE_URL=https://i15e201.p.ssafy.io
```

첫 실행 때 에셋을 앱 폴더로 복사한다. 로그에 `[stt] 모델을 에셋에서 복사했습니다
(175209680바이트)`가 한 번 뜨고, 두 번째 실행부터는 안 뜬다.

확인할 것:

1. 편집 화면을 열고 자막 도구를 누르면 시트에 상대 입력칸 + 아래에 "대사를 알아듣고 있어요. 약 n초 걸려요"가 보인다
2. 로그에 `[stt] whisper` 줄이 뜨고 줄 수가 나온다
3. 전사가 끝나면 "자막 n줄이에요"로 바뀌고 목록이 보인다
4. 목록이 나와도 시트가 화면을 다 먹지 않는다 (높이 148이 적당한지 눈으로 본다)
5. 재생하면 미리보기 아래쪽에 시각에 맞는 자막이 바뀌며 보인다
6. 한 줄을 눌러 고치면 목록과 미리보기에 즉시 반영된다
7. 손 자막을 입력하면 자동 자막이 사라지고 손 자막만 보인다 (겹치지 않는다)
8. 자막을 고친 뒤 뒤로 가려 하면 저장 경고가 뜬다
9. **자르지 않고** 저장 → 갤러리 영상에 시각별 자막이 박혀 있고 길이가 원본과 같다
10. **잘라서** 저장 → 자막이 밀리지 않는다. **밀리면 `caption_line.dart`의 `captionsForExport`만 고친다** (Media3가 자른 클립에 주는 `presentationTimeUs` 기준이 예상과 다른 경우다)
11. 손 자막만 넣고 저장하면 종전과 똑같이 동작한다 (우리 변경이 기존 기능을 깨지 않았다)
12. 전사가 끝나기 전에 저장해도 자막 없이 정상 저장된다
13. 앱을 지우고 다시 깔면 캐시가 없어 다시 전사한다

- [ ] **Step 10: 커밋**

```bash
git -C C:\Users\SSAFY\dev\stt-captions add frontend/lib/core/video_exporter.dart frontend/android/app/src/main/kotlin frontend/test/video_exporter_captions_test.dart
git -C C:\Users\SSAFY\dev\stt-captions commit -m "feat: 내보내기에 시각 자막을 얹는다 (손 자막과 같은 스타일)

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---
## 합칠 때

이 브랜치가 상대 파일에 남기는 것은 다음뿐이다. 나중에 `feat/frontend-app-device`가 진행한 뒤 합칠 때 볼 곳이 여기밖에 없다.

| 파일 | 남기는 것 |
|---|---|
| `pubspec.yaml` | `whisper_ggml_plus` 한 줄 |
| `MainActivity.kt` | `SttChannel.register` 한 줄 + `exportTrimmedVideo` 네 지점 |
| `local_edit_screen.dart` | import 2줄, 필드 1줄, 호출 5지점 (시트 섹션·미리보기 파라미터·저장 인자) |
| `video_exporter.dart` | 인자 1줄 + 맵 1줄 |
| `banuba_video_editor.dart` | 자막 상수 4개의 기본값 제거 |
| `pubspec.lock` | 생성 파일 — 충돌하면 `flutter pub get`으로 다시 만든다 |

합치기 전에 `git rebase origin/feat/frontend-app-device`를 먼저 돌려 우리 쪽에서 충돌을 흡수한다. 상대 브랜치를 우리 커밋으로 어지럽히지 않는 편이 리뷰가 쉽다.

**상대가 자막을 계속 손보는 중이다.** `3c8e91c "프론트 중간"`이 손 자막(한 줄 직접 입력 + 색)과 AR 스티커를 넣었고, 우리는 그 위에 시각 자막을 얹는 구조를 골랐다. 저쪽이 자막 UI를 또 바꾸면 Task 4의 지점이 움직인다 — 작업을 시작하기 전에 `git log origin/feat/frontend-app-device`를 한 번 보고, `_showCaptionEditor`와 미리보기 위젯이 그대로인지 확인한다.

## 남는 천장

- 앱을 완전히 닫으면 전사가 중단되고 다음에 처음부터 돈다 (전경 서비스 없음)
- whisper가 실시간과 비슷한 속도다. 10분 영상이면 10분 대기다
- whisper 모델(167MiB)이 저장소와 APK에 들어 있다. 저장소가 그만큼 커졌고 히스토리에 영구히 남는다. 설치 용량도 늘어난다 — 줄이려면 첫 사용 시 내려받는 경로가 필요하다 (`docs/whisper-model.md`)
- 에셋 복사가 167MiB를 한 번에 메모리에 올린다. 저사양 기기에서 문제가 되면 네이티브 `AssetManager` 스트리밍이 필요하다
- 자막 글자 크기·위치는 `SubtitleOverlay`에 고정값이다. 실기기에서 눈으로 맞춘다
- 미리보기 겹쳐보기와 실제 굽기가 서로 다른 코드다(Flutter 글자 / Android Spannable). 크기·여백이 완전히 같지는 않다
- 줄 추가·삭제, 시각 조절, 화자 구분, 번역, SRT 내보내기 없음
- **손 자막과 자동 자막을 동시에 못 쓴다.** 둘이 화면 같은 자리(anchor -0.72)를 쓰므로 손 자막이 있으면 자동 자막을 안 그린다. 같이 쓰게 하려면 자리를 나눠야 한다
- 자막 색은 상대 시트의 색 선택을 그대로 따른다. 자동 자막만 다른 색으로 두는 기능은 없다
- 4컷 만화는 이 브랜치에 없다. 나중에 붙일 때 `CaptionLine`을 `TranscriptSegment`로 옮기는 어댑터가 필요하다 (신뢰도는 가정값 0.7 — `confidenceFloor` 0.55를 넘겨야 대사가 인용된다)
