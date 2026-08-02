/// videoId로 찾는 자막 캐시.
///
/// **왜 필요한가**: 전사는 서버의 Gemini 호출이다 — 돈이고 네트워크다. 같은
/// 영상을 열 때마다 또 부르면 안 되니 한 번 받은 결과를 파일로 남긴다.
///
/// 실제 전사는 주입받은 [VideoTranscriber] 하나에 맡긴다. 이 클래스는 파일
/// 입출력과 작업 중복 방지만 한다 — 그래야 whisper 없이 테스트할 수 있다.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/api_client.dart';
import 'android_audio.dart';
import 'caption_line.dart';
import 'transcript_api.dart';
import 'whisper_model.dart';
import 'whisper_transcriber.dart';

/// 영상 파일 경로를 받아 자막 줄을 돌려준다. 실패하면 던진다.
typedef VideoTranscriber = Future<List<CaptionLine>> Function(String videoPath);

sealed class TranscriptJobState {
  const TranscriptJobState();
}

/// 돌고 있다. 진행률은 없다 — whisper가 중간 상황을 알려주지 않는다.
/// 화면은 자기가 아는 영상 길이로 예상 시간을 계산해 보여준다.
class TranscriptRunning extends TranscriptJobState {
  const TranscriptRunning();
}

class TranscriptReady extends TranscriptJobState {
  const TranscriptReady(this.lines);
  final List<CaptionLine> lines;
}

class TranscriptFailed extends TranscriptJobState {
  const TranscriptFailed(this.reason, {this.retryable = false});
  final String reason;

  /// 다시 불러 보면 달라질 수 있는 실패인가. 연결·인증·서버 오류·시간 초과가
  /// 그렇고, "발화가 없다"(빈 결과)는 아니다 — 같은 영상은 몇 번을 불러도 조용하다.
  /// 화면은 이 값으로 안내 문구와 [CaptionController.retry] 버튼을 가른다.
  final bool retryable;
}

class TranscriptStore {
  TranscriptStore({
    required this.transcriber,
    required this.root,
    this.serverBuild = transcriptServerReady,
  });

  final VideoTranscriber transcriber;

  /// 서버 전사 빌드인가. 견본(가짜) 전사로 만든 캐시를 무시하고 다시 받기 위해
  /// 필요하다 — 기본값은 빌드 스위치고, 테스트만 직접 넣는다.
  final bool serverBuild;

  /// 자막을 둘 폴더. 임시 폴더가 아니라 **영구 저장소**여야 한다 — 시스템이
  /// 정리해 가면 캐시가 매번 날아간다.
  final Future<Directory> Function() root;

  /// 도는 중인 작업. 같은 videoId로 두 번 부르면 같은 것을 돌려준다.
  ///
  /// ponytail: 앱이 살아있는 동안 계속 쌓인다. 한 번 실행에서 여는 영상 수만큼
  /// 이라 문제되지 않는다. 영상을 수백 개 넘기게 되면 LRU로 자른다.
  final _jobs = <String, ValueNotifier<TranscriptJobState>>{};

  /// 테스트가 완료를 기다릴 수 있게 마지막 작업 Future를 남긴다.
  @visibleForTesting
  Future<void>? pending;

  Future<File> _file(String videoId) async {
    final directory = await root();
    await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}$videoId.json');
  }

  /// 캐시된 자막. 없거나 읽을 수 없으면 null — 호출부는 다시 전사한다.
  Future<List<CaptionLine>?> read(String videoId) async {
    try {
      final file = await _file(videoId);
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(await file.readAsString()) as Map;
      // 견본 전사로 만든 캐시를 서버 빌드가 물려받으면 안 된다. 그대로 두면
      // 스위치를 켜도 영영 다시 받지 않고, 만화(API-71)까지 지어낸 대사로 만든다.
      // source가 없는 옛 캐시도 여기서 걸린다 — 버리고 다시 받으면 그만이다.
      if (serverBuild && decoded['source'] != 'server') {
        debugPrint('[stt] 견본으로 만든 자막 캐시를 버립니다($videoId). 다시 받습니다.');
        return null;
      }
      final raw = decoded['lines'] as List;
      return [
        for (final entry in raw)
          CaptionLine(
            startMs: (entry as Map)['startMs'] as int,
            endMs: entry['endMs'] as int,
            text: entry['text'] as String,
          ),
      ];
    } catch (error) {
      // 깨진 파일로 화면을 막지 않는다. 다시 전사하면 된다.
      debugPrint('[stt] 자막 캐시를 읽지 못했습니다($videoId): $error');
      return null;
    }
  }

  Future<void> write(String videoId, List<CaptionLine> lines) async {
    final file = await _file(videoId);
    await file.writeAsString(
      jsonEncode({
        'version': 1,
        // 어디서 온 자막인지 남긴다. 견본과 진짜를 파일만 보고 구별할 수 있어야
        // 스위치를 켠 빌드가 견본 캐시를 걸러낼 수 있다([read]).
        'source': serverBuild ? 'server' : 'sample',
        'lines': [
          for (final line in lines)
            {'startMs': line.startMs, 'endMs': line.endMs, 'text': line.text},
        ],
      }),
    );
  }

  /// 캐시가 있으면 즉시 완료 상태로, 없으면 백그라운드 전사를 시작한다.
  ValueListenable<TranscriptJobState> ensure(String videoId, String videoPath) {
    final existing = _jobs[videoId];
    if (existing != null) return existing;

    final job = ValueNotifier<TranscriptJobState>(const TranscriptRunning());
    _jobs[videoId] = job;
    pending = _run(videoId, videoPath, job);
    return job;
  }

  Future<void> _run(
    String videoId,
    String videoPath,
    ValueNotifier<TranscriptJobState> job,
  ) async {
    try {
      final cached = await read(videoId);
      if (cached != null && cached.isNotEmpty) {
        debugPrint('[stt] 자막 캐시 적중($videoId) 줄=${cached.length}');
        job.value = TranscriptReady(cached);
        return;
      }
      // 서버 전사는 videoId로 부른다 — 원본이 서버에 이미 있어 경로가 필요 없다.
      // videoPath 매개변수는 남겨 둔다: 호출부(caption_controller → ensure)를
      // 건드리지 않기 위해서고, 온디바이스 경로(transcribeVideo)가 코드에 남아
      // 있어 되돌릴 때 다시 쓴다.
      final fresh = await transcriber(videoId);
      if (fresh.isEmpty) {
        // 빈 결과를 저장하면 캐시 적중으로 보여 영구히 재시도가 막힌다.
        _jobs.remove(videoId);
        job.value = const TranscriptFailed('대사를 알아듣지 못했어요.');
        return;
      }
      await write(videoId, fresh);
      job.value = TranscriptReady(fresh);
    } catch (error, stack) {
      // 사유를 반드시 남긴다. 상태만 바꾸면 화면에는 "못 알아들었어요" 한 줄만
      // 뜨고, 진짜 무발화인지 서버가 죽은 것인지 구분할 수 없다.
      debugPrint('[stt] 전사 실패 ${error.runtimeType}: $error');
      debugPrint(
        '[stt] 스택: ${stack.toString().split('\n').take(3).join(' | ')}',
      );
      // 실패는 캐시하지 않는다 — 다음에 다시 부르면 재시도해야 한다.
      _jobs.remove(videoId);
      // 던져진 실패는 전부 "다시 해 볼 수 있는" 쪽이다. 무발화만이 다시 불러도
      // 같은 결과인데, 그쪽은 위에서 이미 처리했다(빈 결과).
      job.value = TranscriptFailed('$error', retryable: true);
    }
  }
}

/// 자막 캐시를 둘 폴더. 한 곳에서만 만든다 — 배선할 때마다 같은 폴더여야
/// 이전에 받아 둔 자막을 계속 쓴다.
Future<Directory> captionsDirectory() async {
  final documents = await getApplicationDocumentsDirectory();
  return Directory('${documents.path}${Platform.pathSeparator}captions');
}

/// 앱 전체가 쓰는 하나의 저장소.
///
/// 앱은 Riverpod을 쓰지 않으므로 전역 하나로 둔다. 시작할 때
/// [wireTranscriptStore]가 진짜 통로로 교체하고, 테스트는 이 값을 직접
/// 갈아끼운다.
TranscriptStore transcriptStore = TranscriptStore(
  transcriber: _unwiredTranscriber,
  root: captionsDirectory,
);

/// 배선 전에 전사를 부르면 크게 실패한다. 여기서 조용히 가짜를 돌려주면 서버
/// 빌드에서 지어낸 대사가 진짜처럼 영상에 구워진다 — 그게 훨씬 나쁘다.
Future<List<CaptionLine>> _unwiredTranscriber(String videoId) async =>
    throw StateError('자막 통로가 배선되지 않았습니다. wireTranscriptStore(api)를 먼저 부르세요.');

/// 앱이 쓰는 [ApiClient] **하나**를 자막 통로에 연결한다. 시작할 때 한 번 부른다.
///
/// **여기서 `ApiClient()`를 새로 만들면 안 된다.** 토큰은 클라이언트 인스턴스에
/// 붙어 있다:
/// - "로그인 유지"를 끄면 `_saveSession(persistSession: false)`가 저장소 키를
///   **지우고** 토큰을 메모리에만 둔다. 두 번째 클라이언트는 헤더를 못 붙여
///   401이 되고, 갱신 토큰도 없어 그 사용자는 자막을 아예 쓰지 못한다.
/// - 켜 두더라도 먼저 갱신한 쪽이 토큰을 회전시키면, 다른 쪽은 자기 메모리의
///   낡은 토큰을 우선 쓰다가 갱신에 실패해 `clearSession()`으로 간다 — 사용자가
///   편집 도중 로그아웃된다. 단일 실행 가드(`_refreshFuture`)도 인스턴스마다
///   따로라 서로를 막지 못한다.
///
/// [transcriberFor]는 테스트 자리다. 기본 빌드는 `COMIC_SERVER`가 꺼져 있어
/// [defaultTranscriber]가 가짜를 고르고, 그러면 "넘겨준 클라이언트로 갔는가"를
/// 확인할 수 없다.
void wireTranscriptStore(
  ApiClient api, {
  VideoTranscriber Function(ApiClient api) transcriberFor = defaultTranscriber,
}) {
  transcriptStore = TranscriptStore(
    transcriber: transcriberFor(api),
    root: captionsDirectory,
  );
}

/// 영상에서 16kHz 모노 WAV를 뽑아 whisper에 넘긴다. WAV는 쓰고 지운다.
Future<List<CaptionLine>> transcribeVideo(String videoPath) async {
  final temporary = await getTemporaryDirectory();
  final directory = Directory(
    '${temporary.path}${Platform.pathSeparator}stt',
  );
  await directory.create(recursive: true);
  final wavPath = '${directory.path}${Platform.pathSeparator}audio_16k.wav';

  // 모델을 먼저 확보한다 — 에셋에서 복사하거나 dart-define 경로를 쓴다.
  final modelPath = await resolveWhisperModel();
  await AndroidAudioExtractor().toPcmWav16k(videoPath, wavPath);
  try {
    return await WhisperTranscriber(modelPath: modelPath).transcribe(wavPath);
  } finally {
    final wav = File(wavPath);
    if (wav.existsSync()) await wav.delete();
  }
}
